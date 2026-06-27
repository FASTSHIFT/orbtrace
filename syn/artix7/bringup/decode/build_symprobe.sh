#!/usr/bin/env bash
set -eu
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORB="${ORB:-$(cd "$here/../../../../.." && pwd)/orbuculum}"
DW_SRC="$ORB/subprojects/libdwarf-0.7.0/src/lib/libdwarf"
DW_LIBDIR="$ORB/build/subprojects/libdwarf-0.7.0/src/lib/libdwarf"
cc -O2 -I "$ORB/Inc" -I "$ORB/Inc/external" -I "$DW_SRC" \
    -include uicolours_default.h \
    "$here/symprobe.c" \
    "$ORB/Src/loadelf.c" "$ORB/Src/readsource.c" "$ORB/Src/generics.c" \
    -L "$DW_LIBDIR" -ldwarf -Wl,-rpath,"$DW_LIBDIR" \
    $(pkg-config --cflags --libs capstone libelf) \
    -o "$here/symprobe"
echo "built $here/symprobe"
