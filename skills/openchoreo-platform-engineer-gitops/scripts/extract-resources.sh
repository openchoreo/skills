#!/usr/bin/env bash
# Extract OpenChoreo default resources / GitOps workflow YAMLs. Prints raw
# YAML to stdout; never writes files, never edits — the agent does scope-swap,
# allowedWorkflows[] rewriting, runTemplate parameter editing, and PR open.
#
# Usage:
#   extract-resources.sh defaults --list
#   extract-resources.sh defaults --kind <Kind> [--name <name>] [--include-vanilla-ci]
#
#   extract-resources.sh gitops-workflows --list
#   extract-resources.sh gitops-workflows --name <slug>
#
# Sources:
#   defaults         → samples/getting-started/all.yaml in openchoreo/openchoreo
#   gitops-workflows → openchoreo.dev/ecosystem/workflows.md (filtered for "gitops");
#                      pairs each Workflow with its ClusterWorkflowTemplate
#
# Tag pinning:
#   OCC_TAG=vX.Y.z       — pins the openchoreo/openchoreo fetch (all.yaml).
#                          Defaults to "main".
#   GITOPS_TAG=vX.Y.z    — pins the openchoreo/sample-gitops fetches.
#                          Defaults to "main". sample-gitops has no tags today;
#                          set this only when that changes.
#
# Exit: 0 ok · 1 bad args · 2 not found · 3 fetch failed · 4 vanilla-CI guard

set -euo pipefail

OCC_TAG="${OCC_TAG:-main}"
GITOPS_TAG="${GITOPS_TAG:-main}"
DEFAULTS_URL="https://raw.githubusercontent.com/openchoreo/openchoreo/${OCC_TAG}/samples/getting-started/all.yaml"
WORKFLOWS_CATALOG_URL="https://openchoreo.dev/ecosystem/workflows.md"

VANILLA_CI="dockerfile-builder paketo-buildpacks-builder gcp-buildpacks-builder ballerina-buildpack-builder"

die() { echo "extract-resources: $1" >&2; exit "${2:-1}"; }

# Validate that $1 has a value (next arg exists and isn't another --flag). Use
# before any `shift 2` to give a clean error instead of "shift count out of range".
needs_value() {
  local flag="$1" next="${2-}"
  [[ -n "$next" && "$next" != -* ]] || die "$flag requires a value"
}

CURL_OPTS=(-fsSL --connect-timeout 10 --max-time 60)

usage() {
  sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 1
}

cmd_defaults() {
  local mode="" kind="" name="" allow_ci=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --list)               mode="list"; shift ;;
      --kind)               needs_value --kind "${2-}"; kind="$2"; shift 2 ;;
      --name)               needs_value --name "${2-}"; name="$2"; shift 2 ;;
      --include-vanilla-ci) allow_ci=1; shift ;;
      -h|--help)            usage ;;
      *)                    die "unknown arg: $1" ;;
    esac
  done

  [[ "$mode" == "list" || -n "$kind" ]] || die "need --list or --kind"

  local body
  body=$(curl "${CURL_OPTS[@]}" "$DEFAULTS_URL") || die "could not fetch $DEFAULTS_URL" 3

  if [[ "$mode" == "list" ]]; then
    awk -v vanilla="$VANILLA_CI" '
      BEGIN {
        n = split(vanilla, arr, " ")
        for (i = 1; i <= n; i++) vci[arr[i]] = 1
        kind = ""; name = ""
      }
      function flush() {
        if (kind != "" && name != "") {
          tag = ""
          if (kind == "ClusterWorkflow" && (name in vci))
            tag = "\t[vanilla CI — NOT GitOps-compatible]"
          printf "%s\t%s%s\n", kind, name, tag
        }
        kind = ""; name = ""
      }
      /^---[[:space:]]*$/ { flush(); next }
      kind == "" && $1 == "kind:" { kind = $2 }
      name == "" && $1 == "name:" { name = $2 }
      END { flush() }
    ' <<< "$body"
    return 0
  fi

  if [[ "$kind" == "ClusterWorkflow" && $allow_ci -ne 1 ]]; then
    cat >&2 <<'EOF'
extract-resources: ClusterWorkflows in all.yaml are vanilla CI workflows; they
write Workload directly to the cluster and Flux will revert. Use

  extract-resources.sh gitops-workflows ...

for GitOps mode. Override (rarely needed) with --include-vanilla-ci.
EOF
    exit 4
  fi

  local out rc
  set +e
  out=$(awk -v want_kind="$kind" -v want_name="$name" '
    BEGIN { buf = ""; kind = ""; name = ""; first = 1; matched = 0 }
    function flush() {
      if (kind == want_kind && (want_name == "" || name == want_name)) {
        if (!first) print "---"
        printf "%s", buf
        first = 0
        matched++
      }
      buf = ""; kind = ""; name = ""
    }
    /^---[[:space:]]*$/ { flush(); next }
    { buf = buf $0 "\n" }
    kind == "" && $1 == "kind:" { kind = $2 }
    name == "" && $1 == "name:" { name = $2 }
    END { flush(); exit matched > 0 ? 0 : 2 }
  ' <<< "$body")
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    if [[ -n "$name" ]]; then
      die "no $kind/$name in all.yaml" 2
    else
      die "no $kind in all.yaml" 2
    fi
  fi
  printf "%s" "$out"
}

cmd_gitops_workflows() {
  local mode="" name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --list)    mode="list"; shift ;;
      --name)    needs_value --name "${2-}"; name="$2"; shift 2 ;;
      -h|--help) usage ;;
      *)         die "unknown arg: $1" ;;
    esac
  done

  [[ "$mode" == "list" || -n "$name" ]] || die "need --list or --name"

  local catalog
  catalog=$(curl "${CURL_OPTS[@]}" "$WORKFLOWS_CATALOG_URL") || die "could not fetch $WORKFLOWS_CATALOG_URL" 3

  # bullet lines mentioning gitops (case-insensitive), pointing at sample-gitops
  local entries
  entries=$(printf '%s\n' "$catalog" \
    | grep -iE '^- \*\*[^*]+\*\*.*gitops' \
    | grep -E 'openchoreo/sample-gitops' || true)

  [[ -n "$entries" ]] || die "no GitOps workflows found in ecosystem catalog" 2

  # for each catalog line, emit: slug<TAB>raw-workflow-url<TAB>raw-template-url
  list_entry() {
    local line="$1" catalog_name slug url raw_url template_url
    catalog_name=$(sed -nE 's/^- \*\*([^*]+)\*\*.*/\1/p' <<< "$line")
    slug=$(tr '[:upper:]' '[:lower:]' <<< "$catalog_name" | tr ' ' '-')
    url=$(grep -oE 'https://[^ ]+' <<< "$line" | tail -1)
    raw_url=$(sed -E "s|github.com/([^/]+)/([^/]+)/blob/[^/]+/|raw.githubusercontent.com/\1/\2/${GITOPS_TAG}/|" <<< "$url")
    template_url=$(sed -E 's|/namespaces/[^/]+/platform/workflows/([^/]+)\.yaml$|/platform-shared/cluster-workflow-templates/argo/\1-template.yaml|' <<< "$raw_url")
    printf '%s\t%s\t%s\n' "$slug" "$raw_url" "$template_url"
  }

  if [[ "$mode" == "list" ]]; then
    while IFS= read -r line; do
      list_entry "$line"
    done <<< "$entries"
    return 0
  fi

  local matched="" entry slug
  while IFS= read -r line; do
    entry=$(list_entry "$line")
    slug=$(cut -f1 <<< "$entry")
    if [[ "$slug" == "$name" ]]; then
      matched="$entry"
      break
    fi
  done <<< "$entries"

  [[ -n "$matched" ]] || die "no GitOps workflow named '$name' (run --list to see options)" 2

  local wf_url tpl_url wf_yaml tpl_yaml
  wf_url=$(cut -f2 <<< "$matched")
  tpl_url=$(cut -f3 <<< "$matched")
  wf_yaml=$(curl "${CURL_OPTS[@]}" "$wf_url") || die "could not fetch $wf_url" 3
  tpl_yaml=$(curl "${CURL_OPTS[@]}" "$tpl_url") || die "could not fetch $tpl_url" 3
  printf '%s\n---\n%s' "$wf_yaml" "$tpl_yaml"
}

[[ $# -gt 0 ]] || usage
sub="$1"; shift
case "$sub" in
  defaults)         cmd_defaults "$@" ;;
  gitops-workflows) cmd_gitops_workflows "$@" ;;
  -h|--help)        usage ;;
  *)                die "unknown subcommand: $sub" ;;
esac
