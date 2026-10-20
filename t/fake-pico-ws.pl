#!/usr/bin/perl
# Tiny Pico-protocol echo server for tests. Not for production.
# usage: perl t/fake-pico-ws.pl PORT TOKEN [ID [STATEDIR]]
use strict;
use warnings;
use Mojolicious::Lite;
use Mojo::Server::Daemon;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::IOLoop;

my ($port, $token, $id, $statedir) = @ARGV;
die "usage: fake-pico-ws.pl PORT TOKEN [ID [STATEDIR]]\n" unless $port && defined $token;
$id //= 'lab';

my %conns;
my $emit;

sub state_or {
    my ($name, $default) = @_;
    return $default unless $statedir && -f "$statedir/$name";
    open my $fh, '<', "$statedir/$name" or return $default;
    local $/;
    my $raw = <$fh> // '';
    close $fh;
    return eval { decode_json($raw) } || $default;
}

sub append_line {
    my ($name, $obj) = @_;
    return unless $statedir;
    open my $fh, '>>', "$statedir/$name" or return;
    print $fh encode_json($obj), "\n";
    close $fh;
}

get '/health' => sub {
    my $c = shift;
    my $s = state_or('probe.json', {});
    $c->render(json => {
        status => 'ok',
        pid    => 0 + ($s->{pid} // 1),
    });
};

get '/ready' => sub {
    shift->render(json => { status => 'ready' });
};

get '/beacon' => sub {
    my $c = shift;
    my $s = state_or('probe.json', {});
    if (!$statedir || !$s->{nick}) {
        $c->render(text => 'no beacon', status => 404);
        return;
    }
    $c->render(json => {
        id   => $s->{id} // $id,
        nick => $s->{nick},
        role => $s->{role} // $s->{nick},
    });
};

post '/emit' => sub {
    my $c = shift;
    $emit = $c->req->json || {};
    $c->render(json => { ok => 1 });
};

websocket '/pico/ws' => sub {
    my $c = shift;
    my $auth = $c->req->headers->authorization // '';
    unless ($auth eq "Bearer $token") {
        $c->finish;
        return;
    }
    my $sid = $c->param('session_id') // '';
    $conns{$sid} = $c if $sid ne '';
    $c->on(finish => sub { delete $conns{$sid} if $sid ne '' });
    $c->on(json => sub {
        my ($c, $hash) = @_;
        my $type = $hash->{type} // '';
        if ($type eq 'directory' || $type eq 'bus.ack' || $type eq 'bus.error') {
            append_line('frames.ndjson', $hash);
            return;
        }
        return unless $type eq 'message.send';
        my $content = $hash->{payload}{content} // '';
        my $sid     = $hash->{session_id} // '';
        append_line('frames.ndjson', $hash);
        # The one-time introduction is a sentence, not an echo of the prompt.
        if ($content =~ /one-time introduction/) {
            $c->send({ json => {
                type       => 'message.create',
                session_id => $sid,
                payload    => { content => 'I expect to keep this crew working.' },
            } });
            $c->send({ json => {
                type       => 'typing.stop',
                session_id => $sid,
                payload    => {},
            } });
            return;
        }
        $c->send({ json => {
            type       => 'message.create',
            session_id => $sid,
            payload    => { content => "echo:$content" },
        } });
        $c->send({ json => {
            type       => 'typing.stop',
            session_id => $sid,
            payload    => {},
        } });
    });
};

Mojo::IOLoop->recurring(0.1 => sub {
    return unless $emit;
    my $sid = 'pb.' . $id;
    my $c = $conns{$sid} or return;
    my $e = $emit;
    undef $emit;
    if (defined $e->{activity}) {
        $c->send({ json => {
            type       => 'activity',
            session_id => $sid,
            payload    => { state => $e->{activity} },
        }});
        return;
    }
    $c->send({ json => {
        type       => 'bus.send',
        id         => 't1',
        session_id => $sid,
        payload    => {
            to      => $e->{to} // '',
            content => $e->{content} // '',
        },
    }});
});

my $daemon = Mojo::Server::Daemon->new(
    app    => app,
    listen => ["http://127.0.0.1:$port"],
);
$daemon->silent(1);
$daemon->start;
Mojo::IOLoop->start;
