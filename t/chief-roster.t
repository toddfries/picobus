#!/usr/bin/perl
# chief-roster.t — the chief's roster line files an account; the reply is the result.
# usage: perl t/chief-roster.t
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
my $token = 'test-token-chief-roster';
for my $id (qw(chief lab)) {
    open my $tf, '>', "$tokd/$id" or die $!;
    print $tf $token;
    close $tf;
}

my $port;
for my $p (19230 .. 19340) {
    my $probe = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1', LocalPort => $p,
        Proto => 'tcp', Listen => 1, ReuseAddr => 1,
    );
    if ($probe) { $port = $p; close $probe; last }
}
die "no free port\n" unless $port;

$ENV{HUB_SOCK}     = $sock;
$ENV{HUB_LOG}      = $log;
$ENV{FCGI_SOCK}    = "$dir/fcgi.sock";
$ENV{CREW_QUEUE}   = $dir;
delete $ENV{HUB_NOFCGI};
delete $ENV{HUB_NOSANDBOX};
delete $ENV{HUB_GROUP};
delete $ENV{PICOBUS_ZHC_GATE};

my $hub_pid = fork();
die "fork hub: $!" unless defined $hub_pid;
if ($hub_pid == 0) {
    open STDIN,  '<', '/dev/null';
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
    exec $^X, "$FindBin::Bin/fake-pico-ws.pl", $port, $token, 'chief' or exit 127;
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

$ENV{PICO_AGENTS}     = "chief=127.0.0.1:$port,lab=127.0.0.1:$port";
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

my $reg;
for (1 .. 50) {
    if (open my $lf, '<', $log) {
        local $/;
        my $all = <$lf> // '';
        close $lf;
        if ($all =~ /"id":"chief"/ && $all =~ /"id":"lab"/) { $reg = 1; last }
    }
    select undef, undef, undef, 0.1;
}
ok($reg, 'chief and lab registered');

sub read_log {
    open my $lf, '<', $log or return '';
    local $/;
    my $all = <$lf> // '';
    close $lf;
    return $all;
}

sub hub_send {
    my ($from, $to, $content) = @_;
    my $c = IO::Socket::UNIX->new(Peer => $sock, Type => SOCK_STREAM)
        or die "connect hub: $!";
    print $c encode_json({ type => 'register', id => "t-$$-" . int(rand(1000)) }), "\n";
    $c->flush;
    select undef, undef, undef, 0.2;
    print $c encode_json({
        type => 'message', from => $from, to => $to, content => $content,
    }), "\n";
    $c->flush;
    select undef, undef, undef, 0.2;
    close $c;
}

sub clear_queue {
    unlink glob("$dir/*.req"), glob("$dir/*.res"), glob("$dir/*.tmp");
}

sub wait_log {
    my ($re, $n) = @_;
    $n //= 40;
    for (1 .. $n) {
        return 1 if read_log() =~ $re;
        select undef, undef, undef, 0.2;
    }
    return 0;
}

sub take_req {
    my ($op) = @_;
    for (1 .. 40) {
        my @reqs = glob("$dir/*.req");
        if (@reqs) {
            open my $fh, '<', $reqs[0] or die $!;
            local $/;
            my $body = <$fh> // '';
            close $fh;
            return ($body, $reqs[0]);
        }
        select undef, undef, undef, 0.2;
    }
    return ('', '');
}

sub write_res {
    my ($req, $json) = @_;
    my $res = $req;
    $res =~ s/\.req\z/.res/;
    open my $fh, '>', $res or die $!;
    print $fh $json;
    close $fh;
}

my $marker_re = qr/\[\[roster/;

if ($up && $ws_up && $reg) {
    clear_queue();
    hub_send('smoke', 'lab', 'FILE-ROSTER-ADD');
    select undef, undef, undef, 1.2;
    my @reqs = glob("$dir/*.req");
    ok(!@reqs, 'another mate does not file the roster');
    ok(read_log() !~ $marker_re, 'the roster line is not spoken');
    ok(read_log() !~ /The account exists\./, 'another mate does not claim the account exists');
}

my $reserved;
if ($up && $ws_up && $reg) {
    clear_queue();
    hub_send('smoke', 'chief', 'FILE-ROSTER-CAPTAIN');
    $reserved = wait_log(qr/That name is reserved\./);
    my @reqs = glob("$dir/*.req");
    ok($reserved, 'a reserved name is refused');
    ok(!@reqs, 'a reserved name does not file create');
    ok(read_log() !~ /The account exists\./, 'a reserved name is not aboard');
}

my $stays;
if ($up && $ws_up && $reg) {
    clear_queue();
    hub_send('smoke', 'chief', 'FILE-ROSTER-CHIEF-OFF');
    $stays = wait_log(qr/The chief stays\./);
    my @reqs = glob("$dir/*.req");
    ok($stays, 'the chief is not removed');
    ok(!@reqs, 'removing the chief does not file');
}

my $fail_body;
if ($up && $ws_up && $reg) {
    clear_queue();
    hub_send('smoke', 'chief', 'FILE-ROSTER-FAIL');
    my ($body, $req) = take_req('create');
    $fail_body = $body;
    write_res($req, '{"ok":false,"error":"crew exists"}') if $req ne '';
    ok($body =~ /^op=create$/m && $body =~ /^alias=brp$/m && $body =~ /^by=chief$/m,
        'a failed add still files create');
    ok(wait_log(qr/The account already exists\./), 'an existing account is not described as new');
    ok(read_log() !~ /The account exists\./, 'a failed add does not say the account exists');
    ok(read_log() !~ /crew list/, 'the reply does not send the operator to a list');
}

my $add_body;
if ($up && $ws_up && $reg) {
    clear_queue();
    hub_send('smoke', 'chief', 'FILE-ROSTER-ADD');
    my ($body, $req) = take_req('create');
    $add_body = $body;
    write_res($req, '{"ok":true,"alias":"brp"}') if $req ne '';
    ok($body =~ /^op=create$/m && $body =~ /^alias=brp$/m && $body =~ /^by=chief$/m,
        'add files create for the alias');
    ok(wait_log(qr/The account exists\./), 'the account is aboard only after the helper agrees');
    ok(wait_log(qr/business resumption planning/), 'the work they named is in the reply');
    ok(read_log() !~ $marker_re, 'the roster line stays off the chat');
}

my $rm_body;
if ($up && $ws_up && $reg) {
    clear_queue();
    hub_send('smoke', 'chief', 'FILE-ROSTER-REMOVE');
    my ($body, $req) = take_req('remove');
    $rm_body = $body;
    write_res($req, '{"ok":false,"error":"remove is not granted"}') if $req ne '';
    ok($body =~ /^op=remove$/m && $body =~ /^alias=brp$/m, 'remove files the roster');
    ok(wait_log(qr/Remove is not granted\./), 'remove stays off until it is granted');
    ok(read_log() !~ /The account is gone\./, 'an ungranted remove does not say they are gone');
}

if (!$reserved || !$stays || $fail_body !~ /op=create/ || $add_body !~ /op=create/ || $rm_body !~ /op=remove/) {
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
