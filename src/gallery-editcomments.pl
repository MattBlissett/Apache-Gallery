#!/usr//bin/perl

#$Id: gallery-editcomments.pl,v 1.2 2001/10/04 18:57:16 mil Exp $

use warnings;
use strict;
use Carp;

use DB_File;

dbmopen my %comments, "comments.db", 0664 or confess "unable to open comments.db for writing";

opendir (DIR, ".") or confess "unable to open dir: . $!";

my @images = grep { /\.(jpg|jpeg|png)$/ } readdir(DIR);

foreach my $image (@images) {

	if ($comments{$image}) {
		print "$image already has comment: $comments{$image}\n";
		print "would you like to change this? (y): ";
		my $change = <STDIN>;
		chomp ($change);
		next if ($change =~ m/n/i);	
	}

	print "enter comment for $image: ";
	my $comment = <STDIN>;
	chomp($comment);
	$comments{$image} = $comment;

}

closedir(DIR);
