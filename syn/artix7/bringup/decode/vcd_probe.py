#!/usr/bin/env python3
import sys
vcd = "/tmp/selftx.vcd"
want = {"'2":"hdr_valid_reg","J2":"m_udp_hdr_valid_reg","?1":"header_fifo_full",
        "q1":"header_fifo_empty",":.":"outgoing_ip_hdr_valid_reg"}
ones = {k: 0 for k in want}
firsttime = {k: None for k in want}
t = 0
for line in open(vcd):
    line = line.rstrip("\n")
    if line.startswith("#"):
        t = int(line[1:])
    elif len(line) >= 2 and line[0] in "01":
        val, sym = line[0], line[1:]
        if sym in want and val == "1":
            ones[sym] += 1
            if firsttime[sym] is None:
                firsttime[sym] = t
    elif line.startswith("b"):
        pass
for k, name in want.items():
    print(f"{name:28s} ones={ones[k]:5d} first_high@={firsttime[k]}")
