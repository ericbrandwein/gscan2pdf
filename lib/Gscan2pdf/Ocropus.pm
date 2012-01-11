package Gscan2pdf::Ocropus;

use 5.008005;
use strict;
use warnings;
use Carp;
use File::Temp;    # To create temporary files
use File::Basename;
use HTML::Entities;
use Encode;

my ( $exe, $installed, $setup );

sub setup {
 return $installed if $setup;
 if ( system("which ocroscript > /dev/null 2> /dev/null") == 0 ) {

  unless ( defined $ENV{OCROSCRIPTS} ) {
   for (qw(/usr /usr/local)) {
    $ENV{OCROSCRIPTS} = "$_/share/ocropus/scripts"
      if ( -d "$_/share/ocropus/scripts" );
   }
  }
  if ( defined $ENV{OCROSCRIPTS} ) {
   my $script;
   if ( -f "$ENV{OCROSCRIPTS}/recognize.lua" ) {
    $script = 'recognize';
   }
   elsif ( -f "$ENV{OCROSCRIPTS}/rec-tess.lua" ) {
    $script = 'rec-tess';
   }
   if ( defined $script ) {
    $exe       = "ocroscript $script";
    $installed = 1;
    $main::logger->info("Using ocroscript with $script.");
   }
   else {
    $main::logger->warn(
     "Found ocroscript, but no recognition scripts. Disabling.");
   }
  }
  else {
   $main::logger->warn("Found ocroscript, but not its scripts. Disabling.");
  }
 }
 $setup = 1;
 return $installed;
}

sub hocr {
 my ( $class, $file, $language, $pidfile, $png, $cmd ) = @_;
 setup() unless $setup;

 if ( $file !~ /\.(png|jpg|pnm)$/ ) {

  # Temporary filename for new file
  $png = File::Temp->new( SUFFIX => '.png' );
  my $image = Image::Magick->new;
  $image->Read($file);
  $image->Write( filename => $png );
 }
 else {
  $png = $file;
 }
 if ($language) {
  $cmd = "tesslanguage=$language $exe $png";
 }
 else {
  $cmd = "$exe $png";
 }
 $main::logger->info($cmd);

 # decode html->utf8
 my $output;
 if ( defined $pidfile ) {
  $output = `echo $$ > $pidfile;$cmd`;
 }
 else {
  $output = `$cmd`;
 }
 my $decoded = decode_entities($output);

 # Unfortunately, there seems to be a case (tested in t/31_ocropus_utf8.t)
 # where decode_entities doesn't work cleanly, so encode/decode to finally
 # get good UTF-8
 return decode_utf8( encode_utf8($decoded) );
}

1;

__END__
