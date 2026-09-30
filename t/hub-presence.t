#!/usr/bin/perl
# hub-presence.t — online/offline is a #system transition, not berth chatter.
# usage: perl t/hub-presence.t

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

my $dir   = tempdir(CLEANUP => 1);
my $hsock = "$dir/hub.sock";
my $fsock = "$dir/fcgi.sock";
my $chat  = "$dir/chat.ndjson";

sub row {
    my ($type, $id, $extra) = @_;
    my $o = { type => $type, id => $id, ts => '2026-09-30T00:00:00Z' };
    $o->{$_} = $extra->{$_} for keys %{ $extra || {} };
    return $o;
}
my @seed = (
    row('message', 'm1', { from => 'human', to => 'zhc-ops', content => 'real-note' }),
    row('register', 'zhc-ops'),
    row('register', 'zhc-ops'),
    row('register', 'zhc-ops'),
    row('disconnect', 'zhc-ops'),
    row('disconnect', 'zhc-ops'),
    row('register', 'zhc-ops'),
    row('message', 'm2', { from => 'zhc-ops', to => 'human', content => 'reply-note' }),
);
open my $cf, '>', $chat or die $!;
print $cf encode_json($_), "\n" for @seed;
close $cf;

$ENV{HUB_SOCK}      = $hsock;
$ENV{HUB_LOG}       = "$dir/hub.ndjson";
$ENV{FCGI_SOCK}     = $fsock;
$ENV{CHAT_LOG}      = $chat;
$ENV{FILE_DIR}      = "$dir/files";
$ENV{SETUP_FILE}    = "$dir/setup.json";
$ENV{SECRETS_DIR}   = "$dir/secrets";
$ENV{PICOCLAW_HOME} = "$dir/pico";
$ENV{HUB_NOSANDBOX} = 1;
delete $ENV{HUB_NOFCGI};
delete $ENV{PICOBUS_ZHC_GATE};
delete $ENV{PICOBUS_FCGI_GROUP};

my $pid = fork();
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    open STDIN,  '<', '/dev/null';
    open STDOUT, '>', "$dir/hub.out";
    open STDERR, '>&STDOUT';
    exec $^X, "$FindBin::Bin/../bin/picobus" or exit 127;
}

my $up;
for (1 .. 50) {
    if (-S $hsock && -S $fsock) { $up = 1; last }
    select undef, undef, undef, 0.1;
}
ok($up, 'hub listening');

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
    my ($uri) = @_;
    my $c = IO::Socket::UNIX->new(Peer => $fsock, Type => SOCK_STREAM)
        or return { err => "connect: $!" };
    $c->autoflush(1);
    my ($path, $qs) = split /\?/, $uri, 2;
    $qs //= '';
    my %env = (
        REQUEST_METHOD  => 'GET',
        REQUEST_URI     => $uri,
        SCRIPT_NAME     => $path,
        QUERY_STRING    => $qs,
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
    my ($head, $b) = split /\r\n\r\n/, $out, 2;
    $b //= '';
    my $st = ($head // '') =~ /Status:\s*(\d+)/i ? $1 : '';
    return { status => $st, json => eval { decode_json($b) } || {} };
}
sub types_of {
    my ($uri) = @_;
    my $res = fcgi_do($uri);
    my @t = map { $_->{type} // '' } @{ $res->{json}{messages} || [] };
    return join(',', @t);
}
sub connect_hub {
    my $c = IO::Socket::UNIX->new(Peer => $hsock, Type => SOCK_STREAM)
        or die "connect: $!";
    $c->autoflush(1);
    return $c;
}

if ($up) {
    my $ops = types_of('/api/history?channel=zhc-ops&page=last&lines=40');
    ok($ops eq 'message,message', "berth history is only chat ($ops)");
    my $sys = types_of('/api/history?channel=all&page=last&lines=40');
    ok($sys eq 'register,disconnect,register', "#system keeps offline then online ($sys)");

    my $src = '';
    open my $sf, '<', "$FindBin::Bin/../bin/picobus" or die $!;
    local $/;
    $src = <$sf> // '';
    close $sf;
    ok($src =~ /" online"/ && $src =~ /" offline"/, 'the note says online and offline');

    my $a = connect_hub();
    print $a encode_json({ type => 'register', id => 'zhc-ops' }), "\n";
    select undef, undef, undef, 0.2;
    my $b = connect_hub();
    print $b encode_json({ type => 'register', id => 'zhc-ops' }), "\n";
    select undef, undef, undef, 0.2;
    my $after_replace = types_of('/api/history?channel=all&page=last&lines=40');
    ok($after_replace eq 'register,disconnect,register',
        "a second socket does not add another online ($after_replace)");

    my $live = fcgi_do('/api/state');
    my $up_now = 0;
    for my $ag (@{ $live->{json}{agents} || [] }) {
        $up_now = 1 if ($ag->{id} // '') eq 'zhc-ops' && $ag->{connected};
    }
    close $a;
    select undef, undef, undef, 0.3;
    my $still = fcgi_do('/api/state');
    my $still_up = 0;
    for my $ag (@{ $still->{json}{agents} || [] }) {
        $still_up = 1 if ($ag->{id} // '') eq 'zhc-ops' && $ag->{connected};
    }
    ok($up_now && $still_up, 'retiring the old socket leaves the berth online');
    my $no_off = types_of('/api/history?channel=all&page=last&lines=40');
    ok($no_off eq 'register,disconnect,register',
        "the retired socket is not an offline ($no_off)");

    close $b;
    select undef, undef, undef, 0.3;
    my $off = types_of('/api/history?channel=all&page=last&lines=40');
    ok($off eq 'register,disconnect,register,disconnect',
        "#system notes the real offline ($off)");

    my $c = connect_hub();
    print $c encode_json({ type => 'register', id => 'zhc-ops' }), "\n";
    select undef, undef, undef, 0.2;
    my $back = types_of('/api/history?channel=all&page=last&lines=40');
    ok($back eq 'register,disconnect,register,disconnect,register',
        "#system notes the return online ($back)");
    my $ops2 = types_of('/api/history?channel=zhc-ops&page=last&lines=40');
    ok($ops2 eq 'message,message', "berth stays free of presence ($ops2)");
    close $c;
} else {
    for my $n (1 .. 9) { ok(0, "skipped $n"); }
}

if ($pid) {
    kill 'TERM', $pid;
    select undef, undef, undef, 0.2;
    kill 'KILL', $pid;
    waitpid($pid, 0);
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
