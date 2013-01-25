package Apache::Gallery;

# $Author$ $Rev$
# $Date$

use strict;

use vars qw($VERSION);
use Time::HiRes qw/time/;

$VERSION = "1.1";

BEGIN {

	if (exists($ENV{MOD_PERL_API_VERSION})
		and ($ENV{MOD_PERL_API_VERSION}==2)) {
		require mod_perl2;
		if ($mod_perl::VERSION >= 1.99 && $mod_perl::VERSION < 2.0) {
			die "mod_perl 2.0.0 or later is now required";
		}
		require Apache2::ServerRec;
		require Apache2::RequestRec;
		require Apache2::Log;
		require APR::Table;
		require Apache2::RequestIO;
		require Apache2::SubRequest;
		require Apache2::Const;
	
		Apache2::Const->import(-compile => 'OK','DECLINED','FORBIDDEN','NOT_FOUND','HTTP_NOT_MODIFIED','HTTP_NO_CONTENT');

		$::MP2 = 1;
	} else {
		require mod_perl;

		require Apache;
		require Apache::Constants;
		require Apache::Request;
	
		Apache::Constants->import('OK','DECLINED','FORBIDDEN','NOT_FOUND');
		$::MP2 = 0;
	}
}

use Image::Info qw(image_info);
use Image::Size qw(imgsize);
use Image::Imlib2;
use Text::Template;
use File::stat;
use File::Spec;
use POSIX qw(floor);
use URI::Escape;
use CGI;
use CGI::Cookie;
use Encode;
use HTTP::Date;
use Digest::MD5 qw(md5_base64);

use Data::Dumper;

# Regexp for escaping URI's
my $escape_rule = "^A-Za-z0-9\-_.!~*'()\/";
my $memoized;

my $time;
my $timeurl;

sub handler {

	my $r = shift or Apache2::RequestUtil->request();

	log_info("Apache Gallery request for " . $r->uri);

	$time = time();
	$timeurl = $r->uri;

	unless (($r->method eq 'HEAD') or ($r->method eq 'GET')) {
		return $::MP2 ? Apache2::Const::DECLINED() : Apache::Constants::DECLINED();
	}

	if ((not $memoized) and ($r->dir_config('GalleryMemoize'))) {
		require Memoize;
		Memoize::memoize('get_imageinfo');
		$memoized=1;
	}

	$r->headers_out->{"X-Powered-By"} = "apachegallery.dk $VERSION - Hest design!";
	$r->headers_out->{"X-Gallery-Version"} = '$Rev$ $Date$';

	my $filename = $r->filename;
	$filename =~ s/\/$//;
	my $topdir = $filename;

	my $media_rss_enabled = $r->dir_config('GalleryEnableMediaRss');

	# Just return the http headers if the client requested that
	if ($r->header_only) {

		if (!$::MP2) {
			$r->send_http_header;
		}

		if (-f $filename or -d $filename) {
			return $::MP2 ? Apache2::Const::OK() : Apache::Constants::OK();
		}
		else {
			return $::MP2 ? Apache2::Const::NOT_FOUND() : Apache::Constants::NOT_FOUND();
		}
	}

	my $cgi = new CGI;

	# Handle selected images
	if ($cgi->param('selection')) {
		my @selected = $cgi->param('selection');
		my $content = join "<br />\n",@selected;
		$r->content_type('text/html');
		$r->headers_out->{'Content-Length'} = length($content);

		if (!$::MP2) {
			$r->send_http_header;
		}

		$r->print($content);
		return $::MP2 ? Apache2::Const::OK() : Apache::Constants::OK();
	}
	
	# Selectmode providing checkboxes beside all thumbnails
	my $select_mode = $cgi->param('select');
	
	# Let Apache serve icons or favicon without us modifying the request
	if ($r->uri =~ m!^/ApacheGallery/!i || $r->uri =~ m!^/favicon.ico!i) {
		return $::MP2 ? Apache2::Const::DECLINED() : Apache::Constants::DECLINED();
	}

	my $img_pattern = $r->dir_config('GalleryImgFile');
	unless ($img_pattern) {
		$img_pattern = '\.(jpe?g|png|tiff?|ppm)$'
	}

	# Addition by Matt Blissett, June 2011.
	# FOLDER ICONS
	if ($r->uri =~ m/\.cache\/\.bg-/i) {
		log_info("Folder background picture " . $r->filename().$r->path_info());

		my $dirname = $r->filename().$r->path_info();

		$dirname =~ m/\/\.bg-(\d+)/;
		my $image_size = $1;
		log_debug("BG Pic size $image_size");

		$dirname =~ s!/.cache/.bg.*!!;
		log_debug("BG Dirname: $dirname");

		unless (opendir (DIR, $dirname)) {
			show_error ($r, 500, $!, "Unable to access directory $dirname: $!");
			return $::MP2 ? Apache2::Const::OK() : Apache::Constants::OK();
		}

		my $file = cache_dir($r, 0);
		$file =~ s/\.cache//;

		my $subr = $r->lookup_file($file);
		$r->content_type($subr->content_type());

		if (-f $file) {
			# file already in cache
			log_info("Background picture already in cache: $file");
		}
		else {
			my @files = sort grep { !/^\./ && /$img_pattern/i && -f "$dirname/$_" && -r "$dirname/$_" } readdir (DIR);

			if ($#files+1 <= 0) {
				log_debug("No files, returning 204");
				return $::MP2 ? Apache2::Const::HTTP_NO_CONTENT() : Apache::Constants::NOT_FOUND();
			}

			log_debug(($#files+1) . " files " . $files[0]);

			my $newfilename = ".bg-$image_size.jpg";

			my ($width, $height, $type) = imgsize($dirname."/".$files[0]);

			my $imageinfo = get_imageinfo($r, $dirname."/".$files[0], $type, $width, $height);

			log_debug("Making folder bg image from files: " . join(', ', @files));
			log_debug("Making folder bg image with: $imageinfo");

			my $cached = album_cover_picture($r, $image_size, $image_size, $imageinfo, $dirname, $newfilename, @files);

			log_debug("Made folder bg image $cached, $r");
		}

		return send_file_response($r, $file, "BGIMG");
	}
	# END FOLDER ICONS

	# Addition by Matt Blissett, May 2011.
	# XML GEOREFERENCES file for a map
	if ($r->uri =~ m/\.cache\/\.points\.xml$/i) {
		log_debug("Points: " . $r->filename().$r->path_info());

		my $dirname = $r->filename().$r->path_info();
		$dirname =~ s!/.cache/.points.xml!!;
		log_debug("Points: dirname: $dirname");

		unless (opendir (DIR, $dirname)) {
			show_error ($r, 500, $!, "Unable to access directory $dirname: $!");
			return $::MP2 ? Apache2::Const::OK() : Apache::Constants::OK();
		}

		my @files = sort grep { !/^\./ && /$img_pattern/i && -f "$dirname/$_" && -r "$dirname/$_" } readdir (DIR);

		log_debug("Points: $#files files");

		my $file = cache_dir($r, 0);
		log_debug("Points file is " . $file);

		$r->content_type('application/xml');

		if (-f $file) {
			# file already in cache
			log_debug("Points: file already in cache: $file");
		}
		else {
			my %tpl_vars;

			my $tpl_dir = $r->dir_config('GalleryTemplateDir');

			# Could check for these being in the template.
			my %templates = create_templates({
				point     => "$tpl_dir/point.tpl",
				points    => "$tpl_dir/points.tpl"
			});

			if (@files) {
				my $filelist;

				my $file_counter = 0;

				foreach my $file (@files) {
					log_debug("Points: scanning file $file_counter " . $file);
					$file_counter++;
					my $filename = $dirname."/".$file;
					log_debug("Points: filename " . $filename);

					my $dirurl = $r->uri;
					$dirurl =~ s!.cache/.points.xml!!;
					#$fileurl .= $file;
					log_debug("Points: dirurl " . $dirurl);

					if (-f $filename) { # image
						# Check it's an image
						my ($width, $height, $type) = imgsize($filename);
						next if $type eq 'Data stream is not a known image file format';

						my @filetypes = qw(JPG TIF PNG PPM GIF);

						next unless (grep $type eq $_, @filetypes);

						# Thumbnail dimensions needed for URL to thumbnail
						my ($thumbnailwidth, $thumbnailheight) = get_thumbnailsize($r, $width, $height);
						my $cached = get_scaled_picture_name($filename, $thumbnailwidth, $thumbnailheight);
						log_debug("Points: thumbnail name $cached");

						# Read EXIF info
						my $imageinfo = get_imageinfo($r, $filename, $type, $width, $height);

						my %point_vars = (
							FILE => $file,
							STATUS => $imageinfo->{GPSStatus} ? $imageinfo->{GPSStatus} : '',
							LATR => $imageinfo->{GPSLatitudeRef} ? $imageinfo->{GPSLatitudeRef} : '',
							LONGR => $imageinfo->{GPSLongitudeRef} ? $imageinfo->{GPSLongitudeRef} : '',
							LAT => $imageinfo->{GPSLatitude} ? $imageinfo->{GPSLatitude} : '',
							LONG => $imageinfo->{GPSLongitude} ? $imageinfo->{GPSLongitude} : '',
							THUMB => uri_escape($dirurl.".cache/$cached", $escape_rule),
						);

						if (-f $filename . '.comment') {
							log_debug("Points: Found .comment file " . $filename . '.comment');
							my $comment_ref = get_comment($filename . '.comment');
							$tpl_vars{COMMENT} = $comment_ref->{COMMENT} . "\n" if $comment_ref->{COMMENT};
							$tpl_vars{TITLE} = $comment_ref->{TITLE} if $comment_ref->{TITLE};
						} elsif ($r->dir_config('GalleryCommentExifKey')) {
							my $comment = decode("utf8", $imageinfo->{$r->dir_config('GalleryCommentExifKey')});
							$tpl_vars{COMMENT} = encode("iso-8859-1", $comment);
						} else {
							$tpl_vars{COMMENT} = undef;
							$tpl_vars{TITLE} = undef;
						}
						log_debug("Points: Title: ".$tpl_vars{TITLE});
						log_debug("Points: Comment: ".$tpl_vars{COMMENT});

						$tpl_vars{POINTS} .= $templates{point}->fill_in(
							HASH => {%tpl_vars, %point_vars},
						);
					}
				}
			}
			else {
				$tpl_vars{POINTS} = "";
			}

			$tpl_vars{MAIN} = $templates{points}->fill_in(HASH => \%tpl_vars);

			# put $tpl_vars{MAIN} into the file.
			if (open(P, ">$file")) {
				print P $tpl_vars{MAIN};
				close(P);
			}
		}

		return send_file_response($r, $file, "POINTS");
	}
	# End XML GEOREFERENCES

	# Lookup the file in the cache and scale the image if the cached
	# image does not exist
	if ($r->uri =~ m/\.cache\//i) {

		my $filename = $r->filename().$r->path_info();
		my $file = cache_dir($r, 0);

		# Check if the cache image already exists, and assume it's OK if it does.
		# NB: this bypasses the check for a changed file / changed .rotate / changed GalleryCopyrightImage
		unless (-f $file) {
			$filename =~ s/\.cache//;

			$filename =~ m/\/(\d+)x(\d+)\-/;
			my $image_width = $1;
			my $image_height = $2;

			$filename =~ s/\/(\d+)x(\d+)\-//;

			my ($width, $height, $type) = imgsize($filename);

			my $imageinfo = get_imageinfo($r, $filename, $type, $width, $height);

			my $cached = scale_picture($r, $filename, $image_width, $image_height, $imageinfo);

			my $file = cache_dir($r, 0);
			$file =~ s/\.cache//;
		}

		my $subr = $r->lookup_file($file);
		$r->content_type($subr->content_type());

		return send_file_response($r, $file, "IMAGE");
	}

	my $uri = $r->uri;
	$uri =~ s/\/$//;

	unless (-f $filename or -d $filename) {
		show_error($r, 404, "404!", "No such file or directory: ".uri_escape($r->uri, $escape_rule));
		return $::MP2 ? Apache2::Const::OK() : Apache::Constants::OK();
	}

	my $doc_pattern = $r->dir_config('GalleryDocFile');
	unless ($doc_pattern) {
		$doc_pattern = '\.(mpe?g|avi|mov|asf|wmv|doc|mp3|ogg|pdf|rtf|wav|dlt|txt|html?|csv|eps)$'
	}
	my $vid_pattern = $r->dir_config('GalleryVidFile');
	unless ($vid_pattern) {
		$vid_pattern = '\.(ogv|webm|mp4)$'
	}

	# Let Apache serve files we don't know how to handle anyway
	if (-f $filename && $filename !~ m/$img_pattern/i && $filename !~ m/$vid_pattern/i) {
		return $::MP2 ? Apache2::Const::DECLINED() : Apache::Constants::DECLINED();
	}

	# Option to override the CSS file
	my $tpl_css = $r->dir_config('GalleryCssFilename');
	unless ($tpl_css) {
		$tpl_css = "modern.css";
	}

	if (-d $filename) {
		my $filename = $r->filename().$r->path_info();

		unless (opendir (DIR, $filename)) {
			show_error ($r, 500, $!, "Unable to access directory $filename: $!");
			return $::MP2 ? Apache2::Const::OK() : Apache::Constants::OK();
		}

		# Check for cached HTML for the directory
		my $file = cache_dir($r, 0);
		if ($cgi->param('rss')) {
			$file .= "/index.rss";
			$r->content_type('application/rss+xml');
		} else {
			$file .= "/index.html";
			$r->content_type('text/html');
		}
		log_debug("Album HTML cached as " . $file);

		my $usecache = 0;
		if (-f $file) {
		# TODO: check if directory has changed.
			my $dirstat = stat($filename);
			my $cachestat = stat($file);
			$usecache = ($dirstat->mtime < $cachestat->mtime);
		}

		if ($usecache) {
			if ($cgi->param('rss')) {
				$r->content_type('application/rss+xml');
			} else {
				$r->content_type('text/html');
			}
			return send_file_response($r, $file, "C-ALBUM");
		}

		# No cached HTML -- generate it.
		my $tpl_dir = $r->dir_config('GalleryTemplateDir');

		# Instead of reading the templates every single time
		# we need them, create a hash of template names and
		# the associated Text::Template objects.
		my %templates = create_templates({layout       => "$tpl_dir/layout.tpl",
						  index        => "$tpl_dir/index.tpl",
						  directory    => "$tpl_dir/directory.tpl",
						  picture      => "$tpl_dir/picture.tpl",
						  file         => "$tpl_dir/file.tpl",
						  comment      => "$tpl_dir/dircomment.tpl",
						  nocomment    => "$tpl_dir/nodircomment.tpl",
						  video        => "$tpl_dir/video.tpl",
						  rss          => "$tpl_dir/rss.tpl",
						  rss_item     => "$tpl_dir/rss_item.tpl",
						  navdirectory => "$tpl_dir/navdirectory.tpl",
						 });

		my %tpl_vars;

		$tpl_vars{TITLE} = "Index of: $uri";
		$tpl_vars{CSS} = $tpl_css;

		if ($media_rss_enabled) {
			# Put the RSS feed on all directory listings
			$tpl_vars{META} = '<link rel="alternate" href="?rss=1" type="application/rss+xml" title="" id="gallery" />';
		}

		$tpl_vars{MENU} = generate_menu($r);

		$tpl_vars{FORM_BEGIN} = $select_mode?'<form method="post">':'';
		$tpl_vars{FORM_END}   = $select_mode?'<input type="submit" name="Get list" value="Get list"></form>':'';

		# Read, sort, and filter files
		my @files = grep { !/^\./ && -f "$filename/$_" } readdir (DIR);

		@files=gallerysort($r, @files);

		my @downloadable_files;

		if (@files) {
			# Remove unwanted files from list
			my @new_files = ();
			foreach my $picture (@files) {

				my $file = $topdir."/".$picture;

				if ($file =~ /$img_pattern/i || $file =~ /$vid_pattern/i) {
					push (@new_files, $picture);
				}

				if ($file =~ /$doc_pattern/i) {
					push (@downloadable_files, $picture);
				}

			}
			@files = @new_files;
		}

		# Read and sort directories
		rewinddir (DIR);
		my @directories = grep { !/^\./ && -d "$filename/$_" } readdir (DIR);
		my $dirsortby;
		if (defined($r->dir_config('GalleryDirSortBy'))) {
			$dirsortby=$r->dir_config('GalleryDirSortBy');
		} else {
			$dirsortby=$r->dir_config('GallerySortBy');
		}
		if ($dirsortby && $dirsortby =~ m/^(size|atime|mtime|ctime)$/) {
			@directories = map(/^\d+ (.*)/, sort map(stat("$filename/$_")->$dirsortby()." $_", @directories));
		} else {
			@directories = sort @directories;
		}

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

				# Debian bug #619625 <http://bugs.debian.org/619625>
				if (-d $thumbfilename && ! -e $thumbfilename . ".ignore") {
					my $dirtitle = '';
					if (-e $thumbfilename . ".folder") {
						$dirtitle = get_filecontent($thumbfilename . ".folder");
					}

					$dirtitle = $dirtitle ? $dirtitle : $file;
					$dirtitle =~ s/_/ /g if $r->dir_config('GalleryUnderscoresToSpaces');

					$tpl_vars{FILES} .=
					     $templates{directory}->fill_in(HASH=> {FILEURL => uri_escape($fileurl, $escape_rule),
										    FILE    => $dirtitle,
										   }
									   );

				}
				# Debian bug #619625 <http://bugs.debian.org/619625>
				elsif (-f $thumbfilename && $thumbfilename =~ /$doc_pattern/i && $thumbfilename !~ /$img_pattern/i && $thumbfilename !~ /$vid_pattern/i && ! -e $thumbfilename . ".ignore") {
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
					} elsif ($thumbfilename =~ m/$doc_pattern/i) {
						$filetype = "application-$type";
					} else {
						$filetype = "unknown";
					}

					# Debian bug #348724 <http://bugs.debian.org/348724>
					# not images
					my $filetitle = $file;
					$filetitle =~ s/_/ /g if $r->dir_config('GalleryUnderscoresToSpaces');

					$tpl_vars{FILES} .=
					     $templates{file}->fill_in(HASH => {%tpl_vars,
										FILEURL => uri_escape($fileurl, $escape_rule),
										ALT => "Size: $size Bytes",
										FILE => $filetitle,
										TYPE => $type,
										FILETYPE => $filetype,
									       }
								      );
				}
				elsif (-f $thumbfilename && $thumbfilename =~ /$vid_pattern/i && ! -e $thumbfilename . ".ignore") {
					my $stat = stat($thumbfilename);
					my $size = $stat->size;
					my $magnitude = 0;
					while ($size > 1024) {
						$size = $size / 1024;
						$magnitude++;
					}
					my @mag = ("B", "kiB", "MiB", "GiB", "TiB");
					$size = int($size) . $mag[$magnitude];

					# Should generate the thumb file from the video
					my $posterthumbfilename = $thumbfilename;
					$posterthumbfilename =~ s/\....$/.thm/;

					my $posterthumburl = "/ApacheGallery/video-mpg.png";
					if (-f $posterthumbfilename) {
						$posterthumbfilename = $thumbfilename;
						$posterthumbfilename =~ s/\....$/.thm/;
						my ($width, $height, $type) = imgsize($posterthumbfilename);
						my @filetypes = qw(JPG TIF PNG PPM GIF);
						unless ($type eq 'Data stream is not a known image file format') {
							my ($thumbnailwidth, $thumbnailheight) = get_thumbnailsize($r, $width, $height);
							my $cached = get_scaled_picture_name($posterthumbfilename, $thumbnailwidth, $thumbnailheight);
							$posterthumburl = uri_escape(".cache/$cached", $escape_rule);
						}
					}
					log_debug("Video icon: using $posterthumburl");

					my %file_vars = (FILEURL => uri_escape($fileurl, $escape_rule),
							 FILE    => $file,
							 SIZE    => $size,
							 WIDTH   => 176,
							 HEIGHT  => 132,
							 POSTER  => uri_escape($posterthumburl, $escape_rule),
							 SELECT  => $select_mode?'<input type="checkbox" name="selection" value="'.$file.'">&nbsp;&nbsp;':'',
							 );
					$tpl_vars{FILES} .= $templates{video}->fill_in(HASH => {%tpl_vars,%file_vars});
				}
				# Debian bug #619625 <http://bugs.debian.org/619625>
				elsif (-f $thumbfilename && ! -e $thumbfilename . ".ignore") {

					my ($width, $height, $type) = imgsize($thumbfilename);
					next if $type eq 'Data stream is not a known image file format';

					my @filetypes = qw(JPG TIF PNG PPM GIF);

					next unless (grep $type eq $_, @filetypes);
					my ($thumbnailwidth, $thumbnailheight) = get_thumbnailsize($r, $width, $height);	
					my $imageinfo = get_imageinfo($r, $thumbfilename, $type, $width, $height);
					my $cached = get_scaled_picture_name($thumbfilename, $thumbnailwidth, $thumbnailheight);

					my $rotate = readfile_getnum($r, $imageinfo, $thumbfilename.".rotate");

					# Debian bug #348724 <http://bugs.debian.org/348724>
					# HTML <img> tag, alt attribute
					my $filetitle = $file;
					$filetitle =~ s/_/ /g if $r->dir_config('GalleryUnderscoresToSpaces');

					my %file_vars = (FILEURL => uri_escape($fileurl, $escape_rule),
							 FILE    => $filetitle,
							 DATE    => $imageinfo->{DateTimeOriginal} ? $imageinfo->{DateTimeOriginal} : '', # should this really be a stat of the file instead of ''?
							 SRC     => uri_escape($uri."/.cache/$cached", $escape_rule),
							 HEIGHT => (grep($rotate==$_, (1, 3)) ? $thumbnailwidth : $thumbnailheight),
							 WIDTH => (grep($rotate==$_, (1, 3)) ? $thumbnailheight : $thumbnailwidth),
							 SELECT  => $select_mode?'<input type="checkbox" name="selection" value="'.$file.'">&nbsp;&nbsp;':'',);
					$tpl_vars{FILES} .= $templates{picture}->fill_in(HASH => {%tpl_vars,
												 %file_vars,
												},
										       );

					if ($media_rss_enabled) {
						my ($content_image_width, undef, $content_image_height) = get_image_display_size($cgi, $r, $width, $height);
						my %item_vars = ( 
							THUMBNAIL => uri_escape($uri."/.cache/$cached", $escape_rule),
							LINK      => uri_escape($fileurl, $escape_rule),
							TITLE     => $file,
							CONTENT   => uri_escape($uri."/.cache/".$content_image_width."x".$content_image_height."-".$file, $escape_rule)
						);
						$tpl_vars{ITEMS} .= $templates{rss_item}->fill_in(HASH => { 
							%item_vars
						});
					}
				}
			}
		}
		else {
			$tpl_vars{FILES} = "No files found";
			$tpl_vars{BROWSELINKS} = "";
		}

		# Generate prev and next directory menu items
		$filename =~ m/(.*)\/.*?$/;
		my $parent_filename = $1;

		$r->document_root =~ m/(.*)\/$/;
		my $root_path = $1;
		log_debug("$filename vs $root_path");
		if ($filename ne $root_path) {
			unless (opendir (PARENT_DIR, $parent_filename)) {
				show_error ($r, 500, $!, "Unable to access parent directory $parent_filename: $!");
				return $::MP2 ? Apache2::Const::OK() : Apache::Constants::OK();
			}
	
			# Debian bug #619625 <http://bugs.debian.org/619625>
			my @neighbour_directories = grep { !/^\./ && -d "$parent_filename/$_" && ! -e "$parent_filename/$_" . ".ignore" } readdir (PARENT_DIR);
			my $dirsortby;
			if (defined($r->dir_config('GalleryDirSortBy'))) {
				$dirsortby=$r->dir_config('GalleryDirSortBy');
			} else {
				$dirsortby=$r->dir_config('GallerySortBy');
			}
			if ($dirsortby && $dirsortby =~ m/^(size|atime|mtime|ctime)$/) {
				@neighbour_directories = map(/^\d+ (.*)/, sort map(stat("$parent_filename/$_")->$dirsortby()." $_", @neighbour_directories));
			} else {
				@neighbour_directories = sort @neighbour_directories;
			}

			closedir(PARENT_DIR);

			my $neightbour_counter = 0;
			foreach my $neighbour_directory (@neighbour_directories) {
				if ($parent_filename.'/'.$neighbour_directory eq $filename) {
					if ($neightbour_counter > 0) {
						log_debug("prev directory is " .$neighbour_directories[$neightbour_counter-1]);
						my $linktext = $neighbour_directories[$neightbour_counter-1];
						if (-e $parent_filename.'/'.$neighbour_directories[$neightbour_counter-1] . ".folder") {
							$linktext = get_filecontent($parent_filename.'/'.$neighbour_directories[$neightbour_counter-1] . ".folder");
						}
						my %info = (
						URL => "../".$neighbour_directories[$neightbour_counter-1],
						LINK_NAME => "<<< $linktext",
						DIR_FILES => "",
						);
  						$tpl_vars{PREV_DIR_FILES} = $templates{navdirectory}->fill_in(HASH=> {%info});
						log_debug($tpl_vars{PREV_DIR_FILES});

					}
					if ($neightbour_counter < scalar @neighbour_directories - 1) {
						my $linktext = $neighbour_directories[$neightbour_counter+1];
						if (-e $parent_filename.'/'.$neighbour_directories[$neightbour_counter+1] . ".folder") {
							$linktext = get_filecontent($parent_filename.'/'.$neighbour_directories[$neightbour_counter+1] . ".folder");
						}
						my %info = (
						URL => "../".$neighbour_directories[$neightbour_counter+1],
						LINK_NAME => "$linktext >>>",
						DIR_FILES => "",
						);
  						$tpl_vars{NEXT_DIR_FILES} = $templates{navdirectory}->fill_in(HASH=> {%info});
						log_debug("next directory is " .$neighbour_directories[$neightbour_counter+1]);
					}
				}
				$neightbour_counter++;
			}
		}

		if (-f $topdir . '.comment') {
			my $comment_ref = get_comment($topdir . '.comment');
			my %comment_vars;
			$comment_vars{COMMENT} = $comment_ref->{COMMENT} . '<br />' if $comment_ref->{COMMENT};
			$comment_vars{TITLE} = $comment_ref->{TITLE} if $comment_ref->{TITLE};
			$tpl_vars{DIRCOMMENT} = $templates{comment}->fill_in(HASH => \%comment_vars);
			$tpl_vars{TITLE} = $comment_ref->{TITLE} if $comment_ref->{TITLE};
		} else {
			$tpl_vars{DIRCOMMENT} = $templates{nocomment}->fill_in(HASH=>\%tpl_vars);
		}

		if ($cgi->param('rss')) {
			$tpl_vars{MAIN} = $templates{rss}->fill_in(HASH => \%tpl_vars);
		} else {
			$tpl_vars{MAIN} = $templates{index}->fill_in(HASH => \%tpl_vars);
			$tpl_vars{MAIN} = $templates{layout}->fill_in(HASH => \%tpl_vars);
		}

		# put $tpl_vars{MAIN} into the file.
		if (open(P, ">$file")) {
			print P $tpl_vars{MAIN};
			close(P);
		}

		if ($cgi->param('rss')) {
			$r->content_type('application/rss+xml');
		} else {
			$r->content_type('text/html');
		}
		return send_file_response($r, $file, "ALBUM");
	}
	else {

		# original size
		if (defined($ENV{QUERY_STRING}) && $ENV{QUERY_STRING} eq 'orig') {
			if ($r->dir_config('GalleryAllowOriginal') ? 1 : 0) {
				$r->filename($filename);
				return $::MP2 ? Apache2::Const::DECLINED() : Apache::Constants::DECLINED();
			} else {
				return $::MP2 ? Apache2::Const::FORBIDDEN() : Apache::Constants::FORBIDDEN();
			}
		}
	
		# Create cache dir if not existing
		my @tmp = split (/\//, $filename);
		my $picfilename = pop @tmp;
		my $path = (join "/", @tmp)."/";
		my $cache_path = cache_dir($r, 1);

		my ($orig_width, $orig_height, $type);
		my $imageinfo;
		my ($image_width, $width, $height, $original_size);
		my $cached;

		my $isVideo = $filename =~ m/$vid_pattern/i;
		if ($isVideo) {
			log_debug("$filename is a video");
		}
		else {
			($orig_width, $orig_height, $type) = imgsize($filename);

			$imageinfo = get_imageinfo($r, $filename, $type, $orig_width, $orig_height);

			($image_width, $width, $height, $original_size) = get_image_display_size($cgi, $r, $orig_width, $orig_height);

			$cached = get_scaled_picture_name($filename, $image_width, $height);
		}
		
		my @slideshow_intervals = split (/ /, $r->dir_config('GallerySlideshowIntervals') ? $r->dir_config('GallerySlideshowIntervals') : '3 5 10 15 30');
		my $slideshow_selected_interval = "0";
		foreach my $interval (@slideshow_intervals) {
			if ($cgi->param('slideshow') && $cgi->param('slideshow') == $interval) {
				$slideshow_selected_interval = $interval;
			}
		}

		my $file = cache_dir($r, 0) . "-$width-$slideshow_selected_interval.html";
		log_debug("Caching picture HTML as " . $file);

		$r->content_type("text/html");

		# TODO: check for modifications in directory (for prev/next etc).
		if (-f $file) {
			return send_file_response($r, $file, "PICPAGE");
		}

		my $tpl_dir = $r->dir_config('GalleryTemplateDir');

		my %templates = create_templates({layout         => "$tpl_dir/layout.tpl",
						  picture        => "$tpl_dir/showpicture.tpl",
						  video          => "$tpl_dir/showvideo.tpl",
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
						 });

		my %tpl_vars;

		my $resolution;

		unless ($isVideo) {
			$resolution = (($image_width > $orig_width) && ($height > $orig_height)) ? 
				"$orig_width x $orig_height" : "$image_width x $height";
		}

		if ($isVideo) {
			$tpl_vars{TITLE} = "Viewing ".$r->uri();
			my @tmp = split (/\//, $filename);
			my $vidfilename = pop @tmp;
			$tpl_vars{SRC} = uri_escape($vidfilename, $escape_rule) . "?orig";
		}
		else {
			$tpl_vars{TITLE} = "Viewing ".$r->uri()." at $image_width x $height";
			$tpl_vars{RESOLUTION} = $resolution;
			$tpl_vars{SRC} = uri_escape(".cache/$cached", $escape_rule);
		}
		$tpl_vars{CSS} = $tpl_css;
		$tpl_vars{META} = " ";
		$tpl_vars{MENU} = generate_menu($r);
		$tpl_vars{URI} = $r->uri();
	
		my $exif_mode = $r->dir_config('GalleryEXIFMode');
		unless ($exif_mode) {
			$exif_mode = 'namevalue';
		}

		unless (opendir(DATADIR, $path)) {
			show_error($r, 500, "Unable to access directory", "Unable to access directory $path");
			return $::MP2 ? Apache2::Const::OK() : Apache::Constants::OK();
		}
		my @pictures = grep { (/$img_pattern/i || /$vid_pattern/i) && ! -e "$path/$_" . ".ignore" } readdir (DATADIR);
		closedir(DATADIR);
		@pictures = gallerysort($r, @pictures);

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
					my ($orig_width, $orig_height, $type);
					my ($thumbnailwidth, $thumbnailheight);
					my $imageinfo;
					my $cached;
					my %nav_vars;
					$nav_vars{URL}       = uri_escape($prevpicture, $escape_rule);
					$nav_vars{FILENAME}  = $prevpicture;
					$nav_vars{DIRECTION} = "&laquo; <u>p</u>rev";
					$nav_vars{ACCESSKEY} = "P";
					$nav_vars{WIDTH}     = $width;
					if ($prevpicture =~ m/$vid_pattern/i) {
						log_debug("prevpicture is a video");
						#$nav_vars{PICTURE}   = "/ApacheGallery/video-mpg.png";
						my $posterthumburl = $prevpicture;
						$posterthumburl =~ s/\....$/.thm/;
						# Read dimensions from configuration
						$nav_vars{PICTURE} = uri_escape(".cache/176x132-$posterthumburl", $escape_rule);
						$nav_vars{VIDEO} = "video";
					}
					else {
						($orig_width, $orig_height, $type) = imgsize($path.$prevpicture);
						($thumbnailwidth, $thumbnailheight) = get_thumbnailsize($r, $orig_width, $orig_height);	
						$imageinfo = get_imageinfo($r, $path.$prevpicture, $type, $orig_width, $orig_height);
						$cached = get_scaled_picture_name($path.$prevpicture, $thumbnailwidth, $thumbnailheight);
						$nav_vars{PICTURE}   = uri_escape(".cache/$cached", $escape_rule);
					}
					$tpl_vars{BACK} = $templates{navpicture}->fill_in(HASH => \%nav_vars);
				}
				else {
					$tpl_vars{BACK} = "&nbsp;";
				}

				$nextpicture = $pictures[$i+1];
				if ($r->dir_config("GalleryWrapNavigation")) {
					$nextpicture = $pictures[$i == $#pictures ? 0 : $i+1];
				}	

				if ($nextpicture) {
					my ($orig_width, $orig_height, $type);
					my ($thumbnailwidth, $thumbnailheight);
					my $imageinfo;
					my $cached;
					my %nav_vars;
					$nav_vars{URL}       = uri_escape($nextpicture, $escape_rule);
					$nav_vars{FILENAME}  = $nextpicture;
					$nav_vars{DIRECTION} = "<u>n</u>ext &raquo;";
					$nav_vars{ACCESSKEY} = "N";
					$nav_vars{WIDTH}     = $width;
					$tpl_vars{NEXTURL}   = uri_escape($nextpicture, $escape_rule);
					if ($nextpicture =~ m/$vid_pattern/i) {
						log_debug("nextpicture is a video");
						#$nav_vars{PICTURE}   = "/ApacheGallery/video-mpg.png";
						my $posterthumburl = $nextpicture;
						$posterthumburl =~ s/\....$/.thm/;
						# Read dimensions from configuration
						$nav_vars{PICTURE} = uri_escape(".cache/176x132-$posterthumburl", $escape_rule);
						$nav_vars{VIDEO} = "video";
					}
					else {
						($orig_width, $orig_height, $type) = imgsize($path.$nextpicture);
						($thumbnailwidth, $thumbnailheight) = get_thumbnailsize($r, $orig_width, $orig_height);	
						$imageinfo = get_imageinfo($r, $path.$nextpicture, $type, $orig_width, $orig_height);
						$cached = get_scaled_picture_name($path.$nextpicture, $thumbnailwidth, $thumbnailheight);
						$nav_vars{PICTURE}   = uri_escape(".cache/$cached", $escape_rule);
					}
					$tpl_vars{NEXT} = $templates{navpicture}->fill_in(HASH => \%nav_vars);
				}
				else {
					$tpl_vars{NEXT} = "&nbsp;";
					$tpl_vars{NEXTURL}   = '#';
				}
			}
		}

		my $foundcomment = 0;
		if (-f $path . '/' . $picfilename . '.comment') {
			my $comment_ref = get_comment($path . '/' . $picfilename . '.comment');
			$foundcomment = 1;
			$tpl_vars{COMMENT} = $comment_ref->{COMMENT} . '<br />' if $comment_ref->{COMMENT};
			$tpl_vars{TITLE} = $comment_ref->{TITLE} if $comment_ref->{TITLE};
		} elsif ($r->dir_config('GalleryCommentExifKey')) {
			my $comment = decode("utf8", $imageinfo->{$r->dir_config('GalleryCommentExifKey')});
			$tpl_vars{COMMENT} = encode("iso-8859-1", $comment);
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
					$tpl_vars{INFO} .=  $templates{info}->fill_in(HASH => \%info_vars);
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

			$tpl_vars{PICTUREINFO} = $templates{pictureinfo}->fill_in(HASH => \%tpl_vars);

			unless (defined($exifvalues)) {
				$tpl_vars{EXIFVALUES} = "";
			}

		}
		else {
			$tpl_vars{PICTUREINFO} = $templates{nopictureinfo}->fill_in(HASH => \%tpl_vars);
		}

		# Fill in sizes and determine if any are smaller than the
		# actual image. If they are, $scaleable=1
		my $scaleable = 0;
		my @sizes = split (/ /, $r->dir_config('GallerySizes') ? $r->dir_config('GallerySizes') : '640 800 1024 1600');
		foreach my $size (@sizes) {
			if ($size<=$original_size) {
				my %sizes_vars;
				$sizes_vars{IMAGEURI} = uri_escape($r->uri(), $escape_rule);
				$sizes_vars{SIZE}     = $size;
				$sizes_vars{WIDTH}    = $size;
				if ($width == $size) {
					$tpl_vars{SIZES} .= $templates{scaleactive}->fill_in(HASH => \%sizes_vars);
				}
				else {
					$tpl_vars{SIZES} .= $templates{scale}->fill_in(HASH => \%sizes_vars);
				}
				$scaleable = 1;
			}
		}

		unless ($scaleable) {
			my %sizes_vars;
			$sizes_vars{IMAGEURI} = uri_escape($r->uri(), $escape_rule);
			$sizes_vars{SIZE}     = $original_size;
			$sizes_vars{WIDTH}    = $original_size;
			$tpl_vars{SIZES} .= $templates{scaleactive}->fill_in(HASH => \%sizes_vars);
		}

		$tpl_vars{IMAGEURI} = uri_escape($r->uri(), $escape_rule);

		if ($r->dir_config('GalleryAllowOriginal')) {
			$tpl_vars{SIZES} .= $templates{orig}->fill_in(HASH => \%tpl_vars);
		}

		foreach my $interval (@slideshow_intervals) {

			my %slideshow_vars;
			$slideshow_vars{IMAGEURI} = uri_escape($r->uri(), $escape_rule);
			$slideshow_vars{SECONDS} = $interval;
			$slideshow_vars{WIDTH} = ($width > $height ? $width : $height);

			if ($cgi->param('slideshow') && $cgi->param('slideshow') == $interval and $nextpicture) {
				$tpl_vars{SLIDESHOW} .= $templates{intervalactive}->fill_in(HASH => \%slideshow_vars);
			}
			else {

				$tpl_vars{SLIDESHOW} .= $templates{interval}->fill_in(HASH => \%slideshow_vars);

			}
		}

		if ($cgi->param('slideshow') and $nextpicture) {

			$tpl_vars{SLIDESHOW} .= $templates{slideshowoff}->fill_in(HASH => \%tpl_vars);

			unless ((grep $cgi->param('slideshow') == $_, @slideshow_intervals)) {
				show_error($r, 200, "Invalid interval", "Invalid slideshow interval choosen");
				return $::MP2 ? Apache2::Const::OK() : Apache::Constants::OK();
			}

			$tpl_vars{URL} = uri_escape($nextpicture, $escape_rule);
			$tpl_vars{WIDTH} = ($width > $height ? $width : $height);
			$tpl_vars{INTERVAL} = $cgi->param('slideshow');
			$tpl_vars{META} .=  $templates{refresh}->fill_in(HASH => \%tpl_vars);

		}
		else {
			$tpl_vars{SLIDESHOW} .=  $templates{slideshowisoff}->fill_in(HASH => \%tpl_vars);
		}

		if ($isVideo) {
			$tpl_vars{MAIN} = $templates{video}->fill_in(HASH => \%tpl_vars);
		}
		else {
			$tpl_vars{MAIN} = $templates{picture}->fill_in(HASH => \%tpl_vars);
		}
		$tpl_vars{MAIN} = $templates{layout}->fill_in(HASH => \%tpl_vars);

		# put $tpl_vars{MAIN} into the file.
		if (open(P, ">$file")) {
			print P $tpl_vars{MAIN};
			close(P);
		}
		return send_file_response($r, $file, "PICPAGE");
	}
}

sub cache_dir {
	my ($r, $strip_filename) = @_;

	my $cache_root;

	unless ($r->dir_config('GalleryCacheDir')) {
		$cache_root = '/var/cache/www/';
		if ($r->server->is_virtual) {
			$cache_root = File::Spec->catdir($cache_root, $r->server->server_hostname);
		} else {
			$cache_root = File::Spec->catdir($cache_root, $r->location);
		}
	} else {
		$cache_root = $r->dir_config('GalleryCacheDir');
	}

	# If the uri contains .cache we need to remove it
	my $uri = $r->uri;
	$uri =~ s/\.cache//;

	my (undef, $dirs, $filename) = File::Spec->splitpath($uri);
	# We don't need a volume as this is a relative path

	# Create directory if it doesn't exist
	my $dirname = File::Spec->canonpath(File::Spec->catdir($cache_root, $dirs));
	unless (-d $dirname) {
		log_debug("Creating cache directory $dirname");
		unless (create_cache($r, $dirname)) {
			return $::MP2 ? Apache2::Const::OK() : Apache::Constants::OK();
		}
	}

	if ($strip_filename) {
		return($dirname);
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

sub get_scaled_picture_name {

	my ($fullpath, $width, $height) = @_;

	my (undef, undef, $type) = imgsize($fullpath);

	my @dirs = split(/\//, $fullpath);
	my $filename = pop(@dirs);
	my $newfilename;

	if (grep $type eq $_, qw(PPM TIF GIF)) {
		$newfilename = $width."x".$height."-".$filename;
		# needs to be configurable
		$newfilename =~ s/\.(\w+)$/-$1\.jpg/;
	} else {
		$newfilename = $width."x".$height."-".$filename;
	}

	return $newfilename;
	
}

sub scale_picture {

	my ($r, $fullpath, $width, $height, $imageinfo) = @_;

	my @dirs = split(/\//, $fullpath);
	my $filename = pop(@dirs);

	my ($orig_width, $orig_height, $type) = imgsize($fullpath);

	my $cache = cache_dir($r, 1);

	my $newfilename = get_scaled_picture_name($fullpath, $width, $height);

	if (($width > $orig_width) && ($height > $orig_height)) {
		# Run it through the resize code anyway to get watermarks
		$width = $orig_width;
		$height = $orig_height;
	}

	my ($thumbnailwidth, $thumbnailheight) = get_thumbnailsize($r, $orig_width, $orig_height);

	# Do we want to generate a new file in the cache?
	my $scale = 1;

	if (-f $cache."/".$newfilename) {	
		$scale = 0;

		# Check to see if the image has changed
		my $filestat = stat($fullpath);
		my $cachestat = stat($cache."/".$newfilename);
		if ($filestat->mtime >= $cachestat->mtime) {
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
		my $quality = $r->dir_config('GalleryQuality');

		log_debug("Writing resized picture to " . $newpath);

		if ($width == $thumbnailwidth or $width == $thumbnailheight) {

			resizepicture($r, $fullpath, $newpath, $width, $height, $rotate, '', '', '', '', '', '');

		} else {

			resizepicture($r, $fullpath, $newpath, $width, $height, $rotate, 
				($r->dir_config('GalleryCopyrightImage') ? $r->dir_config('GalleryCopyrightImage') : ''), 
				($r->dir_config('GalleryTTFDir') ? $r->dir_config('GalleryTTFDir') : ''), 
				($r->dir_config('GalleryCopyrightText') ? $r->dir_config('GalleryCopyrightText') : ''), 
				($r->dir_config('GalleryCopyrightColor') ? $r->dir_config('GalleryCopyrightColor') : ''), 
				($r->dir_config('GalleryTTFFile') ? $r->dir_config('GalleryTTFFile') : ''), 
				($r->dir_config('GalleryTTFSize') ?  $r->dir_config('GalleryTTFSize') : ''),
				($r->dir_config('GalleryCopyrightBackgroundColor') ?  $r->dir_config('GalleryCopyrightBackgroundColor') : ''),
				$quality);

		}
	}

	return $newfilename;

}

# Addition by Matt Blissett, June 2011
sub album_cover_picture {
	my ($r, $width, $height, $imageinfo, $dirname, $newfilename, @allfiles) = @_;

	my @fullpath;
	log_debug("Have $#allfiles files to select from");

	my $inc = floor($#allfiles/4);
	$inc++ if ($inc == 0);
	for (my $i = 0; $i <= $#allfiles; $i += $inc) {
		my $j = floor($i);
		$r-log_debug("$i choosing ${j}th: $allfiles[$j]");
		push @fullpath, "$dirname/" . $allfiles[$j];
	}

	my @dirs = split(/\//, $fullpath[0]);
	my $filename = pop(@dirs);

	log_debug("filename = $filename");
	log_debug("fullpath0 $fullpath[0]");
	log_debug("fullpath1 $fullpath[1]");
	log_debug("fullpath2 $fullpath[2]");
	log_debug("fullpath3 $fullpath[3]");

	my $cache = cache_dir($r, 1);

	# Do we want to generate a new file in the cache?
	my $scale = 1;

	if (-f $cache."/".$newfilename) {
		$scale = 0;

		# Check to see if the image has changed
		my $filestat = stat($fullpath[0]);
		my $cachestat = stat($cache."/".$newfilename);
		if ($filestat->mtime >= $cachestat->mtime) {
			$scale = 1;
		}

		# Check to see if the .rotate file has been added or changed
		# Rotation is ignored
		#if (-f $fullpath[0] . ".rotate") {
		#	my $rotatestat = stat($fullpath[0] . ".rotate");
		#	if ($rotatestat->mtime > $cachestat->mtime) {
		#		$scale = 1;
		#	}
		#}

		# Check to see if the copyrightimage has been added or changed
		if ($r->dir_config('GalleryCopyrightImage') && -f $r->dir_config('GalleryCopyrightImage')) {
			my $copyrightstat = stat($r->dir_config('GalleryCopyrightImage'));
			if ($copyrightstat->mtime > $cachestat->mtime) {
				$scale = 1;
			}
		}
	}

	if ($scale) {
		my $newpath = $cache."/".$newfilename;
		my $rotate = 0;
		my $quality = $r->dir_config('GalleryQuality');

		albumcoverpicture($r, $newpath, $width, $height,
			($r->dir_config('GalleryCopyrightImage') ? $r->dir_config('GalleryCopyrightImage') : ''),
			($r->dir_config('GalleryTTFDir') ? $r->dir_config('GalleryTTFDir') : ''),
			($r->dir_config('GalleryCopyrightText') ? $r->dir_config('GalleryCopyrightText') : ''),
			($r->dir_config('GalleryCopyrightColor') ? $r->dir_config('GalleryCopyrightColor') : ''),
			($r->dir_config('GalleryTTFFile') ? $r->dir_config('GalleryTTFFile') : ''),
			($r->dir_config('GalleryTTFSize') ?  $r->dir_config('GalleryTTFSize') : ''),
			($r->dir_config('GalleryCopyrightBackgroundColor') ?  $r->dir_config('GalleryCopyrightBackgroundColor') : ''),
			$quality,
			@fullpath);
	}

	return $newfilename;

}
# END album_cover_picture

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

sub get_image_display_size {
	my ($cgi, $r, $orig_width, $orig_height) = @_;

	my $width = $orig_width;

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
			return $::MP2 ? Apache2::Const::OK() : Apache::Constants::OK();
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

	return ($image_width, $width, $height, $original_size);
}

sub get_imageinfo {
	my ($r, $file, $type, $width, $height) = @_;
	my $imageinfo = {};
	if ($type eq 'Data stream is not a known image file format') {
		# should never be reached, this is supposed to be handled outside of here
		log_error("Something was fishy with the type of the file $file\n");
	} else { 

		# Some files, like TIFF, PNG, GIF do not have EXIF info 
		# embedded but use .thm files instead.
		$imageinfo = get_imageinfo_from_thm_file($file, $width, $height);

		# If there is no .thm file and our file is a JPEG file we try to extract the EXIf
		# info using Image::Info
		unless (defined($imageinfo) && (grep $type eq $_, qw(JPG))) {
			# Only for files that natively keep the EXIF info in the same file
			$imageinfo = image_info($file);
		}
	}

	unless (defined($imageinfo->{width}) and defined($imageinfo->{height})) {
		$imageinfo->{width} = $width;
		$imageinfo->{height} = $height;
	}

	my @infos = split /, /, $r->dir_config('GalleryInfo') ? $r->dir_config('GalleryInfo') : 'Picture Taken => DateTimeOriginal, Flash => Flash';
	foreach (@infos) {
		
		my ($human_key, $exif_key) = (split " => ")[0,1];
		if (defined($exif_key) && defined($imageinfo->{$exif_key})) {
			my $value = "";
			if (ref($imageinfo->{$exif_key}) eq 'Image::TIFF::Rational') { 
				if ($exif_key eq 'GPSLatitude' or $exif_key eq 'GPSLongitude') {
					$value = $imageinfo->{$exif_key}[0] / $imageinfo->{$exif_key}[1];
					$value += $imageinfo->{$exif_key}[2] / $imageinfo->{$exif_key}[3] / 60.0;
					$value += $imageinfo->{$exif_key}[4] / $imageinfo->{$exif_key}[5] / 60.0 / 60.0;
				}
				elsif ($exif_key eq 'MaxApertureValue') {
					$value = $imageinfo->{$exif_key}[0] / $imageinfo->{$exif_key}[1];
				}
				else {
					$value = $imageinfo->{$exif_key}->as_string;
				}
			} 
			elsif (ref($imageinfo->{$exif_key}) eq 'ARRAY') {
				foreach my $element (@{$imageinfo->{$exif_key}}) {
					if (ref($element) eq 'ARRAY') {
						foreach (@{$element}) {
							$value .= $_ . ' ';
						}
					} 
					elsif (ref($element) eq 'HASH') {
						$value .= "<br />{ ";
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

sub get_imageinfo_from_thm_file {

	my ($file, $width, $height) = @_;

	my $imageinfo = undef;
	# Windows based file extensions are often .THM, so check 
	# for both .thm and .THM
	my $unix_file = $file;
	my $windows_file = $file;
	$unix_file =~ s/\.(\w+)$/.thm/;
	$windows_file =~ s/\.(\w+)$/.THM/;

	if (-e $unix_file && -f $unix_file && -r $unix_file) {
		$imageinfo = image_info($unix_file);
		$imageinfo->{width} = $width;
		$imageinfo->{height} = $height;
	}
	elsif (-e $windows_file && -f $windows_file && -r $windows_file) {
		$imageinfo = image_info($windows_file);
		$imageinfo->{width} = $width;
		$imageinfo->{height} = $height;
	}

	return $imageinfo;
}


sub readfile_getnum {
	my ($r, $imageinfo, $filename) = @_;

	my $rotate = 0;

	log_debug("orientation: ".$imageinfo->{Orientation});
	# Check to see if the image contains the Orientation EXIF key,
	# but allow user to override using rotate
	if (!defined($r->dir_config("GalleryAutoRotate")) 
		|| $r->dir_config("GalleryAutoRotate") eq "1") {
		if (defined($imageinfo->{Orientation})) {
			log_debug($imageinfo->{Orientation});
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

	my %templates = create_templates({layout => "$tpl/layout.tpl",
					  error  => "$tpl/error.tpl",
					 });

	my %tpl_vars;
	$tpl_vars{TITLE}      = "Error! $errortitle";

	my $tpl_css = $r->dir_config('GalleryCssFilename');
	unless ($tpl_css) {
		$tpl_css = "gallery.css";
	}
	$tpl_vars{CSS} = $tpl_css;

	$tpl_vars{META}       = "";
	$tpl_vars{ERRORTITLE} = "Error! $errortitle";
	$tpl_vars{ERROR}      = $error;

	$tpl_vars{MAIN} = $templates{error}->fill_in(HASH => \%tpl_vars);

	$tpl_vars{PAGE} = $templates{layout}->fill_in(HASH => \%tpl_vars);

	$r->status($statuscode);
	$r->content_type('text/html');

	$r->print($tpl_vars{PAGE});

}

sub generate_menu {

	my $r = shift;

	my $root_text = (defined($r->dir_config('GalleryRootText')) ? $r->dir_config('GalleryRootText') : "root:" );
	my $root_path = (defined($r->dir_config('GalleryRootPath')) ? $r->dir_config('GalleryRootPath') : "" );

	my $subr = $r->lookup_uri($r->uri);
	my $filename = $subr->filename;

	my @links = split (/\//, $r->uri);
	my $uri = $r->uri;
	$uri =~ s/^$root_path//g;

	@links = split (/\//, $uri);

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

	if ($r->uri eq $root_path) {
		return qq{ <a href="$root_path">$root_text</a> };
	}

	my $menu;
	my $menuurl = $root_path;
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

		if ("$root_path$uri" eq $menuurl) {
			$menu .= "$linktext  / ";
		}
		else {
			$menu .= "<a href=\"".uri_escape($menuurl, $escape_rule)."\">$linktext</a> / ";
		}

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
	my ($r, $infile, $outfile, $x, $y, $rotate, $copyrightfile, $GalleryTTFDir, $GalleryCopyrightText, $text_color, $GalleryTTFFile, $GalleryTTFSize, $GalleryCopyrightBackgroundColor, $quality) = @_;

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
			log_error("GalleryCopyrightImage $copyrightfile was not found");
		}
	}

	if ($GalleryTTFDir && $GalleryCopyrightText && $GalleryTTFFile && $text_color) {
		if (!-d $GalleryTTFDir) {

			log_error("GalleryTTFDir $GalleryTTFDir is not a dir\n");

		} elsif ($GalleryCopyrightText eq '') {

			log_error("GalleryCopyrightText is empty. No text inserted to picture\n");

		} elsif (!-e "$GalleryTTFDir/$GalleryTTFFile") {

			log_error("GalleryTTFFile $GalleryTTFFile was not found\n");

		} else {
 
			$GalleryTTFFile =~ s/\.TTF$//i;
			$image->add_font_path("$GalleryTTFDir");

			$image->load_font("$GalleryTTFFile/$GalleryTTFSize");
			my($text_x, $text_y) = $image->get_text_size("$GalleryCopyrightText");
			my $x = $image->get_width();
			my $y = $image->get_height();

			my $offset = 3;

			if (($text_x < $x - $offset) && ($text_y < $y - $offset)) {
				if ($GalleryCopyrightBackgroundColor =~ /^\d+,\d+,\d+,\d+$/) {
					my ($br_val, $bg_val, $bb_val, $ba_val) = split (/,/, $GalleryCopyrightBackgroundColor);
					$image->set_colour($br_val, $bg_val, $bb_val, $ba_val);
					$image->fill_rectangle ($x-$text_x-$offset, $y-$text_y-$offset, $text_x, $text_y);
				}
				my ($r_val, $g_val, $b_val, $a_val) = split (/,/, $text_color);
				$image->set_colour($r_val, $g_val, $b_val, $a_val);
				$image->draw_text($x-$text_x-$offset, $y-$text_y-$offset, "$GalleryCopyrightText");
			} else {
				log_error("Text is to big for the picture.\n");
			}
		}
	}

	if ($quality && $quality =~ m/^\d+$/) {
		$image->set_quality($quality);
	}

	# Force file type for THM files to JPEG
	if ($outfile =~ m/\.thm$/) {
		$image->image_set_format("jpeg");
	}

	$image->save($outfile);

}

# Addition by Matt Blissett, June 2011
sub albumcoverpicture {
	my ($r, $outfile, $x, $y, $copyrightfile, $GalleryTTFDir, $GalleryCopyrightText, $text_color, $GalleryTTFFile, $GalleryTTFSize, $GalleryCopyrightBackgroundColor, $quality, @infile) = @_;

	# Load images
	my @image;
	my $i;
	for ($i = 0; $i < 4 && $i <= $#infile; $i++) {
		$image[$i] = Image::Imlib2->load($infile[$i]) or warn("Unable to open file $infile[$i], $!");
		log_debug("Album cover picture: loaded file $i : $infile[$i]");
	}
	my $pictures = $i;

	my $image = Image::Imlib2->new($x, $y);
	$image->image_set_format("jpeg");

	# Find a square from the central 3/5 of the image.
	# ··g····
	# f·###··
	# ··###··
	# ··###··
	# ·······

	my @f, my @g, my @d;
	for (my $i = 0; $i < $pictures; $i++) {
		if ($image[$i]->width() > $image[$i]->height()) {
		$d[$i] = $image[$i]->height() / 5 * 3;
		$g[$i] = $image[$i]->height() / 5;
		$f[$i] = $g[$i] + ($image[$i]->width()-$image[$i]->height())/2;
		}
		else {
		$d[$i] = $image[$i]->width() / 5 * 3;
		$f[$i] = $image[$i]->width() / 5;
		$g[$i] = $f[$i] + ($image[$i]->height()-$image[$i]->width())/2;
		}
	}

	log_debug("ACP: f $f[0], g $g[0], d $d[0], x $x, y $y, w " . $image[0]->width() . ", h " . $image[0]->height());

	if ($pictures == 4) {
		$image->blend($image[0], 1, $f[0], $g[0], $d[0], $d[0], 0, 0, $x/2, $y/2);
		$image->blend($image[1], 1, $f[1], $g[1], $d[1], $d[1], $x/2, 0, $x/2, $y/2);
		$image->blend($image[2], 1, $f[2], $g[2], $d[2], $d[2], 0, $y/2, $x/2, $y/2);
		$image->blend($image[3], 1, $f[3], $g[3], $d[3], $d[3], $x/2, $y/2, $x/2, $y/2);
	}
	elsif ($pictures == 3) {
		$image->blend($image[2], 1, $f[2], $g[2], $d[2], $d[2], $x/4, 0, $x, $y);
		$image->blend($image[1], 1, $f[1], $g[1], $d[1], $d[1], 0, 3*$y/4, $x, $y);
		$image->blend($image[0], 1, $f[0], $g[0], $d[0], $d[0], 0, 0, 3*$x/4, 3*$y/4);
	}
	elsif ($pictures == 2) {
		$image->blend($image[1], 1, $f[1], $g[1], $d[1], $d[1], 0, 0, $x, $y);
		$image->blend($image[0], 1, $f[0], $g[0], $d[0], $d[0], 0, 0, 3*$x/4, 3*$y/4);
	}
	else {
		$image->blend($image[0], 1, $f[0], $g[0], $d[0], $d[0], 0, 0, $x, $y);
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
			log_error("GalleryCopyrightImage $copyrightfile was not found");
		}
	}

	if ($GalleryTTFDir && $GalleryCopyrightText && $GalleryTTFFile && $text_color) {
		if (!-d $GalleryTTFDir) {

			log_error("GalleryTTFDir $GalleryTTFDir is not a dir\n");

		} elsif ($GalleryCopyrightText eq '') {

			log_error("GalleryCopyrightText is empty. No text inserted to picture\n");

		} elsif (!-e "$GalleryTTFDir/$GalleryTTFFile") {

			log_error("GalleryTTFFile $GalleryTTFFile was not found\n");

		} else {

			$GalleryTTFFile =~ s/\.TTF$//i;
			$image->add_font_path("$GalleryTTFDir");

			$image->load_font("$GalleryTTFFile/$GalleryTTFSize");
			my($text_x, $text_y) = $image->get_text_size("$GalleryCopyrightText");
			my $x = $image->get_width();
			my $y = $image->get_height();

			my $offset = 3;

			if (($text_x < $x - $offset) && ($text_y < $y - $offset)) {
				if ($GalleryCopyrightBackgroundColor =~ /^\d+,\d+,\d+,\d+$/) {
					my ($br_val, $bg_val, $bb_val, $ba_val) = split (/,/, $GalleryCopyrightBackgroundColor);
					$image->set_colour($br_val, $bg_val, $bb_val, $ba_val);
					$image->fill_rectangle ($x-$text_x-$offset, $y-$text_y-$offset, $text_x, $text_y);
				}
				my ($r_val, $g_val, $b_val, $a_val) = split (/,/, $text_color);
				$image->set_colour($r_val, $g_val, $b_val, $a_val);
				$image->draw_text($x-$text_x-$offset, $y-$text_y-$offset, "$GalleryCopyrightText");
			} else {
				log_error("Text is to big for the picture.\n");
			}
		}
	}

	if ($quality && $quality =~ m/^\d+$/) {
		$image->set_quality($quality);
	}

	# Force file type for THM files to JPEG
	if ($outfile =~ m/\.thm$/) {
		$image->image_set_format("jpeg");
	}

	if ($r->dir_config("GalleryForceJPEG")) {
		$image->image_set_format("jpeg");
	}

	$image->save($outfile);
}
# End albumcoverpicture

sub gallerysort {
	my $r=shift;
	my @files=@_;
	my $sortby = $r->dir_config('GallerySortBy');
	my $filename=$r->lookup_uri($r->uri)->filename;
	$filename=(File::Spec->splitpath($filename))[1] if (-f $filename);
	if ($sortby && $sortby =~ m/^(size|atime|mtime|ctime)$/) {
		@files = map(/^\d+ (.*)/, sort map(stat("$filename/$_")->$sortby()." $_", @files));
	} else {
		@files = sort @files;
	}
	return @files;
}

# Create Text::Template objects used by Apache::Gallery. Takes a
# hashref of template_name, template_filename pairs, and returns a
# list of template_name, texttemplate_object pairs.
sub create_templates {
     my $templates = shift;

     # This routine is called whenever a template has an error. Prints
     # the error to the log and sticks the error in the output
     sub tt_broken {
	  my %args = @_;
	  # Pull out the name and filename from the arg option [see
	  # Text::Template for details]
	  @args{qw(name file)} = @{$args{arg}};
	  log_error(qq(Template $args{name} ("$args{file}") is broken: $args{error}));
	  # Don't include the file name in the output, as the user can see this.
	  return qq(<!-- Template $args{name} is broken: $args{error} -->);
     }



     my %texttemplate_objects;

     for my $template_name (keys %$templates) {
	  my $tt_obj = Text::Template->new(TYPE   => 'FILE',
					   SOURCE => $$templates{$template_name},
					   BROKEN => \&tt_broken,
					   BROKEN_ARG => [$template_name, $$templates{$template_name}],
 					  )
	       or die "Unable to create new Text::Template object for $template_name: $Text::Template::ERROR";
	  $texttemplate_objects{$template_name} = $tt_obj;
     }
     return %texttemplate_objects;
}

# Addition by Matt Blissett, December 2012
# Extracted method for sending responses to be used generally
# Content-Type should have been set already
sub send_file_response {
	my $r = shift;
	my $file = shift;
	my $tag = shift;

	if ($::MP2) {
		my $fileinfo = stat($file);

		my $nonce = md5_base64($fileinfo->ino.$fileinfo->mtime);
		if ($r->headers_in->{"If-None-Match"} eq $nonce) {
			log_info("$tag NM TIME elapsed " . int((time() - $time)*1000) . "ms " . $timeurl);
			return Apache2::Const::HTTP_NOT_MODIFIED();
		}

		if ($r->headers_in->{"If-Modified-Since"} && str2time($r->headers_in->{"If-Modified-Since"}) < $fileinfo->mtime) {
			log_info("$tag NM TIME elapsed " . int((time() - $time)*1000) . "ms " . $timeurl);
			return Apache2::Const::HTTP_NOT_MODIFIED();
		}

		$r->headers_out->{"Content-Length"} = $fileinfo->size;
		$r->headers_out->{"Last-Modified-Date"} = time2str($fileinfo->mtime);
		$r->headers_out->{"ETag"} = $nonce;
		$r->sendfile($file);
		log_info("$tag TIME elapsed " . int((time() - $time)*1000) . "ms " . $timeurl);
		return Apache2::Const::OK();
	}
	else {
		$r->path_info('');
		$r->filename($file);
		log_info("$tag TIME elapsed " . int((time() - $time)*1000) . "ms " . $timeurl);
		return Apache::Constants::DECLINED();
	}
}

sub log_error {
	if ($::MP2) {
		Apache2::RequestUtil->request->log->error(shift());
	} else {
		Apache->request->log_error(shift());
	}
}

sub log_info {
	if ($::MP2) {
		Apache2::RequestUtil->request->log->info(shift());
	} else {
		Apache->request->log_info(shift());
	}
}

sub log_debug {
	if ($::MP2) {
		Apache2::RequestUtil->request->log->debug(shift());
	} else {
		Apache->request->log_debug(shift());
	}
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

Example: B<PerlSetVar GalleryCacheDir '/var/cache/www/'>

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
pictures. The default is /var/cache/www/ . Here, a directory for each
virtualhost or location will be created automatically. Make sure your
webserver has write access to the CacheDir.

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

=item B<GalleryDirSortBy>

Set this variable to sort directories differently than other items,
can be set to size, atime, mtime and ctime; setting any other value
will revert to sorting by name.

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
$EXIF_FLASH available to your templates. You can place them
anywhere you want.

=item B<GalleryRootPath>

Change the location of gallery root. The default is ""

=item B<GalleryRootText>

Change the name that appears as the root element in the menu. The
default is "root:"

=item B<GalleryMaxThumbnailsPerPage>

This options controls how many thumbnails should be displayed in a 
page. It requires $BROWSELINKS to be in the index.tpl template file.

=item B<GalleryImgFile>

Pattern matching the image files you want Apache::Gallery to view in the
index as thumbnails. 

The default is '\.(jpe?g|png|tiff?|ppm)$'

=item B<GalleryVidFile>

Pattern matching the video files you want Apache::Gallery to view in the
index as thumbnails, and in the gallery as HTML5 videos.

The default is '\.(ogv|webm|mp4)$'

=item B<GalleryDocFile>

Pattern matching the files you want Apache::Gallery to view in the index
as normal files. All other filetypes will still be served by Apache::Gallery
but are not visible in the index.

The default is '\.(mpe?g|avi|mov|asf|wmv|doc|mp3|ogg|pdf|rtf|wav|dlt|txt|html?|csv|eps)$'

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

=item B<GalleryCopyrightBackgroundColor>

The background-color of a GalleryCopyrightText

r,g,b,a - for examples, see GalleryCopyrightColor

=item B<GalleryQuality>

The quality (1-100) of scaled images

This setting affects the quality of the scaled images.
Set this to a low number to reduce the size of the scaled images.
Remember to clear out your cache if you change this setting.
Quality seems to default to 75, at least in the jpeg and png loader code in
Imlib2 1.1.0.

Examples:

Quality at 50:
        PerlSetVar      GalleryQuality '50'

=item B<GalleryUnderscoresToSpaces>

Set this option to 1 to convert underscores to spaces in the listing
of directory and file names, as well as in the alt attribute for HTML
<img> tags.

=back

=over 4

=item B<GalleryCommentExifKey>

Set this option to e.g. ImageDescription to use this field as comments
for images.

=item B<GalleryEnableMediaRss>

Set this option to 1 to enable generation of a media RSS feed. This
can be used e.g. together with the PicLens plugin from http://piclens.com

=item B<GalleryCssFilename>

Set this to change the CSS filename included.  On some templates this
setting is used to select between different variations.

=back

=head1 FEATURES

=over 4

=item B<Rotate images>

Some cameras, like the Canon G3, detects the orientation of a picture
and adds this info to the EXIF header. Apache::Gallery detects this
and automatically rotates images with this info.

If your camera does not support this, you can rotate the images 
manually, This can also be used to override the rotate information
from a camera that supports that. You can also disable this behavior
with the GalleryAutoRotate option.

To use this functionality you have to create file with the name of the 
picture you want rotated appended with ".rotate". The file should include 
a number where these numbers are supported:

	"1", rotates clockwise by 90 degree
	"2", rotates clockwise by 180 degrees
	"3", rotates clockwise by 270 degrees

So if we want to rotate "Picture1234.jpg" 90 degrees clockwise we would
create a file in the same directory called "Picture1234.jpg.rotate" with
the number 1 inside of it.

=item B<Ignore directories/files>

To ignore a directory or a file (of any kind, not only images) you
create a <directory|file>.ignore file.

=item B<Comments>

To include comments for a directory you create a <directory>.comment
file where the first line can contain "TITLE: New title" which
will be the title of the page, and a comment on the following 
lines.
To include comments for each picture you create files called 
picture.jpg.comment where the first line can contain "TITLE: New
title" which will be the title of the page, and a comment on the
following lines.

Example:

	TITLE: This is the new title of the page
	And this is the comment.<br />
	And this is line two of the comment.

The visible name of the folder is by default identical to the name of
the folder, but can be changed by creating a file <directory>.folder
with the visible name of the folder.

It is also possible to set GalleryCommentExifKey to the name of an EXIF
field containing the comment, e.g. ImageDescription. The EXIF comment is
overridden by the .comment file if it exists.

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

Copyright (C) 2001-2011 Michael Legart <michael@legart.dk>

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
