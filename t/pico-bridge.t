#!/usr/bin/perl
# pico-bridge.t — hub message -> picobus-pico -> fake Pico WS -> hub reply.
# usage: perl t/pico-bridge.t
# Skips if Mojolicious is not installed.

use strict;
use warnings;
use FindBin;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use IO::Socket::UNIX;
use JSON::PP qw(encode_json decode_json);

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $name) = @_;
    if ($cond) { $pass++; print "ok - $name\n" }
    else       { $fail++; print "NOT OK - $name\n" }
}

unless (eval { require Mojolicious; require Mojo::UserAgent; 1 }) {
    print "skip - Mojolicious not installed\n";
    exit 0;
}

my $dir  = tempdir(CLEANUP => 1);
my $sock = "$dir/hub.sock";
my $log  = "$dir/hub.ndjson";
my $tokd = "$dir/tokens";
mkdir $tokd, 0700 or die $!;
my $token = 'test-token-pico-bridge';
open my $tf, '>', "$tokd/lab" or die $!;
print $tf $token;
close $tf;

my $port;
for my $p (19100 .. 19220) {
    my $probe = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1', LocalPort => $p,
        Proto => 'tcp', Listen => 1, ReuseAddr => 1,
    );
    if ($probe) {
        $port = $p;
        close $probe;
        last;
    }
}
die "no free port\n" unless $port;

$ENV{HUB_SOCK}   = $sock;
$ENV{HUB_LOG}    = $log;
$ENV{HUB_NOFCGI} = 1;
delete $ENV{HUB_NOSANDBOX};
delete $ENV{HUB_GROUP};

my $hub_pid = fork();
die "fork hub: $!" unless defined $hub_pid;
if ($hub_pid == 0) {
    open STDOUT, '>', "$dir/hub.out";
    open STDERR, '>&STDOUT';
    exec $^X, "$FindBin::Bin/../bin/picobus" or exit 127;
}

my $up;
for (1 .. 40) {
    if (-S $sock) { $up = 1; last }
    select undef, undef, undef, 0.1;
}
ok($up, 'hub listening');

my $ws_pid = fork();
die "fork ws: $!" unless defined $ws_pid;
if ($ws_pid == 0) {
    open STDOUT, '>', "$dir/ws.out";
    open STDERR, '>&STDOUT';
    exec $^X, "$FindBin::Bin/fake-pico-ws.pl", $port, $token or exit 127;
}

my $ws_up;
for (1 .. 40) {
    my $h = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp', Timeout => 1,
    );
    if ($h) { close $h; $ws_up = 1; last }
    select undef, undef, undef, 0.1;
}
ok($ws_up, 'fake pico listening');

$ENV{PICO_AGENTS}     = "lab=127.0.0.1:$port";
$ENV{PICO_TOKEN_DIR}  = $tokd;
$ENV{PICO_IDLE_FLUSH} = 2;

my $br_pid = fork();
die "fork bridge: $!" unless defined $br_pid;
if ($br_pid == 0) {
    open STDOUT, '>', "$dir/pico.out";
    open STDERR, '>&STDOUT';
    exec $^X, "$FindBin::Bin/../bin/picobus-pico" or exit 127;
}

# wait until lab is registered
my $reg;
for (1 .. 50) {
    if (open my $lf, '<', $log) {
        local $/;
        my $all = <$lf> // '';
        close $lf;
        if ($all =~ /"id":"lab"/) { $reg = 1; last }
    }
    select undef, undef, undef, 0.1;
}
ok($reg, 'picobus-pico registered as lab');

sub connect_hub {
    IO::Socket::UNIX->new(Peer => $sock, Type => SOCK_STREAM)
        or die "connect hub: $!";
}

my $got;
if ($up && $ws_up && $reg) {
    my $c = connect_hub();
    print $c encode_json({ type => 'register', id => 'smoke' }), "\n";
    select undef, undef, undef, 0.2;
    print $c encode_json({
        type    => 'message',
        from    => 'smoke',
        to      => 'lab',
        content => 'ping-pico',
    }), "\n";
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 8;
        while (my $line = <$c>) {
            my $o = eval { decode_json($line) } or next;
            next unless ($o->{type} // '') eq 'message';
            next unless ($o->{from} // '') eq 'lab';
            if (($o->{content} // '') =~ /echo:.*ping-pico/) {
                $got = 1;
                last;
            }
        }
        alarm 0;
    };
    alarm 0;
    close $c;
}
ok($got, 'hub message round-trips through Pico WS');
if (!$got) {
    for my $f (qw(pico.out ws.out hub.out hub.ndjson)) {
        next unless -f "$dir/$f";
        print "--- $f ---\n";
        open my $fh, '<', "$dir/$f" or next;
        print while <$fh>;
        close $fh;
    }
}

for my $pid ($br_pid, $ws_pid, $hub_pid) {
    next unless $pid;
    kill 'TERM', $pid;
}
select undef, undef, undef, 0.2;
for my $pid ($br_pid, $ws_pid, $hub_pid) {
    next unless $pid;
    kill 'KILL', $pid;
    waitpid($pid, 0);
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
