#!/usr/bin/perl
# hub-hello.t — the creator's hello lands once, in that mate's channel.
# usage: perl t/hub-hello.t

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
ok($up, 'hub socket is up');

sub connect_hub {
    IO::Socket::UNIX->new(Peer => $sock, Type => SOCK_STREAM)
        or die "connect $sock: $!";
}

sub roundtrip {
    my ($obj) = @_;
    my $c = connect_hub();
    $c->autoflush(1);
    print $c encode_json($obj), "\n";
    my $line;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 2;
        $line = <$c>;
        alarm 0;
    };
    alarm 0;
    close $c;
    return undef unless defined $line;
    return eval { decode_json($line) };
}

sub messages {
    my @out;
    open my $fh, '<', $log or return @out;
    while (my $line = <$fh>) {
        my $o = eval { decode_json($line) } or next;
        push @out, $o if ($o->{type} // '') eq 'message';
    }
    close $fh;
    return @out;
}

if ($up) {
    my $ack = roundtrip({
        type => 'hello', alias => 'lab', content => 'whats up doc?',
    });
    ok($ack && $ack->{ok} && !$ack->{already}, 'first hello is accepted');
    my @m = messages();
    ok(@m == 1, 'one chat line');
    ok($m[0] && $m[0]{from} eq 'lab', 'line is from the mate');
    ok($m[0] && ($m[0]{to} // '') eq 'human', 'line is for the operator');
    ok($m[0] && ($m[0]{content} // '') eq 'whats up doc?', 'words are whats up doc?');

    my $again = roundtrip({
        type => 'hello', alias => 'Lab', content => 'whats up doc?',
    });
    ok($again && $again->{ok} && $again->{already}, 'a second hello is not a second line');
    @m = messages();
    ok(@m == 1, 'the channel still has one hello');

    my $before = scalar messages();
    my $bad = roundtrip({
        type => 'hello', alias => 'lab', content => 'hello there',
    });
    ok($bad && !$bad->{ok}, 'any other sentence is refused');
    ok(scalar(messages()) == $before, 'a refused hello is not logged');

    my $name = roundtrip({
        type => 'hello', alias => 'Not A Name', content => 'whats up doc?',
    });
    ok($name && !$name->{ok}, 'a bad alias is refused');

    my $mate = connect_hub();
    $mate->autoflush(1);
    print $mate encode_json({ type => 'register', id => 'doc' }), "\n";
    select undef, undef, undef, 0.2;
    my $doc = roundtrip({
        type => 'hello', alias => 'doc', content => 'whats up doc?',
    });
    ok($doc && $doc->{ok} && !$doc->{already}, 'a different mate gets their own hello');
    my ($labs, $docs) = (0, 0);
    for my $row (messages()) {
        next unless ($row->{content} // '') eq 'whats up doc?';
        $labs++ if ($row->{from} // '') eq 'lab';
        $docs++ if ($row->{from} // '') eq 'doc';
    }
    ok($labs == 1 && $docs == 1, 'each mate has one hello');
    my $heard = 0;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 1;
        while (my $line = <$mate>) {
            if ($line =~ /whats up doc\?/) { $heard = 1; last }
        }
        alarm 0;
    };
    alarm 0;
    ok(!$heard, 'the hello is not handed to the mate to answer');
    close $mate;
} else {
    for my $name (
        'first hello is accepted',
        'one chat line',
        'line is from the mate',
        'line is for the operator',
        'words are whats up doc?',
        'a second hello is not a second line',
        'the channel still has one hello',
        'any other sentence is refused',
        'a refused hello is not logged',
        'a bad alias is refused',
        'a different mate gets their own hello',
        'each mate has one hello',
        'the hello is not handed to the mate to answer',
    ) {
        ok(0, "$name (skipped)");
    }
}

if ($pid) {
    kill 'TERM', $pid;
    select undef, undef, undef, 0.2;
    kill 'KILL', $pid if kill 0, $pid;
    waitpid($pid, 0);
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
