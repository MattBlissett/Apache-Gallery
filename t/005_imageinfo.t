use Data::Dumper;
BEGIN {
  $tests=1;
  eval { require Apache::FakeRequest; };
  if ($@) {
    print("1..$tests\n");
    for (1..$tests) {
      print ("ok $_ # skip Apache::FakeRequest not found\n");
    }
    exit 0;
  }
}
use Test::More tests => $tests;
use Apache::FakeRequest;

use Apache::Gallery;

my $request = Apache::FakeRequest->new('get_remote_host' => 'localhost');

my $info = Apache::Gallery::get_imageinfo($request, "t/005_jpg.jpg", "JPG", 15, 11);

is ( $info->{Comment}, "Created with The GIMP", 'Comment');
