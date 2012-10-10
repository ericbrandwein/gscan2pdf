package Gscan2pdf::Frontend::CLI;

use strict;
use warnings;
use feature "switch";

use Locale::gettext 1.05;    # For translations
use Carp;
use Text::ParseWords;
use Glib qw(TRUE FALSE);
use POSIX qw(locale_h :signal_h :errno_h :sys_wait_h);
use Proc::Killfam;
use IPC::Open3;
use IO::Handle;

my $_POLL_INTERVAL = 100;    # ms
my ( $_self, $logger, $d );

sub setup {
 ( my $class, $logger ) = @_;
 $_self = {};
 $d     = Locale::gettext->domain(Glib::get_application_name);
 return;
}

sub get_devices {
 my ( $class, %options ) = @_;
 my $running = TRUE;

 _watch_stdout(
"$options{prefix} scanimage --formatted-device-list=\"'%i','%d','%v','%m','%t'%n\" 2>/dev/null",
  $options{running_callback},
  sub {
   my ($output) = @_;
   $options{finished_callback}
     ->( Gscan2pdf::Frontend::CLI->parse_device_list($output) )
     if ( defined $options{finished_callback} );
  }
 );
 return;
}

sub parse_device_list {
 my ( $class, $output ) = @_;

 my (@device_list);

 $logger->info($output) if ( defined($output) );

 # parse out the device and model names
 my @words =
   &parse_line( ',', 0, substr( $output, 0, index( $output, "'\n" ) + 1 ) );
 while ( @words == 5 ) {
  $output = substr( $output, index( $output, "'\n" ) + 2, length($output) );
  push @device_list,
    {
   name   => $words[1],
   vendor => $words[2],
   model  => $words[3],
   type   => $words[4]
    };
  @words =
    &parse_line( ',', 0, substr( $output, 0, index( $output, "'\n" ) + 1 ) );
 }

 return \@device_list;
}

sub find_scan_options {
 my ( $class, %options ) = @_;

 # Get output from scanimage or scanadf.
 # Inverted commas needed for strange characters in device name
 my $cmd =
"$options{prefix} $options{frontend} --help --device-name='$options{device}'";
 $cmd .= " --mode='$options{mode}'" if ( defined $options{mode} );
 _watch_stdout(
  $cmd,
  $options{running_callback},
  sub {
   my ($output) = @_;
   $options{finished_callback}->($output)
     if ( defined $options{finished_callback} );
  }
 );
 return;
}

# Select wrapper method for _scanadf() and _scanimage()

sub scan_pages {
 my ( $class, %options ) = @_;

 if (
  defined( $options{frontend} )
  and ( $options{frontend} eq 'scanadf'
   or $options{frontend} eq 'scanadf-perl' )
   )
 {
  _scanadf(%options);
 }
 else {
  _scanimage(%options);
 }
 return;
}

# Return file size expected by PNM header
sub get_size_from_PNM {
 my $filename = shift;

 open my $fh, '<', $filename or return 0;
 my $header = <$fh>;
 my $magic_value;
 if ( $header =~ /^P(\d*)\n/x ) {
  $magic_value = $1;
 }
 else {
  close $fh;
  return 0;
 }
 if ( $magic_value < 4 ) {
  close $fh;
  return 0;
 }
 my $line = <$fh>;
 $header .= $line;
 while ( $line =~ /^(\#|\s*\n)/x ) {
  $line = <$fh>;
  $header .= $line;
 }
 if ( $line =~ /(\d*)\ (\d*)\n/x ) {
  my ( $width, $height ) = ( $1, $2 );
  if ( $magic_value == 4 ) {
   my $mod = $width % 8;
   $width += 8 - $mod if ( $mod > 0 );
  }
  my $datasize = $width * $height *
    ( $magic_value == 4 ? 1 / 8 : ( $magic_value == 5 ? 1 : 3 ) );
  if ( $magic_value > 4 ) {
   $line = <$fh>;
   $header .= $line;
  }
  close $fh;
  return length($header) + $datasize;
 }
 else {
  close $fh;
  return 0;
 }
}

# Carry out the scan with scanimage and the options passed.

sub _scanimage {
 my (%options) = @_;

 $options{frontend} = 'scanimage' unless ( defined $options{frontend} );
 $options{prefix}   = ''          unless ( defined $options{prefix} );

 # inverted commas needed for strange characters in device name
 my $device = "--device-name='$options{device}'";

 # Add basic options
 my @options;
 @options = @{ $options{options} } if ( defined $options{options} );
 push @options, '--batch';
 push @options, '--progress';
 push @options, "--batch-count=$options{npages}" if ( $options{npages} != 0 );

 # Create command
 my $cmd = "$options{prefix} $options{frontend} $device @options";

 # flag to ignore error messages after cancelling scan
 $_self->{abort_scan} = FALSE;

# flag to ignore out of documents message if successfully scanned at least one page
 my $num_scans = 0;

 _watch_stderr(
  $cmd,
  $options{started_callback},
  sub {
   my ($line) = @_;
   given ($line) {
    when (/^Progress:\ (\d*\.\d*)%/x) {
     $options{running_callback}->( $1 / 100 )
       if ( defined $options{running_callback} );
    }
    when (/^Scanning\ (-?\d*)\ pages/x) {
     $options{running_callback}
       ->( undef, sprintf( $d->get('Scanning %i pages...'), $1 ) )
       if ( defined $options{running_callback} );
    }
    when (/^Scanning\ page\ (\d*)/x) {
     $options{running_callback}
       ->( 0, sprintf( $d->get('Scanning page %i...'), $1 ) )
       if ( defined $options{running_callback} );
    }
    when (/^Scanned\ page\ (\d*)\.\ \(scanner\ status\ =\ 5\)/x) {
     my $id = $1;

     # Timer will run until callback returns false
     my $timer = Glib::Timeout->add(
      $_POLL_INTERVAL,
      sub {
       return Glib::SOURCE_CONTINUE unless ( -e "out$id.pnm" );
       $options{new_page_callback}->("out$id.pnm")
         if ( defined $options{new_page_callback} );
       $num_scans++;
       return Glib::SOURCE_REMOVE;
      }
     );
    }
    when (
     /Scanner\ warming\ up\ -\ waiting\ \d*\ seconds|wait\ for\ lamp\ warm-up/x ## no critic (ProhibitComplexRegexes)
      )
    {
     $options{running_callback}->( 0, $d->get('Scanner warming up') )
       if ( defined $options{running_callback} );
    }
    when (/^Scanned\ page\ \d*\.\ \(scanner\ status\ =\ 7\)/x) {
     ;
    }
    when (
     /^$options{frontend}:\ sane_start:\ Document\ feeder\ out\ of\ documents/x
      )
    {
     $options{error_callback}->( $d->get('Document feeder out of documents') )
       if ( defined( $options{error_callback} ) and $num_scans == 0 );
    }
    when (
     $_self->{abort_scan}
       and ( $line =~
         /^$options{frontend}:\ sane_start:\ Error\ during\ device\ I\/O/x
      or $line =~ /^$options{frontend}:\ received\ signal\ 2/x
      or $line =~ /^$options{frontend}:\ trying\ to\ stop\ scanner/x )
      )
    {
     ;
    }
    when (/^$options{frontend}:\ rounded/x) {
     $logger->info( substr( $line, 0, index( $line, "\n" ) + 1 ) );
    }
    when (/^$options{frontend}:\ sane_start:\ Device\ busy/x) {
     $options{error_callback}->( $d->get('Device busy') )
       if ( defined $options{error_callback} );
    }
    when (/^$options{frontend}:\ sane_read:\ Operation\ was\ cancelled/x) {
     $options{error_callback}->( $d->get('Operation cancelled') )
       if ( defined $options{error_callback} );
    }
    default {
     $options{error_callback}->(
      $d->get('Unknown message: ') . substr( $line, 0, index( $line, "\n" ) ) )
       if ( defined $options{error_callback} );
    }
   }
  },
  $options{finished_callback}
 );
 return;
}

# Carry out the scan with scanadf and the options passed.

sub _scanadf {
 my (%options) = @_;

 $options{frontend} = 'scanadf' unless ( defined $options{frontend} );
 $options{prefix}   = ''        unless ( defined $options{prefix} );

 # inverted commas needed for strange characters in device name
 my $device = "--device-name='$options{device}'";

 # Add basic options
 my @options;
 @options = @{ $options{options} } if ( defined $options{options} );
 push @options, "--start-count=1";
 push @options, "--end-count=$options{npages}" if ( $options{npages} != 0 );
 push @options, '-o out%d.pnm';

 # Create command
 my $cmd = "$options{prefix} $options{frontend} $device @options";

 # scanadf doesn't have a progress option, so create a timeout to check
 # the size of the image being currently scanned.
 my $size;
 my $id      = 1;
 my $running = TRUE;
 if ( defined $options{running_callback} ) {
  my $timer = Glib::Timeout->add(
   $_POLL_INTERVAL,
   sub {
    if ($running) {
     if ( defined $size ) {
      if ($size) {
       $options{running_callback}->( ( -s "out$id.pnm" ) / $size );
      }
      else {
       # Pulse
       $options{running_callback}->(-1);
      }
     }
     elsif ( -e "out$id.pnm" and ( -s "out$id.pnm" ) > 50 ) {
      $size = get_size_from_PNM("out$id.pnm");
     }
     else {
      # Pulse
      $options{running_callback}->(-1);
     }
     return Glib::SOURCE_CONTINUE;
    }
    return Glib::SOURCE_REMOVE;
   }
  );
 }

 _watch_stderr(
  $cmd,
  $options{started_callback},
  sub {
   my ($line) = @_;
   given ($line) {
    when (
     /Scanner\ warming\ up\ -\ waiting\ \d*\ seconds|wait\ for\ lamp\ warm-up/x ## no critic (ProhibitComplexRegexes)
      )
    {
     $options{running_callback}->( 0, $d->get('Scanner warming up') )
       if ( defined $options{running_callback} );
    }
    when (/^Scanned\ document\ out(\d*)\.pnm/x) {
     $id = $1;

     # Timer will run until callback returns false
     my $timer = Glib::Timeout->add(
      $_POLL_INTERVAL,
      sub {
       return Glib::SOURCE_CONTINUE unless ( -e "out$id.pnm" );
       $options{new_page_callback}->("out$id.pnm")
         if ( defined $options{new_page_callback} );
       return Glib::SOURCE_REMOVE;
      }
     );

     # Prevent the Glib::Timeout from checking the size of the file when it is
     # about to be renamed
     undef $size;

    }
    when (/^Scanned\ \d*\ pages/x) {
     ;
    }
    when (/^$options{frontend}:\ rounded/x) {
     $logger->info( substr( $line, 0, index( $line, "\n" ) + 1 ) );
    }
    when (/^$options{frontend}:\ sane_start:\ Device\ busy/x) {
     $options{error_callback}->( $d->get('Device busy') )
       if ( defined $options{error_callback} );
     $running = FALSE;
    }
    when (/^$options{frontend}:\ sane_read:\ Operation\ was\ cancelled/x) {
     $options{error_callback}->( $d->get('Operation cancelled') )
       if ( defined $options{error_callback} );
     $running = FALSE;
    }
    default {
     $options{error_callback}->(
      $d->get('Unknown message: ') . substr( $line, 0, index( $line, "\n" ) ) )
       if ( defined $options{error_callback} );
    }
   }
  },
  sub {
   $options{finished_callback}->() if ( defined $options{finished_callback} );
   $running = FALSE;
  }
 );
 return;
}

# Flag the scan routine to abort

sub cancel_scan {
 $_self->{abort_scan} = TRUE;
 return;
}

sub _watch_stdout {
 my ( $cmd, $running_callback, $finished_callback ) = @_;
 my $running = TRUE;

 # Timer will run until callback returns false
 my $timer = Glib::Timeout->add(
  $_POLL_INTERVAL,
  sub {
   if ($running) {
    $running_callback->() if ( defined $running_callback );
    return Glib::SOURCE_CONTINUE;
   }
   return Glib::SOURCE_REMOVE;
  }
 );

 $logger->info($cmd);

 # Interface to frontend
 my $pid = open my $read, '-|', $cmd    ## no critic (RequireBriefOpen)
   or croak "can't open pipe: $!";
 $logger->info("Forked PID $pid");

 # Read without blocking
 my $output = '';
 Glib::IO->add_watch(
  fileno($read),
  [ 'in', 'hup' ],
  sub {
   my ( $fileno, $condition ) = @_;
   my ($line);
   if ( $condition & 'in' ) {    # bit field operation. >= would also work
    sysread $read, $line, 1024;
    $output .= $line;
   }

# Can't have elsif here because of the possibility that both in and hup are set.
# Only allow the hup if sure an empty buffer has been read.
   if ( ( $condition & 'hup' ) and ( not defined($line) or $line eq '' ) )
   {    # bit field operation. >= would also work
    close $read;
    $logger->info('Waiting to reap process');
    $pid = waitpid( -1, &WNOHANG );    # So we don't leave zombies
    $logger->info("Reaped PID $pid");
    $running = FALSE;

    $finished_callback->($output) if ( defined $finished_callback );
    return Glib::SOURCE_REMOVE;
   }
   return Glib::SOURCE_CONTINUE;
  }
 );
 return;
}

sub _watch_stderr {
 my ( $cmd, $started_callback, $new_line_callback, $finished_callback ) = @_;

 $logger->info($cmd);

 # Interface to scanimage
 my ( $write, $read );
 my $error = IO::Handle->new;    # this needed because of a bug in open3.
 my $pid = IPC::Open3::open3( $write, $read, $error, $cmd );
 $logger->info("Forked PID $pid");

 $started_callback->() if ( defined $started_callback );
 if ( $_self->{abort_scan} ) {
  local $SIG{INT} = 'IGNORE';
  $logger->info("Sending INT signal to PID $pid and its children");
  killfam 'INT', ($pid);
 }

 my $line;
 Glib::IO->add_watch(
  fileno($error),
  [ 'in', 'hup' ],
  sub {
   my ( $fileno, $condition ) = @_;
   my $buffer;
   if ( $condition & 'in' ) {    # bit field operation. >= would also work

# Only reading one buffer, rather than until sysread gives EOF because things seem to be strange for stderr
    sysread $error, $buffer, 1024;
    $logger->debug($buffer) if ($buffer);
    $line .= $buffer;

    while ( $line =~ /([\r\n])/x ) {
     my $le = $1;
     $new_line_callback->($line) if ( defined $new_line_callback );
     $line = substr( $line, index( $line, $le ) + 1, length($line) );
    }
   }

   # Only allow the hup if sure an empty buffer has been read.
   if ( ( $condition & 'hup' ) and ( not defined($buffer) or $buffer eq '' ) )
   {    # bit field operation. >= would also work
    close $read;
    $logger->info('Waiting to reap process');
    $pid = waitpid( -1, &WNOHANG );    # So we don't leave zombies
    $logger->info("Reaped PID $pid");

    # Now finished scanning, get on with post-processing
    $finished_callback->() if ( defined $finished_callback );
    return Glib::SOURCE_REMOVE;
   }
   return Glib::SOURCE_CONTINUE;
  }
 );
 return;
}

1;

__END__