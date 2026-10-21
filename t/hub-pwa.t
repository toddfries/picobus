#!/usr/bin/perl
# hub-pwa.t — install assets need no session, and both pages offer Install.
# usage: perl t/hub-pwa.t

use strict;
use warnings;
use FindBin;
use File::Temp qw(tempdir);
use IO::Socket::UNIX;
use JSON::PP qw(decode_json);

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $name) = @_;
    if ($cond) { $pass++; print "ok - $name\n" }
    else       { $fail++; print "NOT OK - $name\n" }
}

my $share = "$FindBin::Bin/../share";
my $dir   = tempdir(CLEANUP => 1);
my $hsock = "$dir/hub.sock";
my $fsock = "$dir/fcgi.sock";
$ENV{HUB_SOCK}       = $hsock;
$ENV{HUB_LOG}        = "$dir/hub.ndjson";
$ENV{FCGI_SOCK}      = $fsock;
$ENV{SHARE_DIR}      = $share;
$ENV{SETUP_FILE}     = "$dir/setup.json";
$ENV{SECRETS_DIR}    = "$dir/secrets";
$ENV{CHAT_LOG}       = "$dir/chat.ndjson";
$ENV{FILE_DIR}       = "$dir/files";
$ENV{ROSTER_FILE}    = "$dir/roster.json";
$ENV{PICOCLAW_HOME}  = "$dir/pico";
$ENV{PICOBUS_PRODUCT} = 'Daemon Crew';
$ENV{HUB_NOSANDBOX}  = 1;
delete $ENV{HUB_NOFCGI};
mkdir "$dir/pico", 0700;

my $pid = fork();
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    open STDOUT, '>', "$dir/hub.out";
    open STDERR, '>&STDOUT';
    exec $^X, "$FindBin::Bin/../bin/picobus" or exit 127;
}

my $up;
for (1 .. 50) {
    if (-S $fsock && -S $hsock) { $up = 1; last }
    select undef, undef, undef, 0.1;
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
    my ($method, $uri, $body) = @_;
    my $c = IO::Socket::UNIX->new(Peer => $fsock, Type => SOCK_STREAM)
        or return { err => "connect: $!" };
    $c->autoflush(1);
    $body //= '';
    my %env = (
        REQUEST_METHOD  => $method,
        REQUEST_URI     => $uri,
        SCRIPT_NAME     => $uri,
        DOCUMENT_URI    => $uri,
        QUERY_STRING    => '',
        CONTENT_LENGTH  => length($body),
        CONTENT_TYPE    => '',
        SERVER_PROTOCOL => 'HTTP/1.0',
    );
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
    my $ct = ($head // '') =~ /Content-Type:\s*([^\r\n]+)/i ? $1 : '';
    my $cc = ($head // '') =~ /Cache-Control:\s*([^\r\n]+)/i ? $1 : '';
    my $st = ($head // '') =~ /Status:\s*(\d+)/i ? $1 : '';
    return { status => $st, ctype => $ct, cache => $cc, body => $b };
}

sub png_size {
    my ($b) = @_;
    return () unless defined $b && $b =~ /^\x89PNG\r\n\x1a\n/;
    my ($len, $type) = unpack('Na4', substr($b, 8, 8));
    return () unless $type eq 'IHDR' && $len == 13;
    return unpack('NN', substr($b, 16, 8));
}

ok($up, 'hub listening');
if ($up) {
    my $man = fcgi_do('GET', '/manifest.webmanifest');
    ok($man->{status} eq '200', 'manifest is 200 with no session');
    ok($man->{ctype} eq 'application/manifest+json', 'manifest type');
    ok($man->{cache} =~ /no-store/, 'manifest is not stored');
    my $mj = eval { decode_json($man->{body}) } || {};
    ok($mj->{name} eq 'Daemon Crew', 'manifest name');
    ok($mj->{short_name} && length $mj->{short_name}, 'manifest short_name');
    ok($mj->{start_url} eq '/' && $mj->{scope} eq '/', 'start_url is inside scope');
    ok($mj->{display} eq 'standalone', 'display standalone');
    ok(!exists $mj->{prefer_related_applications}, 'no related-app preference');
    my @icons = @{ $mj->{icons} || [] };
    ok(@icons == 2, 'two icons');
    ok($icons[0]{src} eq '/icon-192.png' && $icons[0]{sizes} eq '192x192'
        && $icons[0]{type} eq 'image/png' && $icons[0]{purpose} eq 'any', '192 icon entry');
    ok($icons[1]{src} eq '/icon-512.png' && $icons[1]{sizes} eq '512x512'
        && $icons[1]{type} eq 'image/png' && $icons[1]{purpose} eq 'any', '512 icon entry');

    my $sw = fcgi_do('GET', '/sw.js');
    ok($sw->{status} eq '200', 'worker is 200 with no session');
    ok($sw->{ctype} eq 'text/javascript; charset=utf-8', 'worker type');
    ok($sw->{cache} =~ /no-store/, 'worker is not stored');
    ok($sw->{body} =~ /addEventListener\('fetch'/, 'worker has a fetch handler');
    ok($sw->{body} !~ /caches/, 'worker does not store pages');

    for my $n (192, 512) {
        my $ico = fcgi_do('GET', "/icon-$n.png");
        my ($w, $h) = png_size($ico->{body});
        ok($ico->{status} eq '200' && $ico->{ctype} eq 'image/png', "icon $n is a png");
        ok($ico->{cache} =~ /no-store/, "icon $n is not stored");
        ok($w == $n && $h == $n, "icon $n is ${n}x${n}");
    }

    my $page = fcgi_do('GET', '/');
    ok($page->{body} =~ m{rel="manifest" href="/manifest.webmanifest"}, 'account page links the manifest');
    ok($page->{body} =~ m{<button type="button" id="install" hidden>Install</button>}, 'account page hides Install');
    ok($page->{body} =~ m{serviceWorker\.register\('/sw\.js'\)}, 'account page registers the worker');

    open my $sf, '>', "$dir/setup.json" or die $!;
    print $sf '{"complete":true,"llm_key":"present"}';
    close $sf;
    my $again = fcgi_do('GET', '/manifest.webmanifest');
    ok($again->{status} eq '200', 'manifest stays open after an account exists');
    my $chat = fcgi_do('GET', '/');
    ok($chat->{body} =~ /id="install" hidden/, 'chat hides Install');
    my ($side) = $chat->{body} =~ m{<aside class="sidebar">(.*?)</aside>}s;
    ok(($side // '') =~ /id="install"/, 'Install sits with the account controls');
    my ($panes) = $chat->{body} =~ m{<div id="panes">(.*?)</div>}s;
    ok(($panes // '') !~ /install/, 'Install is outside the transcript');
}

if ($pid) {
    kill 'TERM', $pid;
    select undef, undef, undef, 0.2;
    kill 'KILL', $pid;
    waitpid($pid, 0);
}

print "$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
