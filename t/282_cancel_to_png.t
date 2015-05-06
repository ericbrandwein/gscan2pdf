use warnings;
use strict;
use Test::More tests => 2;

BEGIN {
    use Gscan2pdf::Document;
    use Gtk2 -init;    # Could just call init separately
}

#########################

use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init($WARN);
my $logger = Log::Log4perl::get_logger;
Gscan2pdf::Document->setup($logger);

# Create test image
system('convert rose: test.pnm');

my $slist = Gscan2pdf::Document->new;

# dir for temporary files
my $dir = File::Temp->newdir;
$slist->set_dir($dir);

$slist->get_file_info(
    path              => 'test.pnm',
    finished_callback => sub {
        my ($info) = @_;
        $slist->import_file(
            info              => $info,
            first             => 1,
            last              => 1,
            finished_callback => sub {
                my $md5sum =
                  `md5sum $slist->{data}[0][2]{filename} | cut -c -32`;
                my $pid = $slist->to_png(
                    page               => $slist->{data}[0][2],
                    cancelled_callback => sub {
                        is(
                            $md5sum,
`md5sum $slist->{data}[0][2]{filename} | cut -c -32`,
                            'image not modified'
                        );
                        $slist->save_image(
                            path              => 'test.jpg',
                            list_of_pages     => [ $slist->{data}[0][2] ],
                            finished_callback => sub { Gtk2->main_quit }
                        );
                    }
                );
                $slist->cancel($pid);
            }
        );
    }
);
Gtk2->main;

is( system('identify test.jpg'),
    0, 'can create a valid JPG after cancelling previous process' );

#########################

unlink 'test.pnm', 'test.jpg';
Gscan2pdf::Document->quit();