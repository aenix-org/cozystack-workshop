# Participant monitor

During a live session the host cannot look over fifteen shoulders at once. This
tool records the terminal of every participant who works through the shared
bastion VM and shows them side by side in a browser page, so the host can see
what people type, what the cluster answers, and who needs help right now.

Participants reach their `app-1` VM from the bastion (`virtctl console`, `ssh`),
so whatever they do inside that VM passes through their bastion terminal and is
recorded too. Nothing has to be installed on the participants' VMs.

[Русская версия](README.ru.md)

## What the host sees

Every participant gets a tile with a full terminal view and its own scrollback.
While you are at the bottom, a tile follows new output; scroll up and it stays
where you left it. Clicking a tile's title bar opens it full screen, with search
inside the output (Enter for the next match, Escape to go back). The header of a
tile shows whether the participant is logged in, the command running right now
and for how long, and the number of recent errors.

The tile frame tells you where to look:

- **red** — an error in the last three minutes;
- **pulsing red** — the participant is stuck;
- **yellow** — a command has been hanging with no output, or the participant has
  been silent for ten minutes.

"Got it" clears the red state once you have helped. The events column on the
right lists every problem with its time; clicking one opens the tile and scrolls
to the highlighted line. Browser notifications and a short sound can be turned on
in the header; by default they fire only when somebody is stuck, a second
checkbox adds every error.

The interface is in English; `?lang=ru` switches it to Russian. Add `?u=online01,online02` to the address to
show only those participants; the same list can be typed into the header field.

## How problems are detected

A small shell hook records each command a participant runs and its exit code
without printing anything to their terminal. A failed command produces one
event that carries the command, the exit code and the first error line from its
output. Inside `virtctl console` or `ssh` the exit codes of the remote commands
are not visible, so there the monitor looks for typical error text instead
(`Error from server`, `forbidden`, `not found`, `permission denied`,
`connection refused`, `timed out`, `CrashLoopBackOff` and so on).

A participant counts as stuck when the same command fails three times within ten
minutes, or when five problems pile up without a single successful command.
Thresholds and patterns are constants at the top of `ws-monitor.py`.

## Install on the bastion

The bastion needs bash, `script` from util-linux and Python 3.8 or newer; all of
them ship with Ubuntu 20.04 and later. The bastion does not need Internet access.

```bash
scp -r monitor ubuntu@<bastion>:/tmp/ws-monitor
ssh ubuntu@<bastion> sudo /tmp/ws-monitor/install.sh
```

The installer puts the recorder into `/etc/profile.d/zz-ws-record.sh`, the
command hook into `/etc/ws-monitor/hook.bash` (sourced from `/etc/bash.bashrc`),
and the server into `/opt/ws-monitor` as the systemd service `ws-monitor`.
Recordings go to `/var/log/ws-sessions/<user>/`.

Every user with UID 1000 or higher is recorded from their next login, except the
accounts listed in `/etc/ws-monitor/exclude` (by default `ubuntu` and `root`).
Shells that were already open before the installation are not recorded. New
participant accounts are picked up automatically.

## Open the monitor

```bash
./open-monitor.sh ubuntu@<bastion> online01,online02,online03
```

The script opens an SSH tunnel and the page at `http://localhost:8088`; Ctrl-C
closes the tunnel. The server listens only on a unix socket that belongs to the
admin account (`/run/ws-monitor/monitor.sock`, mode 0600), so participants on the
same bastion cannot reach the page. The host's browser loads the terminal
emulator (xterm.js) from a CDN, so the host's laptop needs Internet access.

## Limits

- Only the bastion path is covered. Participants who work from their own laptop,
  or open the VM console in the dashboard, are not recorded.
- Passwords that are not echoed (`sudo`, `passwd`) never reach the recording:
  only what appears on the screen is stored.
- Full-screen programs such as `vim` or `top` are drawn correctly, but at tile
  width they are hard to read; open the tile full screen.
- A highlighted line points at the logical line of output; when a long line wraps
  inside a narrow tile, the highlight lands on its last row.

## Files

| File | Where it goes | What it does |
|------|---------------|--------------|
| `zz-ws-record.sh` | `/etc/profile.d/` | wraps an interactive login in `script` |
| `hook.bash` | `/etc/ws-monitor/` | writes command start and exit code events |
| `ws-monitor.py` | `/opt/ws-monitor/` | tails recordings, detects problems, serves the page |
| `index.html` | `/opt/ws-monitor/` | the browser page |
| `ws-monitor.service` | `/etc/systemd/system/` | runs the server |
| `install.sh` | — | installs all of the above |
| `open-monitor.sh` | host's laptop | tunnel + browser |
