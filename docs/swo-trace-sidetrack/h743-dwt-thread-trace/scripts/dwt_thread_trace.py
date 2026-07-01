#!/usr/bin/env python3
"""
STM32H743 + NuttX zero-intrusion thread-switch trace (DWT Data Trace over SWO)

Pure hardware capture: a DWT comparator watches the kernel writing
g_running_tasks and the hardware emits the *written value* (the new TCB
pointer) directly into an SWO data-value packet. The host never reads back
g_running_tasks. Therefore even a very short-lived thread (e.g. hello, which
prints one line and exits) has its TCB pointer already in the SWO stream and
is not missed. The CPU runs the whole time, zero performance cost, and no
NuttX code change is required.

Compared with the earlier "DWT EMIT (emit PC) + host read-back" approach:
read-back depends on host timing; a short-lived thread exits before the host
reads g_running_tasks, so only idle is observed. Data-value packets fix this
at the source.

Encoding reference (official ARMv7-M ARM, DDI0403E):
  - DWT_FUNCTIONn = 0x0D: FUNCTION=0b1101, EMITRANGE=0
      On a write access to the COMPn address, generates a
      "Data trace data value packet" (the written value).
      (Table C1-14 DWT address comparison functions)
  - Data-value write packet header (comparator 0 / write / 4 bytes) = 0x8F:
      bits[7:6]=10 (data value), bit3=1 (write), bit2=1 (hardware source),
      SS=11 (4 bytes) followed by 4-byte little-endian payload.
      (Table D4-7 Discriminator IDs for Data trace packets)
  - Local timestamp packets LTS1 (0b11.TC.0000) / LTS2 (0.TS.0000) are used
      to rebuild the time axis from hardware timestamps (D4.2.4).

Hardware setup:
  STM32H743ZI + DAPLink (CMSIS-DAP), SWO=PB3, SWD=PA13/PA14
  Clock HSE 25MHz -> PLL1 400MHz, PLL1R=8 -> TRACECLKIN=100MHz

Usage:
  python3 dwt_thread_trace.py --elf /path/to/nuttx [--duration 12]
  # or set the ELF path via the NUTTX_ELF environment variable

Output (current directory by default, override with --outdir):
  dwt_thread_trace.csv - thread-switch log (captured TCB + hw timestamp + id)
  dwt_swo_raw.bin      - raw SWO bytes
"""

import sys
import os
import time
import bisect
import argparse
import subprocess

# -- Register addresses (all accessed through AP0 AHB-AP) ---------------------

# PPB registers (standard Cortex-M addresses)
DWT_CTRL      = 0xE0001000
DWT_CYCCNT    = 0xE0001004
DWT_COMP0     = 0xE0001020
DWT_MASK0     = 0xE0001024
DWT_FUNCT0    = 0xE0001028
ITM_TER       = 0xE0000E00
ITM_TPR       = 0xE0000E40
ITM_TCR       = 0xE0000E80
ITM_LAR       = 0xE0000FB0
DEMCR         = 0xE000EDFC

# STM32H7 custom trace components (system-bus addresses 0x5C00xxxx)
DBGMCU_CR     = 0x5C001004
SWO_CODR      = 0x5C003010
SWO_SPPR      = 0x5C0030F0
SWO_LAR       = 0x5C003FB0
SWTF_CTRL     = 0x5C004000   # SWO Trace Funnel
SWTF_LAR      = 0x5C004FB0
CSTF_CTRL     = 0x5C013000
CSTF_LAR      = 0x5C013FB0
TPIU_CURPSIZE = 0x5C015004
TPIU_FFCR     = 0x5C015304
TPIU_LAR      = 0x5C015FB0

RCC_PLL1DIVR  = 0x58024430

# GPIOB / RCC (AHB4), used to configure PB3 as TRACESWO (AF0)
RCC_AHB4ENR   = 0x580244E0   # GPIOBEN = bit1
GPIOB_MODER   = 0x58020400
GPIOB_OSPEEDR = 0x58020408
GPIOB_AFRL    = 0x58020420

LOCK_KEY = 0xC5ACCE55

# DWT data-value-on-write trace function code (FUNCTION=0b1101, EMITRANGE=0)
DWT_FUNC_DATA_WRITE = 0x0D

# RAM regions where NuttX TCBs may live (H743); used to filter SWO parse noise
_TCB_RANGES = (
    (0x20000000, 0x20020000),  # DTCM 128KB
    (0x24000000, 0x24080000),  # AXI SRAM 512KB
    (0x30000000, 0x30048000),  # SRAM1/2/3 (D2)
    (0x38000000, 0x38010000),  # SRAM4 (D3) 64KB
)


def is_valid_tcb(addr):
    """TCB pointer sanity: 4-byte aligned and within a known RAM region."""
    if addr & 0x3:
        return False
    return any(lo <= addr < hi for lo, hi in _TCB_RANGES)


# -- ELF symbol / DWARF extraction --------------------------------------------

class ElfInfo:
    """Extract symbol addresses and TCB field offsets from the NuttX ELF,
    and resolve an address back to a function name."""

    def __init__(self, elf_path, nm="arm-none-eabi-nm", gdb="gdb-multiarch"):
        self.elf = elf_path
        self.nm = nm
        self.gdb = gdb
        self._sorted = None

    def symbol(self, name):
        try:
            out = subprocess.check_output([self.nm, self.elf],
                                          stderr=subprocess.DEVNULL).decode()
            for line in out.split('\n'):
                p = line.split()
                if len(p) >= 3 and p[2] == name:
                    return int(p[0], 16)
        except Exception:
            pass
        return None

    def field_offset(self, struct_type, field, default=None):
        try:
            out = subprocess.check_output([
                self.gdb, "-q", "-batch",
                "-ex", f"p (size_t)&((({struct_type}*)0)->{field})",
                self.elf], stderr=subprocess.DEVNULL).decode()
            import re
            m = re.search(r'\$\d+\s*=\s*(\d+)', out)
            if m:
                return int(m.group(1))
        except Exception:
            pass
        return default

    def field_size(self, struct_type, field, default=4):
        try:
            out = subprocess.check_output([
                self.gdb, "-q", "-batch",
                "-ex", f"p sizeof((({struct_type}*)0)->{field})",
                self.elf], stderr=subprocess.DEVNULL).decode()
            import re
            m = re.search(r'\$\d+\s*=\s*(\d+)', out)
            if m:
                return int(m.group(1))
        except Exception:
            pass
        return default

    def _build(self):
        if self._sorted is not None:
            return
        self._sorted = []
        try:
            out = subprocess.check_output([self.nm, "-n", self.elf],
                                          stderr=subprocess.DEVNULL).decode()
            for line in out.split('\n'):
                p = line.split()
                if len(p) >= 3:
                    self._sorted.append((int(p[0], 16), p[2]))
        except Exception:
            pass

    def addr_to_symbol(self, addr):
        self._build()
        if not self._sorted:
            return "?"
        idx = bisect.bisect_right(self._sorted, (addr, '\xff')) - 1
        return self._sorted[idx][1] if idx >= 0 else "?"

    @property
    def symbol_count(self):
        self._build()
        return len(self._sorted or [])


# -- RTT memory access (drive RTT control block over SWD to trigger switches) -

class RTTMemory:
    def __init__(self, target, rtt_addr):
        self.target = target
        max_up = target.read32(rtt_addr + 16)
        self.up0 = rtt_addr + 24
        self.dn0 = rtt_addr + 24 + 24 * max_up

    def read_up(self):
        wr = self.target.read32(self.up0 + 12)
        rd = self.target.read32(self.up0 + 16)
        buf = self.target.read32(self.up0 + 4)
        sz = self.target.read32(self.up0 + 8)
        if wr == rd:
            return b''
        if wr > rd:
            data = bytes(self.target.read_memory_block8(buf + rd, wr - rd))
        else:
            data = bytes(self.target.read_memory_block8(buf + rd, sz - rd))
            data += bytes(self.target.read_memory_block8(buf, wr))
        self.target.write32(self.up0 + 16, wr)
        return data

    def write_down(self, data):
        wr = self.target.read32(self.dn0 + 12)
        rd = self.target.read32(self.dn0 + 16)
        buf = self.target.read32(self.dn0 + 4)
        sz = self.target.read32(self.dn0 + 8)
        for byte in data:
            nxt = (wr + 1) % sz
            if nxt == rd:
                break
            self.target.write8(buf + wr, byte)
            wr = nxt
        self.target.write32(self.dn0 + 12, wr)


# -- SWO data-value packet + local timestamp parser ---------------------------

class DataTraceParser:
    """Extract DWT data-value write packets (the written TCB pointer) and
    local timestamp packets from the SWO stream."""

    def __init__(self):
        self.events = []   # [(ts_accum, tcb_addr), ...]
        self.ts_accum = 0  # accumulated local timestamp (TS clock units)

    def parse(self, data):
        i, n = 0, len(data)
        while i < n:
            b = data[i]
            ss = b & 0x03

            if ss != 0:
                # Source packet (software instrumentation or DWT hardware source)
                size = {1: 1, 2: 2, 3: 4}[ss]
                is_hw = (b >> 2) & 1
                # Data-value packet: bits[7:6]=10 and hardware source (bit2=1)
                if is_hw and (b & 0xC0) == 0x80:
                    is_write = (b >> 3) & 1
                    if i + 1 + size <= n:
                        val = int.from_bytes(data[i+1:i+1+size], 'little')
                        if is_write:
                            self.events.append((self.ts_accum, val))
                        i += 1 + size
                        continue
                i += 1 + size          # skip any other source packet
                continue

            # Protocol packet (SS==00)
            if b == 0x00:
                i += 1                 # sync stream / idle
                continue
            # Local timestamp LTS2: bit7=0, bits[3:0]=0000, TS=bits[6:4] in 1..6
            if (b & 0x8F) == 0x00:
                ts = (b >> 4) & 0x07
                if 1 <= ts <= 6:
                    self.ts_accum += ts
                i += 1
                continue
            # Local timestamp LTS1: bits[7:6]=11, bits[3:0]=0000, continuation payload
            if (b & 0xCF) == 0xC0:
                ts_val, shift, j = 0, 0, i + 1
                while j < n:
                    pb = data[j]
                    ts_val |= (pb & 0x7F) << shift
                    shift += 7
                    j += 1
                    if (pb & 0x80) == 0:
                        break
                self.ts_accum += ts_val
                i = j
                continue
            i += 1                     # overflow packet / other protocol packet
        return self.events


# -- Trace configuration ------------------------------------------------------

def configure_data_trace(target, watch_addr, swo_baud=115200):
    print("+---------------------------------------------+")
    print("|  STM32H743 DWT Data Trace setup (hardware)  |")
    print("+---------------------------------------------+")

    # PLL1DIVR R1 field is at bit24 (RCC_PLL1DIVR_R1_SHIFT=24), stored = divisor-1
    pll1divr = target.read32(RCC_PLL1DIVR)
    r1 = ((pll1divr >> 24) & 0x7F) + 1
    traceclkin = 800_000_000 / r1
    print(f"    TRACECLKIN   = {traceclkin/1e6:.3f} MHz (PLL1R={r1})")

    target.write32(DBGMCU_CR, 0x00700000)          # trace clock must be enabled first
    print(f"[1] DBGMCU_CR    = 0x{target.read32(DBGMCU_CR):08x} ok")

    # Configure PB3 as TRACESWO (AF0) so the script does not rely on any
    # leftover state after a power cycle.
    #   RCC_AHB4ENR.GPIOBEN=1; MODER PB3=10 (AF); OSPEED PB3=11 (very high);
    #   AFRL PB3=0 (AF0 = TRACESWO)
    target.write32(RCC_AHB4ENR, target.read32(RCC_AHB4ENR) | (1 << 1))
    moder = target.read32(GPIOB_MODER)
    moder = (moder & ~(0x3 << (3 * 2))) | (0x2 << (3 * 2))
    target.write32(GPIOB_MODER, moder)
    ospd = target.read32(GPIOB_OSPEEDR)
    ospd = (ospd & ~(0x3 << (3 * 2))) | (0x3 << (3 * 2))
    target.write32(GPIOB_OSPEEDR, ospd)
    afrl = target.read32(GPIOB_AFRL)
    afrl = afrl & ~(0xF << (3 * 4))                # PB3 AFR = 0 (AF0 = TRACESWO)
    target.write32(GPIOB_AFRL, afrl)
    print(f"[1b] PB3->TRACESWO MODER=0x{target.read32(GPIOB_MODER):08x} "
          f"AFRL=0x{target.read32(GPIOB_AFRL):08x} ok")

    target.write32(DEMCR, target.read32(DEMCR) | (1 << 24))  # TRCENA
    print(f"[2] DEMCR        = 0x{target.read32(DEMCR):08x} ok")

    target.write32(DWT_CTRL, 0x40000001)           # CYCCNTENA (reference time base)
    target.write32(DWT_CYCCNT, 0)
    print(f"[3] DWT_CTRL     = 0x{target.read32(DWT_CTRL):08x} ok")

    # Comparator 0: data-value packet on write access to g_running_tasks
    target.write32(DWT_FUNCT0, 0)
    target.write32(DWT_COMP0, watch_addr)
    target.write32(DWT_MASK0, 0)                   # exact match
    target.write32(DWT_FUNCT0, DWT_FUNC_DATA_WRITE)
    print(f"[4] DWT_COMP0    = 0x{target.read32(DWT_COMP0):08x} ok")
    print(f"    DWT_FUNCT0   = 0x{target.read32(DWT_FUNCT0):08x} (data value on write) ok")

    target.write32(ITM_LAR, LOCK_KEY)
    target.write32(ITM_TPR, 0)
    target.write32(ITM_TER, 0xFFFFFFFF)
    target.write32(ITM_TCR, 0x0000000F)            # ITMENA|TSENA|SYNCENA|TXENA
    print(f"[5] ITM_TCR      = 0x{target.read32(ITM_TCR):08x} ok")

    target.write32(SWTF_LAR, LOCK_KEY)
    target.write32(SWTF_CTRL, 0x303)               # ENS0|ENS1
    print(f"[6] SWTF_CTRL    = 0x{target.read32(SWTF_CTRL):08x} ok")

    target.write32(TPIU_LAR, LOCK_KEY)
    target.write32(TPIU_CURPSIZE, 1)
    target.write32(TPIU_FFCR, 0)                   # disable formatter
    print(f"[7] TPIU_FFCR    = 0x{target.read32(TPIU_FFCR):08x} (no formatter) ok")

    target.write32(SWO_LAR, LOCK_KEY)
    target.write32(SWO_SPPR, 2)                    # NRZ
    prescaler = int(traceclkin / swo_baud) + 1
    actual_baud = traceclkin / (prescaler - 1)
    target.write32(SWO_CODR, prescaler)
    print(f"[8] SWO_SPPR     = 0x{target.read32(SWO_SPPR):08x} (NRZ) ok")
    print(f"    SWO_CODR     = {target.read32(SWO_CODR)} -> {actual_baud:.0f} Hz ok")

    print(f"\nDWT Data Trace configured, watching writes to 0x{watch_addr:08x}")
    return actual_baud


# -- Main ---------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description="STM32H743 NuttX thread-switch trace via DWT Data Trace")
    ap.add_argument("--elf", default=os.environ.get("NUTTX_ELF"),
                    help="path to NuttX ELF (or set NUTTX_ELF)")
    ap.add_argument("--duration", type=int, default=12, help="capture seconds")
    ap.add_argument("--outdir", default=".", help="output directory")
    ap.add_argument("--nm", default="arm-none-eabi-nm")
    ap.add_argument("--gdb", default="gdb-multiarch")
    args = ap.parse_args()

    if not args.elf or not os.path.exists(args.elf):
        ap.error("a valid NuttX ELF path is required (--elf or NUTTX_ELF)")

    os.makedirs(args.outdir, exist_ok=True)
    log_file = os.path.join(args.outdir, "dwt_thread_trace.csv")
    swo_file = os.path.join(args.outdir, "dwt_swo_raw.bin")

    elf = ElfInfo(args.elf, nm=args.nm, gdb=args.gdb)
    watch_addr = elf.symbol("g_running_tasks")
    rtt_addr = elf.symbol("_SEGGER_RTT")
    if watch_addr is None:
        sys.exit("symbol g_running_tasks not found")

    tcb_offs = {
        'pid':   elf.field_offset("struct tcb_s", "pid", 48),
        'state': elf.field_offset("struct tcb_s", "task_state", 64),
        'pri':   elf.field_offset("struct tcb_s", "sched_priority", 52),
        'entry': elf.field_offset("struct tcb_s", "entry", 60),
    }
    tcb_sizes = {
        'state': elf.field_size("struct tcb_s", "task_state"),
        'pri':   elf.field_size("struct tcb_s", "sched_priority"),
    }
    print(f"g_running_tasks = 0x{watch_addr:08x}")
    if rtt_addr:
        print(f"_SEGGER_RTT     = 0x{rtt_addr:08x}")
    print(f"symbols loaded: {elf.symbol_count}")

    from pyocd.core.helpers import ConnectHelper
    session = ConnectHelper.session_with_chosen_probe(
        target_override='cortex_m', auto_init=False)
    probe = session.probe
    probe.open()
    probe.connect()
    probe.assert_reset(False)          # DAPLink nRESET defaults low, release it
    time.sleep(0.5)
    session.board.init()               # manual init (halt CPU), no reset
    target = session.board.target

    tcb_cache = {}

    def resolve_tcb(tcb_addr):
        """After the hardware captured the exact TCB pointer, read its identity
        fields once (on demand, cached) -- not a poll of g_running_tasks."""
        if tcb_addr in tcb_cache:
            return tcb_cache[tcb_addr]
        info = {'pid': 0, 'state': 0, 'pri': 0, 'entry': 0, 'name': '?'}
        if is_valid_tcb(tcb_addr):
            try:
                info['pid'] = target.read32(tcb_addr + tcb_offs['pid'])
            except Exception:
                pass
            try:
                info['state'] = (target.read8(tcb_addr + tcb_offs['state'])
                                 if tcb_sizes['state'] == 1
                                 else target.read32(tcb_addr + tcb_offs['state']))
            except Exception:
                pass
            try:
                info['pri'] = (target.read8(tcb_addr + tcb_offs['pri'])
                               if tcb_sizes['pri'] == 1
                               else target.read32(tcb_addr + tcb_offs['pri']))
            except Exception:
                pass
            try:
                info['entry'] = target.read32(tcb_addr + tcb_offs['entry'])
            except Exception:
                pass
            info['name'] = elf.addr_to_symbol(info['entry']) if info['entry'] else '?'
        tcb_cache[tcb_addr] = info
        return info

    try:
        actual_baud = configure_data_trace(target, watch_addr)
        link = probe._link
        link.swo_configure(True, int(actual_baud))
        link.swo_control(1)
        print(f"\nSWO capture started @ {actual_baud:.0f} Hz")

        with open(log_file, 'w') as f:
            f.write("# NuttX thread-switch trace (DWT Data Trace, hardware, no read-back)\n")
            f.write(f"# date: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.write(f"# watch write: g_running_tasks @ 0x{watch_addr:08x}\n")
            f.write("# mode: DWT FUNCTION=0x0D data-value write packet (captures written TCB pointer)\n")
            f.write("# time: accumulated ITM local timestamp (TS clock units)\n#\n")
            f.write("ts_local,tcb_addr,pid,state,pri,thread_name\n")

        target.resume()
        print("CPU resumed -- DWT data trace running\n")

        rtt = RTTMemory(target, rtt_addr) if rtt_addr else None
        if rtt:
            time.sleep(1.0)
            _ = rtt.read_up()
            print("sending commands to trigger thread switches (incl. short-lived hello)...")
            for cmd in [b"hello\n", b"hello\n", b"hello\n", b"uname -a\n", b"hello\n"]:
                rtt.write_down(cmd)
                time.sleep(0.6)

        parser = DataTraceParser()
        all_swo = b''
        rtt_out = b''
        start = time.time()
        print(f"capturing for {args.duration} s...\n")
        with open(swo_file, 'wb') as sf:
            while time.time() - start < args.duration:
                try:
                    data = link.swo_read()
                    if data:
                        sf.write(data)
                        sf.flush()
                        all_swo += data
                except Exception as e:
                    if 'read' not in str(e).lower():
                        print(f"  SWO err: {e}")
                if rtt:
                    try:
                        r = rtt.read_up()
                        if r:
                            rtt_out += r
                    except Exception:
                        pass
                time.sleep(0.05)

        link.swo_control(0)
        if rtt:
            try:
                r = rtt.read_up()
                if r:
                    rtt_out += r
            except Exception:
                pass

        events = parser.parse(all_swo)
        distinct = {}
        with open(log_file, 'a') as f:
            for ts_local, tcb in events:
                if not is_valid_tcb(tcb):
                    continue
                info = resolve_tcb(tcb)
                f.write(f"{ts_local},0x{tcb:08x},{info['pid']},"
                        f"{info['state']},{info['pri']},{info['name']}\n")
                distinct[tcb] = info

        print("=" * 60)
        print("capture done:")
        print(f"  raw SWO bytes: {len(all_swo)} -> {swo_file}")
        print(f"  data-value write packets (thread switches): {len(events)}")
        print(f"  trace log: {log_file}")
        print("\ndistinct TCBs (threads) captured:")
        for tcb, info in sorted(distinct.items()):
            print(f"  0x{tcb:08x}  pid={info['pid']:<4} pri={info['pri']:<4} "
                  f"state={info['state']:<3} {info['name']}")
        if rtt_out:
            print("\nRTT echo:")
            print("  " + rtt_out.decode(errors='replace').replace('\n', '\n  ').strip())

    finally:
        session.close()


if __name__ == '__main__':
    main()
