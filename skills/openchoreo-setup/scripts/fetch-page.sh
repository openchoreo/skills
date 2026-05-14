#!/usr/bin/env bash
# Fetch an OpenChoreo docs page by title; print rendered Markdown to stdout.
# Resolves the title against openchoreo.dev/llms.txt (a `- [Title](URL)` index).
#
# Usage:
#   fetch-page.sh --title "<title>" [--exact] [--section "<name>"] [--version <minor>|next]
#   fetch-page.sh --list [--section "<name>"] [--version <minor>|next]
#
#   --exact     match the bracketed title verbatim (default: substring)
#   --section   scope matching to one llms.txt heading's subtree
#   --version   pin a minor (default: latest stable); "next" = bleeding-edge docs
#
# Exit: 0 ok · 1 bad args · 2 zero/multiple matches (index dumped) · 3 fetch failed

set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/openchoreo/openchoreo.github.io/main"
LLMS_URL="https://openchoreo.dev/llms.txt"

die() { echo "fetch-page: $*" >&2; exit "${2:-1}"; }

# Print one heading's subtree from stdin: the named heading down to the
# next heading of the same or higher level. Empty if not found.
extract_section() {
  awk -v name="$1" '
    /^#+ / {
      n = 0; while (substr($0, n + 1, 1) == "#") n++
      heading = substr($0, n + 2)
      if (inside && n <= lvl) inside = 0
      if (!inside && heading == name) { lvl = n; inside = 1; print; next }
    }
    inside { print }
  '
}

title="" version="" section="" list_only=0 exact=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)   title="${2:-}"; shift 2 ;;
    --version) version="${2:-}"; shift 2 ;;
    --section) section="${2:-}"; shift 2 ;;
    --list)    list_only=1; shift ;;
    --exact)   exact=1; shift ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1 ;;
    *)         die "unknown argument: $1" ;;
  esac
done

[[ $list_only -eq 1 || -n "$title" ]] || die "missing --title (or --list)"

# "next" = the unreleased docs/ tree: its own index, URLs already prefixed.
if [[ "$version" == "next" ]]; then
  llms=$(curl -fsSL "https://openchoreo.dev/llms-next.txt") || die "could not fetch llms-next.txt"
  echo "fetch-page: using bleeding-edge (next) docs" >&2
else
  versions_json=$(curl -fsSL "$REPO_RAW/versions.json") || die "could not fetch versions.json"
  available=()
  while IFS= read -r v; do available+=("$v"); done \
    < <(printf '%s' "$versions_json" | grep -oE '"[^"]+"' | tr -d '"')
  [[ ${#available[@]} -gt 0 ]] || die "versions.json was empty or unparsable"

  if [[ -z "$version" ]]; then
    # default: newest minor that isn't a pre-release
    for v in "${available[@]}"; do
      [[ "$v" =~ -(alpha|beta|rc|pre|dev) ]] || { version="$v"; break; }
    done
    [[ -n "$version" ]] || die "no stable version in versions.json (${available[*]})"
    echo "fetch-page: defaulting to latest stable: $version" >&2
  else
    printf '%s\n' "${available[@]}" | grep -qxF "$version" \
      || die "version '$version' not in versions.json (${available[*]} or 'next')"
  fi

  llms=$(curl -fsSL "$LLMS_URL") || die "could not fetch $LLMS_URL"
fi

# current version is named in the llms.txt header: "# OpenChoreo Documentation (vX)"
current_version=$(printf '%s' "$llms" \
  | grep -m1 -oE 'OpenChoreo Documentation \([^)]+\)' | sed -E 's/.*\((.*)\)/\1/' || true)

# scope to a section if asked (current_version was read above, from the full header)
search_index="$llms"
if [[ -n "$section" ]]; then
  search_index=$(printf '%s' "$llms" | extract_section "$section")
  [[ -n "$search_index" ]] \
    || die "section '$section' not found. Sections:"$'\n'"$(printf '%s' "$llms" | grep -E '^#+ ' | sed -E 's/^#+ +//')"
fi

if [[ $list_only -eq 1 ]]; then
  printf '%s\n' "$search_index"
  exit 0
fi

# match the bracketed title in `- [Title](URL)` lines (regex-escaped, case-sensitive)
escaped_title=$(printf '%s' "$title" | sed -E 's/[][(){}.^$*+?|\\/]/\\&/g')
if [[ $exact -eq 1 ]]; then
  matches=$(printf '%s' "$search_index" | grep -E "^- \[${escaped_title}\]\(" || true)
else
  matches=$(printf '%s' "$search_index" | grep -E "^- \[[^]]*${escaped_title}[^]]*\]\(" || true)
fi
match_count=$(printf '%s' "$matches" | grep -c '^-' || true)

if [[ "$match_count" -ne 1 ]]; then
  scope=${section:+ in section \'$section\'}
  if [[ "$match_count" -eq 0 ]]; then
    echo "fetch-page: no entry${scope} matches '$title'; dumping index" >&2
  else
    echo "fetch-page: '$title'${scope} matches $match_count entries; dumping index" >&2
    printf '%s\n' "$matches" >&2
  fi
  printf '%s\n' "$search_index"
  exit 2
fi

url=$(printf '%s' "$matches" | sed -E 's/^- \[[^]]+\]\(([^)]+)\).*$/\1/')

# non-current versions: /docs/<path> → /docs/<version>/<path> (docs root is special)
if [[ "$version" != "next" && -n "$current_version" && "$version" != "$current_version" ]]; then
  if [[ "$url" == *"/docs.md" ]]; then
    url="${url%/docs.md}/docs/${version}.md"
  else
    url="$(printf '%s' "$url" | sed "s|/docs/|/docs/${version}/|")"
  fi
fi

page=$(curl -fsSL "$url") \
  || { echo "fetch-page: could not fetch $url; dumping index" >&2; printf '%s\n' "$search_index"; exit 3; }
printf '%s' "$page"
