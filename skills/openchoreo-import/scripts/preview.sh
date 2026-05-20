#!/usr/bin/env bash
# Preview server for the openchoreo-import skill.
#
# Layout in $PWD/.openchoreo-import/:
#   .gitignore                  "*"
#   current  -> runs/<id>       symlink to the active run
#   runs/<id>/                  one folder per plan (see below)
#     meta.json                 {id, name, started_at, status}
#     content/index.html        the rendered page for this run
#     plan.json, plan.md        source of truth + deliverable
#     source-rendered/          helm template / kustomize build / raw YAML copy
#     state/events.jsonl        user interactions captured by the page
#   server-state/               global (per server process, not per run)
#     server-info.json, server.log
#
# Subcommands:
#   preview.sh start  [pwd]             launch server; ensure `current` exists; prints URL (does NOT open browser)
#   preview.sh open   [pwd]             open the running server's URL in the user's browser
#   preview.sh stop   [pwd]             stop the server
#   preview.sh new    [pwd] <slug>      create a new run, flip `current` to it; prints id

set -euo pipefail
die() { echo "preview: $*" >&2; exit 1; }

cmd="${1:-}"
case "$cmd" in
  start|open|stop|new) ;;
  ""|-h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1 ;;
  *) die "unknown subcommand: $cmd (use start | open | stop | new)" ;;
esac

# Parse positional args (pwd is always optional; positions shift for `new` / `switch`)
PWD_ARG="$PWD"
ARG3=""
if [[ $# -ge 2 ]]; then
  if [[ -d "$2" ]]; then PWD_ARG="$2"; ARG3="${3:-}"
  else ARG3="$2"
  fi
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVER_JS="$SCRIPT_DIR/server.cjs"
PREVIEW="$PWD_ARG/.openchoreo-import"
RUNS_DIR="$PREVIEW/runs"
CURRENT_LINK="$PREVIEW/current"
SERVER_STATE="$PREVIEW/server-state"
INFO="$SERVER_STATE/server-info.json"
LOG="$SERVER_STATE/server.log"
STOPPED="$SERVER_STATE/server-stopped"

# ---------- helpers ----------

bootstrap_root() {
  mkdir -p "$RUNS_DIR" "$SERVER_STATE"
  [[ -f "$PREVIEW/.gitignore" ]] || printf '*\n' > "$PREVIEW/.gitignore"
}

slug_of() {
  echo "${1:-untitled}" | tr -cs 'a-zA-Z0-9._-' '-' | tr '[:upper:]' '[:lower:]' | sed 's/^-//;s/-$//' | head -c 60
}

new_run() {
  bootstrap_root
  local slug; slug=$(slug_of "${1:-untitled}")
  [[ -n "$slug" ]] || slug="untitled"
  local id; id="$(date -u +'%Y%m%d-%H%M%S')-$slug"
  local dir="$RUNS_DIR/$id"
  mkdir -p "$dir/content" "$dir/state" "$dir/source-rendered"
  local now; now="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  cat > "$dir/meta.json" <<EOF
{
  "id": "$id",
  "name": "$slug",
  "started_at": "$now",
  "status": "draft"
}
EOF
  # NO placeholder index.html — agent writes the real content before calling
  # preview.sh open. If the URL is hit before content lands, the server returns
  # a tiny "not ready" page (see server.cjs) instead of a misleading placeholder.
  echo "$id"
}

set_current() {
  local id="$1"
  [[ -d "$RUNS_DIR/$id" ]] || die "no such run: $id"
  rm -f "$CURRENT_LINK"
  (cd "$PREVIEW" && ln -s "runs/$id" current)
}

ensure_current() {
  bootstrap_root
  if [[ ! -L "$CURRENT_LINK" ]] || [[ ! -d "$CURRENT_LINK/" ]]; then
    local id; id=$(new_run "untitled")
    set_current "$id"
  fi
}

refuse_reaping_env() {
  local why=""
  [[ -n "${CODEX_CI:-}" ]] && why="Codex CI (\$CODEX_CI is set)"
  case "${OSTYPE:-}" in
    msys*|cygwin*|mingw*) why="${why:-Git Bash / MSYS (\$OSTYPE=$OSTYPE)}" ;;
  esac
  [[ -n "${MSYSTEM:-}" && -z "$why" ]] && why="Git Bash / MSYS (\$MSYSTEM=$MSYSTEM)"
  if [[ -n "$why" ]]; then
    die "this environment ($why) reaps background processes — preview server won't persist. Run from a terminal that survives backgrounding (macOS / Linux / WSL2)."
  fi
}

resolve_owner_pid() {
  # Honor an explicit OC_OWNER_PID from the caller's env (e.g. set OC_OWNER_PID=1
  # to make the server survive past the calling shell — useful for manual review).
  [[ -n "${OC_OWNER_PID:-}" ]] && { echo "$OC_OWNER_PID"; return; }
  local owner
  owner="$(ps -o ppid= -p "$PPID" 2>/dev/null | tr -d ' ' || true)"
  [[ -z "$owner" || "$owner" == "1" || "$owner" == "0" ]] && owner="$PPID"
  echo "$owner"
}

kill_tree() {
  local pid="$1"
  [[ -n "$pid" ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  if command -v pgrep >/dev/null 2>&1; then
    for c in $(pgrep -P "$pid" 2>/dev/null || true); do kill "$c" 2>/dev/null || true; done
  fi
  kill "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
  if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fi
}

# ---------- subcommands ----------

do_start() {
  refuse_reaping_env
  ensure_current

  if [[ -f "$INFO" ]]; then
    local pid url
    pid=$(grep -oE '"pid"[[:space:]]*:[[:space:]]*[0-9]+' "$INFO" | grep -oE '[0-9]+' || true)
    url=$(grep -oE '"url"[[:space:]]*:[[:space:]]*"[^"]*"' "$INFO" | sed -E 's/.*"url"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' || true)
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "preview: server already running (pid $pid)" >&2
      printf '%s\n' "$url"
      return 0
    fi
    rm -f "$INFO"
  fi
  rm -f "$STOPPED"

  # Guard: refuse to spawn the server until the plan has been written. Forces
  # the documented order new → write → start, so the browser never lands on
  # the "not ready" placeholder.
  [[ -s "$CURRENT_LINK/content/index.html" ]] || die "no content at $CURRENT_LINK/content/index.html — write the plan frame there first (order: new → write → start → open)"

  command -v node >/dev/null 2>&1 || die "node not found — install Node.js (>= 18)"
  [[ -f "$SERVER_JS" ]] || die "server.cjs missing at $SERVER_JS"

  local owner; owner="$(resolve_owner_pid)"
  : > "$LOG"
  nohup env OC_PREVIEW_DIR="$PREVIEW" OC_PORT=0 OC_OWNER_PID="$owner" \
    node "$SERVER_JS" >> "$LOG" 2>&1 &
  local pid=$!
  disown "$pid" 2>/dev/null || true

  local ready=0
  for _ in $(seq 1 60); do
    if grep -q '"event":"server-started"' "$LOG" 2>/dev/null; then ready=1; break; fi
    kill -0 "$pid" 2>/dev/null || { echo "preview: server died on startup. Log:" >&2; tail -n 30 "$LOG" >&2; die "server failed to start"; }
    sleep 0.1
  done
  [[ $ready -eq 1 ]] || { tail -n 30 "$LOG" >&2; kill "$pid" 2>/dev/null || true; die "server failed to become ready"; }

  sleep 2
  kill -0 "$pid" 2>/dev/null || { tail -n 30 "$LOG" >&2; die "server reaped after start"; }

  local url; url=$(grep -m1 -oE '"url":"[^"]*"' "$LOG" | sed -E 's/"url":"([^"]*)"/\1/')

  echo "preview: server running on $url (pid $pid, owner $owner). Browser not opened — call \`preview.sh open\` after first content lands." >&2
  printf '%s\n' "$url"
}

do_open() {
  [[ -f "$INFO" ]] || die "server not running — run 'preview.sh start [pwd]' first"
  local url; url=$(grep -oE '"url"[[:space:]]*:[[:space:]]*"[^"]*"' "$INFO" | sed -E 's/.*"url"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
  [[ -n "$url" ]] || die "could not read URL from $INFO"
  command -v open     >/dev/null 2>&1 && open "$url"     >/dev/null 2>&1 || \
  command -v xdg-open >/dev/null 2>&1 && xdg-open "$url" >/dev/null 2>&1 || true
  echo "preview: opened $url in browser" >&2
  printf '%s\n' "$url"
}

do_stop() {
  [[ -f "$INFO" ]] || { echo "preview: nothing to stop" >&2; return 0; }
  local pid
  pid=$(grep -oE '"pid"[[:space:]]*:[[:space:]]*[0-9]+' "$INFO" | grep -oE '[0-9]+' || true)
  kill_tree "$pid"
  [[ -n "$pid" ]] && echo "preview: stopped pid $pid" >&2
  date -u +'%Y-%m-%dT%H:%M:%SZ' > "$STOPPED"
  rm -f "$INFO"
}

do_new() {
  local id; id=$(new_run "${ARG3:-untitled}")
  set_current "$id"
  echo "$id"
}

case "$cmd" in
  start)  do_start ;;
  open)   do_open ;;
  stop)   do_stop ;;
  new)    do_new ;;
esac
