use Test::More tests => 4;
use Apache::Gallery;
use Image::Size qw(imgsize);

Apache::Gallery::resizepicture('t/002_inpng.png', 't/inpng-resized.png', 10, 10, 0, '');
Apache::Gallery::resizepicture('t/002_injpg.jpg', 't/injpg-resized.jpg', 10, 10, 0, '');
my ($pngwidth, $pngheight)=imgsize('t/inpng-resized.png');
my ($jpgwidth, $jpgheight)=imgsize('t/injpg-resized.jpg');

is  ($pngwidth, 10, 'PNG Width') or diag('You need to install libpng before libimlib');
is  ($pngheight, 10, 'PNG Height') or diag('You need to install libpng before libimlib');
is  ($jpgwidth, 10, 'JPG Width') or diag('You need to install libjpeg before libimlib');
is  ($jpgheight, 10, 'JPG Height') or diag('You need to install libjpeg before libimlib');

unlink('t/inpng-resized.png');
unlink('t/injpg-resized.jpg');
