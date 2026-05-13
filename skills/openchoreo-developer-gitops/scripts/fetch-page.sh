#!/usr/bin/env bash
# Fetch a single OpenChoreo docs page by title, optionally pinned to a
# specific version, and print the rendered Markdown to stdout.
#
# Discovery uses openchoreo.dev/llms.txt — a flat index of every page in
# the current version, one per line, in `- [Title](URL)` form. The script
# matches against the bracketed title; on any miss (zero hits, multiple
# hits, fetch failure) it prints the full llms.txt to stdout and exits
# non-zero so the caller can pick by hand.
#
# Versioned pages: openchoreo.dev serves the current version at
# `/docs/<path>.md` and older versions at `/docs/<version>/<path>.md`.
# The .md endpoint returns rendered Markdown with `${versions.X}`
# constants already substituted server-side — no client substitution is
# needed. The current version is named in the llms.txt header
# `# OpenChoreo Documentation (vX)`.
#
# Usage:
#   fetch-page.sh --title "<title>" [--exact] [--version <minor>|next]
#   fetch-page.sh --list [--version <minor>|next]
#
# --exact matches the bracketed title verbatim. Without it, --title is a
# substring match. Many CRD names (e.g. "Component", "Workload",
# "ClusterWorkflow") appear as substrings of other page titles — use
# --exact when you mean the bare API reference page only.
#
# --version next uses the bleeding-edge docs (the `docs/` tree, served
# at /docs/next/...). Its index is at llms-next.txt.
#
# Exit codes:
#   0  page printed to stdout
#   1  argument or version error
#   2  zero or multiple title matches (llms.txt printed for the agent)
#   3  fetch failure on the resolved URL (llms.txt printed)

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/openchoreo/openchoreo.github.io/main"
LLMS_URL="https://openchoreo.dev/llms.txt"

die() { echo "fetch-page: $*" >&2; exit "${2:-1}"; }

title=""
version=""
list_only=0
exact=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)    title="${2:-}"; shift 2 ;;
    --version)  version="${2:-}"; shift 2 ;;
    --list)     list_only=1; shift ;;
    --exact)    exact=1; shift ;;
    -h|--help)
      sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//' >&2
      exit 1 ;;
    *) die "unknown argument: $1" ;;
  esac
done

if [[ $list_only -eq 0 && -z "$title" ]]; then
  die "missing --title (or pass --list to dump the full index)"
fi

# Special case: --version next pulls the bleeding-edge docs (the `docs/`
# tree in openchoreo.github.io, served at /docs/next/...). It's not in
# versions.json; its index is at llms-next.txt and its URLs are already
# correctly prefixed, so the URL transform below is skipped.
if [[ "$version" == "next" ]]; then
  llms=$(curl -fsSL "https://openchoreo.dev/llms-next.txt") \
    || die "could not fetch llms-next.txt" 1
  echo "fetch-page: using bleeding-edge (next) docs" >&2
else
  # Fetch versions.json once, parse to an array of supported minors.
  versions_json=$(curl -fsSL "$REPO_RAW/versions.json") \
    || die "could not fetch versions.json" 1
  available=()
  while IFS= read -r v; do
    available+=("$v")
  done < <(printf '%s' "$versions_json" | grep -oE '"[^"]+"' | tr -d '"')
  [[ ${#available[@]} -gt 0 ]] || die "versions.json was empty or unparsable" 1

  # Default --version to the latest non-pre-release minor when omitted.
  if [[ -z "$version" ]]; then
    for v in "${available[@]}"; do
      if [[ ! "$v" =~ -(alpha|beta|rc|pre|dev) ]]; then
        version="$v"; break
      fi
    done
    [[ -n "$version" ]] || die "no stable version in versions.json (all entries look pre-release: ${available[*]})"
    echo "fetch-page: defaulting to latest stable version: $version" >&2
  else
    found=0
    for v in "${available[@]}"; do
      [[ "$v" == "$version" ]] && { found=1; break; }
    done
    [[ $found -eq 1 ]] || die "version '$version' is not in versions.json (supported: ${available[*]} or 'next')"
  fi

  llms=$(curl -fsSL "$LLMS_URL") || die "could not fetch $LLMS_URL" 1
fi

# The current version is whichever one openchoreo.dev's "current" docs
# point to. It's named in the header of llms.txt as:
#   # OpenChoreo Documentation (vX.Y.Z[-tag])
current_version=$(printf '%s' "$llms" \
  | grep -m1 -oE 'OpenChoreo Documentation \([^)]+\)' \
  | sed -E 's/.*\((.*)\)/\1/' || true)

if [[ $list_only -eq 1 ]]; then
  printf '%s\n' "$llms"
  exit 0
fi

# Match against the bracketed title in `- [Title](URL)` lines. Escape
# regex metacharacters in the title first so it's matched literally.
# Substring match by default; --exact requires the bracket contents to
# equal the title verbatim. Case-sensitive in both modes.
escaped_title=$(printf '%s' "$title" | sed -E 's/[][(){}.^$*+?|\\/]/\\&/g')
if [[ $exact -eq 1 ]]; then
  matches=$(printf '%s' "$llms" \
    | grep -E "^- \[${escaped_title}\]\(" || true)
else
  matches=$(printf '%s' "$llms" \
    | grep -E "^- \[[^]]*${escaped_title}[^]]*\]\(" || true)
fi

match_count=$(printf '%s' "$matches" | grep -c '^-' || true)

if [[ "$match_count" -ne 1 ]]; then
  if [[ "$match_count" -eq 0 ]]; then
    echo "fetch-page: no entry in llms.txt matches title '$title'; dumping full index" >&2
  else
    echo "fetch-page: title '$title' matches $match_count entries; dumping full index" >&2
    printf '%s\n' "$matches" >&2
  fi
  printf '%s\n' "$llms"
  exit 2
fi

# Extract the URL inside the matched `(...)` pair.
url=$(printf '%s' "$matches" \
  | sed -E 's/^- \[[^]]+\]\(([^)]+)\).*$/\1/')

# Transform URL for non-current versions: `/docs/<path>` becomes
# `/docs/<version>/<path>`. Skip for `next` (URLs in llms-next.txt are
# already prefixed with `/docs/next/`). Special-case the docs root
# (`/docs.md`) which would otherwise transform to `/docs/<version>.md`.
if [[ "$version" != "next" && -n "$current_version" && "$version" != "$current_version" ]]; then
  if [[ "$url" == *"/docs.md" ]]; then
    url="${url%/docs.md}/docs/${version}.md"
  else
    url="$(printf '%s' "$url" | sed "s|/docs/|/docs/${version}/|")"
  fi
fi

if ! page=$(curl -fsSL "$url"); then
  echo "fetch-page: could not fetch $url; dumping full index" >&2
  printf '%s\n' "$llms"
  exit 3
fi

printf '%s' "$page"
