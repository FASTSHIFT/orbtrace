#!/usr/bin/env bash
# Build a H743_Blink firmware variant with overridable PLL params.
#
# Usage:
#   build_h743.sh <tag> [M N P Q R]
#
# Examples:
#   build_h743.sh default                         # M=2 N=24 P=6 R=2 -> sys=16M TCLK=48M
#   build_h743.sh cpu100_trace100 2 50 4 2 4      # VCO=200 sys=50 TCLK=50  (nope)
#   build_h743.sh cpu100_trace100 4 100 2 2 2     # VCO=200 sys=100 TCLK=100
#
# Outputs go to $SRC/build/<tag>/ AND get copied+symlinked to $ROOT for easy
# use with existing flash / openocd tools.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../../../.." && pwd)
SRC="$ROOT/H743_Blink_src"

# HSE on THIS board is 25 MHz (not 8 MHz!). Using the wrong base silently
# overclocks the VCO/SYSCLK and crashes the core (INVSTATE / bad fetch) --
# that is exactly what bit us. Defaults below give a safe 200M/100M with 25M HSE.
HSE_MHZ="${HSE_MHZ:-25}"
TAG="${1:-default}"
M="${2:-2}"
N="${3:-32}"
P="${4:-2}"
Q="${5:-2}"
R="${6:-4}"

REF_MHZ=$((HSE_MHZ / M))
VCO_MHZ=$((HSE_MHZ * N / M))
SYSCLK_MHZ=$((VCO_MHZ / P))
HCLK_MHZ=$((SYSCLK_MHZ / 2))          # CubeMX config uses AHB /2
TRACECLK_MHZ=$((VCO_MHZ / R))
echo "==> build $TAG:  HSE=$HSE_MHZ M=$M N=$N P=$P Q=$Q R=$R"
echo "    ref=${REF_MHZ} MHz  VCO=${VCO_MHZ} MHz  sysclk=${SYSCLK_MHZ} MHz  HCLK=${HCLK_MHZ} MHz  TRACECLK=${TRACECLK_MHZ} MHz"

if [ "$REF_MHZ" -lt 4 ] || [ "$REF_MHZ" -gt 16 ]; then
    echo "!! WARNING: PLL ref=${REF_MHZ}M is outside RANGE_3 [8..16] / valid [4..16] -- fix M"
fi
if [ "$VCO_MHZ" -lt 192 ] || [ "$VCO_MHZ" -gt 836 ]; then
    echo "!! WARNING: VCO=${VCO_MHZ}M is outside the wide-mode PLL range [192..836]"
fi
if [ "$SYSCLK_MHZ" -gt 200 ]; then
    echo "!! WARNING: sysclk=${SYSCLK_MHZ}M > 200M -- exceeds VOS1 max, WILL crash the core"
fi

DEFS="-DPLL_M_OVR=$M -DPLL_N_OVR=$N -DPLL_P_OVR=$P -DPLL_Q_OVR=$Q -DPLL_R_OVR=$R"
BUILDDIR="$SRC/build/$TAG"

mkdir -p "$BUILDDIR"
(cd "$SRC" && rm -f "$BUILDDIR"/H743_Blink.* && \
    make -j4 \
        BUILD_DIR="build/$TAG" \
        C_DEFS="-DUSE_HAL_DRIVER -DSTM32H743xx $DEFS" \
    2>&1 | tail -4)

ART="$BUILDDIR/H743_Blink"
if [ -f "$ART.hex" ] && [ -f "$ART.elf" ]; then
    OUT="$ROOT/perf/firmware/$TAG"
    mkdir -p "$OUT"
    cp "$ART.hex" "$OUT/H743_Blink.hex"
    cp "$ART.elf" "$OUT/H743_Blink.axf"
    ln -sf "$OUT/H743_Blink.axf" "$ROOT/H743_Blink.axf"
    ln -sf "$OUT/H743_Blink.hex" "$ROOT/H743_Blink.hex"
    echo "==> installed $OUT/H743_Blink.{hex,axf}"
    echo "    symlinked to workspace root"
else
    echo "!! BUILD FAILED"; exit 1
fi
