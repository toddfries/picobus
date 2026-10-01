#!/usr/bin/perl
# hub-dc-gate.t — /dc and /api/v1/dc/* require one ZHC session.
# usage: perl t/hub-dc-gate.t

use strict;
use warnings;
use FindBin;
use File::Temp qw(tempdir);
use IO::Socket::UNIX;
use JSON::PP qw(encode_json decode_json);
use DBI;

my ($pass, $fail) = (0, 0);
sub ok ($;$) {
    my ($cond, $name) = @_;
    $name //= '';
    if ($cond) { $pass++; print "ok - $name\n" }
    else       { $fail++; print "NOT OK - $name\n" }
    return $cond ? 1 : 0;
}

my $dir   = tempdir(CLEANUP => 1);
my $sprod = "$dir/sessions-prod";
my $sdev  = "$dir/sessions-dev";
my $sqa   = "$dir/sessions-qa";
my $db    = "$dir/users.sqlite";
my $hsock = "$dir/hub.sock";
my $fsock = "$dir/fcgi.sock";
for my $sd ($sprod, $sdev, $sqa) {
    mkdir $sd, 0700 or die "mkdir $sd: $!";
}

my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0 });
$dbh->do('CREATE TABLE zhc_users (id INTEGER PRIMARY KEY, email TEXT, email_verified INTEGER)');
$dbh->do('INSERT INTO zhc_users (id, email, email_verified) VALUES (1, ?, 1)', undef, 'todd@fdh.bz');
$dbh->do('INSERT INTO zhc_users (id, email, email_verified) VALUES (2, ?, 1)', undef, 'todd@fries.net');
$dbh->do('INSERT INTO zhc_users (id, email, email_verified) VALUES (3, ?, 0)', undef, 'todd@fdh.bz');
$dbh->disconnect;

sub php_s {
    my ($s) = @_;
    return 's:' . length($s) . ':"' . $s . '";';
}
sub write_sess {
    my ($sid, $body, $base) = @_;
    $base //= $sprod;
    open my $fh, '>', "$base/sess_$sid" or die $!;
    print $fh $body;
    close $fh;
}
write_sess('aaaaaaaaaaaaaaaa', 'zhc_user_id|i:1;');
write_sess('bbbbbbbbbbbbbbbb', 'zhc_user_id|i:2;');
write_sess('cccccccccccccccc', 'zhc_user_id|i:3;');
# Same shape as a live account cookie: product id, copied email, account id.
write_sess('dddddddddddddddd',
    'user_id|i:9;email|' . php_s('todd@fdh.bz')
    . 'display_name|' . php_s('Todd') . 'zhc_user_id|i:1;');
write_sess('eeeeeeeeeeeeeeee',
    'user_id|i:9;email|' . php_s('todd@fries.net')
    . 'display_name|' . php_s('Todd') . 'zhc_user_id|i:2;');
# Allowlisted id, but the copied email is the other account.
write_sess('ffffffffffffffff',
    'email|' . php_s('todd@fries.net') . 'zhc_user_id|i:1;');
# A string value that contains another account's id must not win.
my $bait = 'zhc_user_id|i:1;';
write_sess('gggggggggggggggg',
    'display_name|' . php_s($bait) . 'zhc_user_id|i:2;');
write_sess('hhhhhhhhhhhhhhhh',
    'zhc_user_id|i:1;zhc_new_tokens|a:1:{s:3:"api";s:3:"red";}');
# Same ids, other doors. A prod cookie must not open them.
write_sess('aaaaaaaaaaaaaaaa', 'zhc_user_id|i:1;', $sdev);
write_sess('bbbbbbbbbbbbbbbb', 'zhc_user_id|i:2;', $sdev);
write_sess('aaaaaaaaaaaaaaaa', 'zhc_user_id|i:1;', $sqa);
write_sess('bbbbbbbbbbbbbbbb', 'zhc_user_id|i:2;', $sqa);

$ENV{HUB_SOCK}                 = $hsock;
$ENV{HUB_LOG}                  = "$dir/hub.ndjson";
$ENV{FCGI_SOCK}                = $fsock;
$ENV{CHAT_LOG}                 = "$dir/chat.ndjson";
$ENV{FILE_DIR}                 = "$dir/files";
$ENV{SETUP_FILE}               = "$dir/setup.json";
$ENV{SECRETS_DIR}              = "$dir/secrets";
$ENV{ROSTER_FILE}              = "$dir/roster.json";
$ENV{PICOCLAW_HOME}            = "$dir/pico";
$ENV{HUB_NOSANDBOX}            = 1;
$ENV{PICOBUS_ZHC_GATE}         = 1;
$ENV{PICOBUS_ZHC_EMAIL}        = 'todd@fdh.bz';
$ENV{PICOBUS_ZHC_COOKIE}       = 'ZHCSESS_PROD';
$ENV{PICOBUS_ZHC_SESSION_DIR}  = $sprod;
$ENV{PICOBUS_ZHC_DB}           = $db;
delete $ENV{HUB_NOFCGI};
delete $ENV{PICOBUS_FCGI_GROUP};

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
ok($up, 'gated hub listening');

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
    return { status => $st, head => $head // '', body => $b };
}

my $fdh   = 'ZHCSESS_PROD=aaaaaaaaaaaaaaaa';
my $fries = 'ZHCSESS_PROD=bbbbbbbbbbbbbbbb';
my $unv   = 'ZHCSESS_PROD=cccccccccccccccc';

if ($up) {
    my $anon = fcgi_do('GET', '/dc/');
    ok($anon->{status} eq '401', 'unsigned /dc/ is 401');
    ok($anon->{body} =~ m{href="/account/"}, 'prod sign-in link');
    ok($anon->{body} !~ m{href="/dev/account/"}, 'prod sign-in is not the dev door');
    ok($anon->{body} =~ /Sign in required/, 'unsigned page says sign in');
    ok($anon->{body} !~ /zhc-ops|altcha|llm_key/i, 'unsigned page has no transcript or setup');
    ok($anon->{head} =~ /X-Frame-Options: DENY/i, 'unsigned page denies frames');

    my $api = fcgi_do('GET', '/api/v1/dc/state');
    ok($api->{status} eq '401', 'unsigned state is 401');
    my $aj = eval { decode_json($api->{body}) } || {};
    ok($aj->{error} && $aj->{error} eq 'sign in required', 'unsigned state JSON');
    ok($api->{body} !~ /<!DOCTYPE/, 'unsigned state is not HTML');

    my $bad = fcgi_do('GET', '/api/v1/dc/state', '', cookie => 'ZHCSESS_PROD=../../../../etc/passwd');
    ok($bad->{status} eq '401', 'path-like session id is 401');

    my $other = fcgi_do('GET', '/api/v1/dc/state', '', cookie => $fries);
    ok($other->{status} eq '403', 'other verified account is 403');
    my $uv = fcgi_do('GET', '/dc/', '', cookie => $unv);
    ok($uv->{status} eq '403', 'unverified same address is 403');

    my $live_fries = fcgi_do('GET', '/dc/', '', cookie => 'ZHCSESS_PROD=eeeeeeeeeeeeeeee');
    ok($live_fries->{status} eq '403', 'real-shaped other account is 403');
    my $mismatch = fcgi_do('GET', '/api/v1/dc/state', '', cookie => 'ZHCSESS_PROD=ffffffffffffffff');
    ok($mismatch->{status} eq '403', 'allowlisted id with the other email is 403');
    my $bait = fcgi_do('GET', '/api/v1/dc/state', '', cookie => 'ZHCSESS_PROD=gggggggggggggggg');
    ok($bait->{status} eq '403', 'id planted in a string does not authorize');
    my $both = fcgi_do('GET', '/dc/', '',
        cookie => 'ZHCSESS_PROD=aaaaaaaaaaaaaaaa; ZHCSESS_PROD=bbbbbbbbbbbbbbbb');
    ok($both->{status} eq '403', 'allowlisted cookie beside another sign-in is 403');
    my $badboth = fcgi_do('GET', '/api/v1/dc/state', '',
        cookie => 'ZHCSESS_PROD=aaaaaaaaaaaaaaaa; ZHCSESS_PROD=short');
    ok($badboth->{status} eq '401', 'malformed second cookie is 401');

    my $page = fcgi_do('GET', '/dc/', '', cookie => $fdh);
    ok($page->{status} eq '200', 'allowlisted /dc/ is 200');
    ok($page->{body} =~ /function bootOut/, 'open page leaves on 401 or 403');
    ok($page->{body} =~ m{/api/v1/dc/state}, 'page polls /api/v1/dc/state');
    ok($page->{body} =~ /compose-hint/, 'composer explains #system');
    ok($page->{body} !~ /altcha|llm_key/i, 'allowlisted page is not the setup form');
    ok($page->{body} =~ m{/dc/chrome\.js}, 'page loads its own chrome script');
    ok($page->{body} =~ m{/dc/chrome\.css}, 'page loads its own chrome css');
    ok($page->{body} =~ /ZHCTHEME_/, 'page boots the site theme cookie');
    ok($page->{body} !~ m{/shared/zhc-prefs}, 'page does not reach around for site chrome');
    ok($anon->{body} !~ m{zhc-services-menu|/dc/chrome}, 'status page has no chrome');

    my $js = fcgi_do('GET', '/dc/chrome.js', '', cookie => $fdh);
    ok($js->{status} eq '200', 'chrome script is 200')
        or print "# chrome status=$js->{status}\n";
    ok(scalar($js->{body} =~ /ZHCTHEME_/), 'chrome script uses the site theme cookie');
    ok(scalar($js->{body} =~ m{pre \+ '/dc/'}), 'catalog link follows the bucket');
    ok(scalar($js->{body} =~ m{/dc/icons/}) && scalar($js->{body} =~ /menu\.svg/), 'chrome script pulls the menu icon');
    ok(scalar($js->{head} =~ m{text/javascript}i), 'chrome script content type');
    my $css = fcgi_do('GET', '/dc/chrome.css', '', cookie => $fdh);
    ok($css->{status} eq '200' && scalar($css->{body} =~ /zhc-cookie-tray/), 'chrome css has the tray');
    my $ico = fcgi_do('GET', '/dc/icons/menu.svg', '', cookie => $fdh);
    ok($ico->{status} eq '200' && scalar($ico->{body} =~ /<svg\b/), 'menu icon is svg');
    ok(scalar($ico->{head} =~ m{image/svg\+xml}i), 'menu icon content type');
    for my $name (qw(theme-light.svg theme-dark.svg theme-system.svg cookie.svg terms.svg privacy.svg)) {
        my $one = fcgi_do('GET', "/dc/icons/$name", '', cookie => $fdh);
        ok($one->{status} eq '200' && scalar($one->{body} =~ /<svg\b/), "icon $name");
    }
    my $trav = fcgi_do('GET', '/dc/icons/../chrome.js', '', cookie => $fdh);
    ok($trav->{status} eq '404', 'icon traversal is 404');
    my $badico = fcgi_do('GET', '/dc/icons/menu.svg.txt', '', cookie => $fdh);
    ok($badico->{status} eq '404', 'odd icon name is 404');
    my $nojs = fcgi_do('GET', '/dc/chrome.js');
    ok($nojs->{status} eq '401', 'unsigned chrome script is 401');
    my $frjs = fcgi_do('GET', '/dc/chrome.js', '', cookie => $fries);
    ok($frjs->{status} eq '403', 'other account chrome script is 403');

    my $root = fcgi_do('GET', '/', '', cookie => $fdh);
    ok($root->{status} eq '404', 'gate does not serve /');
    my $setup = fcgi_do('GET', '/api/setup/challenge', '', cookie => $fdh);
    ok($setup->{status} eq '404', 'setup API is not published');
    ok(($setup->{body} // '') !~ /altcha|challenge/i, 'setup 404 is not a challenge');

    my $shaped = fcgi_do('GET', '/dc/', '', cookie => 'ZHCSESS_PROD=dddddddddddddddd');
    ok($shaped->{status} eq '200', 'real-shaped allowlisted session is 200');
    my $dup = fcgi_do('GET', '/api/v1/dc/state', '',
        cookie => 'ZHCSESS_PROD=aaaaaaaaaaaaaaaa; ZHCSESS_PROD=aaaaaaaaaaaaaaaa');
    ok($dup->{status} eq '200', 'the same allowlisted cookie twice is 200');
    my $tokens = fcgi_do('GET', '/api/v1/dc/state', '', cookie => 'ZHCSESS_PROD=hhhhhhhhhhhhhhhh');
    ok($tokens->{status} eq '200', 'session with an array value still allows');

    my $dev_admin = 'ZHCSESS_DEV=aaaaaaaaaaaaaaaa';
    my $dev_other = 'ZHCSESS_DEV=bbbbbbbbbbbbbbbb';
    my $qa_admin  = 'ZHCSESS_QA=aaaaaaaaaaaaaaaa';
    my $qa_other  = 'ZHCSESS_QA=bbbbbbbbbbbbbbbb';

    my $dev_anon = fcgi_do('GET', '/dev/dc/');
    ok($dev_anon->{status} eq '401', 'unsigned /dev/dc/ is 401');
    ok($dev_anon->{body} =~ m{href="/dev/account/"}, 'dev sign-in link');
    my $dev_api = fcgi_do('GET', '/dev/api/v1/dc/state');
    ok($dev_api->{status} eq '401', 'unsigned /dev/api/v1/dc/state is 401');
    my $qa_anon = fcgi_do('GET', '/qa/dc/');
    ok($qa_anon->{status} eq '401', 'unsigned /qa/dc/ is 401');
    ok($qa_anon->{body} =~ m{href="/qa/account/"}, 'qa sign-in link');
    my $qa_api = fcgi_do('GET', '/qa/api/v1/dc/state');
    ok($qa_api->{status} eq '401', 'unsigned /qa/api/v1/dc/state is 401');

    my $prod_on_dev = fcgi_do('GET', '/dev/dc/', '', cookie => $fdh);
    ok($prod_on_dev->{status} eq '401', 'prod cookie does not open /dev/dc');
    my $dev_on_prod = fcgi_do('GET', '/dc/', '', cookie => $dev_admin);
    ok($dev_on_prod->{status} eq '401', 'dev cookie does not open /dc');
    my $dev_forbid = fcgi_do('GET', '/dev/api/v1/dc/state', '', cookie => $dev_other);
    ok($dev_forbid->{status} eq '403', 'other account on /dev/dc is 403');
    my $qa_forbid = fcgi_do('GET', '/qa/dc/', '', cookie => $qa_other);
    ok($qa_forbid->{status} eq '403', 'other account on /qa/dc is 403');

    my $mixed_no = fcgi_do('GET', '/dev/dc/', '', cookie => "$fdh; $dev_other");
    ok($mixed_no->{status} eq '403', 'dev door ignores a prod admin cookie beside a non-admin');
    my $mixed_yes = fcgi_do('GET', '/dev/api/v1/dc/state', '', cookie => "$fries; $dev_admin");
    ok($mixed_yes->{status} eq '200', 'dev door uses the dev admin cookie, not the prod one');

    my $dev_page = fcgi_do('GET', '/dev/dc/', '', cookie => $dev_admin);
    ok($dev_page->{status} eq '200', 'admin /dev/dc/ is 200');
    ok($dev_page->{body} =~ m{/dev/api/v1/dc/state}, 'dev page polls the dev API');
    ok($dev_page->{body} =~ m{/dev/dc/chrome\.js}, 'dev page loads dev chrome');
    # The crew page puts the link in a JS string, so the quotes are escaped.
    ok($dev_page->{body} =~ m{/dev/account/}, 'dev page sign-in link');
    ok($dev_page->{body} !~ m{href=\\"/account/"}, 'dev page does not link the prod sign-in');
    my $qa_page = fcgi_do('GET', '/qa/dc/', '', cookie => $qa_admin);
    ok($qa_page->{status} eq '200', 'admin /qa/dc/ is 200');
    ok($qa_page->{body} =~ m{/qa/api/v1/dc/state}, 'qa page polls the qa API');
    ok($qa_page->{body} =~ m{/qa/dc/chrome\.js}, 'qa page loads qa chrome');

    my $st = fcgi_do('GET', '/api/v1/dc/state', '', cookie => $fdh);
    my $sj = eval { decode_json($st->{body}) } || {};
    ok($st->{status} eq '200' && ref($sj->{agents}) eq 'ARRAY', 'allowlisted state JSON');

    my $rx = IO::Socket::UNIX->new(Peer => $hsock, Type => SOCK_STREAM);
    ok($rx, 'agent socket');
    if ($rx) {
        $rx->autoflush(1);
        print $rx encode_json({ type => 'register', id => 'zhc' }), "\n";
        select undef, undef, undef, 0.2;
        my $no = fcgi_do('POST', '/api/v1/dc/send',
            encode_json({ to => 'all', content => 'nope-all' }),
            cookie => $fdh);
        ok($no->{status} eq '400', 'to=all is refused')
            or print "# all status=$no->{status} body=$no->{body}\n";
        my $yes = fcgi_do('POST', '/api/v1/dc/send',
            encode_json({ to => 'zhc', content => 'hello captain' }),
            cookie => $fdh);
        ok($yes->{status} eq '200', 'send to a live berth is 200')
            or print "# send status=$yes->{status} body=$yes->{body}\n";
        my $devyes = fcgi_do('POST', '/dev/api/v1/dc/send',
            encode_json({ to => 'zhc', content => 'hello from dev' }),
            cookie => 'ZHCSESS_DEV=aaaaaaaaaaaaaaaa');
        ok($devyes->{status} eq '200', 'dev send to a live berth is 200')
            or print "# dev send status=$devyes->{status} body=$devyes->{body}\n";
        my $saw = 0;
        my $saw_dev = 0;
        my $saw_all = 0;
        eval {
            local $SIG{ALRM} = sub { die "timeout" };
            alarm 2;
            while (my $line = <$rx>) {
                $saw_all = 1 if $line =~ /nope-all/;
                $saw = 1 if $line =~ /hello captain/;
                $saw_dev = 1 if $line =~ /hello from dev/;
                last if $saw && $saw_dev;
            }
            alarm 0;
        };
        alarm 0;
        ok($saw && $saw_dev && !$saw_all, 'berth got prod and dev lines and not the all-send');
    } else {
        ok(0, 'to=all refused');
        ok(0, 'send 200');
        ok(0, 'dev send 200');
        ok(0, 'berth received');
    }

    my $upl = fcgi_do('POST', '/api/v1/dc/files?name=note.txt', 'hello-file',
        ctype => 'text/plain', cookie => $fdh);
    my $uj = eval { decode_json($upl->{body}) } || {};
    ok($upl->{status} eq '200' && $uj->{id}, 'allowlisted upload')
        or print "# upload status=$upl->{status} body=$upl->{body}\n";
    ok((($uj->{url} // '') =~ m{^/api/v1/dc/files/} ? 1 : 0), 'upload url stays under /api/v1/dc');
    if ($uj->{id}) {
        my $hid = fcgi_do('GET', "/api/v1/dc/files/$uj->{id}");
        ok($hid->{status} eq '401', 'unsigned download is 401');
        my $nope = fcgi_do('GET', "/api/v1/dc/files/$uj->{id}", '', cookie => $fries);
        ok($nope->{status} eq '403', 'other account download is 403');
        my $got = fcgi_do('GET', "/api/v1/dc/files/$uj->{id}", '', cookie => $fdh);
        ok($got->{status} eq '200' && $got->{body} eq 'hello-file', 'allowlisted download');
    } else {
        ok(0, 'unsigned download');
        ok(0, 'other download');
        ok(0, 'allowlisted download');
    }
} else {
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

print $fail ? "FAIL $fail  pass $pass\n" : "PASS $pass\n";
exit($fail ? 1 : 0);
