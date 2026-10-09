#!/usr/bin/perl
# pico-recover.t — token-dir failures say why, and a refused /health
# does not kill the bridge.
# usage: perl t/pico-recover.t

use strict;
use warnings;
use FindBin;
use File::Temp qw(tempdir);
use IO::Socket::INET;
use POSIX qw(WNOHANG _exit);

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

my $dir = tempdir(CLEANUP => 1);
my @kids;

sub run_pico {
    my (%env) = @_;
    my $out = $env{_out} or die "out path";
    delete $env{_out};
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open STDIN,  '<', '/dev/null';
        open STDOUT, '>', $out;
        open STDERR, '>&STDOUT';
        %ENV = (%ENV, %env);
        exec $^X, "$FindBin::Bin/../bin/picobus-pico" or _exit(127);
    }
    push @kids, $pid;
    return $pid;
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or return '';
    local $/;
    my $s = <$fh> // '';
    close $fh;
    return $s;
}

sub wait_exit {
    my ($pid, $secs) = @_;
    my $deadline = time + $secs;
    while (time < $deadline) {
        my $got = waitpid($pid, WNOHANG);
        if ($got == $pid) {
            @kids = grep { $_ != $pid } @kids;
            return $?;
        }
        select undef, undef, undef, 0.05;
    }
    return;
}

END {
    my $status = $?;
    for my $pid (@kids) {
        kill 'TERM', $pid;
        waitpid($pid, WNOHANG);
        kill 'KILL', $pid;
        waitpid($pid, 0);
    }
    # tempdir cannot unlink a mode 000 parent
    chmod 0700, "$dir/locked" if -d "$dir/locked";
    $? = $status;
}

# --- die text ---
{
    my $out = "$dir/unset.out";
    my $pid = run_pico(
        _out           => $out,
        PICO_AGENTS    => 'lab=127.0.0.1:9',
        PICO_TOKEN_DIR => '',
        PICO_DIRECTORY => "$dir/no-directory.json",
        HUB_SOCK       => "$dir/no.sock",
        HUB_LOG        => "$dir/no.ndjson",
    );
    my $st = wait_exit($pid, 3);
    ok(defined $st, 'unset token dir exits');
    ok(slurp($out) =~ /PICO_TOKEN_DIR required \(unset\)/, 'unset token dir says unset');
}

{
    my $out = "$dir/missing.out";
    my $pid = run_pico(
        _out           => $out,
        PICO_AGENTS    => 'lab=127.0.0.1:9',
        PICO_TOKEN_DIR => "$dir/does-not-exist",
        PICO_DIRECTORY => "$dir/no-directory.json",
        HUB_SOCK       => "$dir/no.sock",
        HUB_LOG        => "$dir/no.ndjson",
    );
    my $st = wait_exit($pid, 3);
    ok(defined $st, 'missing token dir exits');
    my $err = slurp($out);
    ok($err =~ /PICO_TOKEN_DIR required \(/ && $err !~ /PICO_TOKEN_DIR required\n\z/,
        'missing token dir names the error');
}

{
    mkdir "$dir/locked", 0700 or die $!;
    mkdir "$dir/locked/pico", 0700 or die $!;
    chmod 0000, "$dir/locked" or die $!;
    my $out = "$dir/locked.out";
    my $pid = run_pico(
        _out           => $out,
        PICO_AGENTS    => 'lab=127.0.0.1:9',
        PICO_TOKEN_DIR => "$dir/locked/pico",
        PICO_DIRECTORY => "$dir/no-directory.json",
        HUB_SOCK       => "$dir/no.sock",
        HUB_LOG        => "$dir/no.ndjson",
    );
    my $st = wait_exit($pid, 3);
    chmod 0700, "$dir/locked" or die $!;
    ok(defined $st, 'hidden token dir exits');
    ok(slurp($out) =~ /PICO_TOKEN_DIR required \(Permission denied\)/,
        'hidden token dir says permission denied');
}

# --- refused /health does not kill the process ---
{
    my $port;
    for my $p (19340 .. 19440) {
        my $probe = IO::Socket::INET->new(
            LocalAddr => '127.0.0.1', LocalPort => $p,
            Proto => 'tcp', Listen => 1, ReuseAddr => 1,
        );
        if ($probe) {
            $port = $p;
            close $probe;
            last;
        }
    }
    die "no free port\n" unless $port;

    my $tokd = "$dir/tokens";
    mkdir $tokd, 0700 or die $!;
    open my $tf, '>', "$tokd/lab" or die $!;
    print $tf "test-token-pico-recover\n";
    close $tf;

    my $out = "$dir/alive.out";
    my $pid = run_pico(
        _out           => $out,
        PICO_AGENTS    => "lab=127.0.0.1:$port",
        PICO_TOKEN_DIR => $tokd,
        PICO_DIRECTORY => "$dir/directory.json",
        PICO_POLL      => 1,
        HUB_SOCK       => "$dir/no.sock",
        HUB_LOG        => "$dir/no.ndjson",
    );
    select undef, undef, undef, 2.0;
    my $alive = kill 0, $pid;
    ok($alive, 'bridge stays up when /health is refused');
    my $err = slurp($out);
    ok($err !~ /I\/O watcher failed/, 'refused /health does not kill the reactor');
    my $raw = slurp("$dir/directory.json");
    ok($raw =~ /"presence":"down"/ && $raw =~ /"id":"lab"/,
        'refused /health marks the berth down');
    if (!$alive) {
        print STDERR $err;
    }
}

print "$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
