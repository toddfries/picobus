#!/usr/bin/perl
# Tiny Pico-protocol echo server for tests. Not for production.
# usage: perl t/fake-pico-ws.pl <port> <token>
use strict;
use warnings;
use Mojolicious::Lite;
use Mojo::Server::Daemon;

my ($port, $token) = @ARGV;
die "usage: fake-pico-ws.pl PORT TOKEN\n" unless $port && defined $token;

websocket '/pico/ws' => sub {
    my $c = shift;
    my $auth = $c->req->headers->authorization // '';
    unless ($auth eq "Bearer $token") {
        $c->finish;
        return;
    }
    $c->on(json => sub {
        my ($c, $hash) = @_;
        return unless ($hash->{type} // '') eq 'message.send';
        my $content = $hash->{payload}{content} // '';
        my $sid     = $hash->{session_id} // '';
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

get '/health' => sub { shift->render(text => '{"status":"ok"}') };

my $daemon = Mojo::Server::Daemon->new(
    app    => app,
    listen => ["http://127.0.0.1:$port"],
);
$daemon->silent(1);
$daemon->start;
Mojo::IOLoop->start;
