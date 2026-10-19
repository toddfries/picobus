#!/usr/bin/perl
# hub-acl.t — sessions, worker/coworker/manager grants, reserved child role.
# usage: perl t/hub-acl.t

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
my $ada_pw = 'manager-pass-1';
{
    open my $fh, '>', "$dir/setup.json" or die $!;
    print $fh encode_json({
        complete  => JSON::PP::true,
        user      => 'ada',
        pass_hash => bcrypt_hash($ada_pw),
        llm_key   => JSON::PP::true,
    });
    close $fh;
}

$ENV{HUB_SOCK}       = $hsock;
$ENV{HUB_LOG}        = $log;
$ENV{FCGI_SOCK}      = $fsock;
$ENV{SETUP_FILE}     = "$dir/setup.json";
$ENV{SECRETS_DIR}    = "$dir/secrets";
$ENV{CHAT_LOG}       = "$dir/chat.ndjson";
$ENV{FILE_DIR}       = "$dir/files";
$ENV{PICOCLAW_HOME}  = "$dir/pico";
$ENV{HUB_NOSANDBOX}  = 1;
$ENV{PICOBUS_UID_MAP} = "$dir/uid-map.json";
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
        REQUEST_METHOD => $method,
        REQUEST_URI    => $uri,
        SCRIPT_NAME    => $path,
        QUERY_STRING   => $qs,
        CONTENT_LENGTH => length($body),
        CONTENT_TYPE   => $extra{ctype} // (length($body) ? 'application/json' : ''),
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
    my $ct = ($head // '') =~ /Content-Type:\s*([^\r\n]+)/i ? $1 : '';
    my $st = ($head // '') =~ /Status:\s*(\d+)/i ? $1 : '';
    my $ck = ($head // '') =~ /Set-Cookie:\s*([^\r\n]+)/i ? $1 : '';
    return { status => $st, ctype => $ct, head => $head // '', body => $b, cookie => $ck };
}

sub jdo {
    my ($method, $uri, $obj, $cookie) = @_;
    my $res = fcgi_do($method, $uri, defined $obj ? encode_json($obj) : '', cookie => $cookie);
    my $j = eval { decode_json($res->{body}) } || {};
    $res->{json} = $j;
    return $res;
}

sub sess_of {
    my ($ck) = @_;
    return '' unless $ck =~ /PICOBUS_SESS=([^;]+)/;
    return "PICOBUS_SESS=$1";
}

if ($up) {
    my $anon = jdo('GET', '/api/history?channel=meal');
    ok($anon->{status} eq '401', 'history without a cookie is 401');
    my $anon_send = jdo('POST', '/api/send', { to => 'meal', content => 'nope' });
    ok($anon_send->{status} eq '401', 'send without a cookie is 401');

    my $bad = jdo('POST', '/api/login', { user => 'ada', password => 'nope-nope' });
    ok($bad->{status} eq '401', 'bad password is 401');

    my $ada = jdo('POST', '/api/login', { user => 'ada', password => $ada_pw });
    ok($ada->{status} eq '200' && $ada->{json}{user}{role} eq 'manager',
        'setup account logs in as manager');
    my $ada_ck = sess_of($ada->{cookie});
    ok($ada_ck ne '', 'login sets a session cookie');

    my $child = jdo('POST', '/api/users', { id => 'kid', password => 'kid-pass-1', role => 'child' }, $ada_ck);
    ok($child->{status} eq '400' && ($child->{json}{error} // '') =~ /child/,
        'role child is rejected');

    my $bo = jdo('POST', '/api/users', { id => 'bo', password => 'coworker-pass-1', role => 'coworker' }, $ada_ck);
    ok($bo->{status} eq '200' && $bo->{json}{user}{role} eq 'coworker', 'manager creates a coworker');
    my $cal = jdo('POST', '/api/users', { id => 'cal', password => 'worker-pass-11', role => 'worker' }, $ada_ck);
    ok($cal->{status} eq '200' && $cal->{json}{user}{role} eq 'worker', 'manager creates a worker');

    my $bo_login = jdo('POST', '/api/login', { user => 'bo', password => 'coworker-pass-1' });
    my $cal_login = jdo('POST', '/api/login', { user => 'cal', password => 'worker-pass-11' });
    my $bo_ck = sess_of($bo_login->{cookie});
    my $cal_ck = sess_of($cal_login->{cookie});
    ok($bo_ck ne '' && $cal_ck ne '', 'coworker and worker can log in');

    my $cal_admin = jdo('POST', '/api/users', { id => 'nope', password => 'worker-pass-11', role => 'worker' }, $cal_ck);
    ok($cal_admin->{status} eq '403', 'worker cannot create accounts');

    my $mia = jdo('POST', '/api/users', { id => 'mia', password => 'manager-pass-2', role => 'manager' }, $ada_ck);
    ok($mia->{status} eq '200', 'setup manager can name another manager');
    my $mia_login = jdo('POST', '/api/login', { user => 'mia', password => 'manager-pass-2' });
    my $mia_ck = sess_of($mia_login->{cookie});
    my $mia_mgr = jdo('POST', '/api/users', { id => 'ned', password => 'manager-pass-3', role => 'manager' }, $mia_ck);
    ok($mia_mgr->{status} eq '403', 'a later manager cannot name another manager');

    ok(jdo('POST', '/api/grants', { user => 'cal', channel => 'meal', read => JSON::PP::true, write => JSON::PP::true }, $ada_ck)->{json}{ok},
        'grant worker read+write on meal');
    ok(jdo('POST', '/api/grants', { user => 'bo', channel => 'bo-private', read => JSON::PP::true, write => JSON::PP::true }, $ada_ck)->{json}{ok},
        'grant coworker their private channel');
    ok(jdo('POST', '/api/grants', { user => 'cal', channel => 'g:overlap', read => JSON::PP::true, write => JSON::PP::true }, $ada_ck)->{json}{ok}
        && jdo('POST', '/api/grants', { user => 'bo', channel => 'g:overlap', read => JSON::PP::true, write => JSON::PP::true }, $ada_ck)->{json}{ok},
        'grant both humans the overlap channel');
    ok(jdo('POST', '/api/grants', { user => 'ada', channel => 'g:overlap', read => JSON::PP::true, write => JSON::PP::false }, $ada_ck)->{json}{ok},
        'manager can hold a read-only grant');

    my $cal_hist = jdo('POST', '/api/send', { to => 'meal', content => 'worker meal note' }, $cal_ck);
    ok($cal_hist->{status} eq '200', 'worker can send on their channel');
    my $bo_meal = jdo('POST', '/api/send', { to => 'meal', content => 'should fail' }, $bo_ck);
    ok($bo_meal->{status} eq '403', 'coworker cannot write the worker private channel');
    my $bo_see = jdo('GET', '/api/history?channel=meal', undef, $bo_ck);
    ok($bo_see->{status} eq '404', 'coworker history of the private channel is 404');
    my $ada_meal = jdo('GET', '/api/history?channel=meal', undef, $ada_ck);
    ok($ada_meal->{status} eq '404', 'manager without a grant gets 404');

    my $cal_read = jdo('GET', '/api/history?channel=meal', undef, $cal_ck);
    ok($cal_read->{status} eq '200' && ($cal_read->{json}{messages}[-1]{content} // '') eq 'worker meal note',
        'worker reads their own channel');

    ok(jdo('POST', '/api/send', { to => 'g:overlap', content => 'from worker' }, $cal_ck)->{status} eq '200',
        'worker sends on the overlap');
    ok(jdo('POST', '/api/send', { to => 'g:overlap', content => 'from coworker' }, $bo_ck)->{status} eq '200',
        'coworker sends on the overlap');
    my $both = jdo('GET', '/api/history?channel=g:overlap', undef, $bo_ck);
    my $texts = join ' ', map { $_->{content} // '' } @{ $both->{json}{messages} || [] };
    ok($both->{status} eq '200' && $texts =~ /from worker/ && $texts =~ /from coworker/,
        'overlap history is visible to both');
    my $cal_priv = jdo('GET', '/api/history?channel=bo-private', undef, $cal_ck);
    ok($cal_priv->{status} eq '404', 'worker does not see the coworker private channel');

    my $ada_ro = jdo('POST', '/api/send', { to => 'g:overlap', content => 'manager write' }, $ada_ck);
    ok($ada_ro->{status} eq '403', 'read-only grant cannot send');
    my $ada_rr = jdo('GET', '/api/history?channel=g:overlap', undef, $ada_ck);
    ok($ada_rr->{status} eq '200', 'read-only grant can read history');

    {
        my $meal = IO::Socket::UNIX->new(Peer => $hsock, Type => SOCK_STREAM);
        print $meal encode_json({ type => 'register', id => 'meal' }), "\n";
        select undef, undef, undef, 0.2;
    }
    my $st = jdo('GET', '/api/state', undef, $bo_ck);
    my $ids = join ',', map { $_->{id} } @{ $st->{json}{agents} || [] };
    ok($ids !~ /meal/ && $ids !~ /bo-private/, 'coworker state omits ungranted mates');

    my $sus = jdo('POST', '/api/users/cal', { op => 'suspend' }, $ada_ck);
    ok($sus->{status} eq '200' && $sus->{json}{user}{status} eq 'suspended', 'suspend keeps the account');
    my $sus_login = jdo('POST', '/api/login', { user => 'cal', password => 'worker-pass-11' });
    ok($sus_login->{status} eq '403', 'suspended login is 403');
    my $sus_old = jdo('GET', '/api/history?channel=meal', undef, $cal_ck);
    ok($sus_old->{status} eq '401', 'old session is gone after suspend');
    my $gfile = do { open my $fh, '<', "$dir/grants.json"; local $/; <$fh> };
    ok($gfile =~ /meal/ && $gfile =~ /cal/, 'grants remain on disk while suspended');
    my $res = jdo('POST', '/api/users/cal', { op => 'restore' }, $ada_ck);
    ok($res->{json}{user}{status} eq 'active', 'restore clears suspension');
    my $cal2 = jdo('POST', '/api/login', { user => 'cal', password => 'worker-pass-11' });
    my $cal2_ck = sess_of($cal2->{cookie});
    my $back = jdo('GET', '/api/history?channel=meal', undef, $cal2_ck);
    ok($cal2->{status} eq '200' && $back->{status} eq '200', 'restored worker sees the same room');

    {
        open my $fh, '>', "$dir/uid-map.json" or die $!;
        print $fh encode_json({ mate1 => 0 + $< });
        close $fh;
    }
    my $bad_agent = IO::Socket::UNIX->new(Peer => $hsock, Type => SOCK_STREAM);
    print $bad_agent encode_json({ type => 'register', id => 'captain' }), "\n";
    my $refused = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout" };
        alarm 2;
        $refused = <$bad_agent> // '';
        alarm 0;
    };
    alarm 0;
    ok($refused =~ /register refused/, 'register as an unmapped id is refused');

    my $ok_agent = IO::Socket::UNIX->new(Peer => $hsock, Type => SOCK_STREAM);
    print $ok_agent encode_json({ type => 'register', id => 'mate1' }), "\n";
    select undef, undef, undef, 0.3;
    my $logtxt = '';
    if (open my $fh, '<', $log) { local $/; $logtxt = <$fh>; close $fh }
    ok($logtxt =~ /"id":"mate1"/, 'register from the mapped uid succeeds');
}

kill 'TERM', $pid;
waitpid($pid, 0);
print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
