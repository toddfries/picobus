#!/usr/bin/perl
# hub-protocol.t — register/message JSON against a throwaway sandboxed hub.
# usage: perl t/hub-protocol.t

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

my $dir  = tempdir(CLEANUP => 1);
my $sock = "$dir/hub.sock";
my $log  = "$dir/hub.ndjson";
$ENV{HUB_SOCK} = $sock;
$ENV{HUB_LOG}  = $log;
$ENV{HUB_NOFCGI} = 1;
delete $ENV{HUB_NOSANDBOX};

my $pid = fork();
die "fork: $!" unless defined $pid;
if ($pid == 0) {
    open STDOUT, '>', "$dir/hub.out";
    open STDERR, '>&STDOUT';
    exec $^X, "$FindBin::Bin/../bin/picobus" or exit 127;
}

my $up;
for (1 .. 40) {
    if (-S $sock) { $up = 1; last }
    select undef, undef, undef, 0.1;
}
ok($up, 'hub created UNIX socket (sandbox did not prevent listen)');

sub connect_hub {
    IO::Socket::UNIX->new(Peer => $sock, Type => SOCK_STREAM)
        or die "connect $sock: $!";
}

if ($up) {
    my $rx = connect_hub();
    print $rx encode_json({ type => 'register', id => 'proto-rx' }), "\n";
    select undef, undef, undef, 0.2;

    my $tx = connect_hub();
    print $tx encode_json({ type => 'register', id => 'proto-tx' }), "\n";
    print $tx encode_json({
        type => 'message', from => 'proto-tx', to => 'all',
        content => 'broadcast ping',
    }), "\n";

    my $got_all = 0;
    eval {
        local $SIG{ALRM} = sub { die "timeout" };
        alarm 1;
        while (my $line = <$rx>) {
            if ($line =~ /broadcast ping/) { $got_all = 1; last }
        }
        alarm 0;
    };
    alarm 0;
    ok(!$got_all, 'to=all does not assign work to other agents');

    my $zb = connect_hub();
    print $zb encode_json({ type => 'register', id => 'proto-zb' }), "\n";
    select undef, undef, undef, 0.2;
    print $tx encode_json({
        type => 'message', from => 'proto-tx', to => 'proto-rx',
        content => 'unicast ping',
    }), "\n";
    my $got_uni;
    eval {
        local $SIG{ALRM} = sub { die "timeout" };
        alarm 3;
        while (my $line = <$rx>) {
            if ($line =~ /unicast ping/) { $got_uni = 1; last }
        }
        alarm 0;
    };
    alarm 0;
    ok($got_uni, 'unicast reaches target');

    my $got_zb = 0;
    eval {
        local $SIG{ALRM} = sub { die "timeout" };
        alarm 1;
        while (my $line = <$zb>) {
            if ($line =~ /unicast ping/) { $got_zb = 1; last }
        }
        alarm 0;
    };
    alarm 0;
    ok(!$got_zb, 'unicast not visible to a third agent');

    print $tx encode_json({
        type    => 'channel',
        op      => 'create',
        id      => 'g:lab',
        name    => 'lab',
        members => [ 'human', 'proto-tx', 'proto-rx' ],
    }), "\n";
    select undef, undef, undef, 0.2;
    print $tx encode_json({
        type => 'message', from => 'proto-tx', to => 'g:lab',
        content => 'group ping',
    }), "\n";
    my $got_g;
    eval {
        local $SIG{ALRM} = sub { die "timeout" };
        alarm 3;
        while (my $line = <$rx>) {
            if ($line =~ /group ping/) { $got_g = 1; last }
        }
        alarm 0;
    };
    alarm 0;
    ok($got_g, 'group message reaches members');
    my $got_g_zb = 0;
    eval {
        local $SIG{ALRM} = sub { die "timeout" };
        alarm 1;
        while (my $line = <$zb>) {
            if ($line =~ /group ping/) { $got_g_zb = 1; last }
        }
        alarm 0;
    };
    alarm 0;
    ok(!$got_g_zb, 'group message not visible outside membership');
    close $zb;

    print $tx encode_json({
        type => 'message', from => 'proto-tx', to => 'nobody-here',
        content => 'directed miss',
    }), "\n";
    select undef, undef, undef, 0.3;
    ok(kill(0, $pid), 'unknown to= does not kill hub');

    print $tx "not-json\n";
    print $tx "{]\n";
    select undef, undef, undef, 0.3;
    ok(kill(0, $pid), 'malformed line does not kill hub');
    close $tx;
    close $rx;
} else {
    ok(0, 'to=all does not assign (skipped)');
    ok(0, 'unicast (skipped)');
    ok(0, 'unicast isolation (skipped)');
    ok(0, 'group members (skipped)');
    ok(0, 'group isolation (skipped)');
    ok(0, 'unknown to= (skipped)');
    ok(0, 'malformed line (skipped)');
}

if ($pid) {
    kill 'TERM', $pid;
    select undef, undef, undef, 0.2;
    kill 'KILL', $pid;
    waitpid($pid, 0);
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
