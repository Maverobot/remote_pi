# Remote Pi fork

This checkout is [`Maverobot/remote_pi`](https://github.com/Maverobot/remote_pi),
an independently maintained fork of
[`jacobaraujo7/remote_pi`](https://github.com/jacobaraujo7/remote_pi). See
[README.md](./README.md) for the product overview and
[PROTOCOL.md](./PROTOCOL.md) for the wire protocol.

## Repository layout

| Path | Stack | Role |
|---|---|---|
| `app/` | Flutter (iOS/Android) | Mobile client |
| `pi-extension/` | Node + TypeScript, pnpm | Pi extension: `/remote-pi`, local mesh, relay client |
| `relay/` | Rust + Tokio | WebSocket relay |
| `site/` | Next.js, pnpm | Upstream website |
| `cockpit/` | Flutter desktop | Upstream desktop app |
| `plan/` | Markdown | Plans and the decision record |

Each subproject's `CLAUDE.md` lists its conventions and its build, lint, and
test commands. Edit and validate subprojects directly from this checkout.

The pane-dispatch tooling is upstream's workflow, and this fork doesn't use it:
`scripts/cmux-*.sh`, `scripts/cockpit-dispatch.sh`, `.orchestration/`, and the
`[ORCH:<task-id>]` sections in subproject `CLAUDE.md` files.

## Decisions

Before you propose changes to architecture, pairing, scope, UI, or security,
read [`plan/00-decisions.md`](./plan/00-decisions.md). Don't reverse a recorded
decision silently; raise it explicitly first.

## Test pi-extension without touching live state

Live Remote Pi sessions keep pairing, lock, and broker state under
`~/.pi/remote`, and some code reads `os.homedir()` directly. Before you run
pi-extension tests on a machine with live sessions, point the home and runtime
directories at a fresh temporary directory:

```sh
cd pi-extension
tmp=$(mktemp -d)    # fish: set tmp (mktemp -d)
env HOME=$tmp REMOTE_PI_HOME=$tmp TMPDIR=$tmp XDG_RUNTIME_DIR=$tmp ./node_modules/.bin/tsc --noEmit
env HOME=$tmp REMOTE_PI_HOME=$tmp TMPDIR=$tmp XDG_RUNTIME_DIR=$tmp ./node_modules/.bin/vitest run
```

## Installed extension

Pi installs this fork from `git:github.com/Maverobot/remote_pi@main` into
`~/.pi/agent/git/github.com/Maverobot/remote_pi` and loads `pi-extension/dist`
from that copy. Changes in this checkout don't reach running sessions until the
installed copy is updated and those sessions restart.

## Upstream

The `upstream` remote points at `jacobaraujo7/remote_pi`. This fork doesn't
rebase onto upstream routinely. Bring in upstream changes selectively when they
affect `app/`, `pi-extension/`, `relay/`, or `PROTOCOL.md`.
