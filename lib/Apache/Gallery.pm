package Apache::Gallery;

# $Id: Gallery.pm,v 1.18 2001/10/14 16:26:28 mil Exp $

use 5.006;
use strict;
use warnings;

use vars qw($VERSION);

$VERSION = "0.2";

use Apache();
use Apache::Constants qw(:common);
use Apache::Request();

use Image::Info qw(image_info);
use DB_File;
use CGI::FastTemplate;

use Inline C => Config => 
				LIBS => '-L/usr/X11R6/lib -lImlib2 -lttf -lm -ldl -lXext -lXext',
				DIRECTORY => '/usr/local/apache/Inline',
				ENABLE    => 'UNTAINT';

use Inline 'C';
Inline->init;

sub handler {

	my $r = shift or Apache->request();

	if ($r->header_only) {
		$r->send_http_header;
		return OK;
	}

	my $apr = Apache::Request->instance($r, DISABLE_UPLOADS => 1, POST_MAX => 1024);

	if ($r->uri =~ m/(^\/icons|\.css$|\.cache)/) {
		return DECLINED;
	}

	$r->content_type('text/html');
	$r->send_http_header;

	my $uri = $r->uri;
	$uri =~ s/\/$//;

	my $subr = $r->lookup_uri($r->uri);
	my $filename = $subr->filename;

	unless (-f $filename or -d $filename) {
	
		show_error($r, "404!", "No such file or directory: ".$r->uri);
		return OK;
	}

	if (-d $filename) {

		unless (-d $filename."/.cache") {
			unless (mkdir ($filename."/.cache", 0777)) {
				show_error($r, $!, "Unable to create .cache dir in $filename: $!");
				return OK;
			}
		}

		my $tpl = new CGI::FastTemplate($r->dir_config('GalleryTemplateDir'));

		$tpl->define(
			layout    => 'layout.tpl',
			index     => 'index.tpl',
			directory => 'directory.tpl',
			picture   => 'picture.tpl'
		);

		$tpl->assign(TITLE => "Index of: ".$uri);


		unless (opendir (DIR, $filename)) {
			show_error ($r, $!, "Unable to access $filename: $!");
			return OK;
		}
		
		$tpl->assign(MENU => generate_menu($r));
		
		my @files = grep {!/^\./} readdir (DIR);

		@files = sort @files;

		if (@files) {

			# Remov unwanted files and from list
			my $counter = 0;
			foreach my $picture (@files) {

				my $file = $r->document_root.$uri."/".$picture;

				if (-f $file && !($file =~ m/\.(jpg|jpeg|png)$/i)) {
					splice(@files, $counter, 1);
				}

				$counter++;

			}

			my $filelist;

			foreach my $file (@files) {

				my $thumbfilename = $r->document_root.$uri."/".$file;

				my $fileurl = $uri."/".$file;

				if (-d $thumbfilename) {

					$tpl->assign(FILEURL => $fileurl, FILE => $file);
					$tpl->parse(FILES => '.directory');

				}
				elsif (-f $thumbfilename) {

					my $imageinfo = image_info($thumbfilename);

					next unless ($imageinfo->{file_media_type} && $imageinfo->{file_media_type} eq 'image/jpeg');
					
					my $cached = scale_picture($r, $thumbfilename, 100, 75);


					$tpl->assign(FILEURL => $fileurl);
					$tpl->assign(FILE    => $file);
					$tpl->assign(DATE    => $imageinfo->{DateTimeOriginal});
					$tpl->assign(SRC     => $uri."/.cache/$cached");

					$tpl->parse(FILES => '.picture');

				}
			}
		
		}
		else {
			$tpl->assign(FILES => "Empty dir");
		}

		closedir (DIR);

		$tpl->parse("MAIN", ["index", "layout"]);
		my $content = $tpl->fetch("MAIN");
		$r->print(${$content});
		return OK;

	}
	else {

		my $imageinfo = image_info($filename);

		my $width = $imageinfo->{width};
		if ($width > 640) {
			$width = 640;
		}

		if ($apr->param('width') && $apr->param('width') <= 2048) {
			$width = $apr->param('width');
		}

		my $scale = ($imageinfo->{width} ? $width/$imageinfo->{width} : 1);
		my $height = $imageinfo->{height} * $scale;

		my $cached = scale_picture($r, $filename, $width, $height);


		my $tpl = new CGI::FastTemplate($r->dir_config('GalleryTemplateDir'));

		$tpl->define(
			layout      => 'layout.tpl',
			picture     => 'showpicture.tpl',
			navpicture  => 'navpicture.tpl'
		);

		$tpl->assign(TITLE => "Viewing ".$r->uri()." at $width x $height");
		$tpl->assign(RESOLUTION => "$width x $height");
		$tpl->assign(MENU => generate_menu($r));
		$tpl->assign(SRC => ".cache/".$cached);
		$tpl->assign(URI => $r->uri());

		my @tmp = split (/\//, $filename);
		$filename = pop @tmp;
		my $path = (join "/", @tmp)."/";

		unless (opendir(DATADIR, $path)) {
			show_error($r, "Unable to open dir", "Unable to access $path");
			return OK;
		}
		my @pictures = grep { /\.(jpg|jpeg|png)$/i } readdir (DATADIR);
		closedir(DATADIR);
		@pictures = sort @pictures;

		$tpl->assign(TOTAL => scalar @pictures);
		
		for (my $i=0; $i <= $#pictures; $i++) {
			if ($pictures[$i] eq $filename) {

				$tpl->assign(NUMBER => $i+1);
				
				my $prevpicture = $pictures[$i-1];
				if ($prevpicture and $i > 0) {
					my $cached = scale_picture($r, $path.$prevpicture, 100, 75);
					$tpl->assign(URL       => $prevpicture);
					$tpl->assign(WIDTH     => $width);
					$tpl->assign(PICTURE   => ".cache/$cached");
					$tpl->assign(DIRECTION => "Prev");
					$tpl->parse(BACK => "navpicture");
				}
				else {
					$tpl->assign(BACK => "&nbsp");
				}

				my $nextpicture = $pictures[$i+1];
				if ($nextpicture) {
					my $cached = scale_picture($r, $path.$nextpicture, 100, 75);
					$tpl->assign(URL       => $nextpicture);
					$tpl->assign(WIDTH     => $width);
					$tpl->assign(PICTURE   => ".cache/$cached");
					$tpl->assign(DIRECTION => "Next");
					$tpl->parse(NEXT => "navpicture");
				}
				else {
					$tpl->assign(NEXT => "&nbsp;");
				}
			}
		}

		if (-f $path."/comments.db") {
			dbmopen my %comments, $path."/comments.db", 0664;
			if ($comments{$filename}) {
				$tpl->assign(COMMENT => "Comment: ".$comments{$filename}."<br>");
			}
			else {
				$tpl->assign(COMMENT => "");
			}
		}
		else {
			$tpl->assign(COMMENT => "");
		}

		if ($imageinfo->{DateTimeOriginal}) {
			$tpl->assign(DATETIME => $imageinfo->{DateTimeOriginal});
		}
		else {
			$tpl->assign(DATETIME => "Unknown");
		}

		if ($imageinfo->{Flash}) {
			$tpl->assign(FLASH => $imageinfo->{Flash});
		}
		else {
			$tpl->assign(FLASH => "Unknown");
		}

		$tpl->parse("MAIN", ["picture", "layout"]);
		my $content = $tpl->fetch("MAIN");
		$r->print(${$content});
		return OK;

	}

	return OK;
}

sub scale_picture {

	my ($r, $fullpath, $width, $height) = @_;

	my @dirs = split(/\//, $fullpath);
	my $filename = pop(@dirs);

	my $cache = join ("/", @dirs) . "/.cache";

	my $newfilename = $width."x".$height."-".$filename;

	unless (-f $cache."/".$newfilename) {

		my $newpath = $cache."/".$newfilename;

		resizepicture($fullpath, $newpath, $width, $height);

	}

	return $newfilename;

}

sub show_error {

	my ($r, $errortitle, $error) = @_;

	my $tpl = new CGI::FastTemplate($r->dir_config('GalleryTemplateDir'));

	$tpl->define(
		layout => 'layout.tpl',
		error  => 'error.tpl'
	);

	$tpl->assign(TITLE      => "Error! $errortitle");
	$tpl->assign(ERRORTITLE => "Error! $errortitle");
	$tpl->assign(ERROR      => $error);

	$tpl->parse("MAIN", ["error", "layout"]);

	my $content = $tpl->fetch("MAIN");

	$r->print(${$content});

	return OK;
}

sub generate_menu {

	my $r = shift;

	my $subr = $r->lookup_uri($r->uri);
	my $filename = $subr->filename;

	my @links = split (/\//, $r->uri);

	my $picturename;
	if (-f $filename) {
		$picturename = pop(@links);	
	}

	if ($r->uri eq '/') {
		return qq{ <a href="/">root:</a> };
	}

	my $menu;
	my $menuurl;
	foreach my $link (@links) {

		$menuurl .= $link."/";
		my $linktext = $link;
		unless ($link) {
			$linktext = "root: ";
		}

		$menu .= qq{ <a href="$menuurl">$linktext</a> / };

	}

	if (-f $filename) {
		$menu .= $picturename;
	}

	return $menu;
}

1;
__DATA__
__C__

#include <X11/Xlib.h>
#include <Imlib2.h>
#include <stdio.h>
#include <string.h>

int resizepicture(char* infile, char* outfile, int x, int y) {

	Imlib_Image image;
	Imlib_Image buffer;
	int old_x;
	int old_y;

	image = imlib_load_image(infile);

	imlib_context_set_image(image);
	imlib_context_set_blend(1);
	imlib_context_set_anti_alias(1);
	
	old_x  = imlib_image_get_width();
	old_y = imlib_image_get_height();

	buffer = imlib_create_image(x,y);
	imlib_context_set_image(buffer);
	
	imlib_blend_image_onto_image(image, 0, 0, 0, old_x, old_y, 0, 0, x, y);

	imlib_context_set_image(buffer);
	imlib_save_image(outfile);

	imlib_context_set_image(image);
	imlib_free_image();

	return 1;
}

__END__

=head1 NAME

Apache::Gallery - mod_perl handler to create an image gallery

=head1 SYNOPSIS

In httpd.conf:

<VirtualHost 213.237.118.52>
   ServerName  gallery.foo.org
   DocumentRoot /path/to/pictures
   ErrorLog    logs/gallery-error_log
   TransferLog logs/gallery-access_log
	PerlSetVar   GalleryTemplateDir '/usr/local/apache/gallery/templates'
   <Location />
      SetHandler        perl-script
      PerlHandler       Apache::Gallery
   </Location>
</VirtualHost>


=head1 AUTHOR

Michael Legart <gallery@legart.dk>

=head1 SEE ALSO

L<perl>.

=cut
