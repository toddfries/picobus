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

my $statedir = "$dir/fake";
mkdir $statedir, 0700 or die $!;
open my $pf, '>', "$statedir/probe.json" or die $!;
print $pf encode_json({ id => 'lab', nick => 'bench', role => 'bench', pid => 1 });
close $pf;

my $ws_pid = fork();
die "fork ws: $!" unless defined $ws_pid;
if ($ws_pid == 0) {
    open STDOUT, '>', "$dir/ws.out";
    open STDERR, '>&STDOUT';
    exec $^X, "$FindBin::Bin/fake-pico-ws.pl", $port, $token, 'lab', $statedir or exit 127;
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
$ENV{PICO_DIRECTORY}  = "$dir/directory.json";
$ENV{PICO_POLL}       = 1;

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
my $got_echo;
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
                $got_echo = (($o->{echo} // 0) ? 1 : 0);
                last;
            }
        }
        alarm 0;
    };
    alarm 0;
    close $c;
}
ok($got, 'hub message round-trips through Pico WS');
ok($got_echo, 'flushed reply is marked echo');

my $bounced;
my $echo_quiet;
if ($got) {
    my $c = connect_hub();
    print $c encode_json({ type => 'register', id => 'smoke' }), "\n";
    $c->flush;
    select undef, undef, undef, 0.2;
    print $c encode_json({
        type    => 'message',
        from    => 'smoke',
        to      => 'lab',
        content => 'second-ping',
        echo    => 1,
    }), "\n";
    $c->flush;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 4;
        while (my $line = <$c>) {
            my $o = eval { decode_json($line) } or next;
            next unless ($o->{type} // '') eq 'message';
            next unless ($o->{from} // '') eq 'lab';
            if (($o->{content} // '') =~ /second-ping/) {
                $bounced = 1;
                last;
            }
        }
        alarm 0;
    };
    alarm 0;
    $echo_quiet = 1 if !$bounced && $@ && $@ =~ /timeout/;
    close $c;
}
ok($echo_quiet, 'echo reply is not written back to the hub');

sub read_text {
    my ($path) = @_;
    return '' unless -f $path;
    open my $fh, '<', $path or return '';
    local $/;
    my $raw = <$fh> // '';
    close $fh;
    return $raw;
}

my $dir_ok;
my $nick_ok;
for (1 .. 30) {
    my $raw = read_text("$dir/directory.json");
    if ($raw =~ /"nick":"bench"/ && $raw =~ /"id":"lab"/) {
        $dir_ok = 1;
        $nick_ok = 1;
        last;
    }
    select undef, undef, undef, 0.2;
}
ok($dir_ok && $nick_ok, 'directory learns nick from /beacon');

sub directory_frames {
    return () = read_text("$statedir/frames.ndjson") =~ /"type":"directory"/g;
}

my $frames_before = 0;
my $same = 0;
for (1 .. 40) {
    my $n = directory_frames();
    if ($n > 0 && $n == $frames_before) {
        $same++;
        last if $same >= 3;
    }
    else {
        $same = 0;
        $frames_before = $n;
    }
    select undef, undef, undef, 0.4;
}
ok($frames_before > 0, 'directory frame stored, not a message.send');

open my $pf2, '>', "$statedir/probe.json" or die $!;
print $pf2 encode_json({ id => 'lab', nick => 'bench', role => 'bench', pid => 99 });
close $pf2;
my $pid_ok;
for (1 .. 30) {
    my $raw = read_text("$dir/directory.json");
    if ($raw =~ /"pid":99/) { $pid_ok = 1; last }
    select undef, undef, undef, 0.2;
}
my $frames_after = directory_frames();
ok($pid_ok, 'directory pid updates from /health');
ok($frames_after == $frames_before, 'pid change does not push a directory frame');

sub http_post_json {
    my ($peerport, $path, $obj) = @_;
    my $body = encode_json($obj);
    my $s = IO::Socket::INET->new(
        PeerAddr => '127.0.0.1', PeerPort => $peerport, Proto => 'tcp',
    ) or return 0;
    print $s "POST $path HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: "
        . length($body) . "\r\nConnection: close\r\n\r\n" . $body;
    local $/;
    my $resp = <$s> // '';
    close $s;
    return $resp =~ m{\AHTTP/\S+\s+200};
}

my $todd_got;
my $todd_echo;
if ($up) {
    my $todd = connect_hub();
    print $todd encode_json({ type => 'register', id => 'todd' }), "\n";
    $todd->flush;
    select undef, undef, undef, 0.4;
    my $posted = http_post_json($port, '/emit', { to => 'todd', content => 'hello-todd' });
    ok($posted, 'asked fake pico to emit bus.send');
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 5;
        while (my $line = <$todd>) {
            my $o = eval { decode_json($line) } or next;
            next unless ($o->{type} // '') eq 'message';
            if (($o->{from} // '') eq 'lab' && ($o->{content} // '') eq 'hello-todd') {
                $todd_got = 1;
                $todd_echo = $o->{echo} ? 1 : 0;
                last;
            }
        }
        alarm 0;
    };
    alarm 0;
    close $todd;
}
ok($todd_got, 'bus.send reaches a non-berth hub client');
ok(!$todd_echo, 'bus.send is not marked echo');
my $ack = read_text("$statedir/frames.ndjson");
ok($ack =~ /"type":"bus\.ack"/, 'bus.ack returned on the control socket');

if (!$got || !$got_echo || !$echo_quiet || !$dir_ok || !$pid_ok || !$todd_got || $todd_echo) {
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
