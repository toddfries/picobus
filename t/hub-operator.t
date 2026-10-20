#!/usr/bin/perl
# hub-operator.t — once an account exists, "human" in the log is that account.
# The operator is not a hub socket. usage: perl t/hub-operator.t

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
my $chat = "$dir/chat.ndjson";
my $hub  = "$dir/hub.ndjson";

open my $pf, '>', "$dir/principals.json" or die $!;
print $pf encode_json({
    toddfries => {
        id      => 'toddfries',
        role    => 'manager',
        status  => 'active',
        founder => JSON::PP::true,
    },
});
close $pf;

sub row {
    my ($from, $to, $content) = @_;
    return {
        type => 'message', from => $from, to => $to,
        content => $content, ts => '2026-10-20T00:00:00Z',
    };
}
open my $cf, '>', $chat or die $!;
print $cf encode_json(row('human', 'lab', 'note-out')), "\n";
print $cf encode_json(row('lab', 'human', 'note-back')), "\n";
close $cf;

$ENV{HUB_SOCK}         = $sock;
$ENV{HUB_LOG}          = $hub;
$ENV{FCGI_SOCK}        = "$dir/fcgi.sock";
$ENV{CHAT_LOG}         = $chat;
$ENV{PRINCIPALS_FILE}  = "$dir/principals.json";
$ENV{SETUP_FILE}       = "$dir/setup.json";
$ENV{SECRETS_DIR}      = "$dir/secrets";
$ENV{PICOCLAW_HOME}    = "$dir/pico";
$ENV{FILE_DIR}         = "$dir/files";
$ENV{HUB_NOSANDBOX}    = 1;
delete $ENV{HUB_NOFCGI};
delete $ENV{PICOBUS_ZHC_GATE};

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
    if (-S $sock) { $up = 1; last }
    select undef, undef, undef, 0.1;
}
ok($up, 'hub listening');

sub slurp {
    my ($path) = @_;
    return '' unless -f $path;
    open my $fh, '<', $path or return '';
    local $/;
    my $raw = <$fh> // '';
    close $fh;
    return $raw;
}

my $healed = slurp($chat);
ok($healed =~ /"from":"toddfries"/ && $healed =~ /"to":"toddfries"/,
    'stored human rows become the account id');
ok($healed !~ /"from":"human"/ && $healed !~ /"to":"human"/,
    'the placeholder is gone from the healed log');

my $live_from;
my $unknown;
if ($up) {
    my $c = IO::Socket::UNIX->new(Peer => $sock, Type => SOCK_STREAM)
        or die "connect: $!";
    $c->autoflush(1);
    print $c encode_json({ type => 'register', id => 'lab' }), "\n";
    print $c encode_json({
        type => 'message', from => 'human', to => 'lab', content => 'live-from',
    }), "\n";
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 4;
        while (my $line = <$c>) {
            my $o = eval { decode_json($line) } or next;
            if (($o->{type} // '') eq 'error' && ($o->{msg} // '') =~ /unknown target/) {
                $unknown = $o->{msg};
                last;
            }
            if (($o->{type} // '') eq 'message'
                && ($o->{content} // '') eq 'live-from'
                && ($o->{from} // '') eq 'toddfries') {
                $live_from = 1;
                last;
            }
        }
        alarm 0;
    };
    alarm 0;
    if ($live_from) {
        print $c encode_json({
            type => 'message', from => 'lab', to => 'human', content => 'live-to',
        }), "\n";
        eval {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm 1;
            while (my $line = <$c>) {
                my $o = eval { decode_json($line) } or next;
                if (($o->{type} // '') eq 'error' && ($o->{msg} // '') =~ /unknown target/) {
                    $unknown = $o->{msg};
                    last;
                }
            }
            alarm 0;
        };
        alarm 0;
    }
    close $c;
}
ok($live_from, 'a line from human is delivered as the account id');
ok(!$unknown, 'the operator account is not an unknown target');

my $after = '';
for (1 .. 20) {
    $after = slurp($chat);
    last if $after =~ /live-to/;
    select undef, undef, undef, 0.1;
}
ok($after =~ /"to":"toddfries"/ && $after =~ /live-to/,
    'a new line addressed human is stored as the account id');
ok($after !~ /"to":"human"/, 'new lines do not store the placeholder');

print "$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
