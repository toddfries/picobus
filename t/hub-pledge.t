#!/usr/bin/perl
# hub-pledge.t — sandboxed hub still accepts register + writes the event log.
# Path EPERM coverage lives in t/pledge-unveil.t.
# usage: perl t/hub-pledge.t

use strict;
use warnings;
use FindBin;
use File::Temp qw(tempdir);
use IO::Socket::UNIX;
use JSON::PP qw(encode_json);

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
ok($up, 'sandboxed hub listening');

if ($up) {
    my $c = IO::Socket::UNIX->new(Peer => $sock, Type => SOCK_STREAM)
        or die "connect: $!";
    print $c encode_json({ type => 'register', id => 'pledge-a' }), "\n";
    print $c encode_json({
        type => 'message', from => 'pledge-a', to => 'all',
        content => 'done: pledge coop',
    }), "\n";
    select undef, undef, undef, 0.6;
    close $c;
    ok(kill(0, $pid), 'hub still alive after register+message');
    my $logtxt = '';
    if (open my $lf, '<', $log) { local $/; $logtxt = <$lf> // ''; close $lf }
    ok($logtxt =~ /pledge-a/ && $logtxt =~ /done: pledge coop/,
        'raw event appended under unveil');
} else {
    ok(0, 'hub alive (skipped)');
    ok(0, 'event log (skipped)');
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

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
