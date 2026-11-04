#!/bin/bash
# Creates the "DockFX Local Signing" certificate in the login keychain, so the permissions
# you grant DockFX survive rebuilds. Run once.
set -euo pipefail
source "$(dirname "$0")/appshell.sh"
