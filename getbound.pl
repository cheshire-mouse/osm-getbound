#!/usr/bin/perl

# ABSTRACT: save osm boundary to .poly file

# $Id$


use 5.010;
use strict;
use warnings;
use utf8;
use autodie;

#use lib 'lib';

use Carp;
use Log::Any qw/$log/;
use Log::Any::Adapter 0.11 ('Stderr');

use FindBin qw{ $Bin };
use lib "$Bin/lib";

use Getopt::Long;
use List::Util qw{ min max sum };
use List::MoreUtils qw{ first_index none notall };
use File::Slurp;

use YAML;

use Math::Polygon;
use Math::Polygon::Tree 0.061 qw/ :all /;

use App::OsmGetbound::OsmData;
use App::OsmGetbound::OsmApiClient;
use App::OsmGetbound::RelAlias;

use Math::Clipper;
use Math::Clipper qw{ CT_UNION CT_DIFFERENCE PFT_NONZERO };
use Math::Round qw{ nearest };

####    Settings

my %api_opt = (
    api => $ENV{GETBOUND_API} || 'osm',
);

our %WRITER = (
    poly => 'App::OsmGetbound::WriterPoly',
    'poly-strict' => 'App::OsmGetbound::WriterPolyStrict',
    shp  => 'App::OsmGetbound::WriterShp',
);



####    Command-line

my $writer_name;
GetOptions (
    'h|help!'   => \my $show_help,
    'api=s'     => \$api_opt{api},
    'singlerequest!' => \my $singlerequest,
    'file=s'    => \my $filename,
    'srcout=s'  => \my $srcoutfile,
    'o=s'       => \my $outfile,
    'onering!'  => \my $onering,
    'clip!'     => \my $clip,
    'noinner!'  => \my $noinner,
    'proxy=s'   => \$api_opt{proxy},
    'aliases=s' => \my $alias_config,
    'aliasesdir=s' => \my $alias_dir,
    'writer=s'  => \$writer_name,
    'om=s'      => sub { my $m = $_[1]; my $w = $WRITER{$m}; croak "Unknown mode: $m" if !$w; $writer_name = $w; },
    'offset|buffer=f' => \my $offset,
) or die "Invalid options";

if ( !@ARGV or $show_help) {
    print "Usage:  getbound.pl [options] <relation> [<relation> ...]\n\n";
    print "relation - id or alias\n\n";
    print "Available options:\n";
    print "     -h|help            - show this message\n";
    print "     -api <api>         - api to use (@{[ sort keys %App::OsmGetbound::OsmApiClient::API ]})\n";
    print "     -singlerequest     - download relations in a single request\n                          (overpass only)\n";
    print "     -file <file>       - use local OSM dump as input\n";
    print "     -srcout <file>     - save OSM xml into file\n";
    print "                          (works for single relation or\n";
    print "                          for single request mode)\n";
    print "     -o <file>          - output filename (default: STDOUT)\n";
    print "     -onering           - merge rings (connect into one line)\n";
    print "     -clip              - clip (union) rings\n";
    print "     -noinner           - exclude inner rings from processing\n";
    print "     -proxy <host>      - use proxy\n";
    print "     -aliases <file>    - file, containing aliases for relation IDs,\n";
    print "                          alias can union several ids, negative ids \n";
    print "                          will be substructed from the bound, \n";
    print "                          for example:\n";
    print "                              myalias1: 12345\n";
    print "                              myalias2: [12345, 12346, -12347]\n";
    print "                          (default: ./etc/osm-getbound-aliases.yml)\n";
    print "     -aliasesdir <directory>\n                        - directory, containing alias files (*.yml)\n";
    print "     -writer <name>     - writer to use\n";
    print "     -om <output mode>  - output mode (writer's alias):\n";
    print "                          [poly|poly-strict|shp]\n";
    print "     -offset|buffer <N> - enlarge resulting area by moving bound N degrees\n\n";
    exit 1;
}


####    Writer

$writer_name ||= $WRITER{poly};
eval "require $writer_name; 1" or die $@;
my $writer = $writer_name->new();


####    Aliases
my $alias = App::OsmGetbound::RelAlias->new($alias_config);

if (defined $alias_dir){
    $log->notice("Processing aliases directory");
    opendir(my $DIR_ALIASES, $alias_dir) or die $!;
    my @files = sort readdir($DIR_ALIASES);
    while (my $fl_alias = shift @files ){ 
        next if ( -d  $fl_alias);
        next unless ( $fl_alias =~ /\.yml$/);
        $log->notice("\t$fl_alias");
        $alias->append("$alias_dir/$fl_alias");
    }
    closedir($DIR_ALIASES);
}


####    Process

my @rel_ids = map { my $al = $alias->get_id($_); ref $al ? @$al : ($al) } @ARGV;
croak "Unknown alias"  if notall {defined} @rel_ids;
# mark negative ids as a "holes", they will be substructed from the polygon
my %rel_ids_holes=();
for my $id (@rel_ids){
    if ($id < 0) {
        $id = -$id;
        $rel_ids_holes{$id} = 1;
    }
}

my %valid_role = (
    ''          => 'outer',
    'outer'     => 'outer',
    'border'    => 'outer',
    'exclave'   => 'outer',
    'inner'     => 'inner',
    'enclave'   => 'inner',
);


# getting and parsing
my $osm = App::OsmGetbound::OsmData->new();
if ( $filename ) {
    $log->notice( "Reading file $filename" );
    my $xml = read_file $filename;
    $osm->load($xml);
}
else {
    my $api = App::OsmGetbound::OsmApiClient->new(%api_opt);
    my $xml;
    if ( $singlerequest and $api_opt{api} ne 'osm' ) {
        $log->notice("Downloading relations=@rel_ids");
        $xml = $api->get_object( relation => \@rel_ids, 'full' );
        $osm->load($_)  for @{ ref $xml ? $xml : [$xml] };
    }
    else {
        for my $id ( @rel_ids ) {
            $log->notice("Downloading relation ID=$id");
            my @id_ar = ($id);
            $xml = $api->get_object( relation => \@id_ar, 'full' );
            $osm->load($_)  for @{ ref $xml ? $xml : [$xml] };
        }
    }
    if ( $srcoutfile ) {
        write_file( $srcoutfile, {binmode=>':utf8'}, $xml );
    }
}


# connecting rings: outers are counterclockwise!
$log->notice( "Creating polygons" );

# contours are arrays [ \@chain, $is_inner, $is_hole ]
my @contours;

for my $rel_id ( @rel_ids ) {
    my $relation = $osm->{relations}->{$rel_id};
    my $is_hole = exists $rel_ids_holes{$rel_id};
    my $invert = (not($clip) and $is_hole);
    my %ring;

    for my $member ( @{ $relation->{member} } ) {
        next unless $member->{type} eq 'way';
        my $role = $valid_role{ $member->{role} }  or next;
    
        my $way_id = $member->{ref};
        if ( !exists $osm->{chains}->{$way_id} ) {
            $log->warn( "Incomplete data: way $way_id is missing" );
            next;
        }

        push @{ $ring{$role} },  [ @{ $osm->{chains}->{$way_id} } ];
    }

    while ( my ( $type, $list_ref ) = each %ring ) {
        while ( @$list_ref ) {
            my @chain = @{ shift @$list_ref };
        
            if ( $chain[0] eq $chain[-1] ) {
                my @contour = map { $osm->{nodes}->{$_} } @chain;
                my $order = 0 + Math::Polygon::Calc::polygon_is_clockwise(@contour);
                state $desired_order = { outer => 0, inner => 1 };
                push @contours, [
                    (($order == $desired_order->{$type}) xor $invert)? \@contour : [reverse @contour],
                     (($type eq 'inner') xor $invert), $is_hole
                ];
                next;
            }

            my $pos = first_index { $chain[0] eq $_->[0] } @$list_ref;
            if ( $pos > -1 ) {
                shift @chain;
                $list_ref->[$pos] = [ (reverse @chain), @{$list_ref->[$pos]} ];
                next;
            }
            $pos = first_index { $chain[0] eq $_->[-1] } @$list_ref;
            if ( $pos > -1 ) {
                shift @chain;
                $list_ref->[$pos] = [ @{$list_ref->[$pos]}, @chain ];
                next;
            }
            $pos = first_index { $chain[-1] eq $_->[0] } @$list_ref;
            if ( $pos > -1 ) {
                pop @chain;
                $list_ref->[$pos] = [ @chain, @{$list_ref->[$pos]} ];
                next;
            }
            $pos = first_index { $chain[-1] eq $_->[-1] } @$list_ref;
            if ( $pos > -1 ) {
                pop @chain;
                $list_ref->[$pos] = [ @{$list_ref->[$pos]}, reverse @chain ];
                next;
            }
            $log->error( "Invalid data: ring is not closed" );

            $log->debug( "Non-connecting chain:\n" . Dump( \@chain ) );
            exit 1;
        }
    }
}

if ( !@contours || none { !$_->[1] } @contours ) {
    $log->error( "Invalid data: no outer rings" );
    exit 1;
}


# outers first
# todo: second sort by area
@contours = sort { $a->[1] <=> $b->[1] || $#{$b->[0]} <=> $#{$a->[0]} } @contours;

# clip contours
if ( $clip ) {
    $log->notice( "Clipping polygons" );
    my @polys_subj_unpacked = ();
    my @polys_clip_unpacked = ();
    for my $item ( @contours ) {
        my ($ch, $is_inner, $is_hole) = @$item;
        my @chunpacked = ();
        foreach my $pnt (@$ch) {
            push ( @chunpacked, [ @{$pnt} ] );
        }
        if ( $is_hole ) {
            push ( @polys_clip_unpacked, [ @chunpacked ] );
        }
        else {
            push ( @polys_subj_unpacked, [ @chunpacked ] );
        }
    }

    my $clipper = Math::Clipper->new();
    my $scales = Math::Clipper::integerize_coordinate_sets(@polys_subj_unpacked,@polys_clip_unpacked);
    $clipper->add_subject_polygons([@polys_subj_unpacked]);
    $clipper->add_clip_polygons([@polys_clip_unpacked]);
    my @polysclipped = @{ $clipper->execute(CT_DIFFERENCE,PFT_NONZERO,PFT_NONZERO) } ;
    Math::Clipper::unscale_coordinate_sets( $scales, [@polysclipped] );
    # workaround for int <-> float casting issues
    for my $ring ( @polysclipped ) { 
        for my $point ( @$ring ) { 
            @$point = map { nearest(0.0000000001,$_) } @$point;
        }
    }

    @contours =
        sort { $a->[1] <=> $b->[1] || $#{$b->[0]} <=> $#{$a->[0]} }
        map {[ $_, Math::Polygon::Calc::polygon_is_clockwise(@$_) ]}
        map {[@$_, $_->[0]]}
        @polysclipped;
}


##  Offset
if ( defined $offset ) {
    require Math::Clipper;

    $log->notice( "Calculating buffer" );
    my $ofs_contours = Math::Clipper::offset( [ map { $_->[0] } @contours ], $offset, 1000/$offset );

    @contours =
        sort { $a->[1] <=> $b->[1] || $#{$b->[0]} <=> $#{$a->[0]} }
        map {[ $_, Math::Polygon::Calc::polygon_is_clockwise(@$_) ]}
        map {[@$_, $_->[0]]}
        @$ofs_contours;
}



##  Merge rings
if ( $onering ) {
    $log->notice( "Merging rings" );

    my $first_item = shift @contours;
    my @ring = @{ $first_item->[0] };

    while ( @contours ) {
        my ($add_contour, $is_inner) = @{ shift @contours };
        next if $noinner && $is_inner;

        # find close[st] points
        my $ring_center = polygon_centroid( \@ring );

        if ( $is_inner ) {
            my ( $index_i, $dist ) = ( 0, metric( $ring_center, $ring[0] ) );
            for my $i ( 1 .. $#ring ) {
                my $tdist = metric( $ring_center, $ring[$i] );
                next if $tdist >= $dist;
                ( $index_i, $dist ) = ( $i, $tdist );
            }
            $ring_center = $ring[$index_i];
        }

        @contours = sort { 
                    metric( $ring_center, polygon_centroid($a->[0]) ) <=>
                    metric( $ring_center, polygon_centroid($b->[0]) )
                } @contours;

        my $add_center = polygon_centroid( $add_contour );

        my ( $index_r, $dist ) = ( 0, metric( $add_center, $ring[0] ) );
        for my $i ( 1 .. $#ring ) {
            my $tdist = metric( $add_center, $ring[$i] );
            next if $tdist >= $dist;
            ( $index_r, $dist ) = ( $i, $tdist );
        }

        ( my $index_a, $dist ) = ( 0, metric( $ring[$index_r], $add_contour->[0] ) );
        for my $i ( 1 .. $#$add_contour ) {
            my $tdist = metric( $ring[$index_r], $add_contour->[$i] );
            next if $tdist >= $dist;
            ( $index_a, $dist ) = ( $i, $tdist );
        }

        # merge
        splice @ring, $index_r, 0, (
            $ring[$index_r],
            @$add_contour[ $index_a .. $#$add_contour-1 ],
            @$add_contour[ 0 .. $index_a-1 ],
            $add_contour->[$index_a],
        );
    }

    @contours = ( [ \@ring, 0 ] );
}




##  Output
$log->notice( "Writing" );

my $name = 'Relation ' . join q{+}, @rel_ids;
$writer->save($outfile, $name, \@contours);

$log->notice( "All Ok" );
exit;



sub metric {
    my ($p1, $p2) = @_;

    my ($x1, $y1, $x2, $y2) = map {@$_} map { ref $_ ? $_ : $osm->{nodes}->{$_} } ($p1, $p2);
    confess Dump \@_ if !defined $y2;
    return (($x2-$x1)*cos( ($y2+$y1)/2/180*3.14159 ))**2 + ($y2-$y1)**2;
}




