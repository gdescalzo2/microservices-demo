#!/usr/bin/env bash
# Same as: platform/scripts/build-image.sh frontend <version>
# Kept because bootstrap.sh and the demo commands call it.
#
# Usage: platform/scripts/build-frontend.sh <version>        e.g. 1.1.0
#        FORCE=1 platform/scripts/build-frontend.sh <version>   rebuild and reload
exec "$(dirname "$0")/build-image.sh" frontend "$@"
