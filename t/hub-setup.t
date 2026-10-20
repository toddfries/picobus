#!/usr/bin/perl
# hub-setup.t — first-run setup is JSON (never HTML) + official ALTCHA payload.
# usage: perl t/hub-setup.t

use strict;
use warnings;
use FindBin;
use File::Temp qw(tempdir);
use IO::Socket::UNIX;
use JSON::PP qw(encode_json decode_json);
use Digest::SHA qw(sha256_hex hmac_sha256_hex);
use MIME::Base64 qw(encode_base64 decode_base64);

my ($pass, $fail) = (0, 0);
sub ok {
    my ($cond, $name) = @_;
    if ($cond) { $pass++; print "ok - $name\n" }
    else       { $fail++; print "NOT OK - $name\n" }
}

my $share = "$FindBin::Bin/../share";
ok(-f "$share/setup.html", 'setup.html ships');
ok(-f "$share/shared/altcha-widget-v1.min.js", 'ALTCHA widget ships');
my $html = '';
if (open my $fh, '<', "$share/setup.html") { local $/; $html = <$fh>; close $fh }
ok($html =~ /altcha-widget/, 'signup HTML uses official ALTCHA widget');
ok($html =~ m{/shared/altcha-http-shim\.js}, 'HTTP shim loaded before widget');
ok($html =~ m{challengeurl="/api/setup/challenge"}, 'widget challengeurl is /api/setup/challenge');
ok($html !~ /Solve captcha/i, 'no homemade Solve captcha button');
ok($html =~ />Continue</, 'Continue CTA like ZHC');
ok($html =~ /Captain API key/, 'signup asks for a captain key');
ok($html =~ /OpenRouter management key/, 'signup asks for a management key');
ok($html !~ /name="key_mode"/, 'signup shows both key fields at once');

my $dir  = tempdir(CLEANUP => 1);
my $hsock = "$dir/hub.sock";
my $fsock = "$dir/fcgi.sock";
my $log   = "$dir/hub.ndjson";
$ENV{HUB_SOCK}     = $hsock;
$ENV{HUB_LOG}      = $log;
$ENV{FCGI_SOCK}    = $fsock;
$ENV{SHARE_DIR}    = $share;
$ENV{SETUP_FILE}   = "$dir/setup.json";
$ENV{SECRETS_DIR}  = "$dir/secrets";
$ENV{CHAT_LOG}     = "$dir/chat.ndjson";
$ENV{FILE_DIR}     = "$dir/files";
$ENV{ROSTER_FILE}  = "$dir/roster.json";
$ENV{PICOCLAW_HOME} = "$dir/pico";
mkdir "$dir/pico", 0700;
$ENV{HUB_NOSANDBOX} = 1;
delete $ENV{HUB_NOFCGI};

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
ok($up, 'hub listening on FCGI socket');

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
        REQUEST_METHOD => $method,
        REQUEST_URI    => $uri,
        SCRIPT_NAME    => '/index.html',
        DOCUMENT_URI   => '/index.html',
        QUERY_STRING   => $qs,
        CONTENT_LENGTH => length($body),
        CONTENT_TYPE   => $extra{ctype} // (length($body) ? 'application/json' : ''),
        SERVER_PROTOCOL => 'HTTP/1.0',
    );
    print $c fcgi_rec(1, 1, pack('nC', 1, 0) . ("\0" x 6)); # BEGIN
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
            $out .= $content if $type == 6; # STDOUT
            last if $type == 3;             # END_REQUEST
        }
        alarm 0;
    };
    alarm 0;
    close $c;
    my ($head, $b) = split /\r\n\r\n/, $out, 2;
    $b //= '';
    my $ct = ($head // '') =~ /Content-Type:\s*([^\r\n]+)/i ? $1 : '';
    my $st = ($head // '') =~ /Status:\s*(\d+)/i ? $1 : '';
    return { status => $st, ctype => $ct, head => $head // '', body => $b };
}

if ($up) {
    my $page = fcgi_do('GET', '/');
    ok($page->{ctype} =~ /html/i, 'GET / is HTML');
    ok($page->{body} =~ /altcha-widget/, 'GET / embeds ALTCHA widget');
    ok($page->{body} !~ /Solve captcha/i, 'GET / has no Solve captcha button');

    my $acct = fcgi_do('GET', '/account/');
    ok($acct->{body} =~ /altcha-widget/, 'GET /account/ is signup');

    my $ch = fcgi_do('GET', '/api/setup/challenge');
    ok($ch->{ctype} =~ /json/i, 'GET /api/setup/challenge is JSON');
    ok($ch->{body} !~ /<!DOCTYPE/i, 'challenge body is not HTML');
    my $chal = eval { decode_json($ch->{body}) } || {};
    ok($chal->{algorithm} && $chal->{algorithm} eq 'SHA-256', 'challenge algorithm SHA-256');
    ok($chal->{challenge} && length($chal->{challenge}) >= 40, 'challenge long enough for widget');
    ok($chal->{salt} && length($chal->{salt}) >= 10, 'salt long enough for widget');
    ok(defined $chal->{signature} && length $chal->{signature}, 'challenge has signature');
    ok(($chal->{maxnumber} || 0) >= 1000, 'maxnumber present');

    my $qch = fcgi_do('GET', '/?setup=challenge');
    my $qobj = eval { decode_json($qch->{body}) } || {};
    ok($qch->{ctype} =~ /json/i && $qobj->{challenge}, 'GET /?setup=challenge is JSON');

    my $miss = fcgi_do('GET', '/api/nope');
    ok($miss->{ctype} =~ /json/i, 'unknown /api/ is JSON');
    ok($miss->{body} !~ /<!DOCTYPE/i, 'unknown /api/ is not HTML');

    my $js = fcgi_do('GET', '/shared/altcha-widget-v1.min.js');
    ok($js->{ctype} =~ /javascript/i && $js->{body} =~ /altcha-widget/,
        'hub serves ALTCHA widget JS');

    # Solve like the widget: sha256(salt+n) == challenge, payload is base64 JSON.
    my $number;
    for my $n (0 .. ($chal->{maxnumber} || 100000)) {
        if (sha256_hex($chal->{salt} . $n) eq $chal->{challenge}) { $number = $n; last }
    }
    ok(defined $number, 'PoW solves against hub challenge');
    my $payload = encode_base64(encode_json({
        algorithm => $chal->{algorithm},
        challenge => $chal->{challenge},
        number    => $number,
        salt      => $chal->{salt},
        signature => $chal->{signature},
    }), '');
    my $none = fcgi_do('POST', '/api/setup', encode_json({
        user     => 'todd',
        password => 'hunter2x',
        llm_base => 'https://openrouter.ai/api/v1',
        altcha   => $payload,
    }));
    my $nonej = eval { decode_json($none->{body}) } || {};
    ok(($nonej->{error} // '') =~ /Captain API key or a management key required/,
        'signup requires a captain key or a management key');

    my $both = fcgi_do('POST', '/api/setup', encode_json({
        user     => 'todd',
        password => 'hunter2x',
        llm_base => 'https://openrouter.ai/api/v1',
        llm_key  => 'sk-or-test',
        mgmt_key => 'mgmt-marker-value',
        altcha   => $payload,
    }));
    my $bothj = eval { decode_json($both->{body}) } || {};
    ok($both->{ctype} =~ /json/i && !$bothj->{ok},
        'both keys do not finish until the other mates are allocated')
        or print "# both body=$both->{body}\n";
    ok(($bothj->{error} // '') !~ /mgmt-marker-value|sk-or-test/,
        'both-key failure does not echo either key');
    my $both_sec = '';
    if (open my $bs, '<', "$dir/secrets/security.yml") { local $/; $both_sec = <$bs>; close $bs }
    ok($both_sec =~ /openrouter-mgmt:/ && $both_sec =~ /mgmt-marker-value/
        && $both_sec =~ /sk-or-test/,
        'both keys are stored for the crew');
    my $both_home = '';
    if (open my $bh, '<', "$dir/pico/.security.yml") { local $/; $both_home = <$bh>; close $bh }
    ok($both_home =~ /sk-or-test/ && $both_home !~ /openrouter-mgmt:/,
        'captain home gets the captain key only');
    ok(!-f "$dir/setup.json", 'unfinished allocation does not complete setup');

    my $mgmt = fcgi_do('POST', '/api/setup', encode_json({
        user     => 'todd',
        password => 'hunter2x',
        llm_base => 'https://openrouter.ai/api/v1',
        key_mode => 'mgmt',
        mgmt_key => 'mgmt-marker-value',
        altcha   => $payload,
    }));
    my $mgmtj = eval { decode_json($mgmt->{body}) } || {};
    ok($mgmt->{ctype} =~ /json/i && !$mgmtj->{ok},
        'management signup does not finish without allocation')
        or print "# mgmt body=$mgmt->{body}\n";
    ok(($mgmtj->{error} // '') !~ /mgmt-marker-value/,
        'allocation failure does not echo the management key');
    my $sec = '';
    if (open my $sf, '<', "$dir/secrets/security.yml") { local $/; $sec = <$sf>; close $sf }
    ok($sec =~ /openrouter-mgmt:/ && $sec =~ /mgmt-marker-value/,
        'management key is stored for the crew');
    my $home_sec = '';
    if (open my $hf, '<', "$dir/pico/.security.yml") { local $/; $home_sec = <$hf>; close $hf }
    ok($home_sec !~ /mgmt-marker-value/,
        'management key is not written into the mate home');
    ok(!-f "$dir/setup.json", 'failed allocation does not complete setup');

    my $other = fcgi_do('POST', '/api/setup', encode_json({
        user     => 'todd',
        password => 'hunter2x',
        llm_base => 'https://llm.example/v1',
        key_mode => 'mgmt',
        mgmt_key => 'mgmt-marker-value',
        altcha   => $payload,
    }));
    my $otherj = eval { decode_json($other->{body}) } || {};
    ok(($otherj->{error} // '') =~ /another LLM URL/,
        'management key is only for OpenRouter');

    my $save = fcgi_do('POST', '/api/setup', encode_json({
        user     => 'todd',
        password => 'hunter2x',
        llm_base => 'https://openrouter.ai/api/v1',
        llm_key  => 'sk-or-test',
        altcha   => $payload,
    }));
    ok($save->{ctype} =~ /json/i, 'POST /api/setup is JSON');
    ok($save->{body} !~ /<!DOCTYPE/i, 'POST /api/setup is not HTML');
    my $sj = eval { decode_json($save->{body}) } || {};
    ok($sj->{ok}, 'POST /api/setup accepts official ALTCHA payload')
        or print "# save body=$save->{body}\n";
} else {
    ok(0, 'GET / HTML (skipped)');
    ok(0, 'widget (skipped)');
    ok(0, 'shim (skipped)');
    ok(0, 'no captcha button (skipped)');
    ok(0, '/account/ (skipped)');
    ok(0, 'challenge JSON (skipped)');
    ok(0, 'challenge not HTML (skipped)');
    ok(0, 'algorithm (skipped)');
    ok(0, 'challenge len (skipped)');
    ok(0, 'salt len (skipped)');
    ok(0, 'signature (skipped)');
    ok(0, 'maxnumber (skipped)');
    ok(0, 'query challenge (skipped)');
    ok(0, 'api 404 JSON (skipped)');
    ok(0, 'api 404 not HTML (skipped)');
    ok(0, 'widget JS (skipped)');
    ok(0, 'pow (skipped)');
    ok(0, 'neither key (skipped)');
    ok(0, 'both unfinished (skipped)');
    ok(0, 'both echo (skipped)');
    ok(0, 'both stored (skipped)');
    ok(0, 'captain home (skipped)');
    ok(0, 'save JSON (skipped)');
    ok(0, 'save not HTML (skipped)');
    ok(0, 'save ok (skipped)');
    if (open my $err, '<', "$dir/hub.out") {
        local $/;
        print "hub stderr: ", <$err> // '', "\n";
        close $err;
    }
}

if ($pid) {
    kill 'TERM', $pid;
    select undef, undef, undef, 0.2;
    kill 'KILL', $pid;
    waitpid($pid, 0);
}

# Continue used to SIGABRT the hub: chmod 0600 on secrets without pledge fattr.
if ($^O eq 'openbsd') {
    my $dir2  = tempdir(CLEANUP => 1);
    my $hs2   = "$dir2/hub.sock";
    my $fs2   = "$dir2/fcgi.sock";
    $ENV{HUB_SOCK}      = $hs2;
    $ENV{HUB_LOG}       = "$dir2/hub.ndjson";
    $ENV{FCGI_SOCK}     = $fs2;
    $ENV{SETUP_FILE}    = "$dir2/setup.json";
    $ENV{SECRETS_DIR}   = "$dir2/secrets";
    $ENV{CHAT_LOG}      = "$dir2/chat.ndjson";
    $ENV{FILE_DIR}      = "$dir2/files";
    $ENV{ROSTER_FILE}   = "$dir2/roster.json";
    $ENV{PICOCLAW_HOME} = "$dir2/pico";
    $ENV{SHARE_DIR}     = $share;
    delete $ENV{HUB_NOSANDBOX};
    mkdir "$dir2/secrets", 0700;
    mkdir "$dir2/pico", 0700;
    mkdir "$dir2/files", 0755;
    my $pid2 = fork();
    die "fork: $!" unless defined $pid2;
    if ($pid2 == 0) {
        open STDOUT, '>', "$dir2/hub.out";
        open STDERR, '>&STDOUT';
        exec $^X, "$FindBin::Bin/../bin/picobus" or exit 127;
    }
    my $up2;
    for (1 .. 50) {
        if (-S $fs2 && -S $hs2) { $up2 = 1; last }
        select undef, undef, undef, 0.1;
    }
    ok($up2, 'sandboxed hub listening for setup POST');
    if ($up2) {
        # fcgi_do still talks to $fsock from the first hub — rebind by
        # calling through a local copy of the path.
        my $old_fsock = $fsock;
        $fsock = $fs2;
        my $ch2 = fcgi_do('GET', '/api/setup/challenge');
        my $c2  = eval { decode_json($ch2->{body}) } || {};
        my $n2;
        for my $n (0 .. ($c2->{maxnumber} || 100000)) {
            if (sha256_hex(($c2->{salt} // '') . $n) eq ($c2->{challenge} // '')) {
                $n2 = $n; last;
            }
        }
        my $pl2 = encode_base64(encode_json({
            algorithm => $c2->{algorithm},
            challenge => $c2->{challenge},
            number    => $n2,
            salt      => $c2->{salt},
            signature => $c2->{signature},
        }), '');
        my $sv = fcgi_do('POST', '/api/setup', encode_json({
            user     => 'todd',
            password => 'hunter2x',
            llm_key  => 'sk-or-test',
            altcha   => $pl2,
        }));
        my $sj2 = eval { decode_json($sv->{body}) } || {};
        ok(kill(0, $pid2), 'chmod on secrets does not kill sandboxed hub');
        ok($sv->{ctype} =~ /json/i && $sj2->{ok},
            'sandboxed POST /api/setup returns JSON ok')
            or print "# sandbox save status=$sv->{status} body=$sv->{body}\n";
        $fsock = $old_fsock;
    } else {
        ok(0, 'hub alive after save (skipped)');
        ok(0, 'sandboxed save JSON (skipped)');
        if (open my $err, '<', "$dir2/hub.out") {
            local $/;
            print "sandbox hub stderr: ", <$err> // '', "\n";
            close $err;
        }
    }
    if ($pid2) {
        kill 'TERM', $pid2;
        select undef, undef, undef, 0.2;
        kill 'KILL', $pid2;
        waitpid($pid2, 0);
    }
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
