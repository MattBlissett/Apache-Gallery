package Apache::Gallery::Templates::TextTemplate;

# $Id$

use strict;
use vars qw($VERSION);
$VERSION = sprintf "%d.%02d", (split /\./, (qq$Revision$ =~ /([\d\.]+)/)[0]);

package Apache::Gallery::Templates;

use strict;
use Text::Template qw(fill_in_file);

