#!/usr/bin/perl

#$Id: gallery-buildcache.pl,v 1.1 2001/10/14 17:31:41 mil Exp $

use warnings;
use strict;
use Carp;

$|=1;

use Inline 'C';
use Inline C => Config =>
	LIBS => '-L/usr/X11R6/lib -lImlib2 -lttf -lm -ldl -lXext -lXext',
	ENABLE => 'UNTAINT';

my $path = shift;

unless (defined($path)) {
	confess "usage: gallery-buildcache <path>";
}	

opendir (DIR, $path) or confess "unable to open $path: $!";
my @pictures = grep {/\.(jpg|jpeg|png)$/} readdir (DIR);
closedir(DIR);

unless (-d "$path/.cache") {
	mkdir("$path/.cache", 0777) or confess "unable to create $path/.cache: $!";
}	

print "creating thumbnails in $path...\n";

foreach my $picture (@pictures) {

	my $newfilename = "$path/.cache/100x75-$picture";

	unless (-f $newfilename) {

		print "writing $newfilename\n";
		
		resizepicture("$path/$picture", $newfilename, 100, 75);

	}	
}	

print "done.\n";

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
