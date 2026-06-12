#!/usr/bin/env bash
# Decode a captured OrbFlow (.bin) file with the orbuculum tools.
#
#   ./decode.sh /tmp/oflow.bin            # orbcat: dump ITM/data in OFLOW tag 1
#   AXF=/tmp/axf/proj_new.axf ./decode.sh /tmp/oflow.bin --mortem
#
# The trace_orbflow_top bitstream emits a native OFLOW stream (super_framer +
# COBS + checksum), so orbcat/orbmortem ingest it directly with -p OFLOW and
# no PC-side byte juggling.
set -eu

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../../../.." && pwd)"
orb="$repo_root/orbuculum/build"
file="${1:-/tmp/oflow.bin}"
mode="${2:-cat}"
TAG="${TAG:-1}"
AXF="${AXF:-/tmp/axf/proj_new.axf}"

if [ ! -f "$file" ]; then echo "ERROR: $file not found"; exit 1; fi

if [ "$mode" = "--mortem" ]; then
    if [ ! -x "$orb/orbmortem" ]; then echo "ERROR: $orb/orbmortem missing (build orbuculum)"; exit 1; fi
    echo "==> orbmortem -P ETM3.5 -e $AXF  (ncurses; OFLOW tag $TAG)"
    "$orb/orbmortem" -f "$file" -P ETM3.5 -e "$AXF" -t "$TAG"
else
    if [ ! -x "$orb/orbcat" ]; then echo "ERROR: $orb/orbcat missing (build orbuculum)"; exit 1; fi
    echo "==> orbcat -p OFLOW -t $TAG -f $file -E"
    "$orb/orbcat" -p OFLOW -t "$TAG" -f "$file" -E
fi
