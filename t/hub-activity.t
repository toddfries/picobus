#!/usr/bin/perl
# hub-activity.t — thinking/idle on /api/state, not on the chat log.
# usage: perl t/hub-activity.t

use strict;
use warnings;
use FindBin;
use File::Temp qw(tempdir);
use IO::Socket::UNIX;
use JSON::PP qw(encode_json decode_json);

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $name) = @_;
    if ($cond) { $pass++; print "ok - $name\n" }
    else       { $fail++; print "NOT OK - $name\n" }
}

my $bin = "$FindBin::Bin/../bin/picobus";
my $src = '';
if (open my $sf, '<', $bin) {
    local $/;
    $src = <$sf> // '';
    close $sf;
}
ok($src =~ /setInterval\(tick, 1500\)/, 'roster poll stays at 1.5s');
ok($src =~ /dot-spin/ && $src =~ /prefers-reduced-motion/, 'thinking ball is CSS, and reduced motion is static');
ok($src =~ /dot\.thinking::before/ && $src =~ /dot-spin-back/, 'thinking is a blue ball with a turning ring');
ok($src =~ /selectTarget\("captain"/, 'a fresh visit opens the captain channel');
ok($src =~ /a message from /, 'a mate-to-mate line collapses to a mention');
ok($src =~ /data-zhc-bucket/ && $src =~ /html\[data-zhc-bucket="dev"\] \.dot/ && $src =~ /calc\(10px \* 1\.75\)/, 'dev ball is 75% larger; other buckets stay 10px');
ok($src =~ /holdFor\[a\.id\] === stateGen/, 'a new message pauses the ball only until the next poll');
ok($src =~ /if \(first \|\| prev === key\) continue/, 'the first history paint does not pause the ball');

my $dir   = tempdir(CLEANUP => 1);
my $hsock = "$dir/hub.sock";
my $fsock = "$dir/fcgi.sock";
my $log   = "$dir/hub.ndjson";
$ENV{HUB_SOCK}               = $hsock;
$ENV{HUB_LOG}                = $log;
$ENV{FCGI_SOCK}              = $fsock;
$ENV{HUB_NOSANDBOX}          = 1;
$ENV{PICOBUS_ACTIVITY_STALE} = 2;
delete $ENV{HUB_NOFCGI};
delete $ENV{PICOBUS_ZHC_GATE};
delete $ENV{PICOBUS_FCGI_GROUP};

my $pid = fork();
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    open STDIN,  '<', '/dev/null';
    open STDOUT, '>', "$dir/hub.out";
    open STDERR, '>&STDOUT';
    exec $^X, $bin or exit 127;
}

my $up;
for (1 .. 50) {
    if (-S $hsock && -S $fsock) { $up = 1; last }
    select undef, undef, undef, 0.1;
}
ok($up, 'hub listening on the agent socket and fastcgi');

sub connect_hub {
    IO::Socket::UNIX->new(Peer => $hsock, Type => SOCK_STREAM)
        or die "connect $hsock: $!";
}
sub fcgi_nv {
    my ($k, $v) = @_;
    $v = '' unless defined $v;
    my $n = length $k;
    my $m = length $v;
    my $out = $n < 128 ? pack('C', $n) : pack('N', $n | 0x80000000);
    $out .= $m < 128 ? pack('C', $m) : pack('N', $m | 0x80000000);
    return $out . $k . $v;
}
sub fcgi_rec {
    my ($type, $id, $content) = @_;
    $content //= '';
    my $clen = length $content;
    my $pad  = (8 - ($clen % 8)) % 8;
    return pack('CCnnCC', 1, $type, $id, $clen, $pad, 0) . $content . ("\0" x $pad);
}
sub fcgi_readn {
    my ($fh, $n) = @_;
    my $buf = '';
    while (length($buf) < $n) {
        my $r = read($fh, my $chunk, $n - length($buf));
        return undef if !defined $r || $r == 0;
        $buf .= $chunk;
    }
    return $buf;
}
sub fcgi_do {
    my ($method, $uri) = @_;
    my $c = IO::Socket::UNIX->new(Peer => $fsock, Type => SOCK_STREAM)
        or return { err => "connect: $!" };
    $c->autoflush(1);
    my %env = (
        REQUEST_METHOD  => $method,
        REQUEST_URI     => $uri,
        SCRIPT_NAME     => $uri,
        QUERY_STRING    => '',
        CONTENT_LENGTH  => 0,
        SERVER_PROTOCOL => 'HTTP/1.0',
    );
    print $c fcgi_rec(1, 1, pack('nC', 1, 0) . ("\0" x 6));
    my $params = '';
    $params .= fcgi_nv($_, $env{$_}) for sort keys %env;
    print $c fcgi_rec(4, 1, $params);
    print $c fcgi_rec(4, 1, '');
    print $c fcgi_rec(5, 1, '');
    my $out = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout" };
        alarm 8;
        while (1) {
            my $hdr = fcgi_readn($c, 8);
            last unless defined $hdr;
            my ($ver, $type, $id, $clen, $pad) = unpack('CCnnC', $hdr);
            my $content = $clen ? fcgi_readn($c, $clen) : '';
            fcgi_readn($c, $pad) if $pad;
            last unless defined $content;
            $out .= $content if $type == 6;
            last if $type == 3;
        }
        alarm 0;
    };
    alarm 0;
    close $c;
    my ($head, $body) = split /\r\n\r\n/, $out, 2;
    $body //= '';
    my $st = ($head // '') =~ /Status:\s*(\d+)/i ? $1 : '';
    return { status => $st, body => $body };
}
sub state_activity {
    my ($id) = @_;
    my $res = fcgi_do('GET', '/api/state');
    return ('', $res->{status}, '') unless ($res->{status} // '') eq '200';
    my $obj = eval { decode_json($res->{body}) } || {};
    for my $a (@{ $obj->{agents} || [] }) {
        next unless ($a->{id} // '') eq $id;
        return ($a->{activity} // '', '200', $res->{body});
    }
    return ('', '200', $res->{body});
}

if ($up) {
    my $a = connect_hub();
    my $b = connect_hub();
    $a->autoflush(1);
    $b->autoflush(1);
    print $a encode_json({ type => 'register', id => 'crew-a' }), "\n";
    print $b encode_json({ type => 'register', id => 'crew-b' }), "\n";
    select undef, undef, undef, 0.2;
    print $a encode_json({
        type => 'activity', activity => 'thinking', from => 'crew-b',
    }), "\n";
    $a->flush;
    select undef, undef, undef, 0.2;

    my ($aa, $ast, $abody) = state_activity('crew-a');
    my ($ba) = state_activity('crew-b');
    ok($ast eq '200' && $aa eq 'thinking', 'connection id is thinking');
    ok($ba eq 'idle', 'JSON from does not mark the other berth thinking');
    if ($aa ne 'thinking') {
        print "--- state crew-a ---\n$abody\n";
    }

    print $a encode_json({ type => 'activity', activity => 'spinning' }), "\n";
    $a->flush;
    select undef, undef, undef, 0.2;
    my ($still) = state_activity('crew-a');
    ok($still eq 'thinking', 'unknown activity values are ignored');

    my $leaked = 0;
    eval {
        local $SIG{ALRM} = sub { die "timeout" };
        alarm 1;
        while (my $line = <$b>) {
            if ($line =~ /activity|thinking/) { $leaked = 1; last }
        }
        alarm 0;
    };
    alarm 0;
    ok(!$leaked, 'activity is not delivered to the other berth');

    select undef, undef, undef, 2.3;
    my ($stale) = state_activity('crew-a');
    ok($stale eq 'idle', 'thinking older than the stale window is idle');

    print $a encode_json({ type => 'activity', activity => 'thinking' }), "\n";
    print $a encode_json({ type => 'activity', activity => 'idle' }), "\n";
    $a->flush;
    select undef, undef, undef, 0.2;
    my ($explicit) = state_activity('crew-a');
    ok($explicit eq 'idle', 'an idle broadcast clears thinking');

    close $a;
    close $b;
} else {
    ok(0, 'connection id is thinking (skipped)');
    ok(0, 'spoof (skipped)');
    ok(0, 'not delivered (skipped)');
    ok(0, 'unknown ignored (skipped)');
    ok(0, 'stale (skipped)');
    ok(0, 'idle clears (skipped)');
}

if ($pid) {
    kill 'TERM', $pid;
    select undef, undef, undef, 0.2;
    kill 'KILL', $pid;
    waitpid($pid, 0);
}

my $logged = 0;
if (open my $lf, '<', $log) {
    local $/;
    my $all = <$lf> // '';
    close $lf;
    $logged = 1 if $all =~ /activity/;
}
ok(!$logged, 'activity is absent from the hub log');

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
