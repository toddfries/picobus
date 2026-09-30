#!/usr/bin/perl
# hub-history.t — history pages follow the packer, not ceil(lines / budget).
# A message that does not fill the previous page still consumes a page, so
# the highest page number has to be reachable. usage: perl t/hub-history.t

use strict;
use warnings;
use FindBin;
$| = 1;
use File::Temp qw(tempdir);
use IO::Socket::UNIX;
use JSON::PP qw(encode_json decode_json);

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $name) = @_;
    if ($cond) { $pass++; print "ok - $name\n" }
    else       { $fail++; print "NOT OK - $name\n" }
    return $cond ? 1 : 0;
}

my $dir   = tempdir(CLEANUP => 1);
my $hsock = "$dir/hub.sock";
my $fsock = "$dir/fcgi.sock";
my $chat  = "$dir/chat.ndjson";

# msg_lines = 1 + newlines + 1. Four board messages of weight 6 and a budget
# of 8 cannot share a page (6+6 > 8). Total lines are 24, and ceil(24/8) is 3,
# which used to hide page 4. One tall ops message is a single packed page,
# not the three pages that same ceiling would invent.
sub msg {
    my ($id, $from, $to, $content) = @_;
    return {
        type => 'message', from => $from, to => $to,
        content => $content, id => $id, ts => '2026-09-30T00:00:00Z',
    };
}
my @rows = (
    msg('b1', 'human',     'zhc-board', "board-1\n.\n.\n.\n."),
    msg('b2', 'zhc-board', 'human',     "board-2\n.\n.\n.\n."),
    msg('b3', 'human',     'zhc-board', "board-3\n.\n.\n.\n."),
    msg('b4', 'zhc-board', 'human',     "board-4\n.\n.\n.\n."),
    msg('o1', 'zhc-ops',   'human',     "ops-tall\n" . (".\n" x 16)),
    msg('r1', 'human',     'zhc-res',   "res-1\n."),
    msg('r2', 'zhc-res',   'human',     "res-2\n."),
    msg('r3', 'human',     'zhc-res',   "res-3\n."),
);
open my $cf, '>', $chat or die $!;
print $cf encode_json($_), "\n" for @rows;
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
    open STDOUT, '>', "$dir/hub.out";
    open STDERR, '>&STDOUT';
    exec $^X, "$FindBin::Bin/../bin/picobus" or exit 127;
}
END {
    if ($pid) {
        kill 'KILL', $pid;
        waitpid($pid, 0);
    }
}

my $up;
for (1 .. 50) {
    if (-S $fsock && -S $hsock) { $up = 1; last }
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
    return { status => $st, body => $b, json => eval { decode_json($b) } || {} };
}

sub joined {
    my ($h) = @_;
    return join(' ', map { $_->{content} // '' } @{ $h->{messages} || [] });
}

if ($up) {
    my $last = fcgi_do('/api/history?channel=zhc-board&page=last&lines=8');
    ok($last->{status} eq '200', 'board last page is 200');
    ok($last->{json}{pages} == 4, 'board has 4 packed pages, not the line ceiling');
    ok($last->{json}{page} == 4, 'page=last is the packed last page');
    ok(joined($last->{json}) =~ /board-4/, 'last page contains the newest board message');
    ok(joined($last->{json}) !~ /board-3/, 'last page is not the previous page');

    my $p4 = fcgi_do('/api/history?channel=zhc-board&page=4&lines=8');
    ok($p4->{json}{page} == 4, 'explicit page 4 is page 4');
    ok(joined($p4->{json}) =~ /board-4/, 'clicking page 4 returns its message');

    my $p3 = fcgi_do('/api/history?channel=zhc-board&page=3&lines=8');
    ok($p3->{json}{page} == 3, 'page 3 stays page 3');
    ok(joined($p3->{json}) =~ /board-3/ && joined($p3->{json}) !~ /board-4/,
        'page 3 is only the third message');

    my $ops = fcgi_do('/api/history?channel=zhc-ops&page=last&lines=8');
    ok($ops->{json}{pages} == 1, 'a tall message is one page, not an empty tail');
    ok($ops->{json}{page} == 1 && joined($ops->{json}) =~ /ops-tall/,
        'last page of a tall message is that message');

    my $res = fcgi_do('/api/history?channel=zhc-res&page=last&lines=8');
    ok($res->{json}{pages} == 2 && $res->{json}{page} == 2, 'shared pages still pack');
    ok(joined($res->{json}) =~ /res-3/ && joined($res->{json}) !~ /res-1/,
        'last shared page is the message that did not fit');
    my $res1 = fcgi_do('/api/history?channel=zhc-res&page=1&lines=8');
    ok(joined($res1->{json}) =~ /res-1/ && joined($res1->{json}) =~ /res-2/
        && joined($res1->{json}) !~ /res-3/,
        'earlier page keeps the messages that fit together');
}

if ($pid) {
    kill 'KILL', $pid;
    waitpid($pid, 0);
    $pid = 0;
}
print $fail ? "FAIL $fail  pass $pass\n" : "PASS $pass\n";
exit($fail ? 1 : 0);
