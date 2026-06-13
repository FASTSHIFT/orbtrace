#!/usr/bin/env python3
"""make_opencsd_snapshot — wrap our captured bare-ETM stream + ELF into an
OpenCSD "snapshot" directory so the ARM/Linaro reference decoder
(trc_pkt_lister) can decode it.

This is PURE GLUE — no trace-decode logic. It writes the 3 ini files the
OpenCSD snapshot format requires (spec: ARM-ECM-0611873, shipped in
/usr/share/doc/libopencsd-dev/specs/) and drops in the trace buffer + a memory
image (the ELF's executable sections) so the decoder can follow program flow.

ETMv3 decode needs only 4 registers (spec §4.2.1): ETMCR, ETMCCER, ETMIDR,
ETMTRACEIDR — read live from the STM32F429 M4:
    ETMCR=0x00000980  ETMCCER=0x18541800  ETMIDR=0x4114f250  ETMTRACEIDR=0x02

Usage:
    python3 make_opencsd_snapshot.py <bare-etm.bin> <elf> <out_dir> \
        [--coresight]      # input still has TPIU framing (use -tpiu in lister)

Then:
    trc_pkt_lister -ss_dir <out_dir> -decode -decode_only -logstdout
    (+ -tpiu if --coresight was used)
"""
import argparse
import os
import subprocess
import sys

READELF = os.environ.get("READELF", "arm-none-eabi-readelf")
OBJCOPY = os.environ.get("OBJCOPY", "arm-none-eabi-objcopy")

# Live ETMv3 register values for the STM32F429 Cortex-M4 ETM (override via env).
ETMCR = int(os.environ.get("ETMCR", "0x00000980"), 0)
ETMCCER = int(os.environ.get("ETMCCER", "0x18541800"), 0)
ETMIDR = int(os.environ.get("ETMIDR", "0x4114f250"), 0)
ETMTRACEIDR = int(os.environ.get("ETMTRACEIDR", "0x00000002"), 0)


def text_sections(elf):
    """Return [(addr, size, off)] for executable (AX) flash sections."""
    p = subprocess.run([READELF, "-S", "-W", elf],
                       capture_output=True, text=True)
    out = []
    import re
    for line in p.stdout.splitlines():
        # [Nr] Name Type Addr Off Size ES Flg Lk Inf Al
        m = re.search(r"\]\s+(\S+)\s+\w+\s+([0-9a-fA-F]{8,16})\s+"
                      r"([0-9a-fA-F]+)\s+([0-9a-fA-F]+)\s+\S+\s+([A-Zp]*)", line)
        if not m:
            continue
        addr = int(m.group(2), 16)
        off = int(m.group(3), 16)
        size = int(m.group(4), 16)
        flg = m.group(5)
        if "X" in flg and addr >= 0x08000000 and size > 0:
            out.append((addr, size, off))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace")
    ap.add_argument("elf")
    ap.add_argument("out_dir")
    ap.add_argument("--coresight", action="store_true",
                    help="trace still has TPIU framing (format=coresight)")
    a = ap.parse_args()

    os.makedirs(a.out_dir, exist_ok=True)

    # 1) Trace buffer: copy the captured bytes in.
    trace_bytes = open(a.trace, "rb").read()
    with open(os.path.join(a.out_dir, "etm.bin"), "wb") as f:
        f.write(trace_bytes)

    # 2) Memory image: dump the whole flash code image as a flat binary so the
    #    decoder can fetch opcodes. objcopy -O binary gives a flash-base image.
    mem_bin = os.path.join(a.out_dir, "mem.bin")
    subprocess.run([OBJCOPY, "-O", "binary",
                    "--only-section=.text", "--only-section=ER_IROM1",
                    a.elf, mem_bin], capture_output=True)
    if not os.path.exists(mem_bin) or os.path.getsize(mem_bin) == 0:
        # fall back: whole-image binary
        subprocess.run([OBJCOPY, "-O", "binary", a.elf, mem_bin],
                       capture_output=True)
    mem_size = os.path.getsize(mem_bin)
    # MDK ELF: single ER_IROM1 at 0x08000000. Use flash base.
    mem_base = 0x08000000

    fmt = "coresight" if a.coresight else "source_data"

    # 3) snapshot.ini
    with open(os.path.join(a.out_dir, "snapshot.ini"), "w") as f:
        f.write("[snapshot]\n")
        f.write("version=1.0\n")
        f.write("description=STM32F429 M4 ETM capture (logic-analyser)\n\n")
        f.write("[device_list]\n")
        f.write("device0=cpu.ini\n")
        f.write("device1=etm.ini\n\n")
        f.write("[trace]\n")
        f.write("metadata=trace.ini\n")

    # 4) cpu.ini (core device + memory dump)
    with open(os.path.join(a.out_dir, "cpu.ini"), "w") as f:
        f.write("[device]\n")
        f.write("name=cpu_0\n")
        f.write("class=core\n")
        f.write("type=Cortex-M4\n\n")
        f.write("[dump]\n")
        f.write("file=mem.bin\n")
        f.write(f"address=0x{mem_base:08x}\n")
        f.write(f"length=0x{mem_size:08x}\n")

    # 5) etm.ini (trace source device + the 4 required ETMv3 regs)
    with open(os.path.join(a.out_dir, "etm.ini"), "w") as f:
        f.write("[device]\n")
        f.write("name=etm_0\n")
        f.write("class=trace_source\n")
        f.write("type=ETM3.5\n\n")
        f.write("[regs]\n")
        f.write(f"ETMCR=0x{ETMCR:08x}\n")
        f.write(f"ETMCCER=0x{ETMCCER:08x}\n")
        f.write(f"ETMIDR=0x{ETMIDR:08x}\n")
        f.write(f"ETMTRACEIDR=0x{ETMTRACEIDR:08x}\n")

    # 6) trace.ini (buffer + source/core association)
    with open(os.path.join(a.out_dir, "trace.ini"), "w") as f:
        f.write("[trace_buffers]\n")
        f.write("buffers=buffer0\n\n")
        f.write("[buffer0]\n")
        f.write("name=ETB_0\n")
        f.write("file=etm.bin\n")
        f.write(f"format={fmt}\n\n")
        f.write("[core_trace_sources]\n")
        f.write("cpu_0=etm_0\n\n")
        f.write("[source_buffers]\n")
        f.write("etm_0=ETB_0\n")

    print(f"snapshot written to {a.out_dir}/")
    print(f"  trace: {len(trace_bytes)} bytes (format={fmt})")
    print(f"  mem:   {mem_size} bytes @ 0x{mem_base:08x}")
    print(f"  ETM regs: CR=0x{ETMCR:08x} CCER=0x{ETMCCER:08x} "
          f"IDR=0x{ETMIDR:08x} TRACEID=0x{ETMTRACEIDR:02x}")
    print(f"\nrun: trc_pkt_lister -ss_dir {a.out_dir} -decode -decode_only "
          f"-logstdout" + ("  (add -tpiu)" if a.coresight else ""))


if __name__ == "__main__":
    sys.exit(main())
