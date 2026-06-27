#!/usr/bin/env bash
# Full-stack self-TX sim: udp_tx_streamer + real udp_complete + ARP peer.
# Reproduces the "no packet sent" hardware bug in iverilog.
set -eu
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bringup="$(cd "$here/.." && pwd)"
repo="$(cd "$bringup/../../.." && pwd)"
ex="$repo/syn/external/verilog-ethernet/example/NexysVideo/fpga"
L="$ex/lib/eth/rtl"
AX="$ex/lib/eth/lib/axis/rtl"

iverilog -g2012 -o /tmp/selftx_full \
    "$bringup/rtl/udp_tx_streamer.v" \
    "$bringup/rtl/sim/udp_tx_streamer_tb.v" \
    "$L/udp_complete.v" "$L/udp.v" "$L/udp_ip_rx.v" "$L/udp_ip_tx.v" \
    "$L/udp_checksum_gen.v" \
    "$L/ip_complete.v" "$L/ip.v" "$L/ip_eth_rx.v" "$L/ip_eth_tx.v" "$L/ip_arb_mux.v" \
    "$L/arp.v" "$L/arp_cache.v" "$L/arp_eth_rx.v" "$L/arp_eth_tx.v" \
    "$L/eth_arb_mux.v" \
    "$L/lfsr.v" \
    "$AX/arbiter.v" "$AX/priority_encoder.v" "$AX/axis_fifo.v" \
    2>&1 | tee /tmp/selftx_sim_build.log

vvp /tmp/selftx_full
