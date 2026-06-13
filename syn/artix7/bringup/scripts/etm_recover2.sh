#!/usr/bin/env bash
# Force-sync ETM3.5 recovery: build (if needed) and run etmdecode2, which
# force-syncs the decoder at every ETM A-sync (5+ zero bytes + 0x80) so it
# re-anchors cleanly even when the inter-sync stream has occasional byte
# errors. Maps recovered flash PCs to function names.
#
#   ./etm_recover2.sh /tmp/capA.bin [proj.axf]
#   ./etm_recover2.sh "/tmp/capA.bin /tmp/frames2.bin" proj.axf   # multiple
set -eu
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../../../.." && pwd)"
orb="$repo_root/orbuculum"
FILES="${1:-/tmp/capA.bin}"
AXF="${2:-/tmp/axf/proj_new.axf}"
A2L="${A2L:-/usr/bin/arm-none-eabi-addr2line}"
BIN=/tmp/etmdecode2

if [ ! -x "$BIN" ] || [ "$here/etmdecode2.c" -nt "$BIN" ]; then
    echo "==> building etmdecode2"
    ( cd "$orb" && cc -I Inc -I Inc/external -include uicolours_default.h \
        "$here/etmdecode2.c" Src/traceDecoder.c Src/traceDecoder_etm35.c \
        Src/traceDecoder_etm4.c Src/traceDecoder_mtb.c Src/generics.c -o "$BIN" )
fi

cat $FILES > /tmp/_recover_in.bin
"$BIN" /tmp/_recover_in.bin 1>/tmp/_recover_addrs.txt 2>/tmp/_recover_stat.txt
cat /tmp/_recover_stat.txt
sort -u /tmp/_recover_addrs.txt > /tmp/_recover_fa.txt
echo "==> $(wc -l < /tmp/_recover_fa.txt) distinct flash PCs"
echo "==> functions executed (LVGL):"
"$A2L" -f -e "$AXF" @/tmp/_recover_fa.txt 2>/dev/null | awk 'NR%2==1' \
    | sort -u | grep -vE '^(__dso_handle|\?\?)$'
