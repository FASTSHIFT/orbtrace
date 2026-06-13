#!/usr/bin/env bash
# Build orbetm — the non-interactive ETM3.5 reconstruction tool that reuses
# orbuculum's decoder + symbol/disassembly engine (loadelf.c + capstone).
#
# Compiles against the orbuculum checkout (default: ../../../../../orbuculum,
# i.e. the orbcode-root sibling clone). Override with ORB=/path/to/orbuculum.
#
#   ./build_orbetm.sh           # -> ./orbetm
set -eu

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORB="${ORB:-$(cd "$here/../../../../.." && pwd)/orbuculum}"
OUT="${OUT:-$here/orbetm}"

if [ ! -d "$ORB/Src" ]; then
    echo "ERROR: orbuculum sources not found at $ORB (set ORB=...)"; exit 1
fi

# orbuculum vendors libdwarf as a meson subproject (it does NOT use the system
# dwarf.h, which is why a naive cc fails with "dwarf.h: No such file"). Reuse
# the already-built vendored copy from its meson build/ dir. It also force-
# includes uicolours_default.h globally (defines C_VERB_*), so we must too.
DW_SRC="$ORB/subprojects/libdwarf-0.7.0/src/lib/libdwarf"
DW_LIBDIR="$ORB/build/subprojects/libdwarf-0.7.0/src/lib/libdwarf"
if [ ! -f "$DW_SRC/dwarf.h" ] || [ ! -e "$DW_LIBDIR/libdwarf.so" ]; then
    echo "ERROR: vendored libdwarf not found. Build orbuculum first (meson"
    echo "       compile in $ORB/build) so subprojects/libdwarf-0.7.0 exists."
    exit 1
fi

cc -O2 \
    -I "$ORB/Inc" -I "$ORB/Inc/external" -I "$DW_SRC" \
    -include uicolours_default.h \
    "$here/orbetm.c" \
    "$ORB/Src/loadelf.c" \
    "$ORB/Src/readsource.c" \
    "$ORB/Src/traceDecoder.c" \
    "$ORB/Src/traceDecoder_etm35.c" \
    "$ORB/Src/traceDecoder_etm4.c" \
    "$ORB/Src/traceDecoder_mtb.c" \
    "$ORB/Src/generics.c" \
    -L "$DW_LIBDIR" -ldwarf -Wl,-rpath,"$DW_LIBDIR" \
    $(pkg-config --cflags --libs capstone libelf) \
    -o "$OUT"

echo "built $OUT"
