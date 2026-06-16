#!/usr/bin/env bash
# Print the OpenChoreo docs versions.json — the authoritative list of
# supported minors. First entry is the newest; pre-release tags may appear
# (alpha/beta/rc/m/…) and should be filtered out when "latest stable" is
# wanted. Stable = a plain vX.Y.x / vX.Y.Z with no suffix after the patch.
#
# Usage: list-versions.sh
set -euo pipefail
curl -fsSL https://raw.githubusercontent.com/openchoreo/openchoreo.github.io/main/versions.json
