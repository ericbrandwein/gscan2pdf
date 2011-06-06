package Gscan2pdf;

use strict;
use warnings;

use threads;
use threads::shared;
use Thread::Queue;

use Glib qw(TRUE FALSE);
use Gtk2;
use File::Temp qw(tempfile tempdir);    # To create temporary files

my $_POLL_INTERVAL;
our $_self;
my ( $d, $logger );

sub setup {
 ( my $class, $d, $logger ) = @_;
 $_POLL_INTERVAL = 100;                 # ms
 $_self          = {};

 $_self->{requests}   = Thread::Queue->new;
 $_self->{data_queue} = Thread::Queue->new;
 share $_self->{status};
 share $_self->{message};
 share $_self->{progress};
 share $_self->{file_info};
 share $_self->{dir};

 $_self->{thread} = threads->new( \&_thread_main, $_self );
}

sub _enqueue_request {
 my ( $action, $data ) = @_;
 my $sentinel : shared = 0;
 $_self->{requests}->enqueue(
  {
   action   => $action,
   sentinel => \$sentinel,
   ( $data ? %{$data} : () )
  }
 );
 return \$sentinel;
}

sub _when_ready {
 my ( $sentinel, $ready_callback, $not_ready_callback ) = @_;
 Glib::Timeout->add(
  $_POLL_INTERVAL,
  sub {
   if ($$sentinel) {
    $ready_callback->();
    return Glib::SOURCE_REMOVE;
   }
   else {
    if ( defined $not_ready_callback ) {
     $not_ready_callback->();
    }
    return Glib::SOURCE_CONTINUE;
   }
  }
 );
}

sub kill {
 _enqueue_request('quit');
 $_self->{thread}->join();
 $_self->{thread} = undef;
 return;
}

sub _thread_main {
 my ($self) = @_;

 while ( my $request = $self->{requests}->dequeue ) {
  if ( $request->{action} eq 'quit' ) {
   last;
  }

  elsif ( $request->{action} eq 'get-file-info' ) {
   _thread_get_file_info( $self, $request->{path} );
  }

  elsif ( $request->{action} eq 'import-file' ) {
   _thread_import_file( $self, $request->{first}, $request->{last} );
  }

  elsif ( $request->{action} eq 'save-djvu' ) {
   _thread_save_djvu( $self, $request->{path}, $request->{list_of_pages} );
  }

  elsif ( $request->{action} eq 'save-image' ) {
   _thread_save_image( $self, $request->{path}, $request->{list_of_pages} );
  }

  elsif ( $request->{action} eq 'save-pdf' ) {
   _thread_save_pdf( $self, $request->{path}, $request->{list_of_pages},
    $request->{metadata}, $request->{options} );
  }

  elsif ( $request->{action} eq 'save-tiff' ) {
   _thread_save_tiff( $self, $request->{path}, $request->{list_of_pages},
    $request->{options}, $request->{ps} );
  }

  elsif ( $request->{action} eq 'rotate' ) {
   _thread_rotate( $self, $request->{angle}, $request->{page} );
  }

  elsif ( $request->{action} eq 'cancel' ) {
   _thread_cancel($self);
  }

  else {
   $logger->info( "Ignoring unknown request " . $request->{action} );
   next;
  }

  # Signal the sentinel that the request was completed.
  ${ $request->{sentinel} }++;
 }
}

sub _thread_get_file_info {
 my ( $self, $filename, %info ) = @_;

 $logger->info("Getting info for $filename");

 # Check if djvu
 my ( $fh, $buffer );
 unless ( open $fh, '<', $filename ) {
  $self->{status} = 1;
  $self->{message} = sprintf( $d->get("Can't open %s: %s"), $filename, $! );
  return;
 }
 binmode $fh;
 read( $fh, $buffer, 8 );
 close $fh;
 if ( $buffer eq 'AT&TFORM' ) {

  # Dig out the number of pages
  my $cmd = "djvudump \"$filename\"";
  $logger->info($cmd);
  my $info = `$cmd`;
  $logger->info($info);

  my $pages = 1;
  $pages = $1 if ( $info =~ /\s(\d+)\s+page/ );

  # Dig out and the resolution of each page
  my (@ppi);
  $info{format} = 'DJVU';
  while ( $info =~ /\s(\d+)\s+dpi/ ) {
   push @ppi, $1;
   $logger->info("Page $#ppi is $ppi[$#ppi] ppi");
   $info = substr( $info, index( $info, " dpi" ) + 4, length($info) );
  }
  if ( $pages != @ppi ) {
   $self->{status} = 1;
   $self->{message} =
     $d->get('Unknown DjVu file structure. Please contact the author.');
   return;
  }
  $info{ppi}         = \@ppi;
  $info{pages}       = $pages;
  $info{path}        = $filename;
  $self->{file_info} = shared_clone \%info;
  return;
 }

 # Get file type
 my $image = Image::Magick->new;
 my $x     = $image->Read($filename);
 $logger->warn($x) if "$x";

 my $format = $image->Get('format');
 $logger->info("Format $format") if ( defined $format );
 undef $image;

 if ( not defined($format) ) {
  $self->{status} = 1;
  $self->{message} =
    sprintf( $d->get("%s is not a recognised image type"), $filename );
  return;
 }
 elsif ( $format eq 'Portable Document Format' ) {
  my $info = `pdfinfo \"$filename\"`;
  $logger->info($info);
  my $pages = 1;
  $pages = $1 if ( $info =~ /Pages:\s+(\d+)/ );
  $logger->info("$pages pages");
  $info{pages} = $pages;
 }
 elsif ( $format eq 'Tagged Image File Format' ) {
  my $cmd = "tiffinfo \"$filename\"";
  $logger->info($cmd);
  my $info = `$cmd`;
  $logger->info($info);

  # Count number of pages and their resolutions
  my @ppi;
  while ( $info =~ /Resolution: (\d*)/ ) {
   push @ppi, $1;
   $info = substr( $info, index( $info, 'Resolution' ) + 10, length($info) );
  }
  my $pages = @ppi;
  $logger->info("$pages pages");
  $info{pages} = $pages;
  $self->{file_info} = shared_clone \%info;
 }
 else {
  $info{pages} = 1;
 }
 $info{format}      = $format;
 $info{path}        = $filename;
 $self->{file_info} = shared_clone \%info;
 return;
}

sub _thread_import_file {
 my ( $self, $first, $last ) = @_;

 my $info = $self->{file_info};
 if ( $info->{format} eq 'DJVU' ) {

  # Extract images from DjVu
  if ( $last >= $first and $first > 0 ) {
   for ( my $i = $first ; $i <= $last ; $i++ ) {
    my ( undef, $tif ) = tempfile( DIR => $self->{dir}, SUFFIX => '.tif' );
    my $cmd = "ddjvu -format=tiff -page=$i \"$info->{path}\" $tif";
    $logger->info($cmd);
    system($cmd);
    my $page = Gscan2pdf::Page->new(
     filename   => $tif,
     dir        => $self->{dir},
     delete     => TRUE,
     format     => 'Tagged Image File Format',
     resolution => $info->{ppi}[ $i - 1 ]
    );
    $self->{data_queue}->enqueue($page);
   }
  }
 }
 elsif ( $info->{format} eq 'Portable Document Format' ) {

  # Extract images from PDF
  if ( $last >= $first and $first > 0 ) {
   my $cmd = "pdfimages -f $first -l $last \"$info->{path}\" x";
   $logger->info($cmd);
   system($cmd);
   unless ( system($cmd) == 0 ) {
    $self->{status}  = 1;
    $self->{message} = $d->get('Error extracting images from PDF');
   }

   # Import each image
   my @images = glob('x-???.???');
   my $i      = 0;
   foreach (@images) {
    my $page = Gscan2pdf::Page->new(
     filename => $_,
     dir      => $self->{dir},
     delete   => TRUE,
     format   => 'Portable anymap'
    );
    $self->{data_queue}->enqueue($page);
   }
  }
 }
 elsif ( $info->{format} eq 'Tagged Image File Format' ) {

  # Split the tiff into its pages and import them individually
  if ( $last >= $first and $first > 0 ) {
   for ( my $i = $first - 1 ; $i < $last ; $i++ ) {
    my ( undef, $tif ) = tempfile( DIR => $self->{dir}, SUFFIX => '.tif' );
    my $cmd = "tiffcp \"$info->{path}\",$i $tif";
    $logger->info($cmd);
    system($cmd);
    my $page = Gscan2pdf::Page->new(
     filename => $_,
     dir      => $self->{dir},
     delete   => TRUE,
     format   => 'Portable anymap'
    );
    $self->{data_queue}->enqueue($page);
   }
  }
 }
 elsif ( $info->{format} =~
/(Portable anymap|Portable Network Graphics|Joint Photographic Experts Group JFIF format|CompuServe graphics interchange format)/
   )
 {
  my $page = Gscan2pdf::Page->new(
   filename => $info->{path},
   dir      => $self->{dir},
   format   => $info->{format}
  );
  $self->{data_queue}->enqueue($page);
 }
 else {
  my $tiff = convert_to_tiff( $info->{path} );
  my $page = Gscan2pdf::Page->new(
   filename => $tiff,
   dir      => $self->{dir},
   format   => 'Tagged Image File Format'
  );
  $self->{data_queue}->enqueue($page);
 }
 return;
}

sub convert_to_tiff {
 my ($filename) = @_;
 my $image      = Image::Magick->new;
 my $x          = $image->Read($filename);
 $logger->warn($x) if "$x";
 my $density = get_resolution($image);

 # Write the tif
 my ( undef, $tif ) = tempfile( DIR => $_self->{dir}, SUFFIX => '.tif' );
 $image->Write(
  units       => 'PixelsPerInch',
  compression => 'lzw',
  density     => $density,
  filename    => $tif
 );
 return $tif;
}

sub _thread_save_pdf {
 my ( $self, $path, $list_of_pages, $metadata, $options ) = @_;

 my $page = 0;

 # Create PDF with PDF::API2
 $self->{message} = $d->get('Setting up PDF');
 my $pdf = PDF::API2->new( -file => $path );
 $pdf->info($metadata) if defined($metadata);

 foreach my $pagedata ( @{$list_of_pages} ) {
  ++$page;
  $self->{progress} = $page / ( $#{$list_of_pages} + 2 );
  $self->{message} =
    sprintf( $d->get("Saving page %i of %i"), $page, $#{$list_of_pages} + 1 );

  my $filename = $pagedata->{filename};
  my $image    = Image::Magick->new;
  my $x        = $image->Read($filename);
  $logger->warn($x) if "$x";

  # Get the size and resolution. Resolution is dots per inch, width
  # and height are in inches.
  my $resolution = $pagedata->{resolution};
  my $w          = $image->Get('width') / $resolution;
  my $h          = $image->Get('height') / $resolution;

  # The output resolution is normally the same as the input
  # resolution.
  my $output_resolution = $resolution;

  # Automatic mode
  my $depth;
  my $compression;
  my $type;
  if ( not defined( $options->{compression} )
   or $options->{compression} eq 'auto' )
  {
   $depth = $image->Get('depth');
   $logger->info("Depth of $filename is $depth");
   if ( $depth == 1 ) {
    $compression = 'lzw';
   }
   else {
    $type = $image->Get('type');
    $logger->info("Type of $filename is $type");
    if ( $type =~ /TrueColor/ ) {
     $compression = 'jpg';
    }
    else {
     $compression = 'png';
    }
   }
   $logger->info("Selecting $compression compression");
  }
  else {
   $compression = $options->{compression};
  }

  # Convert file if necessary
  my $format;
  $format = $1 if ( $filename =~ /\.(\w*)$/ );
  if (( $compression ne 'none' and $compression ne $format )
   or $options->{downsample}
   or $compression eq 'jpg' )
  {
   if ( $compression !~ /(jpg|png)/ and $format ne 'tif' ) {
    my $ofn = $filename;
    ( undef, $filename ) = tempfile( DIR => $self->{dir}, SUFFIX => '.tif' );
    $logger->info("Converting $ofn to $filename");
   }
   elsif ( $compression =~ /(jpg|png)/ ) {
    my $ofn = $filename;
    ( undef, $filename ) = tempfile(
     DIR    => $self->{dir},
     SUFFIX => ".$compression"
    );
    $logger->info("Converting $ofn to $filename");
   }

   $depth = $image->Get('depth') if ( not defined($depth) );
   if ( $options->{downsample} ) {
    $output_resolution = $options->{'downsample dpi'};
    my $w_pixels = $w * $output_resolution;
    my $h_pixels = $h * $output_resolution;

    $logger->info("Resizing $filename to $w_pixels x $h_pixels");
    $x = $image->Resize( width => $w_pixels,, height => $h_pixels );
    $logger->warn($x) if "$x";
   }
   $x = $image->Set( quality => $options->{quality} )
     if ( defined( $options->{quality} ) and $compression eq 'jpg' );
   $logger->warn($x) if "$x";

   if (( $compression !~ /(jpg|png)/ and $format ne 'tif' )
    or ( $compression =~ /(jpg|png)/ )
    or $options->{downsample} )
   {

# depth required because resize otherwise increases depth to maintain information
    $logger->info("Writing temporary image $filename with depth $depth");
    $x = $image->Write( filename => $filename, depth => $depth );
    $logger->warn($x) if "$x";
    $format = $1 if ( $filename =~ /\.(\w*)$/ );
   }

   if ( $compression !~ /(jpg|png)/ ) {
    my ( undef, $filename2 ) =
      tempfile( DIR => $self->{dir}, SUFFIX => '.tif' );
    my $cmd = "tiffcp -c $compression $filename $filename2";
    $logger->info($cmd);
    my $status = system("$cmd 2>$self->{dir}/tiffcp.stdout");
    if ( $status != 0 ) {
     my $output = slurp("$self->{dir}/tiffcp.stdout");
     $logger->info($output);
     $self->{status} = 1;
     $self->{message} =
       sprintf( $d->get("Error compressing image: %s"), $output );
     return;
    }
    $filename = $filename2;
   }
  }

  $logger->info(
   "Defining page at ",
   $w * $Gscan2pdf::Document::POINTS_PER_INCH,
   "pt x ", $h * $Gscan2pdf::Document::POINTS_PER_INCH, "pt"
  );
  my $page = $pdf->page;
  $page->mediabox(
   $w * $Gscan2pdf::Document::POINTS_PER_INCH,
   $h * $Gscan2pdf::Document::POINTS_PER_INCH
  );

  # Add OCR as text behind the scan
  if ( defined( $pagedata->{buffer} ) ) {
   $logger->info("Embedding OCR output behind image");
   my $font   = $pdf->corefont('Times-Roman');
   my $text   = $page->text;
   my $canvas = $pagedata->{buffer};
   my $root   = $canvas->get_root_item;
   my $n      = $root->get_n_children;
   for ( my $i = 0 ; $i < $n ; $i++ ) {
    my $group = $root->get_child($i);
    if ( $group->isa('Goo::Canvas::Group') ) {
     my $bounds = $group->get_bounds;
     my ( $x1, $y1, $x2, $y2 ) =
       ( $bounds->x1 + 1, $bounds->y1 + 1, $bounds->x2 - 1, $bounds->y2 - 1 );
     my $n = $group->get_n_children;
     for ( my $i = 0 ; $i < $n ; $i++ ) {
      my $item = $group->get_child($i);
      if ( $item->isa('Goo::Canvas::Text') ) {
       if ( abs( $h * $resolution - $y2 + $y1 ) > 5
        and abs( $w * $resolution - $x2 + $x1 ) > 5 )
       {

        # Box is smaller than the page. We know the text position.
        # Set the text position.
        # Translate x1 and y1 to inches and then to points. Invert the
        # y coordinate (since the PDF coordinates are bottom to top
        # instead of top to bottom) and subtract $size, since the text
        # will end up above the given point instead of below.
        my $size =
          ( $y2 - $y1 ) / $resolution * $Gscan2pdf::Document::POINTS_PER_INCH;
        $text->font( $font, $size );
        $text->translate(
         $x1 / $resolution * $Gscan2pdf::Document::POINTS_PER_INCH,
         ( $h - ( $y1 / $resolution ) ) *
           $Gscan2pdf::Document::POINTS_PER_INCH - $size
        );
        $text->text( $item->get('text') );
       }
       else {

        # Box is the same size as the page. We don't know the text position.
        # Start at the top of the page (PDF coordinate system starts
        # at the bottom left of the page)
        my $size = 1;
        $text->font( $font, $size );
        my $y = $h * $Gscan2pdf::Document::POINTS_PER_INCH;
        foreach my $line ( split( "\n", $item->get('text') ) ) {
         my $x = 0;

         # Add a word at a time in order to linewrap
         foreach my $word ( split( ' ', $line ) ) {
          if (
           length($word) * $size + $x >
           $w * $Gscan2pdf::Document::POINTS_PER_INCH )
          {
           $x = 0;
           $y -= $size;
          }
          $text->translate( $x, $y );
          $word = ' ' . $word if ( $x > 0 );
          $x += $text->text($word);
         }
         $y -= $size;
        }
       }
      }
     }
    }
   }
  }

  # Add scan
  my $gfx = $page->gfx;
  my $imgobj;
  my $msg;
  if ( $format eq 'png' ) {
   eval { $imgobj = $pdf->image_png($filename) };
   $msg = "$@";
  }
  elsif ( $format eq 'jpg' ) {
   eval { $imgobj = $pdf->image_jpeg($filename) };
   $msg = "$@";
  }
  elsif ( $format eq 'pnm' ) {
   eval { $imgobj = $pdf->image_pnm($filename) };
   $msg = "$@";
  }
  elsif ( $format eq 'gif' ) {
   eval { $imgobj = $pdf->image_gif($filename) };
   $msg = "$@";
  }
  elsif ( $format eq 'tif' ) {
   eval { $imgobj = $pdf->image_tiff($filename) };
   $msg = "$@";
  }
  else {
   $msg = "Unknown format $format file $filename";
  }
  if ($msg) {
   $logger->warn($msg);
   $self->{status} = 1;
   $self->{message} =
     sprintf( $d->get("Error creating PDF image object: %s"), $msg );
   return;
  }
  else {
   eval {
    $gfx->image(
     $imgobj, 0, 0,
     $w * $Gscan2pdf::Document::POINTS_PER_INCH,
     $h * $Gscan2pdf::Document::POINTS_PER_INCH
    );
   };
   if ($@) {
    $logger->warn($@);
    $self->{status} = 1;
    $self->{message} =
      sprintf( $d->get("Error embedding file image in %s format to PDF: %s"),
     $format, $@ );
   }
   else {
    $logger->info("Adding $filename at $output_resolution PPI");
   }
  }
 }
 $self->{message} = $d->get('Closing PDF');
 $pdf->save;
 $pdf->end;
 return;
}

sub _thread_save_djvu {
 my ( $self, $path, $list_of_pages ) = @_;

 my $page = 0;
 my @filelist;

 foreach my $pagedata ( @{$list_of_pages} ) {
  ++$page;
  $self->{progress} = $page / ( $#{$list_of_pages} + 2 );
  $self->{message} =
    sprintf( $d->get("Writing page %i of %i"), $page, $#{$list_of_pages} + 1 );

  my $filename = $pagedata->{filename};
  my ( undef, $djvu ) = tempfile( DIR => $self->{dir}, SUFFIX => '.djvu' );

  # Check the image depth to decide what sort of compression to use
  my $image = Image::Magick->new;
  my $x     = $image->Read($filename);
  $logger->warn($x) if "$x";
  my $depth = $image->Get('depth');
  my $class = $image->Get('class');
  my $compression;

  # c44 can only use pnm and jpg
  my $format;
  $format = $1 if ( $filename =~ /\.(\w*)$/ );
  if ( $depth > 1 ) {
   $compression = 'c44';
   if ( $format !~ /(pnm|jpg)/ ) {
    my ( undef, $pnm ) = tempfile( DIR => $self->{dir}, SUFFIX => '.pnm' );
    $x = $image->Write( filename => $pnm );
    $logger->warn($x) if "$x";
    $filename = $pnm;
   }
  }

  # cjb2 can only use pnm and tif
  else {
   $compression = 'cjb2';
   if ( $format !~ /(pnm|tif)/
    or ( $format eq 'pnm' and $class ne 'PseudoClass' ) )
   {
    my ( undef, $pbm ) = tempfile( DIR => $self->{dir}, SUFFIX => '.pbm' );
    $x = $image->Write( filename => $pbm );
    $logger->warn($x) if "$x";
    $filename = $pbm;
   }
  }

  # Create the djvu
  my $resolution = $pagedata->{resolution};
  my $cmd        = "$compression -dpi $resolution $filename $djvu";
  $logger->info($cmd);
  my ( $status, $size ) = ( system($cmd), -s $djvu );
  unless ( $status == 0 and $size ) {
   $self->{status}  = 1;
   $self->{message} = $d->get('Error writing DjVu');
   $logger->error(
"Error writing image for page $page of DjVu (process returned $status, image size $size)"
   );
  }
  push @filelist, $djvu;

  # Add OCR to text layer
  if ( defined( $pagedata->{buffer} ) ) {

   # Get the size
   my $w = $image->Get('width');
   my $h = $image->Get('height');

   # Open djvusedtxtfile
   my ( undef, $djvusedtxtfile ) =
     tempfile( DIR => $self->{dir}, SUFFIX => '.txt' );
   open my $fh, ">:utf8", $djvusedtxtfile
     or die sprintf( $d->get("Can't open file: %s"), $djvusedtxtfile );
   print $fh "(page 0 0 $w $h\n";

   # Write the text boxes
   my $canvas = $pagedata->{buffer};
   my $root   = $canvas->get_root_item;
   my $n      = $root->get_n_children;
   for ( my $i = 0 ; $i < $n ; $i++ ) {
    my $group = $root->get_child($i);
    if ( $group->isa('Goo::Canvas::Group') ) {
     my $n      = $group->get_n_children;
     my $bounds = $group->get_bounds;
     my ( $x1, $y1, $x2, $y2 ) =
       ( $bounds->x1 + 1, $bounds->y1 + 1, $bounds->x2 - 1, $bounds->y2 - 1 );
     for ( my $i = 0 ; $i < $n ; $i++ ) {
      my $item = $group->get_child($i);
      if ( $item->isa('Goo::Canvas::Text') ) {

       # Escape any inverted commas
       my $txt = $item->get('text');
       $txt =~ s/\\/\\\\/g;
       $txt =~ s/"/\\\"/g;
       printf $fh "\n(line %d %d %d %d \"%s\")", $x1, $h - $y2, $x2,
         $h - $y1, $txt;
      }
     }
    }
   }
   print $fh ")";
   close $fh;

   # Write djvusedtxtfile
   my $cmd = "djvused '$djvu' -e 'select 1; set-txt $djvusedtxtfile' -s";
   $logger->info($cmd);
   unless ( system($cmd) == 0 ) {
    $self->{status}  = 1;
    $self->{message} = $d->get('Error adding text layer to DjVu');
    $logger->error("Error adding text layer to DjVu page $page");
   }
  }
 }
 $self->{progress} = 1;
 $self->{message}  = $d->get('Closing DjVu');
 my $cmd = "djvm -c '$path' @filelist";
 $logger->info($cmd);
 unless ( system($cmd) == 0 ) {
  $self->{status}  = 1;
  $self->{message} = $d->get('Error closing DjVu');
  $logger->error("Error closing DjVu");
 }
}

sub _thread_save_tiff {
 my ( $self, $path, $list_of_pages, $options, $ps ) = @_;

 my $page = 0;
 my @filelist;

 foreach my $pagedata ( @{$list_of_pages} ) {
  ++$page;
  $self->{progress} = ( $page - 1 ) / ( $#{$list_of_pages} + 2 );
  $self->{message} = sprintf( $d->get("Converting image %i of %i to TIFF"),
   $page, $#{$list_of_pages} + 1 );

  my $filename = $pagedata->{filename};
  if ( $filename !~ /\.tif/ or $options->{compression} eq 'jpeg' ) {
   my ( undef, $tif ) = tempfile( DIR => $self->{dir}, SUFFIX => '.tif' );
   my $resolution = $pagedata->{resolution};

   # Convert to tiff
   my $depth = '';
   $depth = '-depth 8'
     if ( defined( $options->{compression} )
    and $options->{compression} eq 'jpeg' );
   unless (
    system(
     "convert -units PixelsPerInch -density $resolution $depth $filename $tif")
    == 0
     )
   {
    $self->{status}  = 1;
    $self->{message} = $d->get('Error writing TIFF');
    return;
   }
   $filename = $tif;
  }
  push @filelist, $filename;
 }

 my $compression = "";
 if ( defined $options->{compression} ) {
  $compression = "-c $options->{compression}";
  $compression .= ":$options->{quality}" if ( $compression eq 'jpeg' );
 }

 # Create the tiff
 $self->{progress} = 1;
 $self->{message}  = $d->get('Concatenating TIFFs');
 my $rows = '';
 $rows = '-r 16'
   if ( defined( $options->{compression} )
  and $options->{compression} eq 'jpeg' );
 my $cmd = "tiffcp $rows $compression @filelist '$path'";
 $logger->info($cmd);
 my ( undef, $out ) = tempfile( DIR => $self->{dir}, SUFFIX => '.stdout' );
 my $status = system("$cmd 2>$out");

 if ( $status != 0 ) {
  my $output = slurp($out);
  $logger->info($output);
  $self->{status} = 1;
  $self->{message} = sprintf( $d->get("Error compressing image: %s"), $output );
  return;
 }
 unlink $out;
 if ( defined $ps ) {
  $self->{message} = $d->get('Converting to PS');

  # Note: -a option causes tiff2ps to generate multiple output
  # pages, one for each page in the input TIFF file.  Without it, it
  # only generates output for the first page.
  my $cmd = "tiff2ps -a $path > '$ps'";
  $logger->info($cmd);
  my $output = `$cmd`;
 }
}

# Have to roll my own slurp sub to support utf8

sub slurp {
 my ($file) = @_;

 local ($/);
 open my $fh, "<:utf8", $file or die "Error: cannot open $file\n";
 my $text = <$fh>;
 close $fh;
 return $text;
}

sub _thread_rotate {
 my ( $self, $angle, $page ) = @_;
 my $filename = $page->{filename};

 # Rotate with imagemagick
 my $image = Image::Magick->new;
 my $x     = $image->Read($filename);
 $logger->warn($x) if "$x";

 # workaround for those versions of imagemagick that produce 16bit output
 # with rotate
 my $depth = $image->Get('depth');
 $x = $image->Rotate($angle);
 $logger->warn($x) if "$x";
 my $suffix;
 $suffix = $1 if ( $filename =~ /\.(\w*)$/ );
 ( undef, $filename ) =
   tempfile( DIR => $self->{dir}, SUFFIX => '.' . $suffix );
 $x = $image->Write( filename => $filename, depth => $depth );
 $logger->warn($x) if "$x";
 my $new = $page->clone;
 $new->{filename}   = $filename;
 $new->{dirty_time} = timestamp();    #flag as dirty
 my %data = ( old => $page, new => $new );
 $self->{data_queue}->enqueue( \%data );
 return;
}

# Compute a timestamp

sub timestamp {
 my @time = localtime();

 # return a time which can be string-wise compared
 return sprintf( "%04d%02d%02d%02d%02d%02d",
  $time[5], $time[4], $time[3], $time[2], $time[1], $time[0] );
}

sub _thread_save_image {
 my ( $self, $path, $list_of_pages ) = @_;

 if ( @{$list_of_pages} == 1 ) {
  my $cmd =
"convert $list_of_pages->[0]{filename} -density $list_of_pages->[0]{resolution} '$path'";
  $logger->info($cmd);
  if ( system($cmd) ) {
   $self->{status}  = 1;
   $self->{message} = $d->get('Error saving image');
  }
 }
 else {
  my $current_filename;
  my $i = 1;
  foreach ( @{$list_of_pages} ) {
   $current_filename = sprintf $path, $i++;
   my $cmd = sprintf "convert %s -density %d \"%s\"",
     $_->{filename}, $_->{resolution},
     $current_filename;
   if ( system($cmd) ) {
    $self->{status}  = 1;
    $self->{message} = $d->get('Error saving image');
   }
  }
 }
 return;
}

1;

__END__
