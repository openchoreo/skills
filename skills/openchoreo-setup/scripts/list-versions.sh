#!/usr/bin/env bash
# Print the OpenChoreo docs versions.json — the authoritative list of
# supported minors. First entry is the newest; pre-release tags
# (alpha/beta/rc/pre/dev) may appear and should be filtered out when
# "latest stable" is wanted.
#
# Usage: list-versions.sh
set -euo pipefail
curl -fsSL https://raw.githubusercontent.com/openchoreo/openchoreo.github.io/main/versions.json
