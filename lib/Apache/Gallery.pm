package Apache::Gallery;

# $Author$ $Rev$
# $Date$

use strict;

use vars qw($VERSION);

$VERSION = "0.8";

BEGIN {

	use mod_perl;
	use constant MP2 => ($mod_perl::VERSION >= 1.99);
	
	if (MP2) {
		require Apache2;
		require Apache::Server;
		require Apache::RequestRec;
		require Apache::Log;
		require APR::Table;
		require Apache::RequestIO;
		require Apache::SubRequest;
		require Apache::Const;
	
		Apache::Const->import(-compile => 'OK','DECLINED','FORBIDDEN');
	
	}
	else {
		require Apache;
		require Apache::Constants;
		require Apache::Request;
	
		Apache::Constants->import('OK','DECLINED','FORBIDDEN');

	}

}

use Image::Info qw(image_info);
use Image::Size qw(imgsize);
use Image::Imlib2;
use Text::Template qw(fill_in_file);
use File::stat;
use File::Spec;
use POSIX qw(floor);
use URI::Escape;
use CGI;
use CGI::Cookie;

use Data::Dumper;

# Regexp for escaping URI's
my $escape_rule = "^A-Za-z0-9\-_.!~*'()\/";
my $memoized;

sub handler {

	my $r = shift or Apache->request();

	if ((not $memoized) and ($r->dir_config('GalleryMemoize'))) {
		require Memoize;
		Memoize::memoize('get_imageinfo');
		$memoized=1;
	}

	$r->headers_out->{"X-Powered-By"} = "apachegallery.dk $VERSION - Hest design!";
	$r->headers_out->{"X-Gallery-Version"} = '$Rev$ $Date$';

	# Just return the http headers if the client requested that
	if ($r->header_only) {

		if (!MP2) {
			$r->send_http_header;
		}

		return MP2 ? Apache::OK : Apache::Constants::OK;
	}

	my $cgi = new CGI;

	# Handle selected images
	if ($cgi->param('selection')) {
		my @selected = $cgi->param('selection');
		my $content = "@selected";
		$r->content_type('text/html');
		$r->headers_out->{'Content-Length'} = length(${$content});

		if (!MP2) {
			$r->send_http_header;
		}

		$r->print($content);
		return MP2 ? Apache::OK : Apache::Constants::OK;
	}
	
	# Selectmode providing checkboxes beside all thumbnails
	my $select_mode = $cgi->param('select');
	
	# Let Apache serve icons and files from the cache without us
	# modifying the request
	if ($r->uri =~ m/^\/icons/i) {
		return MP2 ? Apache::DECLINED : Apache::Constants::DECLINED;
	}
	if ($r->uri =~ m/\.cache\//i) {
		my $file = cache_dir($r, 0);
		$file =~ s/\.cache//;
		my $subr = $r->lookup_file($file);
		$r->content_type($subr->content_type());

		if (MP2) {
			$r->sendfile($file);
		}
		else {
			$r->path_info('');
			$r->filename($file);
		}
		
		return MP2 ? Apache::DECLINED : Apache::Constants::DECLINED;

	}

	my $uri = $r->uri;
	$uri =~ s/\/$//;

	my $filename = $r->filename;
	$filename =~ s/\/$//;
	my $topdir = $filename;

	unless (-f $filename or -d $filename) {
	
		show_error($r, 404, "404!", "No such file or directory: ".uri_escape($r->uri, $escape_rule));
		return MP2 ? Apache::OK : Apache::Constants::OK;
	}

	my $doc_pattern = $r->dir_config('GalleryDocFile');
	unless ($doc_pattern) {
		$doc_pattern = '\.(mpe?g|avi|mov|asf|wmv|doc|mp3|ogg|pdf|rtf|wav|dlt|html?|csv|eps)$'
	}
	my $img_pattern = $r->dir_config('GalleryImgFile');
	unless ($img_pattern) {
		$img_pattern = '\.(jpe?g|png|tiff?|ppm)$'
	}

	# Let Apache serve files we don't know how to handle anyway
	if (-f $filename && $filename !~ m/$img_pattern/i) {
		return MP2 ? Apache::DECLINED : Apache::Constants::DECLINED;
	}

	if (-d $filename) {

		unless (-d cache_dir($r, 0)) {
			unless (create_cache($r, cache_dir($r, 0))) {
				return MP2 ? Apache::OK : Apache::Constants::OK;
			}
		}

		my $tpl_dir = $r->dir_config('GalleryTemplateDir');

		my %tpl_vars = (layout    => "$tpl_dir/layout.tpl",
				index     => "$tpl_dir/index.tpl",
				directory => "$tpl_dir/directory.tpl",
				picture   => "$tpl_dir/picture.tpl",
				file      => "$tpl_dir/file.tpl",
				comment   => "$tpl_dir/dircomment.tpl",
				nocomment => "$tpl_dir/nodircomment.tpl",
			       );

		$tpl_vars{TITLE} = "Index of: $uri";
		$tpl_vars{META} = " ";

		unless (opendir (DIR, $filename)) {
			show_error ($r, 500, $!, "Unable to access directory $filename: $!");
			return MP2 ? Apache::OK : Apache::Constants::OK;
		}

		$tpl_vars{MENU} = generate_menu($r);

		$tpl_vars{FORM_BEGIN} = $select_mode?'<form method="post">':'';
		$tpl_vars{FORM_END}   = $select_mode?'</form>':'';

		# Read, sort, and filter files
		my @files = grep { !/^\./ && -f "$filename/$_" } readdir (DIR);

		my $sortby = $r->dir_config('GallerySortBy');
		if ($sortby && $sortby =~ m/^(size|atime|mtime|ctime)$/) {
			@files = map(/^\d+ (.*)/, sort map(stat("$filename/$_")->$sortby()." $_", @files));
		} else {
			@files = sort @files;
		}

		my @downloadable_files;

		if (@files) {
			# Remove unwanted files from list
			my @new_files = ();
			foreach my $picture (@files) {

				my $file = $topdir."/".$picture;

				if ($file =~ /$doc_pattern/i) {
					push (@downloadable_files, $picture);
					
				}

				if ($file =~ /$img_pattern/i) {
					push (@new_files, $picture);
				}

			}
			@files = @new_files;
		}

		# Read and sort directories
		rewinddir (DIR);
		my @directories = grep { !/^\./ && -d "$filename/$_" } readdir (DIR);
		@directories = sort @directories;
		closedir(DIR);

		# Combine directories and files to one listing
		my @listing;
		push (@listing, @directories);
		push (@listing, @files);
		push (@listing, @downloadable_files);
		
		if (@listing) {

			my $filelist;

			my $file_counter = 0;
			my $start_at = 1;
			my $max_files = $r->dir_config('GalleryMaxThumbnailsPerPage');

			if (defined($cgi->param('start'))) {
				$start_at = $cgi->param('start');
				if ($start_at < 1) {
					$start_at = 1;
				}
			}

			my $browse_links = "";
			if (defined($max_files)) {
			
				for (my $i=1; $i<=scalar(@listing); $i++) {

					my $from = $i;

					my $to = $i+$max_files-1;
					if ($to > scalar(@listing)) {
						$to = scalar(@listing);
					}

					if ($start_at < $from || $start_at > $to) {
						$browse_links .= "<a href=\"?start=$from\">$from - ".$to."</a> ";
					}
					else {
						$browse_links .= "$from - $to ";
					}

					$i+=$max_files-1;

				}

			}

			$tpl_vars{BROWSELINKS} = $browse_links;

			DIRLOOP:
			foreach my $file (@listing) {

				$file_counter++;

				if ($file_counter < $start_at) {
					next;
				}

				if (defined($max_files) && $file_counter > $max_files+$start_at-1) {
					last DIRLOOP;
				}

				my $thumbfilename = $topdir."/".$file;

				my $fileurl = $uri."/".$file;

				if (-d $thumbfilename) {
					my $dirtitle = '';
					if (-e $thumbfilename . ".folder") {
						$dirtitle = get_filecontent($thumbfilename . ".folder");
					}

					$tpl_vars{FILES} .= fill_in_file($tpl_vars{directory},
						HASH=> {FILEURL => uri_escape($fileurl, $escape_rule),
						FILE    => ($dirtitle ? $dirtitle : $file),
					});

				}
				elsif (-f $thumbfilename && $thumbfilename =~ /$doc_pattern/i) {
					my $type = lc($1);
					my $stat = stat($thumbfilename);
					my $size = $stat->size;
					my $filetype;

					if ($thumbfilename =~ m/\.(mpe?g|avi|mov|asf|wmv)$/i) {
						$filetype = "video-$type";
					} elsif ($thumbfilename =~ m/\.(txt|html?)$/i) {
						$filetype = "text-$type";
					} elsif ($thumbfilename =~ m/\.(mp3|ogg|wav)$/i) {
						$filetype = "sound-$type";
					} elsif ($thumbfilename =~ m/\.(doc|pdf|rtf|csv|eps)$/i) {
						$filetype = "application-$type";
					} else {
						$filetype = "unknown";
					}

					$tpl_vars{FILES} .= fill_in_file($tpl_vars{file},
						HASH => {%tpl_vars,
						FILEURL => uri_escape($fileurl, $escape_rule),
						ALT => "Size: $size Bytes",
						FILE => $file,
						TYPE => $type,
						FILETYPE => $filetype,
					});

				}
				elsif (-f $thumbfilename) {

					my ($width, $height, $type) = imgsize($thumbfilename);
					next if $type eq 'Data stream is not a known image file format';

					my @filetypes = qw(JPG TIF PNG PPM GIF);

					next unless (grep $type eq $_, @filetypes);
					my ($thumbnailwidth, $thumbnailheight) = get_thumbnailsize($r, $width, $height);	
					my $imageinfo = get_imageinfo($r, $thumbfilename, $type, $width, $height);
					my $cached = scale_picture($r, $thumbfilename, $thumbnailwidth, $thumbnailheight, $imageinfo);

					my $rotate = readfile_getnum($r, $imageinfo, $thumbfilename.".rotate");
					my %file_vars = (FILEURL => uri_escape($fileurl, $escape_rule),
							 FILE    => $file,
							 DATE    => $imageinfo->{DateTimeOriginal} ? $imageinfo->{DateTimeOriginal} : '', # should this really be a stat of the file instead of ''?
							 SRC     => uri_escape($uri."/.cache/$cached", $escape_rule),
							 HEIGHT => (grep($rotate==$_, (1, 3)) ? $thumbnailwidth : $thumbnailheight),
							 WIDTH => (grep($rotate==$_, (1, 3)) ? $thumbnailheight : $thumbnailwidth),
							 SELECT  => $select_mode?'<input type="checkbox" name="selection" value="'.$file.'">&nbsp;&nbsp;':'',);
					$tpl_vars{FILES} .= fill_in_file($tpl_vars{picture},
									 HASH => {%tpl_vars,
										  %file_vars});
				}
			}
		}
		else {
			$tpl_vars{FILES} = "No files found";
			$tpl_vars{BROWSELINKS} = "";
		}

		if (-f $topdir . '.comment') {
			my $comment_ref = get_comment($topdir . '.comment');
			my %comment_vars;
			$comment_vars{COMMENT} = $comment_ref->{COMMENT} . '<br>' if $comment_ref->{COMMENT};
			$comment_vars{TITLE} = $comment_ref->{TITLE} if $comment_ref->{TITLE};
			$tpl_vars{DIRCOMMENT} = fill_in_file($tpl_vars{comment},
							     HASH => \%comment_vars,
							    );
		} else {
			$tpl_vars{DIRCOMMENT} = fill_in_file($tpl_vars{nocomment});
		}

		$tpl_vars{MAIN} = fill_in_file($tpl_vars{index},
					       HASH => \%tpl_vars,
					      );
		$tpl_vars{MAIN} = fill_in_file($tpl_vars{layout},
					       HASH => \%tpl_vars,
					      );


		$r->content_type('text/html');
		$r->headers_out->{'Content-Length'} = length($tpl_vars{MAIN});

		if (!MP2) {
			$r->send_http_header;
		}

		$r->print($tpl_vars{MAIN});
		return MP2 ? Apache::OK : Apache::Constants::OK;

	}
	else {

		# original size
		if (defined($ENV{QUERY_STRING}) && $ENV{QUERY_STRING} eq 'orig') {
			if ($r->dir_config('GalleryAllowOriginal') ? 1 : 0) {
				$r->filename($filename);
				return MP2 ? Apache::DECLINED : Apache::Constants::DECLINED;
			} else {
				return MP2 ? Apache::FORBIDDEN : Apache::Constants::FORBIDDEN;
			}
		}
	
		# Create cache dir if not existing
		my @tmp = split (/\//, $filename);
		my $picfilename = pop @tmp;
		my $path = (join "/", @tmp)."/";
		my $cache_path = cache_dir($r, 1);

		unless (-d $cache_path) {
			unless (create_cache($r, $cache_path)) {
				return MP2 ? Apache::OK : Apache::Constants::OK;
			}
		}

		my ($orig_width, $orig_height, $type) = imgsize($filename);
		my $width = $orig_width;

		my $imageinfo = get_imageinfo($r, $filename, $type, $orig_width, $orig_height);

		my $original_size=$orig_height;
 		if ($orig_width>$orig_height) {
			$original_size=$orig_width;
 		}

		# Check if the selected width is allowed
		my @sizes = split (/ /, $r->dir_config('GallerySizes') ? $r->dir_config('GallerySizes') : '640 800 1024 1600');

		my %cookies = fetch CGI::Cookie;

		if ($cgi->param('width')) {
			unless ((grep $cgi->param('width') == $_, @sizes) or ($cgi->param('width') == $original_size)) {
				show_error($r, 200, "Invalid width", "The specified width is invalid");
				return MP2 ? Apache::OK : Apache::Constants::OK;
			}

			$width = $cgi->param('width');
			my $cookie = new CGI::Cookie(-name => 'GallerySize', -value => $width, -expires => '+6M');
			$r->headers_out->{'Set-Cookie'} = $cookie;

		} elsif ($cookies{'GallerySize'} && (grep $cookies{'GallerySize'}->value == $_, @sizes)) {

			$width = $cookies{'GallerySize'}->value;

		} else {
			$width = $sizes[0];
		}	

		my $scale;
		my $image_width;
		if ($orig_width<$orig_height) {
			$scale = ($orig_height ? $width/$orig_height: 1);
			$image_width=$width*$orig_width/$orig_height;
		}
		else {
			$scale = ($orig_width ? $width/$orig_width : 1);
			$image_width = $width;
		}

		my $height = $orig_height * $scale;

		$image_width = floor($image_width);
		$width       = floor($width);
		$height      = floor($height);

		my $cached = scale_picture($r, $filename, $image_width, $height, $imageinfo);
		
		my $tpl_dir = $r->dir_config('GalleryTemplateDir');

		my %tpl_vars = (layout         => "$tpl_dir/layout.tpl",
				picture        => "$tpl_dir/showpicture.tpl",
				navpicture     => "$tpl_dir/navpicture.tpl",
				info           => "$tpl_dir/info.tpl",
				scale          => "$tpl_dir/scale.tpl",
				scaleactive    => "$tpl_dir/scaleactive.tpl",
				orig           => "$tpl_dir/orig.tpl",
				refresh        => "$tpl_dir/refresh.tpl",
				interval       => "$tpl_dir/interval.tpl",
				intervalactive => "$tpl_dir/intervalactive.tpl",
				slideshowisoff => "$tpl_dir/slideshowisoff.tpl",
				slideshowoff   => "$tpl_dir/slideshowoff.tpl",
				pictureinfo    => "$tpl_dir/pictureinfo.tpl",
				nopictureinfo  => "$tpl_dir/nopictureinfo.tpl",
			       );

		my $resolution = (($image_width > $orig_width) && ($height > $orig_height)) ? 
		    "$orig_width x $orig_height" : "$image_width x $height";

		$tpl_vars{TITLE} = "Viewing ".$r->uri()." at $image_width x $height";
		$tpl_vars{META} = " ";
		$tpl_vars{RESOLUTION} = $resolution;
		$tpl_vars{MENU} = generate_menu($r);
		$tpl_vars{SRC} = uri_escape(".cache/$cached", $escape_rule);
		$tpl_vars{URI} = $r->uri();
	
		my $exif_mode = $r->dir_config('GalleryEXIFMode');
		unless ($exif_mode) {
			$exif_mode = 'namevalue';
		}

		unless (opendir(DATADIR, $path)) {
			show_error($r, 500, "Unable to access directory", "Unable to access directory $path");
			return MP2 ? Apache::OK : Apache::Constants::OK;
		}
		my @pictures = grep { /$img_pattern/i } readdir (DATADIR);
		closedir(DATADIR);
		@pictures = sort @pictures;

		$tpl_vars{TOTAL} = scalar @pictures;

		my $prevpicture;
		my $nextpicture;
	
		for (my $i=0; $i <= $#pictures; $i++) {
			if ($pictures[$i] eq $picfilename) {

				$tpl_vars{NUMBER} = $i+1;

				$prevpicture = $pictures[$i-1];
				my $displayprev = ($i>0 ? 1 : 0);

				if ($r->dir_config("GalleryWrapNavigation")) {
					$prevpicture = $pictures[$i>0 ? $i-1 : $#pictures];
					$displayprev = 1;
				}
				if ($prevpicture and $displayprev) {
					my ($orig_width, $orig_height, $type) = imgsize($path.$prevpicture);
					my ($thumbnailwidth, $thumbnailheight) = get_thumbnailsize($r, $orig_width, $orig_height);	
					my $imageinfo = get_imageinfo($r, $path.$prevpicture, $type, $orig_width, $orig_height);
					my $cached = scale_picture($r, $path.$prevpicture, $thumbnailwidth, $thumbnailheight, $imageinfo);
					my %nav_vars;
					$nav_vars{URL}       = uri_escape($prevpicture, $escape_rule);
					$nav_vars{FILENAME}  = $prevpicture;
					$nav_vars{WIDTH}     = $width;
					$nav_vars{PICTURE}   = uri_escape(".cache/$cached", $escape_rule);
					$nav_vars{DIRECTION} = "&laquo; prev";
					$tpl_vars{BACK} = fill_in_file($tpl_vars{navpicture},
								       HASH => \%nav_vars,
								      );
				}
				else {
					$tpl_vars{BACK} = "&nbsp";
				}

				$nextpicture = $pictures[$i+1];
				if ($r->dir_config("GalleryWrapNavigation")) {
					$nextpicture = $pictures[$i == $#pictures ? 0 : $i+1];
				}	

				if ($nextpicture) {
					my ($orig_width, $orig_height, $type) = imgsize($path.$nextpicture);
					my ($thumbnailwidth, $thumbnailheight) = get_thumbnailsize($r, $orig_width, $orig_height);	
					my $imageinfo = get_imageinfo($r, $path.$nextpicture, $type, $thumbnailwidth, $thumbnailheight);
					my $cached = scale_picture($r, $path.$nextpicture, $thumbnailwidth, $thumbnailheight, $imageinfo);
					my %nav_vars;
					$nav_vars{URL}       = uri_escape($nextpicture, $escape_rule);
					$nav_vars{FILENAME}  = $nextpicture;
					$nav_vars{WIDTH}     = $width;
					$nav_vars{PICTURE}   = uri_escape(".cache/$cached", $escape_rule);
					$nav_vars{DIRECTION} = "next &raquo;";

					$tpl_vars{NEXT} = fill_in_file($tpl_vars{navpicture},
								       HASH => \%nav_vars
								      );
				}
				else {
					$tpl_vars{NEXT} = "&nbsp;";
				}
			}
		}

		my $foundcomment = 0;
		if (-f $path . '/' . $picfilename . '.comment') {
			my $comment_ref = get_comment($path . '/' . $picfilename . '.comment');
			$foundcomment = 1;
			$tpl_vars{COMMENT} = $comment_ref->{COMMENT} . '<br>' if $comment_ref->{COMMENT};
			$tpl_vars{TITLE} = $comment_ref->{TITLE} if $comment_ref->{TITLE};
		} else {
			$tpl_vars{COMMENT} = '';
		}

		my @infos = split /, /, $r->dir_config('GalleryInfo') ? $r->dir_config('GalleryInfo') : 'Picture Taken => DateTimeOriginal, Flash => Flash';
		my $foundinfo = 0;
		my $exifvalues;
		foreach (@infos) {
	
			my ($human_key, $exif_key) = (split " => ")[0,1];
			my $value = $imageinfo->{$human_key};
			if (defined($value)) {

				$foundinfo = 1;

				if ($exif_mode eq 'namevalue') {
					my %info_vars;
					$info_vars{KEY} = $human_key;
					$info_vars{VALUE} = $value;
					$tpl_vars{INFO} .=  fill_in_file($tpl_vars{info},
									 HASH => \%info_vars,
									);
				}

				if ($exif_mode eq 'variables') {
					$tpl_vars{"EXIF_".uc($exif_key)} = $value;
				}

				if ($exif_mode eq 'values') {
					$exifvalues .= "| ".$value." ";
				}

			} 

		}

		if ($exif_mode eq 'values') {
			if (defined($exifvalues)) {
				$tpl_vars{EXIFVALUES} = $exifvalues;
			}
			else {
				$tpl_vars{EXIFVALUES} = "";
			}
		}

		if ($foundcomment and !$foundinfo) {
			$tpl_vars{INFO} = "";
		}

		if ($exif_mode ne 'namevalue') {
			$tpl_vars{INFO} = "";
		}

		if ($exif_mode eq 'namevalue' && $foundinfo or $foundcomment) {

			$tpl_vars{PICTUREINFO} = fill_in_file($tpl_vars{pictureinfo},
				HASH => \%tpl_vars
			);

			unless (defined($exifvalues)) {
				$tpl_vars{EXIFVALUES} = "";
			}

		}
		else {
			$tpl_vars{PICTUREINFO} = fill_in_file($tpl_vars{nopictureinfo},
							      HASH => \%tpl_vars,
							     );
		}

		my $scaleable = 0;
		foreach my $size (@sizes) {
			if ($size<=$original_size) {
				my %sizes_vars;
				$sizes_vars{IMAGEURI} = uri_escape($r->uri(), $escape_rule);
				$sizes_vars{SIZE}     = $size;
				$sizes_vars{WIDTH}    = $size;
				if ($width == $size) {
					$tpl_vars{SIZES} .= fill_in_file($tpl_vars{scaleactive},
						HASH => \%sizes_vars,
					);
				}
				else {
					$tpl_vars{SIZES} .= fill_in_file($tpl_vars{scale},
						HASH => \%sizes_vars,
					);
					$scaleable = 1;
				}
			}
		}

		unless ($scaleable) {
			my %sizes_vars;
			$sizes_vars{IMAGEURI} = uri_escape($r->uri(), $escape_rule);
			$sizes_vars{SIZE}     = $original_size;
			$sizes_vars{WIDTH}    = $original_size;
			$tpl_vars{SIZES} .= fill_in_file($tpl_vars{scaleactive},
				HASH => \%sizes_vars,
			);
		}

		$tpl_vars{IMAGEURI} = uri_escape($r->uri(), $escape_rule);

		if ($r->dir_config('GalleryAllowOriginal')) {
			$tpl_vars{SIZES} .= fill_in_file($tpl_vars{orig},
				HASH => \%tpl_vars,
			);
		}

		my @slideshow_intervals = split (/ /, $r->dir_config('GallerySlideshowIntervals') ? $r->dir_config('GallerySlideshowIntervals') : '3 5 10 15 30');
		foreach my $interval (@slideshow_intervals) {

			my %slideshow_vars;
			$slideshow_vars{IMAGEURI} = uri_escape($r->uri(), $escape_rule);
			$slideshow_vars{SECONDS} = $interval;
			$slideshow_vars{WIDTH} = ($width > $height ? $width : $height);

			if ($cgi->param('slideshow') && $cgi->param('slideshow') == $interval and $nextpicture) {
				$tpl_vars{SLIDESHOW} .= fill_in_file($tpl_vars{intervalactive},
					HASH => \%slideshow_vars,
				);

			}
			else {

				$tpl_vars{SLIDESHOW} .= fill_in_file($tpl_vars{interval},
					HASH => \%slideshow_vars,
				);

			}
		}

		if ($cgi->param('slideshow') and $nextpicture) {

			$tpl_vars{SLIDESHOW} .= fill_in_file($tpl_vars{slideshowoff},
				HASH => \%tpl_vars,
			);

			unless ((grep $cgi->param('slideshow') == $_, @slideshow_intervals)) {
				show_error($r, 200, "Invalid interval", "Invalid slideshow interval choosen");
				return MP2 ? Apache::OK : Apache::Constants::OK;
			}

			$tpl_vars{URL} = uri_escape($nextpicture, $escape_rule);
			$tpl_vars{WIDTH} = ($width > $height ? $width : $height);
			$tpl_vars{INTERVAL} = $cgi->param('slideshow');
			$tpl_vars{META} .=  fill_in_file($tpl_vars{refresh},
				HASH => \%tpl_vars,
			);

		}
		else {
			$tpl_vars{SLIDESHOW} .=  fill_in_file($tpl_vars{slideshowisoff},
				HASH => \%tpl_vars,
			);
		}

		$tpl_vars{MAIN} = fill_in_file($tpl_vars{picture},
			HASH => \%tpl_vars,
		);
		$tpl_vars{MAIN} = fill_in_file($tpl_vars{layout},
			HASH => \%tpl_vars,
		);

		$r->content_type('text/html');
		$r->headers_out->{'Content-Length'} = length($tpl_vars{MAIN});

		if (!MP2) {
			$r->send_http_header;
		}

		$r->print($tpl_vars{MAIN});
		return MP2 ? Apache::OK : Apache::Constants::OK;

	}

}

sub cache_dir {

	my ($r, $strip_filename) = @_;

	my $cache_root;

	unless ($r->dir_config('GalleryCacheDir')) {

		$cache_root = '/var/tmp/Apache-Gallery/';
		if ($r->server->is_virtual) {
			$cache_root = File::Spec->catdir($cache_root, $r->server->server_hostname);
		} else {
			$cache_root = File::Spec->catdir($cache_root, $r->location);
		}

	} else {

		$cache_root = $r->dir_config('GalleryCacheDir');

	}

	my (undef, $dirs, $filename) = File::Spec->splitpath($r->uri);
	# We don't need a volume as this is a relative path

	if ($strip_filename) {
		return(File::Spec->canonpath(File::Spec->catdir($cache_root, $dirs)));
	} else {
		return(File::Spec->canonpath(File::Spec->catfile($cache_root, $dirs, $filename)));
	}
}

sub create_cache {

	my ($r, $path) = @_;

		unless (mkdirhier ($path)) {
			show_error($r, 500, $!, "Unable to create cache directory in $path: $!");
			return 0;
		}

	return 1;
}

sub mkdirhier {

	my $dir = shift;

	unless (-d $dir) {

		unless (mkdir($dir, 0755)) {
			my $parent = $dir;
			$parent =~ s/\/[^\/]*$//;

			mkdirhier($parent);

			mkdir($dir, 0755);
		}
	}
}

sub scale_picture {

	my ($r, $fullpath, $width, $height, $imageinfo) = @_;

	my @dirs = split(/\//, $fullpath);
	my $filename = pop(@dirs);

	my ($orig_width, $orig_height, $type) = imgsize($fullpath);

	my $cache = cache_dir($r, 1);

	if (($width > $orig_width) && ($height > $orig_height)) {
	    require File::Copy;
	    require File::Basename;

	    my $fname     = File::Basename::basename($fullpath);
	    my $cachefile = join("/",$cache,$fname);
	    File::Copy::copy($fullpath,$cachefile);

	    return $fname;
	}

	my ($thumbnailwidth, $thumbnailheight) = get_thumbnailsize($r, $orig_width, $orig_height);

	# Do we want to generate a new file in the cache?
	my $scale = 1;

	my $newfilename;
	if (grep $type eq $_, qw(PPM TIF GIF)) {
		$newfilename = $width."x".$height."-".$filename;
		# needs to be configurable
		$newfilename =~ s/\.(\w+)$/-$1\.jpg/;
	} else {
		$newfilename = $width."x".$height."-".$filename;
	}
	
	if (-f $cache."/".$newfilename) {	
		$scale = 0;

		# Check to see if the image has changed
		my $filestat = stat($fullpath);
		my $cachestat = stat($cache."/".$newfilename);
		if ($filestat->mtime > $cachestat->mtime) {
			$scale = 1;
		}	

		# Check to see if the .rotate file has been added or changed
		if (-f $fullpath . ".rotate") {
			my $rotatestat = stat($fullpath . ".rotate");
			if ($rotatestat->mtime > $cachestat->mtime) {
				$scale = 1;
			}	
		}		
		# Check to see if the copyrightimage has been added or changed
		if ($r->dir_config('GalleryCopyrightImage') && -f $r->dir_config('GalleryCopyrightImage')) {
			unless ($width == $thumbnailwidth or $width == $thumbnailheight) {
				my $copyrightstat = stat($r->dir_config('GalleryCopyrightImage'));
				if ($copyrightstat->mtime > $cachestat->mtime) {
					$scale = 1;
				}	
			}
		}	

	}	

	if ($scale) {

		my $newpath = $cache."/".$newfilename;
		my $rotate = readfile_getnum($r, $imageinfo, $fullpath . ".rotate");

		if ($width == $thumbnailwidth or $width == $thumbnailheight) {

		    resizepicture($fullpath, $newpath, $width, $height, $rotate, '', '', '', '', '');

		} else {

				resizepicture($fullpath, $newpath, $width, $height, $rotate, 
					($r->dir_config('GalleryCopyrightImage') ? $r->dir_config('GalleryCopyrightImage') : ''), 
					($r->dir_config('GalleryTTFDir') ? $r->dir_config('GalleryTTFDir') : ''), 
					($r->dir_config('GalleryCopyrightText') ? $r->dir_config('GalleryCopyrightText') : ''), 
					($r->dir_config('GalleryCopyrightColor') ? $r->dir_config('GalleryCopyrightColor') : ''), 
					($r->dir_config('GalleryTTFFile') ? $r->dir_config('GalleryTTFFile') : ''), 
					($r->dir_config('GalleryTTFSize') ?  $r->dir_config('GalleryTTFSize') : ''));

		}
	}

	return $newfilename;

}

sub get_thumbnailsize {
	my ($r, $orig_width, $orig_height) = @_;

	my $gallerythumbnailsize=$r->dir_config('GalleryThumbnailSize');

	if (defined($gallerythumbnailsize)) {
		warn("Invalid setting for GalleryThumbnailSize") unless
			$gallerythumbnailsize =~ /^\s*\d+\s*x\s*\d+\s*$/i;
	}

	my ($thumbnailwidth, $thumbnailheight) = split(/x/i, ($gallerythumbnailsize) ?  $gallerythumbnailsize : "100x75");

	my $width = $thumbnailwidth;
	my $height = $thumbnailheight;

        # If the image is rotated, flip everything around.
        if (defined $r->dir_config('GalleryThumbnailSizeLS')
	    and $r->dir_config('GalleryThumbnailSizeLS') eq '1'
	    and $orig_width < $orig_height) {
		$width = $thumbnailheight;
		$height = $thumbnailwidth;
	}

	my $scale = ($orig_width ? $width/$orig_width : 1);

	if ($orig_height) {
		if ($orig_height * $scale > $thumbnailheight) {
			$scale = $height/$orig_height;
			$width = $orig_width * $scale;
		}
	}

	$height = $orig_height * $scale;

	$height = floor($height);
	$width  = floor($width);

	return ($width, $height);
}

sub get_imageinfo {
	my ($r, $file, $type, $width, $height) = @_;
	my $imageinfo = {};
	if ($type eq 'Data stream is not a known image file format') {
		# should never be reached, this is supposed to be handled outside of here
		Apache->request->log_error("Something was fishy with the type of the file $file\n");
	} elsif (grep $type eq $_, qw(PPM TIF PNG GIF)) {
		# These files do not natively have EXIF info embedded in the file
		my $tmpfilename = $file;
		# We have a problem with Windows based file extensions here as they are often .THM
		$tmpfilename =~ s/\.(\w+)$/.thm/;
		if (-e $tmpfilename && -f $tmpfilename && -r $tmpfilename) {
			$imageinfo = image_info($tmpfilename);
		}
	} elsif (grep $type eq $_, qw(JPG)) {
		# Only for files that natively keep the EXIF info in the same file
		$imageinfo = image_info($file);
	}

	unless (defined($imageinfo->{width}) and defined($imageinfo->{height})) {
		$imageinfo->{width} = $width;
		$imageinfo->{height} = $height;
	}

	my @infos = split /, /, $r->dir_config('GalleryInfo') ? $r->dir_config('GalleryInfo') : 'Picture Taken => DateTimeOriginal, Flash => Flash';
	foreach (@infos) {
		
		my ($human_key, $exif_key) = (split " => ")[0,1];
		if (defined($imageinfo->{$exif_key})) {
			my $value = "";
			if (ref($imageinfo->{$exif_key}) eq 'Image::TIFF::Rational') { 
				$value = $imageinfo->{$exif_key}->as_string;
			} 
			elsif (ref($imageinfo->{$exif_key}) eq 'ARRAY') {
				foreach my $element (@{$imageinfo->{$exif_key}}) {
					if (ref($element) eq 'ARRAY') {
						foreach (@{$element}) {
							$value .= $_ . ' ';
						}
					} 
					elsif (ref($element) eq 'HASH') {
						$value .= "<br>{ ";
			    		foreach (sort keys %{$element}) {
							$value .= "$_ = " . $element->{$_} . ' ';
						}
			    		$value .= "} ";
					} 
					else {
						$value .= $element;
					}
					$value .= ' ';
				}
			} 
			else {
				my $exif_value = $imageinfo->{$exif_key};
				if ($human_key eq 'Flash' && $exif_value =~ m/\d/) {
					my %flashmodes = (
						"0"  => "No",
						"1"  => "Yes",
						"9"  => "Yes",
						"16" => "No (Compulsory) Should be External Flash",
						"17" => "Yes (External)",
						"24" => "No",
						"25" => "Yes (Auto)",
						"73" => "Yes (Compulsory, Red Eye Reducing)",
						"89" => "Yes (Auto, Red Eye Reducing)"
					);
					$exif_value = defined $flashmodes{$exif_value} ? $flashmodes{$exif_value} : 'unknown flash mode';
				}
				$value = $exif_value;
			}
			if ($exif_key eq 'MeteringMode') {
				my $exif_value = $imageinfo->{$exif_key};
				if ($exif_value =~ /^\d+$/) {
					my %meteringmodes = (
						'0' => 'unknown',
						'1' => 'Average',
						'2' => 'CenterWeightedAverage',
						'3' => 'Spot',
						'4' => 'MultiSpot',
						'5' => 'Pattern',
						'6' => 'Partial',
						'255' => 'Other'
					);
					$exif_value = defined $meteringmodes{$exif_value} ? $meteringmodes{$exif_value} : 'unknown metering mode';
				}
				$value = $exif_value;
				
			}
			if ($exif_key eq 'LightSource') {
				my $exif_value = $imageinfo->{$exif_key};
				if ($exif_value =~ /^\d+$/) {
					my %lightsources = (
						'0' => 'unknown',
						'1' => 'Daylight',
						'2' => 'Fluorescent',
						'3' => 'Tungsten (incandescent light)',
						'4' => 'Flash',
						'9' => 'Fine weather',
						'10' => 'Cloudy weather',
						'11' => 'Shade',
						'12' => 'Daylight fluorescent',
						'13' => 'Day white fluorescent',
						'14' => 'Cool white fluorescent',
						'15' => 'White fluorescent',
						'17' => 'Standard light A',
						'18' => 'Standard light B',
						'19' => 'Standard light C',
						'20' => 'D55',
						'21' => 'D65',
						'22' => 'D75',
						'23' => 'D50',
						'24' => 'ISO studio tungsten',
						'255' => 'other light source'
					);
					$exif_value = defined $lightsources{$exif_value} ? $lightsources{$exif_value} : 'unknown light source';
				}
				$value = $exif_value;
			}
			if ($exif_key eq 'FocalLength') {
				if ($value =~ /^(\d+)\/(\d+)$/) {
					$value = eval { $1 / $2 };
					if ($@) {
						$value = $@;
					} else {
						$value = int($value + 0.5) . "mm";

					}
				}
			}
			if ($exif_key eq 'ShutterSpeedValue') {
				if ($value =~ /^((?:\-)?\d+)\/(\d+)$/) {
					$value = eval { $1 / $2 };
					if ($@) {
						$value = $@;
					} else {
						eval {
							$value = 1/(exp($value*log(2)));
							if ($value < 1) {
								$value = "1/" . (int((1/$value)));
							} else {
						  	 	$value = int($value*10)/10; 
							}
						};
						if ($@) {
							$value = $@;
						} else {
							$value = $value . " sec";
						}
					}
				}
			}
			if ($exif_key eq 'ApertureValue') {
				if ($value =~ /^(\d+)\/(\d+)$/) {
					$value = eval { $1 / $2 };
					if ($@) {
						$value = $@;
					} else {
						# poor man's rounding
						$value = int(exp($value*log(2)*0.5)*10)/10;
						$value = "f" . $value;
					}
				}
			}
			if ($exif_key eq 'FNumber') {
				if ($value =~ /^(\d+)\/(\d+)$/) {
					$value = eval { $1 / $2 };
					if ($@) {
						$value = $@;
					} else {
						$value = int($value*10+0.5)/10;
						$value = "f" . $value;
					}
				}
			}
			$imageinfo->{$human_key} = $value;
		} 
	}

	if ($r->dir_config('GalleryUseFileDate') &&
		($r->dir_config('GalleryUseFileDate') eq '1'
		|| !$imageinfo->{"Picture Taken"} )) {

		my $st = stat($file);
		$imageinfo->{"DateTimeOriginal"} = $imageinfo->{"Picture Taken"} = scalar localtime($st->mtime) if $st;
	}

	return $imageinfo;
}

sub readfile_getnum {
	my ($r, $imageinfo, $filename) = @_;

	my $rotate = 0;

	# Check to see if the image contains the Orientation EXIF key,
	# but allow user to override using rotate
	if (!defined($r->dir_config("GalleryAutoRotate")) 
		|| $r->dir_config("GalleryAutoRotate") eq "1") {
		if (defined($imageinfo->{Orientation})) {
			if ($imageinfo->{Orientation} eq 'right_top') {
				$rotate=1;
			}	
			elsif ($imageinfo->{Orientation} eq 'left_bot') {
				$rotate=3;
			}
		}
	}

	if (open(FH, "<$filename")) {
		my $temp = <FH>;
		chomp($temp);
		close(FH);
		unless ($temp =~ /^\d$/) {
			$rotate = 0;
		}
		unless ($temp == 1 || $temp == 2 || $temp == 3) {
			$rotate = 0;
		}
		$rotate = $temp;
	}

	return $rotate;
}

sub get_filecontent {
	my $file = shift;
	open(FH, $file) or return undef;
	my $content = '';
	{
	local $/;
	$content = <FH>;
	}
	close(FH);
	return $content;
}

sub get_comment {
	my $filename = shift;
	my $comment_ref = {};
 	$comment_ref->{TITLE} = undef;
	$comment_ref->{COMMENT} = '';

	open(FH, $filename) or return $comment_ref;
	my $title = <FH>;
	if ($title =~ m/^TITLE: (.*)$/) {
		chomp($comment_ref->{TITLE} = $1);
	} 
	else {
		$comment_ref->{COMMENT} = $title;
	}

	while (<FH>) {
		chomp;
		$comment_ref->{COMMENT} .= $_;
	}
	close(FH);

	return $comment_ref;
}

sub show_error {

	my ($r, $statuscode, $errortitle, $error) = @_;

	my $tpl = $r->dir_config('GalleryTemplateDir');

	my %tpl_vars = (layout => "$tpl/layout.tpl",
			error  => "$tpl/error.tpl",
		       );

	$tpl_vars{TITLE}      = "Error! $errortitle";
	$tpl_vars{META}       = "";
	$tpl_vars{ERRORTITLE} = "Error! $errortitle";
	$tpl_vars{ERROR}      = $error;

	$tpl_vars{MAIN} = fill_in_file($tpl_vars{error},
		HASH => \%tpl_vars,
	);

	$tpl_vars{PAGE} = fill_in_file($tpl_vars{layout},
		HASH => \%tpl_vars,
 	);

	$r->status($statuscode);
	$r->content_type('text/html');

	$r->print($tpl_vars{PAGE});

}

sub generate_menu {

	my $r = shift;

	my $subr = $r->lookup_uri($r->uri);
	my $filename = $subr->filename;

	my @links = split (/\//, $r->uri);

	# Get the full path of the base directory
	my $dirname;
	{
		my @direlem = split (/\//, $filename);
		for my $i ( 0 .. ( scalar(@direlem) - scalar(@links) ) ) {
			$dirname .= shift(@direlem) . '/';
		}
		chop $dirname;
	}

	my $picturename;
	if (-f $filename) {
		$picturename = pop(@links);	
	}

	my $root_text = (defined($r->dir_config('GalleryRootText')) ? $r->dir_config('GalleryRootText') : "root:" );
	if ($r->uri eq '/') {
		return qq{ <a href="/">$root_text</a> };
	}

	my $menu;
	my $menuurl;
	foreach my $link (@links) {

		$menuurl .= $link."/";
		my $linktext = $link;
		unless (length($link)) {
			$linktext = "$root_text ";
		}
		else {
			
			$dirname = File::Spec->catdir($dirname, $link);

			if (-e $dirname . ".folder") {
				$linktext = get_filecontent($dirname . ".folder");
			}
		}

		$menu .= "<a href=\"".uri_escape($menuurl, $escape_rule)."\">$linktext</a> / ";

	}

	if (-f $filename) {
		$menu .= $picturename;
	}
	else {

		if ($r->dir_config('GallerySelectionMode') && $r->dir_config('GallerySelectionMode') eq '1') {
			$menu .= "<a href=\"".uri_escape($menuurl, $escape_rule);
			$menu .= "?select=1\">[select]</a> ";
		}
	}

	return $menu;
}

sub resizepicture {
	my ($infile, $outfile, $x, $y, $rotate, $copyrightfile, $GalleryTTFDir, $GalleryCopyrightText, $text_color, $GalleryTTFFile, $GalleryTTFSize) = @_;

	# Load image
	my $image = Image::Imlib2->load($infile) or warn("Unable to open file $infile, $!");

	# Scale image
	$image=$image->create_scaled_image($x, $y) or warn("Unable to scale image $infile. Are you running out of memory?");

	# Rotate image
	if ($rotate != 0) {
		$image->image_orientate($rotate);
	}

	# blend copyright image onto image
 	if ($copyrightfile ne '') {
		if (-f $copyrightfile and (my $logo=Image::Imlib2->load($copyrightfile))) {
			my $x = $image->get_width();
			my $y = $image->get_height();
			my $logox = $logo->get_width();
			my $logoy = $logo->get_height();
			$image->blend($logo, 0, 0, 0, $logox, $logoy, $x-$logox, $y-$logoy, $logox, $logoy);
		}
		else {
			Apache->request->log_error("GalleryCopyrightImage $copyrightfile was not found\n");
		}
	}

	if ($GalleryTTFDir && $GalleryCopyrightText && $GalleryTTFFile, $text_color) {
		if (!-d $GalleryTTFDir) {

			Apache->request->log_error("GalleryTTFDir $GalleryTTFDir is not a dir\n");

		} elsif ($GalleryCopyrightText eq '') {

			Apache->request->log_error("GalleryCopyrightText is empty. No text inserted to picture\n");

		} elsif (!-e "$GalleryTTFDir/$GalleryTTFFile") {

			Apache->request->log_error("GalleryTTFFile $GalleryTTFFile was not found\n");

		} else {
 
			$GalleryTTFFile =~ s/\.TTF$//i;
			$image->add_font_path("$GalleryTTFDir");

			my ($r_val, $g_val, $b_val, $a_val) = split (/,/, $text_color);

			$image->set_colour($r_val, $g_val, $b_val, $a_val);

			$image->load_font("$GalleryTTFFile/$GalleryTTFSize");
			my($text_x, $text_y) = $image->get_text_size("$GalleryCopyrightText");
			my $x = $image->get_width();
			my $y = $image->get_height();

			my $offset = 3;

			if (($text_x < $x - $offset) && ($text_y < $y - $offset)) {
				$image->draw_text($x-$text_x-$offset, $y-$text_y-$offset, "$GalleryCopyrightText");
			} else {
				Apache->request->log_error("Text is to big for the picture.\n");
			}
		}
	}
 
	$image->save($outfile);

}

1;

=head1 NAME

Apache::Gallery - mod_perl handler to create an image gallery

=head1 SYNOPSIS

See the INSTALL file in the distribution for installation instructions.

=head1 DESCRIPTION

Apache::Gallery creates an thumbnail index of each directory and allows 
viewing pictures in different resolutions. Pictures are resized on the 
fly and cached. The gallery can be configured and customized in many ways
and a custom copyright image can be added to all the images without
modifying the original.

=head1 CONFIGURATION

In your httpd.conf you set the global options for the gallery. You can
also override each of the options in .htaccess files in your gallery
directories.

The options are set in the httpd.conf/.htaccess file using the syntax:
B<PerlSetVar OptionName 'value'>

Example: B<PerlSetVar GalleryCacheDir '/var/tmp/Apache-Gallery/'>

=over 4

=item B<GalleryAutoRotate>

Some cameras, like the Canon G3, can detect the orientation of a 
the pictures you take and will save this information in the 
'Orientation' EXIF field. Apache::Gallery will then automatically
rotate your images. 

This behavior is default but can be disabled by setting GalleryAutoRotate
to 0.

=item B<GalleryCacheDir>

Directory where Apache::Gallery should create its cache with scaled
pictures. The default is /var/tmp/Apache-Gallery/ . Here, a directory
for each virtualhost or location will be created automaticly. Make
sure your webserver has write access to the CacheDir.

=item B<GalleryTemplateDir>

Full path to the directory where you placed the templates. This option
can be used both in your global configuration and in .htaccess files,
this way you can have different layouts in different parts of your 
gallery.

No default value, this option is required.

=item B<GalleryInfo>

With this option you can define which EXIF information you would like
to present from the image. The format is: '<MyName => KeyInEXIF, 
MyOtherName => OtherKeyInEXIF'

Examples of keys: B<ShutterSpeedValue>, B<ApertureValue>, B<SubjectDistance>,
and B<Camera>

You can view all the keys from the EXIF header using this perl-oneliner:

perl C<-e> 'use Data::Dumper; use Image::Info qw(image_info); print Dumper(image_info(shift));' filename.jpg

Default is: 'Picture Taken => DateTimeOriginal, Flash => Flash'

=item B<GallerySizes>

Defines which widths images can be scaled to. Images cannot be
scaled to other widths than the ones you define with this option.

The default is '640 800 1024 1600'

=item B<GalleryThumbnailSize>

Defines the width and height of the thumbnail images. 

Defaults to '100x75'

=item B<GalleryThumbnailSizeLS>

If set to '1', B<GalleryThumbnailSize> is the long and the short side of
the thumbnail image instead of the width and height.

Defaults to '0'.

=item B<GalleryCopyrightImage>

Image you want to blend into your images in the lower right
corner. This could be a transparent png saying "copyright
my name 2001".

Optional.

=item B<GalleryWrapNavigation>

Make the navigation in the picture view wrap around (So Next
at the end displays the first picture, etc.)

Set to 1 or 0, default is 0

=item B<GalleryAllowOriginal>

Allow the user to download the Original picture without
resizing or putting the CopyrightImage on it.

Set to 1 or 0, default is 0

=item B<GallerySlideshowIntervals>

With this option you can configure which intervals can be selected for
a slideshow. The default is '3 5 10 15 30'

=item B<GallerySortBy>

Instead of the default filename ordering you can sort by any
stat attribute. For example size, atime, mtime, ctime.

=item B<GalleryMemoize>

Cache EXIF data using Memoize - this will make Apache::Gallery faster
when many people access the same images, but it will also cache EXIF
data until the current Apache child dies.

=item B<GalleryUseFileDate>

Set this option to 1 to make A::G show the files timestamp
instead of the EXIF value for "Picture taken".

=item B<GallerySelectionMode>

Enable the selection mode. Select images with checkboxes and
get a list of filenames. 

=item B<GalleryEXIFMode>

You can choose how Apache::Gallery should display EXIF info
from your images. 

The default setting is 'namevalue'. This setting will make 
Apache::Gallery print out the names and values of the EXIF values 
you configure with GalleryInfo. The information will be parsed into 
$INFO in pictureinfo.tpl.  

You can also set it to 'values' which will make A::G parse
the configured values into the var $EXIFVALUES as 'value | value | value'

If you set this option to 'variables' the items you configure in GalleryInfo 
will be available to your templates as $EXIF_<KEYNAME> (in all uppercase). 
That means that with the default setting "Picture Taken => DateTimeOriginal, 
Flash => Flash" you will have the variables $EXIF_DATETIMEORIGINAL and 
$EXIF_FLASH avilable to your templates. You can place them
anywhere you want.

=item B<GalleryRootText>

Change the name that appears as the root element in the menu. The
default is "root:"

=item B<GalleryMaxThumbnailsPerPage>

This options controls how many thumbnails should be displayed in a 
page. It requires $BROWSELINKS to be in the index.tpl template file.

=item B<GalleryImgFile>

Pattern matching the files you want Apache::Gallery to view in the
index as thumbnails. 

The default is '\.(jpe?g|png|tiff?|ppm)$'

=item B<GalleryDocFile>

Pattern matching the files you want Apache::Gallery to view in the index
as normal files. All other filetypes will still be served by Apache::Gallery
but are not visible in the index.

The default is '\.(mpe?g|avi|mov|asf|wmv|doc|mp3|ogg|pdf|rtf|wav|dlt|html?|csv|eps)$'

=item B<GalleryTTFDir>

To use the GalleryCopyrightText feature you must set this option to the
directory where your True Type fonts are stored. No default is set.

Example:

	PerlSetVar      GalleryTTFDir '/usr/share/fonts/'

=item B<GalleryTTFFile>

To use the GalleryCopyrightText feature this option must be set to the
name of the True Type font you wish to use. Example:

	PerlSetVar      GalleryTTFFile 'verdanab.ttf'

=item B<GalleryTTFSize>

Configure the size of the CopyrightText that will be inserted as 
copyright notice in the corner of your pictures.

Example:

	PerlSetVar      GalleryTTFSize '10'

=item B<GalleryCopyrightText>

The text that will be inserted as copyright notice.

Example:

        PerlSetVar      GalleryCopyrightText '(c) Michael Legart'

=item B<GalleryCopyrightColor>

The text color of your copyright notice.

Examples:

White:
        PerlSetVar      GalleryCopyrightColor '255,255,255,255'

Black:
        PerlSetVar      GalleryCopyrightColor '0,0,0,255'

Red:
        PerlSetVar      GalleryCopyrightColor '255,0,0,255'

Green:
        PerlSetVar      GalleryCopyrightColor '0,255,0,255'

Blue:
        PerlSetVar      GalleryCopyrightColor '0,0,255,255'

Transparent orange:
        PerlSetVar      GalleryCopyrightColor '255,127,0,127'

=back

=head1 FEATURES

=over 4

=item B<Rotate images>

Some cameras, like the Canon G3, detects the orientation of a picture
and adds this info to the EXIF header. Apache::Gallery detects this
and automaticly rotates images with this info.

If your camera does not support this, you can rotate the images 
manually, This can also be used to override the rotate information
from a camera that supports that. You can also disable this behavior
with the GalleryAutoRotate option.

To use this functionality you have to create file with the name of the 
picture you want rotated appened with ".rotate". The file should include 
a number where these numbers are supported:

	"1", rotates clockwise by 90 degree
	"2", rotates clockwise by 180 degrees
	"3", rotates clockwise by 270 degrees

So if we want to rotate "Picture1234.jpg" 90 degrees clockwise we would
create a file in the same directory called "Picture1234.jpg.rotate" with
the number 1 inside of it.

=item B<Comments>

To include comments for a directory you create a directory.comment
file where the first line can contain "TITLE: New title" which
will be the title of the page, and a comment on the following 
lines.
To include comments for each picture you create files called 
picture.jpg.comment where the first line can contain "TITLE: New
title" which will be the title of the page, and a comment on the
following lines.

Example:

	TITLE: This is the new title of the page
	And this is the comment.<br>
	And this is line two of the comment.

The visible name of the folder is by default identical to the name of
the folder, but can be changed by creating a file <directory>.folder
with the visible name of the folder.

=back

=head1 DEPENDENCIES

=over 4

=item B<Perl 5>

=item B<Apache with mod_perl>

=item B<URI::Escape>

=item B<Image::Info>

=item B<Image::Size>

=item B<Text::Template>

=item B<Image::Imlib2>

=item B<X11 libraries>
(ie, XFree86)

=item B<Imlib2>
Remember the -dev package when using rpm, deb or other package formats!

=back

=head1 AUTHOR

Michael Legart <michael@legart.dk>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2001-2003 Michael Legart <michael@legart.dk>

Templates designed by Thomas Kjaer <tk@lnx.dk>

Apache::Gallery is free software and is released under the Artistic License.
See B<http://www.perl.com/language/misc/Artistic.html> for details.

The video icons are from the GNOME project. B<http://www.gnome.org/>

=head1 THANKS

Thanks to Thomas Kjaer for templates and design of B<http://apachegallery.dk>
Thanks to Thomas Eibner and other for patches. (See the Changes file)

=head1 SEE ALSO

L<perl>, L<mod_perl>, L<Image::Imlib2>, L<CGI::FastTemplate>,
L<Image::Info>, and L<Image::Size>.

=cut
