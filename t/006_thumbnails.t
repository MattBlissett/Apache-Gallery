use Apache::Gallery;
my $tests =0;
BEGIN {
	$tests = 4;
	eval { require Test::MockObject; };
	if ($@) {
		print ("1..$tests\n");
		for (1..$tests) {
			print "ok $_ # skip because Test::MockObject not found\n";
		}
		exit 0;
	}
}
use Test::More tests => $tests;

my $r = Test::MockObject->new();

$r->set_always('dir_config', '100x75');

my ($width, $height) = Apache::Gallery::get_thumbnailsize($r, 640, 480);
is ($width, 100, 'Width');
is ($height, 75, 'Height');

($width, $height) = Apache::Gallery::get_thumbnailsize($r, 480, 640);
is ($width, 75, 'Height rotated');
is ($height, 100, 'Width rotated');

