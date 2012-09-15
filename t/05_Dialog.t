use warnings;
use strict;
use Test::More tests => 17;
use Glib qw(TRUE FALSE);    # To get TRUE and FALSE
use Gtk2 -init;
use Scalar::Util;

BEGIN {
 use_ok('Gscan2pdf::Dialog');
}

#########################

my $window = Gtk2::Window->new;

ok(
 my $dialog =
   Gscan2pdf::Dialog->new( title => 'title', 'transient-for' => $window ),
 'Created dialog'
);
isa_ok( $dialog, 'Gscan2pdf::Dialog' );

is( $dialog->get('title'),         'title', 'title' );
is( $dialog->get('transient-for'), $window, 'transient-for' );
ok( $dialog->get('hide-on-delete') == FALSE, 'default destroy' );
is( $dialog->get('border-width'), 0, 'default border width' );

ok( my $vbox = $dialog->get('vbox'), 'Get vbox' );
isa_ok( $vbox, 'Gtk2::VBox' );
is(
 $vbox->get('border-width'),
 $dialog->get('border-width'),
 'border width applied to vbox'
);

my $border_width = 6;
$dialog->set( 'border-width', $border_width );
is( $dialog->get('border-width'), $border_width, 'set border width' );
is( $vbox->get('border-width'),
 $border_width, 'new border width applied to vbox' );

$dialog = Gscan2pdf::Dialog->new;
$dialog->signal_emit( 'delete_event', undef );
Scalar::Util::weaken($dialog);
is( $dialog, undef, 'destroyed on delete_event' );

$dialog = Gscan2pdf::Dialog->new( 'hide-on-delete' => TRUE );
$dialog->signal_emit( 'delete_event', undef );
Scalar::Util::weaken($dialog);
isnt( $dialog, undef, 'hidden on delete_event' );

$dialog = Gscan2pdf::Dialog->new;
my $event = Gtk2::Gdk::Event->new('key-press');
$event->keyval( $Gtk2::Gdk::Keysyms{Escape} );
$dialog->signal_emit( 'key_press_event', $event );
Scalar::Util::weaken($dialog);
is( $dialog, undef, 'destroyed on escape' );

$dialog = Gscan2pdf::Dialog->new( 'hide-on-delete' => TRUE );
$dialog->signal_emit( 'key_press_event', $event );
Scalar::Util::weaken($dialog);
isnt( $dialog, undef, 'hidden on escape' );

$dialog = Gscan2pdf::Dialog->new;
$dialog->signal_connect_after(
 key_press_event => sub {
  my ( $widget, $event ) = @_;
  is(
   $event->keyval,
   $Gtk2::Gdk::Keysyms{Delete},
   'other key press events still propagate'
  );
 }
);
$event = Gtk2::Gdk::Event->new('key-press');
$event->keyval( $Gtk2::Gdk::Keysyms{Delete} );
$dialog->signal_emit( 'key_press_event', $event );

__END__