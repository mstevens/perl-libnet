use strict;
use warnings;
use Test::More;
use File::Temp 'tempfile';
use Net::POP3;

my $debug = 0; # Net::POP3 Debug => ..

plan skip_all => "no SSL support found in Net::POP3" if ! Net::POP3->can_ssl;

plan skip_all => "fork not supported on this platform"
  if grep { $^O =~m{$_} } qw(MacOS VOS vmesa riscos amigaos);

plan skip_all => "incomplete or to old version of IO::Socket::SSL" if ! eval {
  require IO::Socket::SSL
    && IO::Socket::SSL->VERSION(1.968)
    && require IO::Socket::SSL::Utils
    && defined &IO::Socket::SSL::Utils::CERT_create;
};

my $srv = IO::Socket::INET->new(
  LocalAddr => '127.0.0.1',
  Listen => 10
);
plan skip_all => "cannot create listener on localhost: $!" if ! $srv;
my $saddr = $srv->sockhost.':'.$srv->sockport;

plan tests => 2;

my ($ca,$key) = IO::Socket::SSL::Utils::CERT_create( CA => 1 );
my ($fh,$cafile) = tempfile();
print $fh IO::Socket::SSL::Utils::PEM_cert2string($ca);
close($fh);

my $parent = $$;
END { unlink($cafile) if $$ == $parent }

my ($cert) = IO::Socket::SSL::Utils::CERT_create(
  subject => { CN => 'pop3.example.com' },
  issuer_cert => $ca, issuer_key => $key,
  key => $key
);

test(1); # direct ssl
test(0); # starttls


sub test {
  my $ssl = shift;
  defined( my $pid = fork()) or die "fork failed: $!";
  exit(pop3_server($ssl)) if ! $pid;
  pop3_client($ssl);
  wait;
}


sub pop3_client {
  my $ssl = shift;
  my %sslopt = (
    SSL_verifycn_name => 'pop3.example.com',
    SSL_ca_file => $cafile
  );
  $sslopt{SSL} = 1 if $ssl;
  my $cl = Net::POP3->new($saddr, %sslopt, Debug => $debug);
  diag("created Net::POP3 object");
  if (!$cl) {
    fail( ($ssl ? "SSL ":"" )."POP3 connect failed");
  } elsif ($ssl) {
    $cl->quit;
    pass("SSL POP3 connect success");
  } elsif ( ! $cl->starttls ) {
    no warnings 'once';
    fail("starttls failed: $IO::Socket::SSL::SSL_ERROR");
  } else {
    $cl->quit;
    pass("starttls success");
  }
}

sub pop3_server {
  my $ssl = shift;
  my $cl = $srv->accept or die "accept failed: $!";
  my %sslargs = (
    SSL_server => 1,
    SSL_cert => $cert,
    SSL_key => $key,
  );
  if ( $ssl ) {
    if ( ! IO::Socket::SSL->start_SSL($cl, %sslargs)) {
      diag("initial ssl handshake with client failed");
      return;
    }
  }

  print $cl "+OK localhost ready\r\n";
  while (<$cl>) {
    my ($cmd,$arg) = m{^(\S+)(?: +(.*))?\r\n} or die $_;
    $cmd = uc($cmd);
    if ($cmd eq 'QUIT' ) {
      print $cl "+OK bye\r\n";
      last;
    } elsif ( $cmd eq 'CAPA' ) {
      print $cl "+OK\r\n".
	( $ssl ? "" : "STLS\r\n" ).
	".\r\n";
    } elsif ( ! $ssl and $cmd eq 'STLS' ) {
      print $cl "+OK starting ssl\r\n";
      if ( ! IO::Socket::SSL->start_SSL($cl, %sslargs)) {
	diag("initial ssl handshake with client failed");
	return;
      }
      $ssl = 1;
    } else {
      diag("received unknown command: $cmd");
      print "-ERR unknown cmd\r\n";
    }
  }

  diag("POP3 dialog done");
}
