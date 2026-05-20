# Preview server — directory layout, lifecycle, events

The agent writes `current/content/index.html` (an HTML fragment with an `<!-- oc-frame: NAME -->` directive). The server splices it into the matching frame and pushes a WebSocket reload to the browser. User interactions land back in `state/events.jsonl`. That's the whole loop.

For the per-frame content-writing guide, see [`frames.md`](frames.md). For the OpenChoreo model, see [`concepts.md`](concepts.md).

## Preview directory (under the user's working dir, `$PWD`)

```text
.openchoreo-import/
├── .gitignore                          "*" — entire folder untracked
├── current -> runs/<id>                symlink — the active run
├── runs/
│   └── <YYYYMMDD-HHMMSS-slug>/         one folder per plan
│       ├── meta.json                   {id, name, started_at, status}
│       ├── content/index.html          ★ THE THING YOU WRITE — body fragment with an oc-frame directive
│       ├── plan.md                     human-readable deliverable (you write this too, on approve)
│       ├── source-rendered/            helm template / kustomize build / raw YAML copy
│       └── state/events.jsonl          user interactions (auto-cleared on every content/ write)
└── server-state/                       global, per server process
    ├── server-info.json
    └── server.log
```

## Lifecycle (`preview.sh`)

```text
preview.sh start  [pwd]              launch server (creates `current` if none); prints URL — does NOT open the browser
preview.sh open   [pwd]              open the running URL in the user's browser
preview.sh stop   [pwd]              stop the server
preview.sh new    [pwd] <slug>       create a new run, flip `current`; prints id
```

`new`, `start`, and `open` are deliberately separate, and the order is **enforced**: `start` refuses to launch without `current/content/index.html`. The flow: `new $PWD <slug>` (creates the run, **no server**) → write the first `content/index.html` (the `plan` frame) → `start` (spawns the server) → `open`. Writing *before* `start` means the browser's first paint is the real plan, never the "not ready" placeholder — the guard makes that order-of-operations, not a request. A different chart later → call `preview.sh new $PWD <name>` again; same chart, more iterations → just rewrite `current/content/index.html`.

**Run `preview.sh` by its absolute path; never `cd`.** The `[pwd]` argument (`$PWD`) is the **user's working directory** — the dir you were in when the skill started — *not* the skill directory and *not* the temp folder; that's where `.openchoreo-import/` is created. Don't `cd` into the skill dir to run `./scripts/…`, and don't `cd` into `.openchoreo-import/` to read or write — use absolute paths (e.g. `$PWD/.openchoreo-import/current/content/index.html`).

## What the server does

- **Serves `current/content/`.** `/` → `current/content/index.html`; other paths → static files under `current/content/`.
- **Frame wrapping** — if the body doesn't start with `<!doctype` / `<html>`, splices it into `<!-- CONTENT -->` of the frame named in the `<!-- oc-frame: NAME -->` directive (falls back to `assets/frame.html`).
- **Auto-injects** `<link rel="stylesheet" href="/__tokens.css">` and `<link rel="stylesheet" href="/__components.css">` before `</head>`, and `<script src="/__helper.js" defer>` before `</body>`, on every HTML response — including full-doc opt-outs. Frame wrapping is opt-out; the tokens + components + helper injection is not.
- **Watches `current/content/`.** On change, broadcasts `{type:'reload'}` to all WebSocket clients. Uses `fs.watch` plus an `fs.watchFile` polling fallback (≤ 1.5 s) — `fs.watch` can silently miss atomic-write events on macOS.
- **Auto-clears `state/events.jsonl`** on every content change so the agent always sees a fresh window of user interactions.
- **Serves a "not ready" page** if `/` is hit before any content exists (browser auto-refreshes when content appears).
- **Self-monitors the harness's PID** every 60 s; exits when it dies. Override with `OC_OWNER_PID=…` to survive past the calling shell (e.g. manual review). Refuses to start in environments that reap detached processes (Codex CI, Git Bash on Windows).

## The WebSocket channel

All three frames are **view-only** — nothing in the UI sends events back. The WebSocket carries one direction of traffic: the server pushes `{type:'reload'}` when content changes, and the browser reloads. The user's input arrives through **chat**, not the page; you fold their replies into the next `content/index.html`.

## Brand tokens + component CSS

Brand palette + font stacks live in `assets/tokens.css`; the app shell, content typography, and the `<oc-*>` tag vocabulary live in `assets/components.css`. Both are auto-injected into every page. Content references the tokens as CSS custom properties (`var(--primary)`, `var(--ink)`, `var(--font-sans)`, etc.). You don't write CSS at all — no `<style>` blocks, no inline `style=`; you write `<oc-*>` tags + plain HTML and the stylesheet renders them (see [`frames.md`](frames.md) → *Tags you write*).

## Iteration loop

Each agent turn, confirm the server is up by reading `server-state/server-info.json` (restart it if not), resolve the active run via the `current/` symlink (or `preview.sh new $PWD <slug>` if starting a fresh chart), and read `<active-run>/state/events.jsonl` — every line is a user interaction since the last regeneration. Fold those plus the chat message into a new `current/content/index.html` and write it. The browser refreshes via WebSocket. End the turn.

Don't restart the server between turns. Don't re-render the manifests under `source-rendered/` unless the input source itself changed.
