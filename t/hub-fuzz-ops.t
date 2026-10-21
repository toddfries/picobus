#!/usr/bin/perl
# hub-fuzz-ops.t — blank lines, self-address, a second account, channel
# history, a roster helper that is down, a too-long alias, and grant bits.
# usage: perl t/hub-fuzz-ops.t

use strict;
use warnings;
$| = 1;
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

sub bcrypt_hash {
    my ($pw) = @_;
    my @c = ('.', '/', 0 .. 9, 'A' .. 'Z', 'a' .. 'z');
    my $salt = join '', map { $c[ int rand @c ] } 1 .. 22;
    return crypt($pw, '$2b$10$' . $salt);
}

my $dir   = tempdir(CLEANUP => 1);
my $hsock = "$dir/hub.sock";
my $fsock = "$dir/fcgi.sock";
my $log   = "$dir/hub.ndjson";
my $chat  = "$dir/chat.ndjson";
my $ada_pw = 'manager-pass-1';

open my $blocked, '>', "$dir/blocked" or die $!;
print $blocked "not-a-directory\n";
close $blocked;

sub row {
    my ($from, $to, $content) = @_;
    return {
        type => 'message', from => $from, to => $to,
        content => $content, ts => '2026-10-20T00:00:00Z',
    };
}
open my $cf, '>', $chat or die $!;
print $cf encode_json(row('lab', 'all', 'BROADCAST-LEAK')), "\n";
print $cf encode_json(row('lab', 'human', 'DIRECT-LINE')), "\n";
print $cf encode_json(row('chief', 'lab', 'MATE-LINE')), "\n";
close $cf;

open my $sf, '>', "$dir/setup.json" or die $!;
print $sf encode_json({
    complete  => JSON::PP::true,
    user      => 'ada',
    pass_hash => bcrypt_hash($ada_pw),
    llm_key   => JSON::PP::true,
});
close $sf;

$ENV{HUB_SOCK}        = $hsock;
$ENV{HUB_LOG}         = $log;
$ENV{CHAT_LOG}        = $chat;
$ENV{FCGI_SOCK}       = $fsock;
$ENV{SETUP_FILE}      = "$dir/setup.json";
$ENV{SECRETS_DIR}     = "$dir/secrets";
$ENV{FILE_DIR}        = "$dir/files";
$ENV{PICOCLAW_HOME}   = "$dir/pico";
$ENV{PRINCIPALS_FILE} = "$dir/principals.json";
$ENV{GRANTS_FILE}     = "$dir/grants.json";
$ENV{SESSIONS_FILE}   = "$dir/sessions.json";
$ENV{CREW_QUEUE}      = "$dir/blocked";
$ENV{HUB_NOSANDBOX}   = 1;
delete $ENV{HUB_NOFCGI};
delete $ENV{PICOBUS_ZHC_GATE};
delete $ENV{HUB_BROADCAST};

my $pid = fork();
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    open STDIN,  '<', '/dev/null';
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
    my ($method, $uri, $body, %extra) = @_;
    my $c = IO::Socket::UNIX->new(Peer => $fsock, Type => SOCK_STREAM)
        or return { err => "connect: $!" };
    $c->autoflush(1);
    my ($path, $qs) = split /\?/, $uri, 2;
    $qs //= '';
    $body //= '';
    my %env = (
        REQUEST_METHOD  => $method,
        REQUEST_URI     => $uri,
        SCRIPT_NAME     => $path,
        QUERY_STRING    => $qs,
        CONTENT_LENGTH  => length($body),
        CONTENT_TYPE    => $extra{ctype} // (length($body) ? 'application/json' : ''),
        SERVER_PROTOCOL => 'HTTP/1.0',
    );
    $env{HTTP_COOKIE} = $extra{cookie} if defined $extra{cookie};
    print $c fcgi_rec(1, 1, pack('nC', 1, 0) . ("\0" x 6));
    my $params = '';
    $params .= fcgi_nv($_, $env{$_}) for sort keys %env;
    print $c fcgi_rec(4, 1, $params);
    print $c fcgi_rec(4, 1, '');
    print $c fcgi_rec(5, 1, $body);
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
    my $ck = ($head // '') =~ /Set-Cookie:\s*([^\r\n]+)/i ? $1 : '';
    return { status => $st, body => $b, cookie => $ck, json => eval { decode_json($b) } || {} };
}

sub slurp {
    my ($path) = @_;
    return '' unless -f $path;
    open my $fh, '<', $path or return '';
    local $/;
    my $raw = <$fh> // '';
    close $fh;
    return $raw;
}

sub joined {
    my ($h) = @_;
    return join "\n", map { $_->{content} // '' } @{ $h->{messages} || [] };
}

sub sess_of {
    my ($ck) = @_;
    return '' unless defined $ck && $ck =~ /PICOBUS_SESS=([^;]+)/;
    return "PICOBUS_SESS=$1";
}

sub connect_hub {
    my $c = IO::Socket::UNIX->new(Peer => $hsock, Type => SOCK_STREAM)
        or die "connect: $!";
    $c->autoflush(1);
    return $c;
}

sub read_until {
    my ($fh, $re, $secs) = @_;
    my $got = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm($secs // 1);
        while (my $line = <$fh>) {
            $got .= $line;
            last if $line =~ $re;
        }
        alarm 0;
    };
    alarm 0;
    return $got;
}

my $ada_ck = '';
if ($up) {
    my $login = fcgi_do('POST', '/api/login', encode_json({ user => 'ada', password => $ada_pw }));
    $ada_ck = sess_of($login->{cookie});
    ok($login->{status} eq '200' && $ada_ck ne '', 'captain account signs in');

    my $lab_hist = fcgi_do('GET', '/api/history?channel=lab&page=last&lines=40', '', cookie => $ada_ck);
    my $lab_body = joined($lab_hist->{json});
    ok($lab_hist->{status} eq '200'
        && $lab_body =~ /DIRECT-LINE/ && $lab_body =~ /MATE-LINE/
        && $lab_body !~ /BROADCAST-LEAK/,
        'a mate channel hides a broadcast');

    my $sys = fcgi_do('GET', '/api/history?channel=all&page=last&lines=40', '', cookie => $ada_ck);
    my $sys_body = joined($sys->{json});
    ok($sys->{status} eq '200'
        && $sys_body =~ /BROADCAST-LEAK/
        && $sys_body !~ /DIRECT-LINE/ && $sys_body !~ /MATE-LINE/,
        '#system hides a direct line');

    my $blank = fcgi_do('POST', '/api/send', encode_json({ to => 'lab', content => "  \n\t  " }), cookie => $ada_ck);
    ok($blank->{status} eq '400', 'whitespace content is refused on send');
    my $empty = fcgi_do('POST', '/api/send', encode_json({ to => 'lab', content => '' }), cookie => $ada_ck);
    ok($empty->{status} eq '400', 'empty content is refused on send');
}

my $mate_got = 0;
my $self_got = 0;
my $unknown = '';
my $human_err = '';
my $from_seen = '';
if ($up) {
    my $cal = fcgi_do('POST', '/api/users', encode_json({
        id => 'cal', password => 'worker-pass-11', role => 'worker',
    }), cookie => $ada_ck);
    ok($cal->{status} eq '200', 'a second human account exists');

    my $lab = connect_hub();
    my $chief = connect_hub();
    print $lab encode_json({ type => 'register', id => 'lab' }), "\n";
    print $chief encode_json({ type => 'register', id => 'chief' }), "\n";
    select undef, undef, undef, 0.2;

    print $lab encode_json({
        type => 'message', from => 'lab', to => 'chief', content => 'MATE-TALK',
    }), "\n";
    my $heard = read_until($chief, qr/MATE-TALK/, 3);
    $mate_got = $heard =~ /MATE-TALK/ ? 1 : 0;
    ok($mate_got, 'a mate-to-mate line is delivered');

    print $lab encode_json({
        type => 'message', from => 'lab', to => 'human', content => 'FOR-OPERATOR',
    }), "\n";
    my $op_echo = read_until($chief, qr/FOR-OPERATOR|unknown target/, 1);
    ok($op_echo !~ /FOR-OPERATOR/, 'a line to the operator is not handed to another mate');

    print $lab encode_json({
        type => 'message', from => 'human', to => 'lab', content => 'FROM-PLACEHOLDER',
    }), "\n";
    select undef, undef, undef, 0.4;
    for my $line (split /\n/, slurp($log)) {
        my $o = eval { decode_json($line) } or next;
        next unless ($o->{content} // '') eq 'FROM-PLACEHOLDER';
        $from_seen = $o->{from} // '';
    }
    ok($from_seen eq 'ada', 'the placeholder human is the captain, not the second account');

    print $lab encode_json({
        type => 'message', from => 'lab', to => 'cal', content => 'TO-SECOND',
    }), "\n";
    my $miss = read_until($lab, qr/unknown target/, 3);
    $unknown = $miss =~ /unknown target cal/ ? 'cal' : '';
    ok($unknown eq 'cal', 'the second account is not a berth');

    print $lab encode_json({
        type => 'message', from => 'lab', to => 'human', content => 'STILL-OPERATOR',
    }), "\n";
    my $still = read_until($lab, qr/unknown target/, 1);
    $human_err = $still =~ /unknown target/ ? 'yes' : '';
    ok($human_err eq '', 'the placeholder is still the operator after a second account');

    print $lab encode_json({
        type => 'message', from => 'lab', to => 'nobody-here', content => 'MISS',
    }), "\n";
    my $unk = read_until($lab, qr/unknown target nobody-here/, 3);
    ok($unk =~ /unknown target nobody-here/, 'an unknown target is reported to the sender');

    print $lab encode_json({
        type => 'message', from => 'lab', to => 'lab', content => 'SELF-LINE',
    }), "\n";
    my $self = read_until($lab, qr/SELF-LINE/, 1);
    $self_got = $self =~ /SELF-LINE/ ? 1 : 0;
    ok(!$self_got, 'a message whose to is the sender is not handed back');

    print $lab encode_json({
        type => 'message', from => 'lab', to => 'chief', content => '   ',
    }), "\n";
    print $lab encode_json({
        type => 'message', from => 'lab', to => 'chief', content => '',
    }), "\n";
    my $blank_rx = read_until($chief, qr/^\s*$|"content":"\s*"/, 1);
    ok($blank_rx !~ /"content":""/ && $blank_rx !~ /"content":"   "/,
        'empty and whitespace mate lines are not delivered');

    print $chief encode_json({
        type => 'roster', op => 'add', alias => 'brp', work => 'desk', to => 'human',
    }), "\n";
    select undef, undef, undef, 0.4;
    my $down = slurp($log);
    ok($down =~ /the roster did not answer/i, 'a down roster helper is told as the roster');
    ok($down !~ /queue unavailable/ && $down !~ /crew helper/ && $down !~ /\[\[roster/,
        'the down-roster reply does not name the helper or the marker');

    my $before = slurp($log);
    print $chief encode_json({
        type => 'roster', op => 'add',
        alias => 'abcdefghijklmnopq', work => '', to => 'human',
    }), "\n";
    select undef, undef, undef, 0.4;
    my $long = slurp($log);
    my @reqs = glob("$dir/blocked/*.req");
    ok($long eq $before, 'an alias longer than 16 characters is not filed');
    ok(!@reqs, 'a too-long alias does not write a roster request');
    ok($long !~ /\[\[roster/, 'a too-long alias does not log the marker');

    close $lab;
    close $chief;
} else {
    ok(0, 'sign-in (skipped)');
    ok(0, 'mate history (skipped)');
    ok(0, 'system history (skipped)');
    ok(0, 'whitespace send (skipped)');
    ok(0, 'empty send (skipped)');
    ok(0, 'second account (skipped)');
    ok(0, 'mate line (skipped)');
    ok(0, 'operator line (skipped)');
    ok(0, 'placeholder (skipped)');
    ok(0, 'second berth (skipped)');
    ok(0, 'placeholder stays (skipped)');
    ok(0, 'unknown target (skipped)');
    ok(0, 'self (skipped)');
    ok(0, 'blank deliver (skipped)');
    ok(0, 'roster words (skipped)');
    ok(0, 'roster marker (skipped)');
    ok(0, 'long alias (skipped)');
    ok(0, 'long req (skipped)');
    ok(0, 'long marker (skipped)');
}

if ($up && $ada_ck ne '') {
    my $bad = fcgi_do('POST', '/api/grants', encode_json({
        user => 'cal', channel => 'meal', read => 2, write => 0,
    }), cookie => $ada_ck);
    ok($bad->{status} eq '400', 'a grant bit other than 0 or 1 is refused');
    my $cal_login = fcgi_do('POST', '/api/login', encode_json({
        user => 'cal', password => 'worker-pass-11',
    }));
    my $cal_ck = sess_of($cal_login->{cookie});
    my $hist = fcgi_do('GET', '/api/history?channel=meal', '', cookie => $cal_ck);
    ok($hist->{status} eq '404', 'a refused odd grant does not open the channel');

    my $okg = fcgi_do('POST', '/api/grants', encode_json({
        user => 'cal', channel => 'meal', read => 1, write => 0,
    }), cookie => $ada_ck);
    ok($okg->{status} eq '200' && $okg->{json}{ok}, 'grant bits 0 and 1 still apply');
    my $opened = fcgi_do('GET', '/api/history?channel=meal', '', cookie => $cal_ck);
    ok($opened->{status} eq '200', 'a 0/1 grant opens the channel');
}

my $logged = slurp($log) . slurp($chat);
ok($logged !~ /SELF-LINE/ ? 0 : 1, 'a self-addressed line is still in the chat log');
ok($logged !~ /"content":""/ && $logged !~ /"content":"   "/ && $logged !~ /"content":"  \\n\\t  "/,
    'empty and whitespace lines are not in the chat log');

if ($pid) {
    kill 'KILL', $pid;
    waitpid($pid, 0);
    $pid = 0;
}

print "$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
