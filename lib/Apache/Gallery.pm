package Apache::Gallery;

use strict;

use vars qw($VERSION);
use Time::HiRes qw/time/;

$VERSION = "2.0-rc1";

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

		Apache2::Const->import(-compile => 'OK','DECLINED','FORBIDDEN','NOT_FOUND','HTTP_NOT_MODIFIED','HTTP_NO_CONTENT','REDIRECT');

		$::MP2 = 1;
	} else {
		require mod_perl;

		require Apache;
		require Apache::Constants;
		require Apache::Request;

		Apache::Constants->import('OK','DECLINED','FORBIDDEN','NOT_FOUND','REDIRECT');
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

	$time = time();
	$timeurl = $r->uri;

	my $cgi = new CGI;

	log_info("Apache Gallery request for " . $r->uri . "?" . $ENV{QUERY_STRING});

	# Handle selected images
	if ($cgi->param('selection')) {
		log_info("Selection request");
		return selected_images($r, $cgi);
	}

	unless (($r->method eq 'HEAD') or ($r->method eq 'GET')) {
		return $::MP2 ? Apache2::Const::DECLINED() : Apache::Constants::DECLINED();
	}

	if ((not $memoized) and ($r->dir_config('GalleryMemoize'))) {
		require Memoize;
		Memoize::memoize('get_imageinfo');
		$memoized=1;
	}

	$r->headers_out->{"X-Powered-By"} = "apachegallery.dk $VERSION - Hest design!";

	# Just return the http headers if the client requested that
	if ($r->header_only) {
		if (!$::MP2) {
			$r->send_http_header;
		}

		my $filename = $r->filename().$r->path_info();
		if (-f $filename or -d $filename) {
			return $::MP2 ? Apache2::Const::OK() : Apache::Constants::OK();
		}
		else {
			return $::MP2 ? Apache2::Const::NOT_FOUND() : Apache::Constants::NOT_FOUND();
		}
	}

	# Let Apache serve icons or favicon without us modifying the request
	if ($r->uri =~ m!^/ApacheGallery/!i || $r->uri =~ m!^/favicon.ico!i) {
		return $::MP2 ? Apache2::Const::DECLINED() : Apache::Constants::DECLINED();
	}

	my $img_pattern = get_image_pattern($r);
	my $vid_pattern = get_video_pattern($r);
	my $doc_pattern = get_document_pattern($r);

	my $uri = $r->uri;
	if ($uri =~ m|/\.cache/|) {
		log_debug("Old URL: ".$r->uri);
		if ($uri =~ m|/\.cache/\.points\.xml$|) {
			# Redirect to /.points.xml
			$uri =~ s|\.cache/||;
			log_info("Redirecting to $uri");
			$r->headers_out->set('Location' => $uri);
			return $::MP2 ? Apache2::Const::REDIRECT() : Apache::Constants::REDIRECT();
		}
		elsif ($uri =~ m|/\.cache/.bg-\d+.jpg|) {
			# Redirect to /.bg-{}.jpg
			$uri =~ s|\.cache/||;
			log_info("Redirecting to $uri");
			$r->headers_out->set('Location' => $uri);
			return $::MP2 ? Apache2::Const::REDIRECT() : Apache::Constants::REDIRECT();
		}
		elsif ($uri =~ m|/\.cache/\d+x\d+-.+\.[a-zA-Z0-9]+|) {
			# Redirect to /$3?w=$1&h=2
			$uri =~ s|/\.cache/(\d+)x(\d+)-(.+)$|/$3?w=$1&h=$2|;
			log_info("Redirecting to $uri");
			$r->headers_out->set('Location' => $uri);
			return $::MP2 ? Apache2::Const::REDIRECT() : Apache::Constants::REDIRECT();
		}
	}
	# /dir/dir/                  Directory listing
	# /dir/dir/?rss
	elsif ($uri =~ m|/$|) {
		log_info("Directory listing: $uri");
		return directory_listing($r);
	}
	# /dir/dir/.points.xml      Points -- or put it in the XHTML?
	elsif ($uri =~ m|/\.points\.xml$|) {
		log_info("Points file: $uri");
		return points_file($r);
	}
	# /dir/dir/.bg-123.jpg       Background (embedding).
	elsif ($uri =~ m|/\.bg-(\d+)\.jpg$|) {
		log_info("Directory icon: $uri");
		return directory_icon($r);
	}
	# /dir/dir/file.jpg          Photo (original)
	# /dir/dir/file.jpg?w=640    Photo (scaled)
	# /dir/dir/file.thm          Video thumbnail
	elsif ($uri =~ m|$img_pattern|i || $uri =~ m|\.thm$|i) {
		log_info("Image file: $uri");
		return image_file($r);
	}
	# /dir/dir/file.mpg          Video (original)
	# /dir/dir/file.mpg?f=ogv    Video (transcode)
	elsif ($uri =~ m|$vid_pattern|i) {
		log_info("Video file: $uri");
		return image_file($r);
	}
	# /dir/dir/file.txt          Document
	elsif ($uri =~ m|$doc_pattern|i) {
		log_info("Document file: $uri");
		return $::MP2 ? Apache2::Const::DECLINED() : Apache::Constants::DECLINED();
	}
	# /dir/dir/file              Photo/video page
	# (Check for existence of file.$img_pattern)
	elsif (my ($f, $e) = is_picture_or_video_page($r)) {
		log_info("Image/video page: $uri ($e)");
		return picture_page($r, $f, $e);
	}
	else {

	}

	show_error($r, 404, "404!", "No such file or directory: ".uri_escape($r->uri, $escape_rule));
	return $::MP2 ? Apache2::Const::OK() : Apache::Constants::OK();
}

######################## END HANDLER ########################

sub get_image_pattern {
	my $r = shift;
	my $img_pattern = $r->dir_config('GalleryImgFile');
	unless ($img_pattern) {
		$img_pattern = '\.(jpe?g|png|tiff?|ppm)$'
	}
	return $img_pattern;
}

sub get_video_pattern {
	my $r = shift;
	my $vid_pattern = $r->dir_config('GalleryVidFile');
	unless ($vid_pattern) {
		$vid_pattern = '\.(ogv|webm|mp4)$'
	}
	return $vid_pattern;
}

sub get_document_pattern {
	my $r = shift;
	my $doc_pattern = $r->dir_config('GalleryDocFile');
	unless ($doc_pattern) {
		$doc_pattern = '\.(mpe?g|avi|mov|asf|wmv|doc|mp3|ogg|pdf|rtf|wav|dlt|txt|html?|csv|eps)$'
	}
	return $doc_pattern;
}

sub directory_listing {
	my $r = shift;
	my $dirname = $r->filename().$r->path_info();
	$dirname =~ s/\/$//;

	my $cgi = new CGI;

	my $uri = $r->uri;
	$uri =~ s/\/$//;

	unless (opendir (DIR, $dirname)) {
		show_error($r, 404, "404!", "No such file or directory: ".uri_escape($r->uri, $escape_rule));
		return $::MP2 ? Apache2::Const::OK() : Apache::Constants::OK();
	}

	my $media_rss_enabled = $r->dir_config('GalleryEnableMediaRss');

	# Selectmode providing checkboxes beside all thumbnails
	my $select_mode = $cgi->param('select') ? "s" : "";

	# Check for cached HTML for the directory
	my $cache_fullpath = cache_dir($r);
	if ($cgi->param('rss') && $media_rss_enabled) {
		$cache_fullpath .= "index.rss";
		$r->content_type('application/rss+xml');
	}
	else {
		$cache_fullpath .= "index$select_mode.html";
		$r->content_type('text/html');
	}
	log_debug("directory_listing: cache file is/will be " . $cache_fullpath);

	my $usecache = 0;
	if (-f $cache_fullpath) {
		# TODO: is this sufficient to check if directory has changed?
		my $dirstat = stat($dirname);
		my $cachestat = stat($cache_fullpath);
		$usecache = ($dirstat->mtime < $cachestat->mtime);
		log_debug("directory_listing: $dirname newer than $cache_fullpath, ignoring cache") unless $usecache;
	}

	if ($usecache) {
		return send_file_response($r, $cache_fullpath, "C-ALBUM");
	}

	# No cached HTML -- generate it.

	my $img_pattern = get_image_pattern($r);
	my $vid_pattern = get_video_pattern($r);
	my $doc_pattern = get_document_pattern($r);

	my $tpl_dir = $r->dir_config('GalleryTemplateDir');

	# Instead of reading the templates every single time
	# we need them, create a hash of template names and
	# the associated Text::Template objects.
	my %templates = create_templates(
		{layout       => "$tpl_dir/layout.tpl",
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

	log_debug("directory_listing: looking for $dirname.folder");
	my $title;
	if (-f $dirname.".folder") {
		$title = get_filecontent($dirname.".folder");
		$title =~ s|<.*?>||g;
		$tpl_vars{TITLE} = $title;
	}
	else {
		$title = "Index of: $uri";
		$tpl_vars{TITLE} = $title;
		# TODO: Strip HTML
	}

	# Option to override the CSS file
	$tpl_vars{CSS} = $r->dir_config('GalleryCssFilename') ? $r->dir_config('GalleryCssFilename') : "modern.css";

	if ($media_rss_enabled) {
		# Put the RSS feed on all directory listings
		$tpl_vars{META} = '<link rel="alternate" href="?rss=1" type="application/rss+xml" title="$title"/>';
	}

	# OpenGraph information
	my $og_image = 'http://' . $r->server->server_hostname . $uri . '/.bg-1600.jpg';
	$tpl_vars{META} .= "<meta property='og:image' content='$og_image'/>\n";
	$tpl_vars{META} .= "<meta property='og:title' content='$title'/>\n";
	my $og_url = 'http://' . $r->server->server_hostname . $uri . '/';
	$tpl_vars{META} .= "<meta property='og:url' content='$og_url'/>\n";

	$tpl_vars{MENU} = generate_menu($r);

	$tpl_vars{FORM_BEGIN} = $select_mode ? '<form method="get">' : '';
	$tpl_vars{FORM_END}   = $select_mode ? '<input type="submit" name="Get list" value="Get list"/></form>' : '';

	# Read, sort, and filter files
	# Changed implementation of "Debian bug #619625 <http://bugs.debian.org/619625>"
	my @files = grep { !/^\./ && -f "$dirname/$_" && -r "$dirname/$_" && ! -e "$dirname/$_.ignore" && ! -e "$dirname/$_.noindex" } readdir (DIR);

	@files=gallerysort($r, @files);

	my @downloadable_files;

	if (@files) {
		# Remove unwanted files from list
		my @new_files = ();
		foreach my $picture (@files) {
			my $file = $dirname."/".$picture;

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
	# Changed implementation of "Debian bug #619625 <http://bugs.debian.org/619625>"
	my @directories = grep { !/^\./ && -d "$dirname/$_" && -r "$dirname/$_" && ! -e "$dirname/$_.ignore" && ! -e "$dirname/$_.noindex" } readdir (DIR);
	my $dirsortby;
	if (defined($r->dir_config('GalleryDirSortBy'))) {
		$dirsortby=$r->dir_config('GalleryDirSortBy');
	} else {
		$dirsortby=$r->dir_config('GallerySortBy');
	}
	if ($dirsortby && $dirsortby =~ m/^(size|atime|mtime|ctime)$/) {
		@directories = map(/^\d+ (.*)/, sort map(stat("$dirname/$_")->$dirsortby()." $_", @directories));
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

			my $thumbfilename = $dirname."/".$file;

			my $fileurl = $uri."/".$file;

			if (-d $thumbfilename) {
				my $dirtitle = '';
				if (-e $thumbfilename . ".folder") {
					$dirtitle = get_filecontent($thumbfilename . ".folder");
				}

				$dirtitle = $dirtitle ? $dirtitle : $file;
				$dirtitle =~ s/_/ /g if $r->dir_config('GalleryUnderscoresToSpaces');

				$tpl_vars{FILES} .=
					$templates{directory}->fill_in(
						HASH=> {
							FILEURL => uri_escape($fileurl, $escape_rule),
							# TODO: configure size of directory icon.
							DIRICON => uri_escape($fileurl, $escape_rule) . "/.bg-116.jpg",
							FILE    => $dirtitle,
						});
			}
			elsif (-f $thumbfilename && $thumbfilename =~ /$doc_pattern/i && $thumbfilename !~ /$img_pattern/i && $thumbfilename !~ /$vid_pattern/i) {
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
					$templates{file}->fill_in(
						HASH => {
							%tpl_vars,
							FILEURL => uri_escape($fileurl, $escape_rule),
							ALT => "Size: $size Bytes",
							FILE => $filetitle,
							TYPE => $type,
							FILETYPE => $filetype,
						}
					);
			}
			elsif (-f $thumbfilename && $thumbfilename =~ /$vid_pattern/i) {
				my $stat = stat($thumbfilename);
				my $size = $stat->size;
				my $magnitude = 0;
				while ($size > 1024) {
					$size = $size / 1024;
					$magnitude++;
				}
				my @mag = ("B", "kiB", "MiB", "GiB", "TiB");
				$size = int($size) . $mag[$magnitude];

				# Chop extension off.
				my $fileurlnoext = $fileurl;
				$fileurlnoext =~ s|\....?$||;

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
						$posterthumburl = $fileurl;
						$posterthumburl =~ s|\....$|.thm|;
						$posterthumburl = uri_escape($posterthumburl, $escape_rule) . "?w=$thumbnailwidth&amp;h=$thumbnailheight";
					}
				}

				log_debug("directory_listing: Video icon: using $posterthumburl");

				my %file_vars = (
					FILEURL => uri_escape($fileurlnoext, $escape_rule),
					FILE    => $file,
					SIZE    => $size,
					WIDTH   => 176,
					HEIGHT  => 132,
					POSTER  => $posterthumburl,
					SELECT  => $select_mode ? '<input type="checkbox" name="selection" value="'.$file.'">&nbsp;&nbsp;' : '',
					);
				$tpl_vars{FILES} .= $templates{video}->fill_in(HASH => {%tpl_vars,%file_vars});
			}
			elsif (-f $thumbfilename) { # Matches image pattern
				my ($width, $height, $type) = imgsize($thumbfilename);
				next if $type eq 'Data stream is not a known image file format';

				my @filetypes = qw(JPG TIF PNG PPM GIF);

				next unless (grep $type eq $_, @filetypes);
				my ($thumbnailwidth, $thumbnailheight) = get_thumbnailsize($r, $width, $height);

				# Chop extension off.
				my $fileurlnoext = $fileurl;
				$fileurlnoext =~ s|\.....?$||;

				my $imageinfo = get_imageinfo($r, $thumbfilename, $type, $width, $height);
				my $cached = get_scaled_picture_name($thumbfilename, $thumbnailwidth, $thumbnailheight);

				my $rotate = readfile_getnum($r, $imageinfo, $thumbfilename.".rotate");

				# Debian bug #348724 <http://bugs.debian.org/348724>
				# HTML <img> tag, alt attribute
				my $filetitle = $file;
				$filetitle =~ s/_/ /g if $r->dir_config('GalleryUnderscoresToSpaces');

				my $h = (grep($rotate==$_, (1, 3)) ? $thumbnailwidth : $thumbnailheight);
				my $w = (grep($rotate==$_, (1, 3)) ? $thumbnailheight : $thumbnailwidth);

				my %file_vars = (
					FILEURL => uri_escape($fileurlnoext, $escape_rule),
					FILE    => $filetitle,
					DATE    => $imageinfo->{DateTimeOriginal} ? $imageinfo->{DateTimeOriginal} : '',
					SRC     => uri_escape($fileurl, $escape_rule) . "?w=$w&amp;h=$h",
					HEIGHT  => $h,
					WIDTH   => $w,
					SELECT  => $select_mode ? '<input type="checkbox" name="selection" value="'.$file.'"/>&nbsp;&nbsp;':'',
					);
				$tpl_vars{FILES} .= $templates{picture}->fill_in(
					HASH => {
						%tpl_vars,
						%file_vars,
					},);

				if ($media_rss_enabled) {
					my ($content_image_width, undef, $content_image_height) = get_image_display_size($cgi, $r, $width, $height);
					my %item_vars = (
						THUMBNAIL => uri_escape($fileurl, $escape_rule) . "?w=$w&amp;h=$h",
						LINK      => uri_escape($fileurlnoext, $escape_rule),
						TITLE     => $filetitle,
						CONTENT   => uri_escape($fileurl, $escape_rule) . "?w=$content_image_width&amp;h=$content_image_height",
						);
					$tpl_vars{ITEMS} .= $templates{rss_item}->fill_in(
						HASH => {
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
	$dirname =~ m|(.*)/.*?$|;
	my $parent_filename = $1;

	$r->document_root =~ m|(.*)/$|;
	my $root_path = $1;
	if ($dirname ne $root_path && opendir (PARENT_DIR, $parent_filename)) {
		# Debian bug #619625 <http://bugs.debian.org/619625>
		my @neighbour_directories = grep { !/^\./ && -d "$parent_filename/$_" && -r "$parent_filename/$_" && ! -e "$parent_filename/$_.ignore" && ! -e "$dirname/$_.noindex" } readdir (PARENT_DIR);
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

		my $neighbour_counter = 0;
		foreach my $neighbour_directory (@neighbour_directories) {
			if ($parent_filename.'/'.$neighbour_directory eq $dirname) {
				if ($neighbour_counter > 0) {
					log_debug("prev directory is " .$neighbour_directories[$neighbour_counter-1]);
					my $linktext = $neighbour_directories[$neighbour_counter-1];
					if (-e $parent_filename.'/'.$neighbour_directories[$neighbour_counter-1] . ".folder") {
						$linktext = get_filecontent($parent_filename.'/'.$neighbour_directories[$neighbour_counter-1] . ".folder");
					}
					my %info = (
						URL => "../".$neighbour_directories[$neighbour_counter-1],
						LINK_NAME => "<<< $linktext",
						DIR_FILES => "",
						);
					$tpl_vars{PREV_DIR_FILES} = $templates{navdirectory}->fill_in(HASH=> {%info});
					log_debug($tpl_vars{PREV_DIR_FILES});
				}
				if ($neighbour_counter < scalar @neighbour_directories - 1) {
					my $linktext = $neighbour_directories[$neighbour_counter+1];
					if (-e $parent_filename.'/'.$neighbour_directories[$neighbour_counter+1] . ".folder") {
						$linktext = get_filecontent($parent_filename.'/'.$neighbour_directories[$neighbour_counter+1] . ".folder");
					}
					my %info = (
						URL => "../".$neighbour_directories[$neighbour_counter+1],
						LINK_NAME => "$linktext >>>",
						DIR_FILES => "",
						);
					$tpl_vars{NEXT_DIR_FILES} = $templates{navdirectory}->fill_in(HASH=> {%info});
					log_debug("next directory is " .$neighbour_directories[$neighbour_counter+1]);
				}
			}
			$neighbour_counter++;
		}
	}

	if (-f $dirname . '.comment') {
		my $comment_ref = get_comment($dirname . '.comment');
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
	if (open(P, ">$cache_fullpath")) {
		print P $tpl_vars{MAIN};
		close(P);
	}

	if ($cgi->param('rss')) {
		$r->content_type('application/rss+xml');
	} else {
		$r->content_type('text/html');
	}
	return send_file_response($r, $cache_fullpath, "ALBUM");
}

# Addition by Matt Blissett, June 2011.
# Directory icon, composed from images in the directory
sub directory_icon {
	my $r = shift;

	my $filename = $r->filename().$r->path_info();

	$filename =~ m|/\.bg-(\d+)|;
	my $image_size = $1;
	log_debug("BG Pic size $image_size");

	my $dirname = $filename;
	$dirname =~ s!/.bg-.*!!;
	log_debug("BG Dirname: $dirname");

	unless (opendir (DIR, $dirname)) {
		show_error($r, 404, "404!", "No such file or directory: ".uri_escape($r->uri, $escape_rule));
		return $::MP2 ? Apache2::Const::OK() : Apache::Constants::OK();
	}

	my $cache_filename = ".bg-$image_size.jpg";
	my $cache_fullpath = cache_dir($r) . $cache_filename;

	$r->content_type("image/jpeg");

	if (-f $cache_fullpath) {
		# file already in cache
		log_info("Background picture already in cache: $cache_fullpath");
	}
	else {
		my $img_pattern = get_image_pattern($r);

		my @files = sort grep { !/^\./ && /$img_pattern/i && -f "$dirname/$_" && -r "$dirname/$_" && ! -e "$dirname/$_.ignore" && ! -e "$dirname/$_.noindex" } readdir (DIR);

		if ($#files+1 <= 0) {
			log_debug("No files, returning 204");
			return $::MP2 ? Apache2::Const::HTTP_NO_CONTENT() : Apache::Constants::NOT_FOUND();
		}

		#log_debug(($#files+1) . " file, first " . $files[0]);

		log_debug("Making folder bg image from files: " . join(', ', @files));

		my $cached = album_cover_picture($r, $dirname, $image_size, $image_size, $cache_fullpath, @files);

		log_debug("Made folder bg image $cached, $r");
	}

	return send_file_response($r, $cache_fullpath, "BGIMG");
}

# Tests whether the requested URL is the HTML page for an image or video
sub is_picture_or_video_page {
	my $r = shift;
	my $filename = $r->filename().$r->path_info();
	log_debug("is_picture_or_video_page: Looking for file for $filename");

	my @extensions = split (/ /, $r->dir_config('GalleryImgFileThing') ? $r->dir_config('GalleryImgFileThing') : 'jpg jpeg png tiff ppm ogv mpg mp4');
	push @extensions, split (/ /, $r->dir_config('GalleryImgFileThing') ? uc($r->dir_config('GalleryImgFileThing')) : 'JPG JPEG PNG TIFF PPM OGV MPG MP4');

	foreach my $ext (@extensions) {
		if (-f $filename . "." . $ext && ! -e "$filename.$ext.ignore" ) { # Files marked .noindex can still be accessed
			$filename .= "." . $ext;
			log_debug("is_picture_or_video_page: Found file $filename");
			return ($filename, $ext);
		}
	}

	return;
}

# HTML page for an image
sub picture_page {
	my $r = shift;
	my $filename = shift;
	my $ext = shift;

	# Find the image file
	my $img_pattern = get_image_pattern($r);
	my $vid_pattern = get_video_pattern($r);

	# Create cache dir if not existing
	my @tmp = split (m|/|, $filename);
	my $picfilename = pop @tmp;
	my $path = (join "/", @tmp)."/";
	my $cache_path = cache_dir($r);

	my ($orig_width, $orig_height, $type);
	my $imageinfo;
	my ($image_width, $width, $height, $original_size);
	my $cached;

	my $cgi = new CGI;

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

	my $cache_fullpath = cache_dir($r) . picturepage_filename($r->uri, $width, $slideshow_selected_interval);
	log_debug("Picture HTML cache is/will be " . $cache_fullpath);

	$r->content_type("text/html");

	# TODO: check for modifications in directory (for prev/next etc).
	my $usecache = 0;
	if (-f $cache_fullpath) {
		# TODO: check if directory has changed.
		my $filestat = stat($filename);
		my $cachestat = stat($cache_fullpath);
		$usecache = ($filestat->mtime < $cachestat->mtime);
		log_debug("$filename newer than $cache_fullpath, ignoring cache") unless $usecache;
	}

	if ($usecache) {
		return send_file_response($r, $cache_fullpath, "C-PICPAGE");
	}

	my $tpl_dir = $r->dir_config('GalleryTemplateDir');

	my %templates = create_templates(
		{layout         => "$tpl_dir/layout.tpl",
		 picture        => "$tpl_dir/showpicture.tpl",
		 video          => "$tpl_dir/showvideo.tpl",
		 navpicture     => "$tpl_dir/navpicture.tpl",
		 info           => "$tpl_dir/info.tpl",
		 map            => "$tpl_dir/map.tpl",
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
	else {
		$width = $cgi->param('width');
	}

	my $og_image;
	$tpl_vars{TITLE} = "Viewing ".$r->uri();
	$tpl_vars{TITLE} =~ s!^Viewing /!Viewing !;
	$tpl_vars{TITLE} =~ s!/!&#8594;!g;
	if ($isVideo) {
		my @tmp = split (m|/|, $filename);
		my $vidfilename = pop @tmp;
		$tpl_vars{SRC} = uri_escape($vidfilename, $escape_rule);

		my $thmfilename = $vidfilename;
		$thmfilename =~ s/\....?$/.thm/;
		if (-f $path.$thmfilename) {
			# TODO: Scale
			$tpl_vars{POSTER} = uri_escape($thmfilename, $escape_rule);
		}
		else {
			$tpl_vars{POSTER} = "/ApacheGallery/video-mpg.png";
		}
		$og_image = $tpl_vars{POSTER};
	}
	else {
		$tpl_vars{RESOLUTION} = $resolution;
		$tpl_vars{SRC} = uri_escape($picfilename, $escape_rule) . "?w=$image_width&amp;h=$height";
		$og_image = uri_escape($picfilename, $escape_rule) . "?w=$image_width&amp;h=$height";
	}
	$tpl_vars{META} = "";
	$tpl_vars{MENU} = generate_menu($r);
	$tpl_vars{URI} = $r->uri();

	# Option to override the CSS file
	$tpl_vars{CSS} = $r->dir_config('GalleryCssFilename') ? $r->dir_config('GalleryCssFilename') : "modern.css";

	# OpenGraph information
	my @uribits = split (m|/|, $r->uri);
	pop @uribits;
	my $uripath = (join "/", @uribits)."/";
	$tpl_vars{META} .= "<meta property='og:image' content='http://" . $r->server->server_hostname . $uripath . $og_image . "'/>\n";
	my $og_url = 'http://' . $r->server->server_hostname . $r->uri;
	$tpl_vars{META} .= "<meta property='og:url' content='$og_url'/>\n";

	my $exif_mode = $r->dir_config('GalleryEXIFMode');
	unless ($exif_mode) {
		$exif_mode = 'namevalue';
	}

	unless (opendir(DATADIR, $path)) {
		show_error($r, 404, "404!", "No such file or directory: ".uri_escape($r->uri, $escape_rule));
		return $::MP2 ? Apache2::Const::OK() : Apache::Constants::OK();
	}

	my $doc_pattern = get_document_pattern($r);

	my @pictures = grep { (/$img_pattern/i || /$vid_pattern/i) && -r "$path/$_" && ! -e "$path/$_.ignore" && ! -e "$path/$_.noindex" } readdir (DATADIR);
	closedir(DATADIR);
	@pictures = gallerysort($r, @pictures);

	$tpl_vars{TOTAL} = scalar @pictures;

	my $prevpicture;
	my $nextpicture;
	my $nextpicturenoext = $nextpicture;

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

				# Chop extension off.
				my $prevpicturenoext = $prevpicture;
				$prevpicturenoext =~ s|\....?$||;

				$nav_vars{URL}       = uri_escape($prevpicturenoext, $escape_rule);
				$nav_vars{FILENAME}  = $prevpicturenoext;
				$nav_vars{DIRECTION} = "prev";
				$nav_vars{ACCESSKEY} = "P";
				$nav_vars{WIDTH}     = $width;
				if ($prevpicture =~ m/$vid_pattern/i) {
					log_debug("prevpicture=$prevpicture is a video");
					my $thmfilename = $prevpicture;
					$thmfilename =~ s/\....?$/.thm/;
					log_debug("thmfilename ? " . $path."/".$thmfilename);
					if (-f $path.$thmfilename) {
						$prevpicture =~ s/\....$/.thm/;
						($orig_width, $orig_height, $type) = imgsize($path.$prevpicture);
						($thumbnailwidth, $thumbnailheight) = get_thumbnailsize($r, $orig_width, $orig_height);
						$nav_vars{PICTURE} = uri_escape($prevpicture, $escape_rule) . "?w=$thumbnailwidth&amp;h=$thumbnailheight";
					}
					else {
						$nav_vars{PICTURE} = "/ApacheGallery/video-mpg.png";
					}
					$nav_vars{VIDEO} = "video";
				}
				else {
					($orig_width, $orig_height, $type) = imgsize($path.$prevpicture);
					($thumbnailwidth, $thumbnailheight) = get_thumbnailsize($r, $orig_width, $orig_height);
					$nav_vars{PICTURE} = uri_escape($prevpicture, $escape_rule) . "?w=$thumbnailwidth&amp;h=$thumbnailheight";
				}
				$tpl_vars{BACK} = $templates{navpicture}->fill_in(HASH => \%nav_vars);
			}
			else {
				$tpl_vars{BACK} = "";
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

				# Chop extension off.
				$nextpicturenoext = $nextpicture;
				$nextpicturenoext =~ s|\....?$||;

				$nav_vars{URL}       = uri_escape($nextpicturenoext, $escape_rule);
				$nav_vars{FILENAME}  = $nextpicturenoext;
				$nav_vars{DIRECTION} = "next";
				$nav_vars{ACCESSKEY} = "N";
				$nav_vars{WIDTH}     = $width;
				#$tpl_vars{NEXTURL}   = uri_escape($nextpicture, $escape_rule);
				if ($nextpicture =~ m/$vid_pattern/i) {
					log_debug("nextpicture=$nextpicture is a video");
					my $thmfilename = $nextpicture;
					$thmfilename =~ s/\....?$/.thm/;
					log_debug("thmfilename ? " . $path."/".$thmfilename);
					if (-f $path.$thmfilename) {
						$nextpicture =~ s/\....$/.thm/;
						($orig_width, $orig_height, $type) = imgsize($path.$nextpicture);
						($thumbnailwidth, $thumbnailheight) = get_thumbnailsize($r, $orig_width, $orig_height);
						$nav_vars{PICTURE} = uri_escape($nextpicture, $escape_rule) . "?w=$thumbnailwidth&amp;h=$thumbnailheight";
					}
					else {
						$nav_vars{PICTURE} = "/ApacheGallery/video-mpg.png";
					}
					$nav_vars{VIDEO} = "video";
				}
				else {
					($orig_width, $orig_height, $type) = imgsize($path.$nextpicture);
					($thumbnailwidth, $thumbnailheight) = get_thumbnailsize($r, $orig_width, $orig_height);
					$nav_vars{PICTURE} = uri_escape($nextpicture, $escape_rule) . "?w=$thumbnailwidth&amp;h=$thumbnailheight";

					# Tell browser to prefetch next image
					my $next_width; my $next_height;
					($next_width, undef, $next_height) = get_image_display_size($cgi, $r, $orig_width, $orig_height);
					my $next_picture_url = uri_escape($nextpicture, $escape_rule) . "?w=$next_width&amp;h=$next_height";
					$tpl_vars{META} .= "<link rel='prefetch' href='$next_picture_url'/>\n";
				}
				$tpl_vars{NEXT} = $templates{navpicture}->fill_in(HASH => \%nav_vars);

				# Tell browser to prefetch next page
				$tpl_vars{META} .= "<link rel='prefetch prerender' href='$nav_vars{URL}?width=$width'/>\n";
			}
			else {
				$tpl_vars{NEXT} = "";
				$tpl_vars{NEXTURL} = '#';
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
		$tpl_vars{COMMENT} = encode("utf8", $comment);
		$tpl_vars{TITLE} = encode("utf8", $comment);
	} else {
		$tpl_vars{COMMENT} = '';
	}
	my $title_no_html = $tpl_vars{TITLE};
	$title_no_html =~ s/<.+?>/ /sg;
	$title_no_html =~ s/\s(\s+)/$1/g;
	$title_no_html =~ s/^\s+|\s+$//g;
	$tpl_vars{META} .= "<meta property='og:title' content='". $title_no_html ."'/>\n";
	my $comment_no_html = $tpl_vars{COMMENT};
	$comment_no_html =~ s/<.+?>/ /sg;
	$comment_no_html =~ s/\s(\s+)/$1/g;
	$comment_no_html =~ s/^\s+|\s+$//g;
	$tpl_vars{META} .= "<meta property='og:description' content='". $comment_no_html ."'/>\n";

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

	unless ($r->dir_config('GalleryHideMap')) {
		my %map_vars;
		$map_vars{IMAGEURI} = uri_escape($r->uri() . ".$ext", $escape_rule);
		(
		 $map_vars{LAT},
		 $map_vars{LONG},
		 $map_vars{ALTITUDE},
		 $map_vars{LAT_NICE},
		 $map_vars{LONG_NICE},
		 $map_vars{STATUS},
		 $map_vars{PIN_COLOUR}
		) =
			get_georef(
			    $imageinfo->{GPSLatitude} ? $imageinfo->{GPSLatitude} : '',
			    $imageinfo->{GPSLatitudeRef} ? $imageinfo->{GPSLatitudeRef} : '',
			    $imageinfo->{GPSLongitude} ? $imageinfo->{GPSLongitude} : '',
			    $imageinfo->{GPSLongitudeRef} ? $imageinfo->{GPSLongitudeRef} : '',
			    $imageinfo->{GPSAltitude} ? $imageinfo->{GPSAltitude} : '',
			    $imageinfo->{GPSStatus} ? $imageinfo->{GPSStatus} : '',
			    );

		if ($map_vars{LAT} != '') {
			$tpl_vars{MAP} = $templates{map}->fill_in(HASH => \%map_vars);
		}
		else {
			$tpl_vars{MAP} = "";
		}
	}
	else {
		$tpl_vars{MAP} = "";
	}

	# Fill in sizes and determine if any are smaller than the
	# actual image. If they are, $scaleable=1
	my $scaleable = 0;
	my @sizes = split (/ /, $r->dir_config('GallerySizes') ? $r->dir_config('GallerySizes') : '640 800 1024 1600');
	my @available_sizes;
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
			push @available_sizes, $size
		}
	}
	$tpl_vars{AVAILABLEWIDTHS} = join ", ", @available_sizes;

	unless ($scaleable) {
		my %sizes_vars;
		$sizes_vars{IMAGEURI} = uri_escape($r->uri(), $escape_rule);
		$sizes_vars{SIZE}     = $original_size;
		$sizes_vars{WIDTH}    = $original_size;
		$tpl_vars{SIZES} .= $templates{scaleactive}->fill_in(HASH => \%sizes_vars);
	}

	$tpl_vars{IMAGEURI} = uri_escape($r->uri() . ".$ext", $escape_rule);

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
			show_error($r, 403, "Invalid interval", "Invalid slideshow interval choosen");
			return $::MP2 ? Apache2::Const::OK() : Apache::Constants::OK();
		}

		$tpl_vars{URL} = uri_escape($nextpicturenoext, $escape_rule);
		$tpl_vars{WIDTH} = ($width > $height ? $width : $height);
		$tpl_vars{INTERVAL} = $cgi->param('slideshow');
		$tpl_vars{META} .=  $templates{refresh}->fill_in(HASH => \%tpl_vars);
	}
	else {
		$tpl_vars{SLIDESHOW} .=  $templates{slideshowisoff}->fill_in(HASH => \%tpl_vars);
	}

	if (my $license_file = $r->dir_config('GalleryCopyrightHtmlTemplate')) {
		my %license_template = create_templates({license => $license_file});
		$tpl_vars{LICENSE} = $license_template{license}->fill_in(HASH => \%tpl_vars);
	}

	if ($isVideo) {
		$tpl_vars{MAIN} = $templates{video}->fill_in(HASH => \%tpl_vars);
	}
	else {
		$tpl_vars{MAIN} = $templates{picture}->fill_in(HASH => \%tpl_vars);
	}
	$tpl_vars{MAIN} = $templates{layout}->fill_in(HASH => \%tpl_vars);

	# put $tpl_vars{MAIN} into the file.
	if (open(P, ">$cache_fullpath")) {
		print P $tpl_vars{MAIN};
		close(P);
	}
	return send_file_response($r, $cache_fullpath, "PICPAGE");
}

# Handles image files (original or scaled)
sub image_file {
	my $r = shift;
	my $image_fullpath = $r->filename().$r->path_info();

	# original size
	if (!defined($ENV{QUERY_STRING}) || $ENV{QUERY_STRING} eq '') {
		log_info("Sending full-sized image");
		if ($r->dir_config('GalleryAllowOriginal') ? 1 : 0) {
			$r->filename($image_fullpath);
			return $::MP2 ? Apache2::Const::DECLINED() : Apache::Constants::DECLINED();
		} else {
			return $::MP2 ? Apache2::Const::FORBIDDEN() : Apache::Constants::FORBIDDEN();
		}
	}

	my $cgi = new CGI;

	# TODO Check width is allowed (remembering thumnail width)
	# TODO Validate user-controlled parameter
	my $request_width = $cgi->param('w');
	my $request_height = $cgi->param('h');

	my $cached_fullpath = scale_picture($r, $image_fullpath, $request_width, $request_height);

	my $subr = $r->lookup_file($cached_fullpath);
	$r->content_type($subr->content_type());

	return send_file_response($r, $cached_fullpath, "IMAGE");
}

# Generate XML file containing georeferences of photographs
# Addition by Matt Blissett, May 2011.
sub points_file {
	my $r = shift;

	my $dirname = $r->filename().$r->path_info();
	$dirname =~ s!/.points.xml!!;

	unless (opendir (DIR, $dirname)) {
		show_error($r, 404, "404!", "No such file or directory: ".uri_escape($r->uri, $escape_rule));
		return $::MP2 ? Apache2::Const::OK() : Apache::Constants::OK();
	}

	$r->content_type('application/xml');

	my $cache_fullpath = cache_dir($r) . ".points.xml";
	log_debug("points_file: cache file is/will be " . $cache_fullpath);

	my $usecache = 0;
	if (-f $cache_fullpath) {
		my $dirstat = stat($dirname);
		my $cachestat = stat($cache_fullpath);
		$usecache = ($dirstat->mtime < $cachestat->mtime);
		log_debug("points_file: $dirname newer than $cache_fullpath, ignoring cache") unless $usecache;
	}

	if ($usecache) {
		log_debug("points_file: file already in cache: $cache_fullpath");
		return send_file_response($r, $cache_fullpath, "C-POINTS");
	}
	else {
		my $img_pattern = get_image_pattern($r);

		my @files = sort grep { !/^\./ && /$img_pattern/i && -f "$dirname/$_" && -r "$dirname/$_" && ! -e "$dirname/$_.ignore" && ! -e "$dirname/$_.noindex" } readdir (DIR);

		log_debug("points_file: $#files files");

		my %tpl_vars;

		my $tpl_dir = $r->dir_config('GalleryTemplateDir');

		# Could check for these being in the template.
		my %templates = create_templates(
			{
				point     => "$tpl_dir/point.tpl",
				points    => "$tpl_dir/points.tpl"
			});

		if (@files) {
			my $filelist;

			my $file_counter = 0;

			my $dirurl = $r->uri;
			$dirurl =~ s!.points.xml!!;

			foreach my $file (@files) {
				log_debug("points_file: scanning file $file_counter " . $file);
				$file_counter++;
				my $filename = $dirname."/".$file;

				if (-f $filename) {
					# Check it's an image
					my ($width, $height, $type) = imgsize($filename);
					next if $type eq 'Data stream is not a known image file format';

					my @filetypes = qw(JPG TIF PNG PPM GIF);

					next unless (grep $type eq $_, @filetypes);

					# Thumbnail dimensions needed for URL to thumbnail
					my ($thumbnailwidth, $thumbnailheight) = get_thumbnailsize($r, $width, $height);
					my $cached = get_scaled_picture_name($filename, $thumbnailwidth, $thumbnailheight);
					log_debug("points_file: thumbnail name $cached");

					# Read EXIF info
					my $imageinfo = get_imageinfo($r, $filename, $type, $width, $height);

					my %point_vars = (
						FILE => $file,
						STATUS => $imageinfo->{GPSStatus} ? $imageinfo->{GPSStatus} : '',
						LATR => $imageinfo->{GPSLatitudeRef} ? $imageinfo->{GPSLatitudeRef} : '',
						LONGR => $imageinfo->{GPSLongitudeRef} ? $imageinfo->{GPSLongitudeRef} : '',
						LAT => $imageinfo->{GPSLatitude} ? $imageinfo->{GPSLatitude} : '',
						LONG => $imageinfo->{GPSLongitude} ? $imageinfo->{GPSLongitude} : '',
						THUMB => uri_escape($dirurl."/$cached", $escape_rule) . "?w=$thumbnailwidth&amp;h=$thumbnailheight",
					);

					if (-f $filename . '.comment') {
						log_debug("points_file: Found .comment file " . $filename . '.comment');
						my $comment_ref = get_comment($filename . '.comment');
						$tpl_vars{COMMENT} = $comment_ref->{COMMENT} . "\n" if $comment_ref->{COMMENT};
						$tpl_vars{TITLE} = $comment_ref->{TITLE} if $comment_ref->{TITLE};
					}
					elsif ($r->dir_config('GalleryCommentExifKey')) {
						my $comment = decode("utf8", $imageinfo->{$r->dir_config('GalleryCommentExifKey')});
						$tpl_vars{COMMENT} = encode("iso-8859-1", $comment);
					}
					else {
						$tpl_vars{COMMENT} = undef;
						$tpl_vars{TITLE} = undef;
					}
					log_debug("points_file: Title: ".$tpl_vars{TITLE});
					log_debug("points_file: Comment: ".$tpl_vars{COMMENT});

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
		if (open(P, ">$cache_fullpath")) {
			print P $tpl_vars{MAIN};
			close(P);
		}
	}

	return send_file_response($r, $cache_fullpath, "POINTS");
}

sub selected_images {
	my $r = shift;
	my $cgi = shift;

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

################################################################
#                      # Helper methods #                      #
################################################################

# Turns /url/path/file -> /cache/dir/path/
# Argument: Request object
sub cache_dir {
	my ($r) = @_;

	my $cache_root;

	unless ($r->dir_config('GalleryCacheDir')) {
		$cache_root = '/var/cache/www/';
		if ($r->server->is_virtual) {
			$cache_root = File::Spec->catdir($cache_root, $r->server->server_hostname);
		}
		else {
			$cache_root = File::Spec->catdir($cache_root, $r->location);
		}
	}
	else {
		$cache_root = $r->dir_config('GalleryCacheDir');
	}

	my $uri = $r->uri;

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

	return($dirname . "/");
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

# Gets HTML cache page filename
sub picturepage_filename {
	my ($fullpath, $width, $slideshow_selected_interval) = @_;

	my @parts = split(m|/|, $fullpath);
	my $filename = pop(@parts);
	my $picturepage_filename;

	$picturepage_filename = "$filename-$width-$slideshow_selected_interval.html";

	return $picturepage_filename;
}

sub get_scaled_picture_name {
	my ($fullpath, $width, $height) = @_;

	my (undef, undef, $type) = imgsize($fullpath);

	my @dirs = split(m|/|, $fullpath);
	my $filename = pop(@dirs);
	my $newfilename;

	# needs to be configurable
	if (grep $type eq $_, qw(PNG PPM TIF GIF)) {
		$newfilename = $width."x".$height."-".$filename;
		$newfilename =~ s/\.(\w+)$/-$1\.jpg/;
	} else {
		$newfilename = $width."x".$height."-".$filename;
	}

	return $newfilename;
}

sub scale_picture {
	my ($r, $image_fullpath, $request_width, $request_height) = @_;

	my ($orig_width, $orig_height, $type) = imgsize($image_fullpath);

	my $imageinfo = get_imageinfo($r, $image_fullpath, $type, $orig_width, $orig_height);

	if (($request_width > $orig_width) && ($request_height > $orig_height)) {
		# Run it through the resize code anyway to get watermarks
		# Also, to convert non-JPEG to a JPEG (if enabled)
		$request_width = $orig_width;
		$request_height = $orig_height;
	}

	my $cache_dir = cache_dir($r);
	my $cache_filename = get_scaled_picture_name($image_fullpath, $request_width, $request_height);
	my $cache_fullpath = $cache_dir . $cache_filename;

	my ($thumbnailwidth, $thumbnailheight) = get_thumbnailsize($r, $orig_width, $orig_height);

	# Do we want to generate a new file in the cache?
	my $scale = 1;

	if (-f $cache_fullpath) {
		$scale = 0;

		# Check to see if the image has changed
		my $filestat = stat($image_fullpath);
		my $cache_dirstat = stat($cache_dir."/".$cache_filename);
		if ($filestat->mtime >= $cache_dirstat->mtime) {
			$scale = 1;
		}

		# Check to see if the .rotate file has been added or changed
		if (-f $image_fullpath . ".rotate") {
			my $rotatestat = stat($image_fullpath . ".rotate");
			if ($rotatestat->mtime > $cache_dirstat->mtime) {
				$scale = 1;
			}
		}
		# Check to see if the copyrightimage has been added or changed
		if ($r->dir_config('GalleryCopyrightImage') && -f $r->dir_config('GalleryCopyrightImage')) {
			unless ($request_width == $thumbnailwidth or $request_width == $thumbnailheight) {
				my $copyrightstat = stat($r->dir_config('GalleryCopyrightImage'));
				if ($copyrightstat->mtime > $cache_dirstat->mtime) {
					$scale = 1;
				}
			}
		}
	}

	if ($scale) {
		my $rotate = readfile_getnum($r, $imageinfo, $image_fullpath . ".rotate");
		my $quality = $r->dir_config('GalleryQuality');

		log_debug("scale_picture: writing resized picture to " . $cache_fullpath);

		if ($request_width == $thumbnailwidth or $request_width == $thumbnailheight) {
			resizepicture($r, $image_fullpath, $cache_fullpath, $request_width, $request_height, $rotate, '', '', '', '', '', '');
		}
		else {
			resizepicture($r, $image_fullpath, $cache_fullpath, $request_width, $request_height, $rotate,
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
	else {
		log_debug("scale_picture: using existing scaled picture at " . $cache_fullpath);
	}

	return $cache_fullpath;
}

# Addition by Matt Blissett, June 2011
sub album_cover_picture {
	my ($r, $dir_fullpath, $width, $height, $cache_fullpath, @all_filenames) = @_;

	my @fullpath;
	log_debug("album_cover_picture: Have $#all_filenames files to select from");

	# Choose (up to) four images
	my $inc = floor($#all_filenames/4);
	$inc++ if ($inc == 0);
	for (my $i = 0; $i <= $#all_filenames; $i += $inc) {
		my $j = floor($i);
		log_debug("album_cover_picture: $i choosing ${j}th: $all_filenames[$j]");
		push @fullpath, "$dir_fullpath/" . $all_filenames[$j];
	}

	log_debug("album_cover_picture: 1st $fullpath[0]");
	log_debug("album_cover_picture: 2nd $fullpath[1]");
	log_debug("album_cover_picture: 3rd $fullpath[2]");
	log_debug("album_cover_picture: 4th $fullpath[3]");

	my $quality = $r->dir_config('GalleryQuality');

	make_album_cover_picture($r, $cache_fullpath, $width, $height,
			($r->dir_config('GalleryCopyrightImage') ? $r->dir_config('GalleryCopyrightImage') : ''),
			($r->dir_config('GalleryTTFDir') ? $r->dir_config('GalleryTTFDir') : ''),
			($r->dir_config('GalleryCopyrightText') ? $r->dir_config('GalleryCopyrightText') : ''),
			($r->dir_config('GalleryCopyrightColor') ? $r->dir_config('GalleryCopyrightColor') : ''),
			($r->dir_config('GalleryTTFFile') ? $r->dir_config('GalleryTTFFile') : ''),
			($r->dir_config('GalleryTTFSize') ?  $r->dir_config('GalleryTTFSize') : ''),
			($r->dir_config('GalleryCopyrightBackgroundColor') ?  $r->dir_config('GalleryCopyrightBackgroundColor') : ''),
			$quality,
			@fullpath);

	return $cache_fullpath;
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
	if (defined $r->dir_config('GalleryThumbnailSizeLS') and $r->dir_config('GalleryThumbnailSizeLS') eq '1' and $orig_width < $orig_height) {
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
			show_error($r, 403, "Invalid width", "The specified width is invalid");
			return $::MP2 ? Apache2::Const::OK() : Apache::Constants::OK();
		}

		$width = $cgi->param('width');
		my $cookie = new CGI::Cookie(-name => 'GallerySize', -value => $width, -expires => '+6M');
		$r->headers_out->{'Set-Cookie'} = $cookie;

	}
	elsif ($cookies{'GallerySize'} && (grep $cookies{'GallerySize'}->value == $_, @sizes)) {
		$width = $cookies{'GallerySize'}->value;
	}
	else {
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
	}
	else {
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
				elsif ($exif_key eq 'MaxApertureValue' or $exif_key eq 'GPSAltitude') {
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

	log_error($error);

	my $tpl = $r->dir_config('GalleryTemplateDir');

	my %templates = create_templates(
		{
			layout => "$tpl/layout.tpl",
			error  => "$tpl/error.tpl",
		});

	my %tpl_vars;
	$tpl_vars{TITLE}      = "Error! $errortitle";

	$tpl_vars{CSS} = $r->dir_config('GalleryCssFilename') ? $r->dir_config('GalleryCssFilename') : "modern.css";

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

	my @links = split (m|/|, $r->uri);
	my $uri = $r->uri;
	$uri =~ s/^$root_path//g;

	@links = split (m|/|, $uri);

	# Get the full path of the base directory
	my $dirname;
	{
		my @direlem = split (m|/|, $filename);
		for my $i ( 0 .. ( scalar(@direlem) - scalar(@links) ) ) {
			$dirname .= shift(@direlem) . '/';
		}
		chop $dirname;
	}

	my $picturename;
	if (! -e $filename) {
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
			$linktext = "$root_text";
		}
		else {
			$dirname = File::Spec->catdir($dirname, $link);

			if (-e $dirname . ".folder") {
				$linktext = get_filecontent($dirname . ".folder");
			}
		}

		if ("$root_path$uri" eq $menuurl) {
			$menu .= "$linktext / ";
		}
		else {
			# Final link should have rel="index"
			my $extraAttribute;
			if (\$link == \$links[-1]) {
				$extraAttribute = 'rel="index"';
			}
			$menu .= "<a ${extraAttribute} href=\"".uri_escape($menuurl, $escape_rule)."\">$linktext</a> / ";
		}

	}

	if ($picturename) {
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
		}
		elsif ($GalleryCopyrightText eq '') {
			log_error("GalleryCopyrightText is empty. No text inserted to picture\n");
		}
		elsif (!-e "$GalleryTTFDir/$GalleryTTFFile") {
			log_error("GalleryTTFFile $GalleryTTFFile was not found\n");
		}
		else {
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
			}
			else {
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
sub make_album_cover_picture {
	my ($r, $outfile, $x, $y, $copyrightfile, $GalleryTTFDir, $GalleryCopyrightText, $text_color, $GalleryTTFFile, $GalleryTTFSize, $GalleryCopyrightBackgroundColor, $quality, @infile) = @_;

	# Load images
	# TODO: Load one at a time to reduce memory use?
	my @image;
	my $i;
	for ($i = 0; $i < 4 && $i <= $#infile; $i++) {
		$image[$i] = Image::Imlib2->load($infile[$i]) or warn("Unable to open file $infile[$i], $!");
		log_debug("make_album_cover_picture: loaded file $i : $infile[$i]");
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

	log_debug("make_album_cover_picture: f $f[0], g $g[0], d $d[0], x $x, y $y, w " . $image[0]->width() . ", h " . $image[0]->height());

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
		}
		elsif ($GalleryCopyrightText eq '') {
			log_error("GalleryCopyrightText is empty. No text inserted to picture\n");
		}
		elsif (!-e "$GalleryTTFDir/$GalleryTTFFile") {
			log_error("GalleryTTFFile $GalleryTTFFile was not found\n");
		}
		else {
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
			}
			else {
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
	}
	else {
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
		 my $tt_obj = Text::Template->new
			 (TYPE   => 'FILE',
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
		log_debug("Sending file $file");
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
		$r->headers_out->{"ETag"} = "\"$nonce\"";
		$r->headers_out->{"Cache-Control"} = "public";
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

sub get_georef {
	my ($gps_lat, $gps_lat_ref, $gps_long, $gps_long_ref, $gps_altitude, $gps_status) = @_;

	my ($lat, $long, $altitude, $lat_nice, $long_nice, $status, $pin);

	if ($gps_lat ne '' && $gps_long ne '') {
		$status = $gps_status;
		$pin = 'red';
		if ($gps_status eq 'A') { $pin = 'yellow'; }
		if ($gps_status eq 'V') { $pin = 'gray'; }

		if ($gps_lat_ref eq 'S') { $lat = "-" };
		$lat .= $gps_lat;
		if ($gps_long_ref eq 'W') { $long = "-" };
		$long .= $gps_long;

		if (length $gps_altitude) {
			$altitude = $gps_altitude . "m";
		}

		$lat_nice = decimal_to_degminsec($lat, "N", "S");
		$long_nice = decimal_to_degminsec($long, "E", "W");
	}

	log_debug("Map values are $lat, $long, $altitude, $lat_nice, $long_nice, $status, $pin");
	return ($lat, $long, $altitude, $lat_nice, $long_nice, $status, $pin);
}

sub decimal_to_degminsec {
	my ($value, $positive, $negative) = @_;

	my $v = abs($value);
	my $dms  = int($v) . "° ";
	$v -= int($v);
	$v *= 60;
	$dms .= int($v) . "′ ";
	$v -= int($v);
	$v *= 60;
	$dms .= (sprintf '%.3f', $v) . "″ ";
	if ($value < 0) { $dms .= $negative; }
	else { $dms .= $positive; }

	return $dms;
}

sub log_error {
	if ($::MP2) {
		Apache2::RequestUtil->request->log->error(shift());
	}
	else {
		Apache->request->log_error(shift());
	}
}

sub log_info {
	if ($::MP2) {
		Apache2::RequestUtil->request->log->info(shift());
	}
	else {
		Apache->request->log_info(shift());
	}
}

sub log_debug {
	if ($::MP2) {
		Apache2::RequestUtil->request->log->debug(shift());
	}
	else {
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

=item B<GalleryCopyrightHtmlTemplate>

Path to a template file that will be inserted on every picture/video
page.

Example template file:
        <p id="license" about="{ $IMAGEURI }">This <span
href="http://purl.org/dc/dcmitype/Image" rel="dc:type">work</span> by <span
property="cc:attributionName">Matthew Blissett</span> is licensed under a <a
rel="license"
href="http://creativecommons.org/licenses/by-sa/3.0/deed.en_GB">Creative Commons
Attribution-ShareAlike 3.0 Unported License</a>.<br />Permissions beyond the
scope of this license may be available at <a href="/contact/"
rel="cc:morePermissions">http://matt.blissett.me.uk/contact/</a>.</p>

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

=item B<GalleryHideMap>

Setting to hide the map for images with EXIF georeference data (if
supported by the theme).

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
create a <directory|file>.ignore file.  This prevents access to the
directory or file.

To hide a directory or a file from gallery views and the previous/next
sequence, create a file <directory|file>.noindex.  This still allows
direct access if you know the filename.

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

# Local variables:
# c-basic-offset: 4
# tab-width: 4
# indent-tabs-mode: t
# End:
