use Data::Dumper;

use Test::More tests => 1;
use Apache::FakeRequest;

use Apache::Gallery;

my $request = Apache::FakeRequest->new('get_remote_host' => 'localhost');

my $info = Apache::Gallery::get_imageinfo($request, "t/005_jpg.jpg", "JPG", 15, 11);

is ( $info->{Comment}, "Created with The GIMP", 'Comment');
