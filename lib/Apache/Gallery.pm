package Apache::Gallery;

# $Id: Gallery.pm,v 1.39 2002/01/02 10:50:23 mil Exp $

use 5.006;
use strict;
use warnings;

use vars qw($VERSION);

$VERSION = "0.3";

use Apache();
use Apache::Constants qw(:common);
use Apache::Request();

use Image::Info qw(image_info);
use DB_File;
use CGI::FastTemplate;
use URI::Escape;

my $escape_rule = '^a-zA-Z0-9/_\\.';

use Inline C => Config => 
				LIBS => '-L/usr/X11R6/lib -lImlib2 -lttf -lm -ldl -lXext -lXext',
				DIRECTORY => Apache->request()->dir_config('InlineDir') ?  Apache->request()->dir_config('InlineDir') : "/tmp/",
				INC => '-I/usr/X11R6/include',
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

					$tpl->assign(FILEURL => uri_escape($fileurl, $escape_rule), FILE => $file);
					$tpl->parse(FILES => '.directory');

				}
				elsif (-f $thumbfilename) {

					my $imageinfo = image_info($thumbfilename);

					next unless ($imageinfo->{file_media_type} && $imageinfo->{file_media_type} eq 'image/jpeg');
					my ($thumbnailwidth, $thumbnailheight) = get_thumbnailsize($thumbfilename);	
					my $cached = scale_picture($r, $thumbfilename, $thumbnailwidth, $thumbnailheight);


					$tpl->assign(FILEURL => $fileurl);
					$tpl->assign(FILE    => $file);
					$tpl->assign(DATE    => $imageinfo->{DateTimeOriginal});
					$tpl->assign(SRC     => uri_escape($uri."/.cache/$cached", $escape_rule));

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

		# Check if the selected width is allowed
		if ($apr->param('width')) {
			my @sizes = split (/ /, $r->dir_config('GallerySizes') ? $r->dir_config('GallerySizes') : '640 800 1024 1600');
			unless (grep $apr->param('width') == $_, @sizes) {
				show_error($r, "Invalid width", $apr->param('width')." is an invalid width.");
				return OK;
			}
			$width = $apr->param('width');
		}

		my $scale = ($imageinfo->{width} ? $width/$imageinfo->{width} : 1);
		my $height = $imageinfo->{height} * $scale;

		my $cached = scale_picture($r, $filename, $width, $height);


		my $tpl = new CGI::FastTemplate($r->dir_config('GalleryTemplateDir'));

		$tpl->define(
			layout      => 'layout.tpl',
			picture     => 'showpicture.tpl',
			navpicture  => 'navpicture.tpl',
			info        => 'info.tpl',
			scale       => 'scale.tpl'
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
					my ($thumbnailwidth, $thumbnailheight) = get_thumbnailsize($path.$prevpicture);	
					my $cached = scale_picture($r, $path.$prevpicture, $thumbnailwidth, $thumbnailheight);
					$tpl->assign(URL       => uri_escape($prevpicture, $escape_rule));
					$tpl->assign(WIDTH     => $width);
					$tpl->assign(PICTURE   => uri_escape(".cache/$cached", $escape_rule));
					$tpl->assign(DIRECTION => "Prev");
					$tpl->parse(BACK => "navpicture");
				}
				else {
					$tpl->assign(BACK => "&nbsp");
				}

				my $nextpicture = $pictures[$i+1];
				if ($nextpicture) {
					my ($thumbnailwidth, $thumbnailheight) = get_thumbnailsize($path.$nextpicture);	
					my $cached = scale_picture($r, $path.$nextpicture, $thumbnailwidth, $thumbnailheight);
					$tpl->assign(URL       => uri_escape($nextpicture, $escape_rule));
					$tpl->assign(WIDTH     => $width);
					$tpl->assign(PICTURE   => uri_escape(".cache/$cached", $escape_rule));
					$tpl->assign(DIRECTION => "Next");
					$tpl->parse(NEXT => "navpicture");
				}
				else {
					$tpl->assign(NEXT => "&nbsp;");
				}
			}
		}

		if (-e $path . '/' . $filename . '.comment' && -f $path . '/' . $filename . '.comment') {
		    my $comment_ref = get_comment($path . '/' . $filename . '.comment');
		    $tpl->assign(COMMENT => $comment_ref->{COMMENT} . '<br>') if $comment_ref->{COMMENT};
		    $tpl->assign(TITLE => $comment_ref->{TITLE}) if $comment_ref->{TITLE};
		} else {
		    $tpl->assign(COMMENT => '');
		}

		my @infos = split /, /, $r->dir_config('GalleryInfo') ? $r->dir_config('GalleryInfo') : 'Picture Taken => DateTimeOriginal, Flash => Flash';

		foreach (@infos) {
		
			my ($key, $value) = (split " => ")[0,1];
			if ($imageinfo->{$value}) {
				my $content = "";
				if (ref($imageinfo->{$value}) eq 'Image::TIFF::Rational') { 
					$content = $imageinfo->{$value}->as_string;
				} 
				elsif (ref($imageinfo->{$value}) eq 'ARRAY') {
					foreach my $array_el (@{$imageinfo->{$value}}) {
						if (ref($array_el) eq 'ARRAY') {
							foreach (@{$array_el}) {
								$content .= $_ . ' ';
							}
						} 
						elsif (ref($array_el) eq 'HASH') {
							$content .= "<br>{ ";
				    	foreach (sort keys %{$array_el}) {
								$content .= "$_ = " . $array_el->{$_} . ' ';
							}
				    	$content .= "} ";
						} 
						else {
							$content .= $array_el;
						}
						$content .= ' ';
					}
				} 
				else {
					$content = $imageinfo->{$value};
				}
				$tpl->assign(KEY => $key);
				$tpl->assign(VALUE => $content);
				$tpl->parse(INFO => '.info');
			} 
			else {
				print STDERR $value, " not found in picture info\n";
			}
		}

		my @sizes = split (/ /, $r->dir_config('GallerySizes') ? $r->dir_config('GallerySizes') : '640x480 800x600 1024x768 1600x1200');
		foreach my $size (@sizes) {
			$tpl->assign(IMAGEURI => $r->uri());
			$tpl->assign(SIZE     => $size);
			$tpl->assign(WIDTH    => $size);
			$tpl->parse(SIZES => '.scale');
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

		my $rotate = 0;

		if (-f $fullpath . ".rotate") {
		    $rotate = readfile_getnum($fullpath . ".rotate");
		}

		if ($width == 100 or $width == 75) {
		    resizepicture($fullpath, $newpath, $width, $height, $rotate, '');
		} else {
		    resizepicture($fullpath, $newpath, $width, $height, $rotate, ($r->dir_config('GalleryCopyrightImage') ? $r->dir_config('GalleryCopyrightImage') : ''));
		}
	}

	return $newfilename;

}

sub get_thumbnailsize {
	my $filename = shift;

	my $imageinfo = image_info($filename);

	my $width = 100;
	if ($imageinfo->{width} < $imageinfo->{height}) {
		$width = 75;
	}
	my $scale = ($imageinfo->{width} ? $width/$imageinfo->{width} : 1);
	my $height = $imageinfo->{height} * $scale;

	return ($width, $height);
}


sub readfile_getnum {
	my $filename = shift;
	open(FH, "<$filename") or return 0;
	my $temp = <FH>;
	chomp($temp);
	close(FH);
	unless ($temp =~ /^\d$/) {
		return 0;
	}
	unless ($temp == 1 || $temp == 2 || $temp == 3) {
		return 0;
	}
	return $temp;
}

sub get_comment {
	my $filename = shift;
	my $comment_ref = {};
 	$comment_ref->{TITLE} = undef;
	$comment_ref->{COMMENT} = '';

	my $content = '';
	open(FH, $filename) or return $comment_ref;
	my $title = <FH>;
	if ($title =~ /^TITLE: (.*)$/) {
		$comment_ref->{TITLE} = $1;
	} 
	else {
		$comment_ref->{COMMENT} = $title;
	}
	{
		local $/;
		$comment_ref->{COMMENT} .= <FH>;
	}
	close(FH);

	return $comment_ref;
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

		$menu .= "<a href=\"".uri_escape($menuurl, $escape_rule)."\">$linktext</a> / ";

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

int resizepicture(char* infile, char* outfile, int x, int y, int rotate, char* copyrightfile) {

	Imlib_Image image;
	Imlib_Image buffer;
	Imlib_Image logo;
	int logo_x, logo_y;
	int old_x;
	int old_y;

	image = imlib_load_image(infile);

	imlib_context_set_image(image);
	imlib_context_set_blend(1);
	imlib_context_set_anti_alias(1);
	
	old_x = imlib_image_get_width();
	old_y = imlib_image_get_height();

	buffer = imlib_create_image(x,y);
	imlib_context_set_image(buffer);
	
	imlib_blend_image_onto_image(image, 0, 0, 0, old_x, old_y, 0, 0, x, y);

	imlib_context_set_image(buffer);
	
	if (rotate != 0) {
	    imlib_image_orientate(rotate);
	}
	if (strcmp(copyrightfile, "") != 0) {
	    logo = imlib_load_image(copyrightfile);

	    imlib_context_set_image(buffer);

	    x = imlib_image_get_width();
	    y = imlib_image_get_height();
	    
	    imlib_context_set_image(logo);
	    
	    logo_x = imlib_image_get_width();
	    logo_y = imlib_image_get_height();

	    imlib_context_set_image(buffer);
	    imlib_blend_image_onto_image(logo, 0, 0, 0, logo_x, logo_y, x-logo_x, y-logo_y, logo_x, logo_y);

	    imlib_context_set_image(logo);
	    imlib_free_image();
	    imlib_context_set_image(buffer);
	}

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
   ServerName   gallery.foo.org
   DocumentRoot /path/to/pictures
   ErrorLog     logs/gallery-error_log
   TransferLog  logs/gallery-access_log
   PerlSetVar   InlineDir '/tmp/'
   PerlSetVar   GalleryTemplateDir '/usr/local/apache/gallery/templates'
   PerlSetVar   GalleryInfo 'Picture Taken => DateTimeOriginal, Flash => Flash' 
   PerlSetVar   GallerySizes '640 1024 1600 2272'
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
