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
line: `{"type":"register","id":"NAME"}`. `bin/hub-bridge.pl` does that
from an inbox file and an outbox file:

```sh
HUB_SOCK=/var/run/picoclaw/hub.sock AGENT_ID=NAME \
  perl hub-bridge.pl inbox.ndjson outbox.ndjson
```

`picobus` writes every bus message to `hub-events.ndjson`. It does not
score agents and it does not own a roster. A product that wants either
of those reads the event log, or starts the agents that register.

`/etc/picobus.conf` can set `PICOBUS_PRODUCT` and `PICOBUS_COOKIE`.
Unset, the page title is `picobus` and theme cookies are `PICOBUS_*`.

Signup (`/api/setup`, ALTCHA, account page) writes the LLM key into
`$PICOCLAW_HOME/.security.yml`. The model alias defaults to `default`;
set `PICOBUS_LLM_ALIAS` to use another name.

Tests: `perl picobus/t/hub-protocol.t`, `perl picobus/t/hub-setup.t`.
