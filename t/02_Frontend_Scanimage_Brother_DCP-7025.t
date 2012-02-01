# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl Gscan2pdf.t'

#########################

# change 'tests => 1' to 'tests => last_test_to_print';

use warnings;
use strict;
use Test::More tests => 2;
BEGIN { use_ok('Gscan2pdf::Frontend::Scanimage') }

#########################

# Insert your test code below, the Test::More module is use()ed here so read
# its man page ( perldoc Test::More ) for help writing this test script.

my $filename = 'scanners/Brother_DCP-7025';
my $output   = do { local ( @ARGV, $/ ) = $filename; <> };
my %this     = Gscan2pdf::Frontend::Scanimage::options2hash($output);
my %that     = (
 'source' => {
  'tip'     => 'Selects the scan source (such as a document-feeder).',
  'default' => 'Automatic Document Feeder',
  'values'  => [ 'FlatBed', 'Automatic Document Feeder' ],
 },
 'brightness' => {
  'tip'     => 'Controls the brightness of the acquired image.',
  'default' => 0,
  'min'     => -50,
  'max'     => 50,
  'step'    => 1,
  'unit'    => '%',
 },
 'mode' => {
  'tip'     => 'Select the scan mode',
  'default' => 'Black & White',
  'values'  => [
   'Black & White',
   'Gray[Error Diffusion]',
   'True Gray',
   '24bit Color',
   '24bit Color[Fast]'
  ]
 },
 'resolution' => {
  'tip'     => 'Sets the resolution of the scanned image.',
  'default' => 200,
  'values'  => [ 100, 150, 200, 300, 400, 600, 1200, 2400, 4800, '9600' ],
  'unit'    => 'dpi',
 },
 'contrast' => {
  'tip'     => 'Controls the contrast of the acquired image.',
  'default' => 'inactive',
  'min'     => -50,
  'max'     => 50,
  'step'    => 1,
  'unit'    => '%',
 },
 'l' => {
  'tip'     => 'Top-left x position of scan area.',
  'default' => 0,
  'min'     => 0,
  'max'     => 210,
  'step'    => 0.0999908,
  'unit'    => 'mm',
 },
 't' => {
  'tip'     => 'Top-left y position of scan area.',
  'default' => 0,
  'min'     => 0,
  'max'     => 297,
  'step'    => 0.0999908,
  'unit'    => 'mm',
 },
 'x' => {
  'tip'     => 'Width of scan-area.',
  'default' => 209.981,
  'min'     => 0,
  'max'     => 210,
  'step'    => 0.0999908,
  'unit'    => 'mm',
 },
 'y' => {
  'tip'     => 'Height of scan-area.',
  'default' => 296.973,
  'min'     => 0,
  'max'     => 297,
  'step'    => 0.0999908,
  'unit'    => 'mm',
 }
);
is_deeply( \%this, \%that, 'Brother_DCP-7025' );