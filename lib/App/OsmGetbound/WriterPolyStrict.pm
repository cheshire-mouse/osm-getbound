package App::OsmGetbound::WriterPolyStrict;

# ABSTRACT:  writing polygons in POLY format

# $Id$

use 5.010;
use strict;
use warnings;
use autodie;
use utf8;

use Carp;
use Log::Any qw($log);


=head1 SYNOPSIS

    App::OsmGetbound::WriterPolyStrict->new()->save( $filename, $name, \@contours );

=cut

=method new

Constructor.

    my $writer = App::OsmGetbound::WriterPolyStrict->new();

=cut

sub new { return bless {}, shift() }


=func save

    $writer->save( $filename, $name, \@contours );

Save data in POLY format. Writes to STDOUT if $filename is '-' or not defined.

=cut

sub save {
    my ($self, $outfile, $name, $contours) = @_;

    $name ||= 'unknown';

    my $need_to_open = defined $outfile && length $outfile && $outfile ne q{-};
    my $out = $need_to_open
        ? do { open my $fh, '>', $outfile; $fh }
        : *STDOUT;
    _write_poly($out, $name, $contours);
    close $out  if $need_to_open;
    return;
}


=func _write_poly (internal)
=cut

sub _write_poly {
    my ($out, $name, $contours) = @_;

    print {$out} "$name\n";

    my $num = 1;

    for my $item ( @$contours ) {
        my ($ring, $is_inner) = @$item;
        
        print {$out} ( $is_inner ? q{!} : q{}) . $num++ . "\n";
        for my $point ( @$ring ) {
            printf {$out} "   %-11s  %-11s\n", @$point;
        }
        print {$out} "END\n";
    }

    print {$out} "END\n";

    return;
}


1;

