package Apache::Gallery::Templates;

# $Id$

use strict;
use vars qw($VERSION);

$VERSION = sprintf "%d.%02d", (split /\./, (qq$Revision$ =~ /([\d\.]+)/)[0]);

sub new {
    my $class = shift;

		my $obj = {};

    return bless { $obj }, $class;
}

