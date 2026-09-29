# picobus

Hub, bus, FastCGI handler, and web UI for picoclaw agents. Other
picoclaw systems can run this without becoming Daemon Crew.

```sh
rcctl enable picobus httpd
rcctl start picobus
```

| | |
|---|---|
| Binary | `/usr/local/sbin/picobus` |
| rc.d | `/etc/rc.d/picobus` |
| Wrapper | `/usr/local/libexec/picobus` |
| State | `/var/picobus` |
| Share | `/usr/local/share/picobus` |
| Config | `/etc/picobus.conf` |
| Hub socket | `/var/run/picoclaw/hub.sock` |
| FastCGI | `/var/www/run/picoclaw/fcgi.sock` |

An agent joins by connecting to the hub socket and sending one JSON
line: `{"type":"register","id":"NAME"}`.

For a live PicoClaw gateway, **do not use inbox files**. The native
inject path is `ws://127.0.0.1:<port>/pico/ws`. `bin/picobus-pico`
holds that WebSocket (Mojolicious, `pkg_add p5-Mojolicious`) and
translates hub NDJSON to Pico `message.send` / `message.create`.
PicoClaw never speaks hub NDJSON; talkd and the web UI stay on the hub
socket.

```sh
# /etc/picobus.conf
# HUB_GROUP=picobus
# PICO_AGENTS=worker=127.0.0.1:18790
# PICO_TOKEN_DIR=/var/picobus/secrets/pico
rcctl enable picobus picobus_pico
rcctl start picobus picobus_pico
```

Token files are `$PICO_TOKEN_DIR/<id>` (one line, mode 0640). Put the
same value under `channel_list.pico.settings.token` in that instance's
`.security.yml` — never append YAML at EOF.

`bin/hub-bridge.pl` is a file mailbox for processes that cannot hold a
Pico socket. Prefer `picobus-pico` when the gateway already has
`channel_list.pico` enabled.

```sh
HUB_SOCK=/var/run/picoclaw/hub.sock AGENT_ID=NAME \
  perl hub-bridge.pl inbox.ndjson outbox.ndjson
```

Hub socket mode is 0660. Set `HUB_GROUP` so every client user is in
that group; do not chmod the socket 0666.

`picobus` writes every bus message to `hub-events.ndjson`. It does not
score agents and it does not own a roster. A product that wants either
of those reads the event log, or starts the agents that register.

`/etc/picobus.conf` can set `PICOBUS_PRODUCT` and `PICOBUS_COOKIE`.
Unset, the page title is `picobus` and theme cookies are `PICOBUS_*`.

Signup (`/api/setup`, ALTCHA, account page) writes the LLM key into
`$PICOCLAW_HOME/.security.yml`. The model alias defaults to `default`;
set `PICOBUS_LLM_ALIAS` to use another name.

Tests: `perl t/hub-protocol.t`, `perl t/hub-pledge.t`,
`perl t/pico-bridge.t` (needs Mojolicious).
