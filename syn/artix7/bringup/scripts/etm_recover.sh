#!/usr/bin/env bash
# Maximise PC/function recovery from a raw ETM3.5 capture by decoding from
# EVERY A-sync offset independently and unioning the resolved flash addresses.
# Each A-sync gives the ETM35 decoder a fresh packet-alignment anchor; even
# without continuous I-SYNC lock, this recovers the set of executed functions.
#
#   ./etm_recover.sh /tmp/frames2.bin [proj.axf]
set -eu
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILE="${1:-/tmp/frames2.bin}"
AXF="${2:-/tmp/axf/proj_new.axf}"
A2L="${A2L:-/usr/bin/arm-none-eabi-addr2line}"
ETMDEC="${ETMDEC:-/tmp/etmdecode}"

python3 - "$FILE" <<'PY' > /tmp/asyncoffs.txt
import sys
d=open(sys.argv[1],'rb').read()
A=bytes.fromhex('000000000080')
i=0; offs=[]
while True:
    j=d.find(A,i)
    if j<0: break
    offs.append(j); i=j+1
print('\n'.join(map(str,offs)))
PY

n=$(wc -l < /tmp/asyncoffs.txt)
echo "==> $n A-sync anchors in $FILE"
: > /tmp/allflash.txt
while read off; do
    [ -z "$off" ] && continue
    tail -c +$((off+1)) "$FILE" > /tmp/_seg.bin
    "$ETMDEC" /tmp/_seg.bin 2>/dev/null | grep -oE "0x080[0-9a-f]{5}" >> /tmp/allflash.txt || true
done < /tmp/asyncoffs.txt

sort -u /tmp/allflash.txt > /tmp/flash_u.txt
echo "==> $(wc -l < /tmp/flash_u.txt) distinct flash addresses recovered"
echo "==> distinct functions executed:"
"$A2L" -f -e "$AXF" @/tmp/flash_u.txt 2>/dev/null | awk 'NR%2==1' | sort -u | grep -v '^__dso_handle$' | grep -v '^??$'
