use ExtUtils::MakeMaker;
# $Id: Makefile.PL,v 1.3 2001/09/02 17:30:35 mil Exp $
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    'NAME'		=> 'Apache::Gallery',
    'VERSION_FROM'	=> 'lib/Apache/Gallery.pm', # finds $VERSION
    'PREREQ_PM'		=> {}, # e.g., Module::Name => 1.1
    ($] >= 5.005 ?    ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM => 'lib/Apache/Gallery.pm', # retrieve abstract from module
       AUTHOR     => 'Michael Legart <michael@legart.dk>') : ()),
);
