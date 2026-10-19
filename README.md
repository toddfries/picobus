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

A live PicoClaw gateway does **not** join that way. It already serves
`ws://127.0.0.1:<port>/pico/ws`. `bin/picobus-pico` (Mojolicious,
`pkg_add p5-Mojolicious`) holds that WebSocket — one connection per
hub sender, `?session_id=` matching the Pico chat — and translates hub
NDJSON to Pico `message.send` / `message.create`. PicoClaw never
speaks hub NDJSON. Talkd, the web UI, and `hubctl` stay on the hub
socket and never speak Pico.

Do **not** give a gateway `hub-inbox.ndjson` / `hub-outbox.ndjson`.
That mailbox makes the model spend tool turns (`echo >> file`, `cat`
polls) to talk to its neighbours. The Pico path *is* the turn.

```sh
# /etc/picobus.conf
# HUB_GROUP=picobus
# PICO_AGENTS=worker=127.0.0.1:18790
# PICO_TOKEN_DIR=/var/picobus/pico
rcctl enable picobus picobus_pico
rcctl start picobus picobus_pico
```

`picobus-pico` polls `GET /health`, `GET /ready`, and `GET /beacon`
(no model turn) and writes `/var/picobus/dir/directory.json`. That
directory is `0750 _picobus:picobus` because `/var/picobus` itself is
not writable by the daemon (secrets live next to it). A `directory`
frame is pushed on the control socket `pb.<id>` only when id, nick, or
role changes. Pid and uptime changes do not push. A gateway `bus.send`
frame on that socket is one hub unicast. `bus.ack` or `bus.error`
comes back on the same socket. Nick stays empty until `/beacon` returns
it. Missing beacon is 404, not a guessed name.

Token files are `$PICO_TOKEN_DIR/<id>` (one line, mode 0640), default
`/var/picobus/pico`. Do not put them under `/var/picobus/secrets`:
the hub chmod `0700`s that directory on every start, `_picobus`
cannot search it, and the bridge dies at startup. Put the
same value under `channel_list.pico.settings.token` in that instance's
`.security.yml` — never append YAML at EOF. Handshake `?session_id=`
must match the `session_id` on `message.send` or Pico replies
`no active connections for session`.

Hub socket mode is 0660. Set `HUB_GROUP` so every client user is in
that group; do not chmod the socket 0666.

talkd (IRC/XMPP/… ) is a hub client: register as `talkd` (never a
gateway id), unicast `to=<agent>`, apply protocol ACLs **in talkd**.
It never speaks Pico and never uses inbox files. `to=all` is the
system log, not work. Gateway liveness is `GET /health` on the
gateway port, token-free, not a hub message.

`picobus` writes every bus message to `hub-events.ndjson`. It does not
score agents and it does not own a roster. A product that wants either
of those reads the event log, or starts the agents that register.

Humans sign in with `POST /api/login`. The session cookie is
`{PICOBUS_COOKIE}_SESS` (default `PICOBUS_SESS`). The setup account is
the first **manager**. A manager may create **worker** and **coworker**
accounts. Only that setup manager may name another manager. The role
`child` is reserved and rejected until restricted users are built.

One human sees every channel. A second human turns on grants: no grant
means the channel is not listed, history is 404, and send is 403.
`POST /api/grants` with `{user, channel, read, write}` is manager-only.
Write implies read. Suspend keeps the grants and drops the session.

Local agents are still whoever `register` names, unless
`uid-map.json` exists next to the other state files (or
`PICOBUS_UID_MAP` points somewhere else). The file is a JSON object of
agent id to numeric uid. A register is refused when the peer uid does
not match. The supervisor writes that file. Leave it absent and the
hub does not check.

`/etc/picobus.conf` can set `PICOBUS_PRODUCT` and `PICOBUS_COOKIE`.
Unset, the page title is `picobus` and theme cookies are `PICOBUS_*`.

With `PICOBUS_ZHC_GATE=1`, the site session is the login and channel
grants stay off. A refused `/dc` page is only a status:
Sign in required, Forbidden, or Unavailable. The plain look is enough
for now. A later cut may style it. Do not replace it with the crew UI.

The signed-in page copies the site menu, the light/dark/system control,
and the cookie tray. Those files live in `share/dc/` and are served from
`/dc/chrome.js`, `/dc/chrome.css`, and `/dc/icons/`. The theme cookie is
`ZHCTHEME_*`, the same one the rest of the site writes. Do not point the
page at `/shared/zhc-prefs.js`.

Signup (`/api/setup`, ALTCHA, account page) writes the LLM key into
`$PICOCLAW_HOME/.security.yml`. The model alias defaults to `default`;
set `PICOBUS_LLM_ALIAS` to use another name.

Tests: `perl t/hub-protocol.t`, `perl t/hub-pledge.t`,
`perl t/hub-acl.t`, `perl t/pico-bridge.t` (needs Mojolicious).
