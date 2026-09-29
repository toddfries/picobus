#!/usr/bin/perl
# hub-bridge.pl — a tiny bridge that lets a picoclaw agent (or any process
# that can run shell commands) participate in the hub network.
#
# usage: HUB_SOCK=... AGENT_ID=name perl hub-bridge.pl <inbox-file> <outbox-file>
#
# Protocol:
#   - Lines written to <outbox-file> (echo "..." >> outbox) are sent to the
#     hub as messages from AGENT_ID.
#   - Messages from other agents are appended to <inbox-file>.
#
# This gives picoclaw agents file-based access to the hub: the agent writes
# to its outbox with a shell command and reads its inbox for replies.

use strict;
use warnings;
use IO::Socket::UNIX;
use JSON::PP qw(encode_json decode_json);

my ($inbox, $outbox) = @ARGV;
die "usage: hub-bridge.pl <inbox> <outbox>\n" unless $inbox && $outbox;
my $id    = $ENV{AGENT_ID} or die "AGENT_ID env required\n";
my $sock  = $ENV{HUB_SOCK} or die "HUB_SOCK env required\n";

my $c;
for my $i (1 .. 30) {
    $c = IO::Socket::UNIX->new(Peer => $sock, Type => SOCK_STREAM);
    last if $c;
    sleep 1;
}
die "connect $sock: $!\n" unless $c;
$c->blocking(0);
print $c encode_json({ type => 'register', id => $id }), "\n";

# outbox: send anything new (start at 0 so pre-existing lines are sent)
open my $ob, '<', $outbox or die "outbox $outbox: $!";

# inbox: create empty if missing
open my $ib, '>>', $inbox; close $ib;

$| = 1;
while (1) {
    # read from hub -> append to inbox
    my $chunk;
    while (defined($chunk = <$c>)) {
        open my $fh, '>>', $inbox or last;
        print $fh $chunk;
        close $fh;
    }

    # read new outbox lines -> send to hub
    while (my $line = <$ob>) {
        chomp $line;
        next unless length $line;
        my $obj = eval { decode_json($line) } || { type => 'message', content => $line };
        $obj->{type}    //= 'message';
        $obj->{from}    //= $id;
        $obj->{content} //= $line unless $obj->{body};
        delete $obj->{from} if defined $obj->{from} && $obj->{from} ne $id;
        print $c encode_json($obj), "\n";
    }
    # track position even if file was replaced
    my $pos = tell($ob);
    seek $ob, $pos, 0;

    select undef, undef, undef, 0.3;
}
