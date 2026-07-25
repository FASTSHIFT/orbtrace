#!/usr/bin/env python3
"""trace_doctor — unified CLI for the ORBTrace/A7-Lite/H743 bring-up (proposal 41).

Consolidates the ~45 loose scripts under scripts/ into a single entry point with
subcommand groups. Most subcommands wrap existing native scripts; state is kept
in ~/workpath/orbcode/.trace_doctor.state.json so a new conversation can run
`trace_doctor status` and immediately see the current bit / firmware / tap /
ETM configuration.

Design principles (proposal 41 §7):
  * Don't reinvent — wrap existing scripts, keep them under scripts/ callable
    directly for the user who wants to dig in.
  * Don't hide — `--show` prints the exact underlying command each subcommand
    runs, so you can copy-paste for debugging.
  * Don't swallow — subcommand exit codes pass through.
  * State file is a cache, not truth — every diag re-verifies (bit md5 vs
    state, PLL readback vs state).
  * Archive != delete — obsolete scripts move to attic/ with a README.

Entry pattern:
  trace_doctor <group> <cmd> [args]     e.g. `trace_doctor probe voltmeter`
  trace_doctor status                    # print current state file
  trace_doctor recent                    # last N runs
  trace_doctor <group> --help            # list subcommands in a group

For the full design see proposals/41-trace_doctor-v2-*.md.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

# ----------------------------------------------------------------------------
# Paths (all resolved relative to this file so trace_doctor works from any cwd)
# ----------------------------------------------------------------------------
HERE = Path(__file__).resolve().parent            # .../scripts/
BRINGUP = HERE.parent                              # .../bringup/
ORB_ROOT = BRINGUP.parents[2]                      # .../orbtrace/ (up 3: syn/artix7/bringup->bringup->artix7->syn)
# NB: orbtrace root layout: orbtrace/syn/artix7/bringup/scripts/, so scripts=
# HERE (level 0), bringup=level1, artix7=level2, syn=level3, orbtrace=level4.
WORKSPACE = BRINGUP.parents[3]                     # ~/workpath/orbcode/ (up 4)
STATE_FILE = WORKSPACE / ".trace_doctor.state.json"
LOG_DIR = WORKSPACE / ".trace_doctor.log"
DECODE_DIR = BRINGUP / "decode"
BUILD_DIR = BRINGUP / "build"
TARGET_DIR = BRINGUP / "target"

# ----------------------------------------------------------------------------
# State file: cache of current fpga/stm32/etm/network state (proposal 41 §3.3)
# ----------------------------------------------------------------------------

def state_load() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except Exception:
            return {}
    return {}


def state_save(state: dict) -> None:
    state["last_updated"] = datetime.datetime.now().isoformat(timespec="seconds")
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2, ensure_ascii=False))


def state_update(section: str, **kv) -> dict:
    st = state_load()
    st.setdefault(section, {}).update(kv)
    state_save(st)
    return st


def md5_of(path: Path) -> str | None:
    if not path.exists():
        return None
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

# ----------------------------------------------------------------------------
# Run helper: prints the underlying command (unless --quiet), records to log
# ----------------------------------------------------------------------------

def run(cmd: list[str] | str, *, show: bool = False, cwd: Path | None = None,
        timeout: float | None = None, capture: bool = False, env: dict | None = None):
    """Run a shell/subprocess command; return CompletedProcess. If show, prints
    the exact command for copy-paste. Never swallows exit codes."""
    if isinstance(cmd, str):
        cmd_str = cmd
        shell = True
    else:
        cmd_str = shlex.join(cmd)
        shell = False
    if show:
        print(f"$ {cmd_str}", file=sys.stderr)
    kw = dict(cwd=str(cwd) if cwd else None, timeout=timeout, env=env, shell=shell)
    if capture:
        kw.update(stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    return subprocess.run(cmd, **kw)


def native(script: str, *args: str, cwd: Path | None = None, **kw):
    """Invoke a native script from scripts/. `script` is name relative to
    scripts/ (e.g. 'trace_ctrl.py' or 'hw_selftest.py')."""
    p = HERE / script
    if not p.exists():
        # try decode/
        p2 = DECODE_DIR / script
        if p2.exists():
            p = p2
        else:
            sys.exit(f"[trace_doctor] native script not found: {script}")
    cmd = ["python3", str(p), *args] if script.endswith(".py") else [str(p), *args]
    return run(cmd, cwd=cwd or BRINGUP, **kw)

# ============================================================================
# status / recent / help_all — meta commands
# ============================================================================

def cmd_status(a):
    """Print current state file — always the first thing an agent should read."""
    st = state_load()
    if not st:
        print("(no state file yet — run any subcommand and state will populate)")
        return 0
    if a.json:
        print(json.dumps(st, indent=2, ensure_ascii=False))
        return 0
    # human summary
    print("=== trace_doctor state ===")
    print(f"last updated: {st.get('last_updated', '?')}")
    for section in ("fpga", "stm32", "etm", "network"):
        if section in st:
            print(f"\n[{section}]")
            for k, v in st[section].items():
                print(f"  {k:22} = {v}")
    caps = st.get("last_captures", [])
    if caps:
        print(f"\n[last_captures] ({len(caps)} kept)")
        for c in caps[-5:]:
            print(f"  {c.get('time','?')}  {c.get('file','?')}  {c.get('config','?')}")
    warns = st.get("warnings", [])
    if warns:
        print("\n[warnings]")
        for w in warns:
            print(f"  ⚠️  {w}")
    return 0


def cmd_recent(a):
    """Show the last N invocations (from log dir)."""
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    logs = sorted(LOG_DIR.glob("*.log"))[-a.n:]
    if not logs:
        print("(no runs logged yet)")
        return 0
    for p in logs:
        print(f"--- {p.name} ---")
        print(p.read_text()[-2000:])
    return 0

# ============================================================================
# probe group — hardware datapath diagnostics (§1.1)
# ============================================================================

def cmd_probe_voltmeter(a):
    """TPIU AA/55 physical datapath test. REQUIRES pin_la bit (which has the
    logic analyzer wired into a BRAM ring). If you're on clktap, run
    `td burn fpga build/trace_pin_la.bit` first, run this, then burn back."""
    # Detect current bit signature quickly
    r = subprocess.run(
        ["python3", str(HERE / "trace_dump.py"), "--status-only"],
        cwd=str(BRINGUP), capture_output=True, text=True, timeout=3)
    import re
    m = re.search(r"DEPTH=(\d+)", r.stdout)
    if m and 32000 <= int(m.group(1)) < 33000:
        pass  # pin_la, good to go
    elif m:
        depth = int(m.group(1))
        print(f"[trace_doctor] WARNING: current DEPTH={depth} doesn't match pin_la "
              f"(expected ~32639). This test will likely fail with 'pin_la not ready'.")
        print(f"  To run voltmeter: td burn fpga build/trace_pin_la.bit")
        print(f"  To resume normal trace: td burn fpga build/trace_iddr_clktap.bit")
    return native("hw_selftest.py", "quick", *(["--ip", a.ip] if a.ip else [])).returncode


def cmd_probe_health(a):
    """Read dbg_regfile via :5001 (proposal 30) — err codes + counters +
    (⚠️ 100M+ freq reading is under-sampled per r31, use only qualitatively)."""
    args = [a.ip] if a.ip else []
    rc = native("fpga_health.py", *args).returncode
    # persist last check ts
    state_update("network", last_health_check=datetime.datetime.now().isoformat(timespec="seconds"))
    return rc


def cmd_probe_wire(a):
    """Pin connectivity — trace pins wire-check."""
    script = "pin_wire_check_isolated.py" if a.isolated else "pin_wire_check.py"
    return native(script, *(a.extra or [])).returncode


def cmd_probe_pin_la(a):
    """pin_la bit health check."""
    return native("check_pinla.py", *(a.extra or [])).returncode

# ============================================================================
# tap group — IDDR sampling phase (§1.2)
# ============================================================================

def cmd_tap_set_clk(a):
    """Set clock-lane IDELAY tap (0..31)."""
    rc = native("trace_ctrl.py", "set-tap-clk", str(a.value)).returncode
    if rc == 0:
        state_update("fpga", tap_clk=a.value)
    return rc


def cmd_tap_set_data(a):
    """Set data-lane IDELAY tap (all 4 lanes, 0..31)."""
    rc = native("trace_ctrl.py", "set-tap", str(a.value)).returncode
    if rc == 0:
        state_update("fpga", tap_data=a.value)
    return rc


def cmd_tap_set_lane(a):
    """Per-lane IDELAY tap: lane 0..3, tap 0..31."""
    rc = native("trace_ctrl.py", "set-tap-lane", str(a.lane), str(a.value)).returncode
    if rc == 0:
        st = state_load().get("fpga", {}).get("tap_per_lane", {})
        st[str(a.lane)] = a.value
        state_update("fpga", tap_per_lane=st)
    return rc


def cmd_tap_sweep(a):
    """Sweep clock IDELAY tap, find best fsync count. Wraps iddr_tap_sweep.py.
    Falls back to inline sweep if the native script signature differs."""
    return native("iddr_tap_sweep.py", *(a.extra or [])).returncode

# ============================================================================
# freq group — sysclk / TRACECLK sweeps (§1.3)
# ============================================================================

def cmd_freq_sweep(a):
    """Frequency sweep."""
    return native("freq_sweep.py", *(a.extra or [])).returncode


def cmd_freq_ceiling(a):
    """Find frequency ceiling."""
    return native("freq_ceiling_sweep.py", *(a.extra or [])).returncode


def cmd_freq_push(a):
    """Push frequency step by step (150→200→300→400M)."""
    return native("freq_push.sh", *(a.extra or [])).returncode


def cmd_freq_run(a):
    """Run at a single frequency."""
    return native("freq_run.sh", *(a.extra or [])).returncode


def cmd_freq_yield(a):
    """Hardware arming yield."""
    return native("hardarm_yield.sh", *(a.extra or [])).returncode

# ============================================================================
# mmcm group — MMCM phase (§1.4)
# ============================================================================

def cmd_mmcm_status(a):
    return native("mmcm_status.py", *(a.extra or [])).returncode


def cmd_mmcm_phase(a):
    script = "mmcm_phase_quality.sh" if a.quality else "mmcm_phase_scan.sh"
    return native(script, *(a.extra or [])).returncode


def cmd_mmcm_test(a):
    return native("mmcm_test_one.sh", str(a.phase), *(a.extra or [])).returncode

# ============================================================================
# capture group — one-shot / streaming trace capture (§1.5)
# ============================================================================

def cmd_capture_snapshot(a):
    """One-shot trace capture via trace_dump.py."""
    args = ["--depth", str(a.depth), "-o", a.out]
    if a.timebase:
        args.append("--timebase")
    if a.ip:
        args += ["--ip", a.ip]
    rc = native("trace_dump.py", *args).returncode
    if rc == 0:
        st = state_load()
        caps = st.setdefault("last_captures", [])
        caps.append({
            "file": a.out,
            "time": datetime.datetime.now().strftime("%H:%M:%S"),
            "config": a.tag or "unspecified",
            "depth": a.depth,
        })
        st["last_captures"] = caps[-20:]  # keep last 20
        state_save(st)
    return rc


def cmd_capture_rearm(a):
    return native("trace_ctrl.py", "rearm").returncode


def cmd_capture_status(a):
    """Read FPGA capture status (DEPTH/full/gen)."""
    return native("trace_dump.py", "--status-only", *(["--ip", a.ip] if a.ip else [])).returncode


def cmd_capture_stream(a):
    return native("trace_stream_rx.py", *(a.extra or [])).returncode


def cmd_capture_la_dump(a):
    """Read la_ddr_writer's DDR3 black-box (proposal 32)."""
    return native("la_readout.py", *(a.extra or [])).returncode


def cmd_capture_run(a):
    return native("trace_run.sh", *(a.extra or [])).returncode

# ============================================================================
# decode group — ETMv4 decode + verification (§1.6)
# ============================================================================

def cmd_decode_opencsd(a):
    """OpenCSD ETMv4 decode + coverage."""
    args = [a.raw, a.elf]
    if a.keep:
        args += ["--keep", a.keep]
    args += a.extra or []
    return native("opencsd_etm4_run.py", *args).returncode


def cmd_decode_verify(a):
    """Golden call-edge verification against ELF (proposal 38 discipline)."""
    return native("verify_calls.py", a.pkt_log, a.dis).returncode


def cmd_decode_perf(a):
    """Export Perfetto perf via etm_with_time.py + orbetto. Wrapper for the
    two-step pipeline from AGENT.md §4.6."""
    ts_bin = a.raw + ".time.bin"
    ts_json = a.raw + ".ts.json"
    # step 1: attach timebase
    r1 = native("etm_with_time.py", a.raw, ts_json, ts_bin)
    if r1.returncode != 0:
        return r1.returncode
    # step 2: orbetto
    orbetto = ORB_ROOT.parent / "embedded-debug-tools" / "ext" / "orbetto" / "build" / "orbetto"
    if not orbetto.exists():
        print(f"[trace_doctor] orbetto binary not found at {orbetto}")
        return 2
    cmd = [str(orbetto), "-C", str(a.freq_khz), "-t", "1", "-f", a.raw,
           "-e", a.elf, "-F", ts_bin + ".time.bin"]
    env = os.environ.copy()
    env.setdefault("ORBETTO_ETM_PROT", "ETM4")
    return run(cmd, env=env).returncode


def cmd_decode_tpiu_diff(a):
    return native("tpiu_testpattern_diff.py", *(a.extra or [])).returncode


def cmd_decode_walk_score(a):
    return native("walk_score.py", *(a.extra or [])).returncode


def cmd_decode_golden(a):
    """v0 golden check (proposal 22)."""
    return native("v0_golden_check.py", *(a.extra or [])).returncode

# ============================================================================
# build / burn / etm groups — construction and configuration (§1.7)
# ============================================================================

def cmd_build_fpga(a):
    """Synthesize FPGA bitstream."""
    return native("build.sh", *(a.extra or [])).returncode


def cmd_build_fw(a):
    """Build H743 firmware."""
    return native("build_h743.sh", *(a.extra or [])).returncode


def cmd_burn_fpga(a):
    """Burn FPGA bit via openFPGALoader. Auto-rearms after ~3s so subsequent
    `capture status` doesn't read stale 0xFFFF CSR."""
    import time
    bit = a.bit or str(BUILD_DIR / "trace_iddr_clktap.bit")
    p = Path(bit)
    if not p.exists():
        sys.exit(f"[trace_doctor] bit not found: {bit}")
    rc = run(["openFPGALoader", "-c", "ft232", "--fpga-part", "xc7a35tfgg484", bit]).returncode
    if rc == 0:
        state_update("fpga", bit_file=p.name, bit_md5=md5_of(p),
                     burned_at=datetime.datetime.now().isoformat(timespec="seconds"))
        # Give the FPGA a moment to boot, then auto-rearm so CSRs refresh
        # from 0xFF (uninitialized) to real values. Skippable with --no-rearm.
        if not a.no_rearm:
            time.sleep(3)
            native("trace_ctrl.py", "rearm")
    return rc


def cmd_burn_fw(a):
    """Burn STM32 firmware via openocd (CMSIS-DAP + stm32h7x cfg).

    NOTE: `program.sh` in scripts/ is a *FPGA* JTAG loader (via Vivado), not
    an STM32 firmware programmer -- naming is misleading. We use openocd
    directly here, matching AGENT.md §4.2."""
    hexp = a.hex
    if not Path(hexp).exists():
        sys.exit(f"[trace_doctor] hex not found: {hexp}")
    cmd = ["openocd", "-f", "interface/cmsis-dap.cfg", "-f", "target/stm32h7x.cfg",
           "-c", "init", "-c", "reset halt",
           "-c", f"program {hexp} verify",
           "-c", "reset run", "-c", "shutdown"]
    rc = run(cmd, cwd=BRINGUP.parents[2]).returncode
    if rc == 0:
        state_update("stm32", hex_file=hexp, hex_md5=md5_of(Path(hexp)),
                     burned_at=datetime.datetime.now().isoformat(timespec="seconds"))
    return rc


def cmd_burn_fpga_persistent(a):
    """PERSISTENT QSPI flash of FPGA (via program.sh) — for final designs.
    Contrast with `burn fpga` which is volatile SRAM load via openFPGALoader."""
    return native("program.sh", a.target, "flash", *(a.extra or [])).returncode


def cmd_etm_enable(a):
    """Enable STM32 ETM via openocd cfg (with CACHE_FLAG / TRACE_BB / TRACE_STALL env)."""
    cfg = TARGET_DIR / "etm_enable_h743.cfg"
    env = os.environ.copy()
    if a.cache_flag is not None:
        env["CACHE_FLAG"] = a.cache_flag
    if a.bb is not None:
        env["TRACE_BB"] = str(a.bb)
    if a.stall is not None:
        env["TRACE_STALL"] = str(a.stall)
    cmd = ["openocd", "-f", "interface/cmsis-dap.cfg", "-f", "target/stm32h7x.cfg",
           "-f", str(cfg), "-c", "shutdown"]
    rc = run(cmd, cwd=BRINGUP.parents[2], env=env).returncode
    if rc == 0:
        state_update("etm", bb=a.bb, stall=a.stall, cache_flag=a.cache_flag,
                     last_config=datetime.datetime.now().isoformat(timespec="seconds"))
    return rc


def cmd_etm_recover(a):
    return native("etm_recover.sh", *(a.extra or [])).returncode


def cmd_etm_clear_curtpm(a):
    """Clear TPIU CURTPM register (test-pattern generator) so real ETM data
    can flow to the pins. This is a mandatory step after `etm enable` when
    the ETM cfg leaves CURTPM in test-mode (proposal 36 AGENT.md §4.4)."""
    cmd = ["openocd", "-f", "interface/cmsis-dap.cfg", "-f", "target/stm32h7x.cfg",
           "-c", "init", "-c", "halt", "-c", "mww 0x5C015204 0",
           "-c", "resume", "-c", "shutdown"]
    return run(cmd, cwd=BRINGUP.parents[2]).returncode


def cmd_etm_show(a):
    """Read CoreSight registers, verify ETM state matches AGENT.md §4.4 expected."""
    ocd = ["openocd", "-f", "interface/cmsis-dap.cfg", "-f", "target/stm32h7x.cfg",
           "-c", "init", "-c", "halt",
           "-c", "echo [format {TRCPRGCTLR=0x%08x TRCSTATR=0x%08x TRCCONFIGR=0x%08x "
                 "TPIU_CURPSIZE=0x%08x CSTF=0x%08x ETF_CTL=0x%08x DBGMCU=0x%08x} "
                 "[mrw 0xE0041004] [mrw 0xE004100C] [mrw 0xE0041010] "
                 "[mrw 0x5C015004] [mrw 0x5C013000] [mrw 0x5C014020] [mrw 0x5C001004]]",
           "-c", "resume", "-c", "shutdown"]
    return run(ocd, cwd=BRINGUP.parents[2]).returncode

# ============================================================================
# diag group — layered fault-isolation (§3, per r31 阻断已接受)
# ============================================================================

def _check_l0(state, verbose=True):
    """L0 host: no residual processes, USB devices present, hgfs OK."""
    issues = []
    for proc in ("openocd", "openFPGALoader", "hw_server"):
        rc = subprocess.run(["pgrep", "-f", proc], capture_output=True).returncode
        if rc == 0:
            issues.append(f"L0 residual {proc} running")
    for did, name in (("0d28:0204", "DAPLink"), ("0403:6014", "FT232H")):
        rc = subprocess.run(["lsusb"], capture_output=True, text=True)
        if did not in rc.stdout:
            issues.append(f"L0 USB device missing: {name} ({did})")
    if not Path("/dev/ttyACM0").exists():
        issues.append("L0 /dev/ttyACM0 missing (DAPLink VCP)")
    if not Path("/mnt/hgfs/DESIGN/STM32_Project/H743_Blink/Makefile").exists():
        issues.append("L0 hgfs firmware share unreadable (H743 project)")
    return issues


def _check_l2_fpga_bit(state, verbose=True):
    """L2 FPGA bit: UDP status + DEPTH signature."""
    issues = []
    rc = subprocess.run(
        ["python3", str(HERE / "trace_dump.py"), "--status-only"],
        cwd=str(BRINGUP), capture_output=True, text=True, timeout=5)
    if rc.returncode != 0 or "device DEPTH=" not in rc.stdout:
        issues.append("L2 FPGA UDP status unreachable (bit not loaded / net down)")
    else:
        # look for DEPTH= line
        import re
        m = re.search(r"DEPTH=(\d+).*?full=(\d+).*?gen=(\d+)", rc.stdout)
        if m:
            depth = int(m.group(1))
            # Known-good DEPTH signatures per bit (proposal 41 §3.3 whitelist):
            #   trace_iddr_clktap.bit    -> DEPTH ~63472-63479, gen 0..255
            #   pin_la (trace_pin_la)    -> DEPTH ~32639
            #   trace_ddr_selftest       -> higher
            # A DEPTH >= 0xFF00 (65280) is diagnostic of "CSR reads returning
            # 0xFF" i.e. the bit isn't answering with real state -- either not
            # loaded or wrong bit. Note gen=0xFF is NORMAL for freshly-loaded
            # clktap after some captures; do NOT gate on gen alone.
            # Bit-signature whitelist: depth range -> plausible bit name.
            # Used to detect state-file-vs-reality drift (e.g. hw_selftest
            # secretly re-flashed pin_la but state still claims clktap).
            BIT_SIGNATURE = [
                (32000, 33000, "pin_la"),
                (63000, 64500, "clktap 4-bit"),
                (64500, 65000, "unknown / newer bit"),
            ]
            if depth >= 0xFF00:
                issues.append(
                    f"L2 FPGA DEPTH={depth} full={m.group(2)} gen={m.group(3)} "
                    f"— stale/uninitialized (CSR reads 0xFF, bit not loaded?)")
            elif depth == 0:
                if verbose: print(f"  L2 FPGA DEPTH=0 (fresh, needs rearm to fill)")
            else:
                # cross-check with state file
                expected_bit = state.get("fpga", {}).get("bit_file", "")
                signature = "unknown"
                for lo, hi, name in BIT_SIGNATURE:
                    if lo <= depth < hi:
                        signature = name
                        break
                if expected_bit and signature != "unknown":
                    if "clktap" in expected_bit and "clktap" not in signature:
                        issues.append(
                            f"L2 FPGA state says '{expected_bit}' but DEPTH={depth} "
                            f"matches '{signature}' — state file DRIFT, actual bit "
                            f"different! Re-burn or `td burn fpga <correct>` to fix.")
                    elif "pin_la" in expected_bit and "pin_la" not in signature:
                        issues.append(
                            f"L2 FPGA state says '{expected_bit}' but DEPTH={depth} "
                            f"matches '{signature}' — state file DRIFT.")
                if verbose and not issues:
                    print(f"  L2 FPGA DEPTH={depth} matches '{signature}' "
                          f"(state: '{expected_bit}')")
        else:
            issues.append(f"L2 FPGA status parse failed: {rc.stdout[:200]}")
    return issues


def _check_l1_probe(state, verbose=True):
    """L1 physical: DAPLink SWD DPIDR + STM32 IDCODE via a quick openocd."""
    issues = []
    r = subprocess.run(
        ["openocd", "-f", "interface/cmsis-dap.cfg", "-f", "target/stm32h7x.cfg",
         "-c", "init", "-c",
         "echo [format {IDCODE=0x%08x} [mrw 0x5C001000]]",
         "-c", "shutdown"],
        cwd=str(BRINGUP.parents[2]), capture_output=True, text=True, timeout=10)
    out = r.stdout + r.stderr
    if "DPIDR 0x6ba02477" not in out:
        issues.append("L1 DAPLink SWD DPIDR mismatch or SWD not up")
    import re
    m = re.search(r"IDCODE=0x([0-9a-fA-F]+)", out)
    if m:
        idcode = int(m.group(1), 16)
        if (idcode & 0xFFF) != 0x450:
            issues.append(f"L1 STM32 IDCODE=0x{idcode:08x} (expected H74x/75x family 0x450)")
        elif verbose:
            print(f"  L1 STM32 IDCODE=0x{idcode:08x} (H74x/75x)")
    else:
        issues.append("L1 STM32 IDCODE readout failed")
    return issues


def _check_l3_net(state, verbose=True):
    """L3 net: FPGA UDP status 3 consecutive successes."""
    issues = []
    fails = 0
    for i in range(3):
        r = subprocess.run(
            ["python3", str(HERE / "trace_dump.py"), "--status-only"],
            cwd=str(BRINGUP), capture_output=True, text=True, timeout=3)
        if r.returncode != 0 or "device DEPTH=" not in r.stdout:
            fails += 1
    if fails > 0:
        issues.append(f"L3 FPGA UDP status flaky ({fails}/3 failed)")
    elif verbose:
        print(f"  L3 FPGA UDP 3/3 responded")
    return issues


def _check_l7_etm(state, verbose=True):
    """L7 STM32 ETM state: read CoreSight regs and check for common failure
    modes (ETM not enabled / IDLE / test-pattern still on / auth locked)."""
    issues = []
    r = subprocess.run(
        ["openocd", "-f", "interface/cmsis-dap.cfg", "-f", "target/stm32h7x.cfg",
         "-c", "init", "-c", "halt",
         "-c", "echo [format {PRGCTLR=0x%08x STATR=0x%08x CONFIGR=0x%08x "
               "CURPSIZE=0x%08x CSTF=0x%08x ETF=0x%08x DBGMCU=0x%08x "
               "CURTPM=0x%08x AUTH=0x%08x} "
               "[mrw 0xE0041004] [mrw 0xE004100C] [mrw 0xE0041010] "
               "[mrw 0x5C015004] [mrw 0x5C013000] [mrw 0x5C014020] "
               "[mrw 0x5C001004] [mrw 0x5C015204] [mrw 0xE0041FB8]]",
         "-c", "resume", "-c", "shutdown"],
        cwd=str(BRINGUP.parents[2]), capture_output=True, text=True, timeout=10)
    out = r.stdout + r.stderr
    import re
    def get(name):
        m = re.search(name + r"=0x([0-9a-fA-F]+)", out)
        return int(m.group(1), 16) if m else None
    prg = get("PRGCTLR"); stat = get("STATR"); tpiu = get("CURPSIZE")
    cstf = get("CSTF"); etf = get("ETF"); dbg = get("DBGMCU")
    curtpm = get("CURTPM"); auth = get("AUTH")
    if prg is None:
        return ["L7 CoreSight readback failed (openocd/SWD?)"]
    if prg != 1:
        issues.append(f"L7 TRCPRGCTLR=0x{prg:x} (ETM not enabled; run `td etm enable`)")
    if stat is not None and stat != 0:
        issues.append(f"L7 TRCSTATR=0x{stat:x} (ETM in IDLE/error, not tracing)")
    if tpiu not in (0x01, 0x02, 0x08):
        issues.append(f"L7 TPIU_CURPSIZE=0x{tpiu:x} (expected 1/2/8-bit)")
    if cstf is None or (cstf & 0x1) != 1:
        issues.append(f"L7 CSTF ENS0 not set (ETM ATB blocked; funnel disabled)")
    if etf is None or (etf & 0x1) != 1:
        issues.append(f"L7 ETF_CTL disabled (no trace capture)")
    if dbg is None or (dbg & 0x00700000) != 0x00700000:
        issues.append(f"L7 DBGMCU_CR trace clocks not fully enabled (0x{dbg:x})")
    if curtpm and curtpm != 0:
        issues.append(f"L7 TPIU CURTPM=0x{curtpm:x} (test-pattern on! run `td etm clear-curtpm`)")
    # TRCAUTHSTATUS (IHI0064H §7.3.3): bits[7:6]=SNID, bits[3:2]=NSNID.
    # H743 is Armv7-M with no Security Extensions -> SNID indicates the
    # permitted debug level, NSNID is always 0b00. So AUTH=0xC0 (SNID=11
    # Secure non-invasive ENABLED) is NORMAL for this chip. Only flag
    # AUTH=0 or SNID=00 (bits[7:6]=00) as genuinely-blocked.
    if auth is not None and (auth & 0xC0) == 0:
        issues.append(f"L7 TRCAUTHSTATUS=0x{auth:x} — SNID bits[7:6]=00 "
                      f"(non-invasive debug blocked; check DAPLink attach / DAUTHCTRL)")
    if verbose and not issues:
        print(f"  L7 ETM prg=1 stat=0 tpiu=0x{tpiu:x} cstf=0x{cstf:x} etf=0x{etf:x} "
              f"auth=0x{auth:x}")
    return issues


def cmd_diag(a):
    """Layered diagnostic (proposal 41 §3). Early-stop on first FAIL unless --deep."""
    print("=== trace_doctor diag ===")
    all_issues = []
    for name, checker in [
        ("L0 host env", _check_l0),
        ("L1 SWD/STM32", _check_l1_probe),
        ("L2 FPGA bit", _check_l2_fpga_bit),
        ("L3 FPGA net", _check_l3_net),
        ("L7 STM32 ETM", _check_l7_etm),
    ]:
        print(f"\n[{name}]")
        issues = checker(state_load())
        if issues:
            for i in issues:
                print(f"  FAIL {i}")
            all_issues.extend(issues)
            if not a.deep:
                print(f"\n=== EARLY STOP at {name} ({len(issues)} issues) ===")
                print("Run with --deep to continue past failures.")
                return 1
        else:
            print("  PASS")
    if all_issues:
        print(f"\n=== FINISHED with {len(all_issues)} issues ===")
        return 1
    print("\n=== ALL GREEN ===")
    return 0

# ============================================================================
# CLI wiring
# ============================================================================

def _add_extra(p):
    """Add a common --extra ... passthrough for wrapper subcommands."""
    p.add_argument("--extra", nargs=argparse.REMAINDER,
                   help="pass remaining args to the underlying script")
    p.add_argument("--ip", help="FPGA IP (default 192.168.10.42)")


def build_parser():
    p = argparse.ArgumentParser(
        prog="trace_doctor",
        description="Unified CLI for ORBTrace/A7-Lite/H743 bring-up (proposal 41)")
    sub = p.add_subparsers(dest="group", required=True)

    # -- meta --
    ps = sub.add_parser("status", help="print current state file")
    ps.add_argument("--json", action="store_true")
    ps.set_defaults(func=cmd_status)
    pr = sub.add_parser("recent", help="show recent runs")
    pr.add_argument("-n", type=int, default=5)
    pr.set_defaults(func=cmd_recent)

    # -- diag --
    pd = sub.add_parser("diag", help="run layered diagnostic")
    pd.add_argument("--deep", action="store_true", help="continue past FAIL")
    pd.add_argument("--json", action="store_true")
    pd.set_defaults(func=cmd_diag)

    # -- probe group --
    pp = sub.add_parser("probe", help="hardware datapath diagnostics")
    pp_sub = pp.add_subparsers(dest="cmd", required=True)
    x = pp_sub.add_parser("voltmeter", help="TPIU AA/55 physical link test")
    _add_extra(x); x.set_defaults(func=cmd_probe_voltmeter)
    x = pp_sub.add_parser("health", help="read dbg_regfile error codes")
    _add_extra(x); x.set_defaults(func=cmd_probe_health)
    x = pp_sub.add_parser("wire", help="trace pin wire-check")
    x.add_argument("--isolated", action="store_true")
    _add_extra(x); x.set_defaults(func=cmd_probe_wire)
    x = pp_sub.add_parser("pin-la", help="pin_la bit health")
    _add_extra(x); x.set_defaults(func=cmd_probe_pin_la)

    # -- tap group --
    pt = sub.add_parser("tap", help="IDDR sampling phase (IDELAY)")
    pt_sub = pt.add_subparsers(dest="cmd", required=True)
    x = pt_sub.add_parser("set-clk", help="set clock-lane IDELAY tap 0..31")
    x.add_argument("value", type=int); x.set_defaults(func=cmd_tap_set_clk)
    x = pt_sub.add_parser("set-data", help="set all-data-lane IDELAY tap 0..31")
    x.add_argument("value", type=int); x.set_defaults(func=cmd_tap_set_data)
    x = pt_sub.add_parser("set-lane", help="set per-lane IDELAY tap")
    x.add_argument("lane", type=int); x.add_argument("value", type=int)
    x.set_defaults(func=cmd_tap_set_lane)
    x = pt_sub.add_parser("sweep", help="sweep clock IDELAY tap, find best fsync")
    _add_extra(x); x.set_defaults(func=cmd_tap_sweep)

    # -- freq group --
    pf = sub.add_parser("freq", help="sysclk / TRACECLK sweeps")
    pf_sub = pf.add_subparsers(dest="cmd", required=True)
    for name, fn in (("sweep", cmd_freq_sweep), ("ceiling", cmd_freq_ceiling),
                     ("push", cmd_freq_push), ("run", cmd_freq_run),
                     ("yield", cmd_freq_yield)):
        x = pf_sub.add_parser(name); _add_extra(x); x.set_defaults(func=fn)

    # -- mmcm group --
    pm = sub.add_parser("mmcm", help="MMCM phase")
    pm_sub = pm.add_subparsers(dest="cmd", required=True)
    x = pm_sub.add_parser("status"); _add_extra(x); x.set_defaults(func=cmd_mmcm_status)
    x = pm_sub.add_parser("phase")
    x.add_argument("--quality", action="store_true"); _add_extra(x)
    x.set_defaults(func=cmd_mmcm_phase)
    x = pm_sub.add_parser("test"); x.add_argument("phase", type=int)
    _add_extra(x); x.set_defaults(func=cmd_mmcm_test)

    # -- capture group --
    pc = sub.add_parser("capture", help="one-shot / streaming trace capture")
    pc_sub = pc.add_subparsers(dest="cmd", required=True)
    x = pc_sub.add_parser("snapshot", help="one-shot 60KB capture")
    x.add_argument("-o", "--out", default="/tmp/cap.bin")
    x.add_argument("--depth", type=int, default=61440)
    x.add_argument("--timebase", action="store_true")
    x.add_argument("--tag", help="short label for state log")
    x.add_argument("--ip"); x.set_defaults(func=cmd_capture_snapshot)
    x = pc_sub.add_parser("rearm"); x.set_defaults(func=cmd_capture_rearm)
    x = pc_sub.add_parser("status"); x.add_argument("--ip"); x.set_defaults(func=cmd_capture_status)
    for name, fn in (("stream", cmd_capture_stream), ("la-dump", cmd_capture_la_dump),
                     ("run", cmd_capture_run)):
        x = pc_sub.add_parser(name); _add_extra(x); x.set_defaults(func=fn)

    # -- decode group --
    pdc = sub.add_parser("decode", help="ETMv4 decode + verification")
    pdc_sub = pdc.add_subparsers(dest="cmd", required=True)
    x = pdc_sub.add_parser("opencsd")
    x.add_argument("raw"); x.add_argument("elf")
    x.add_argument("--keep"); x.add_argument("extra", nargs=argparse.REMAINDER)
    x.set_defaults(func=cmd_decode_opencsd)
    x = pdc_sub.add_parser("verify", help="verify call edges vs ELF (proposal 38)")
    x.add_argument("pkt_log"); x.add_argument("dis")
    x.set_defaults(func=cmd_decode_verify)
    x = pdc_sub.add_parser("perf", help="export Perfetto perf (etm_with_time + orbetto)")
    x.add_argument("raw"); x.add_argument("elf")
    x.add_argument("--freq-khz", type=int, default=300000)
    x.set_defaults(func=cmd_decode_perf)
    for name, fn in (("tpiu-diff", cmd_decode_tpiu_diff),
                     ("walk-score", cmd_decode_walk_score),
                     ("golden", cmd_decode_golden)):
        x = pdc_sub.add_parser(name); _add_extra(x); x.set_defaults(func=fn)

    # -- build group --
    pb = sub.add_parser("build")
    pb_sub = pb.add_subparsers(dest="cmd", required=True)
    x = pb_sub.add_parser("fpga"); _add_extra(x); x.set_defaults(func=cmd_build_fpga)
    x = pb_sub.add_parser("fw"); _add_extra(x); x.set_defaults(func=cmd_build_fw)

    # -- burn group --
    pbu = sub.add_parser("burn")
    pbu_sub = pbu.add_subparsers(dest="cmd", required=True)
    x = pbu_sub.add_parser("fpga"); x.add_argument("bit", nargs="?")
    x.add_argument("--no-rearm", action="store_true",
                   help="skip auto-rearm after burn (default: rearm to refresh CSRs)")
    x.set_defaults(func=cmd_burn_fpga)
    x = pbu_sub.add_parser("fw"); x.add_argument("hex"); _add_extra(x)
    x.set_defaults(func=cmd_burn_fw)

    # -- etm group --
    pe = sub.add_parser("etm", help="STM32 ETM configuration")
    pe_sub = pe.add_subparsers(dest="cmd", required=True)
    x = pe_sub.add_parser("enable")
    x.add_argument("--bb", type=int, choices=[0, 1])
    x.add_argument("--stall", type=int, choices=[0, 1])
    x.add_argument("--cache-flag", help="RAM_D1 flag e.g. 0x0000CACE / 0")
    x.set_defaults(func=cmd_etm_enable)
    x = pe_sub.add_parser("recover"); _add_extra(x); x.set_defaults(func=cmd_etm_recover)
    x = pe_sub.add_parser("show"); x.set_defaults(func=cmd_etm_show)
    x = pe_sub.add_parser("clear-curtpm",
        help="clear TPIU test-pattern register (mandatory after etm enable)")
    x.set_defaults(func=cmd_etm_clear_curtpm)

    return p


def main():
    p = build_parser()
    a = p.parse_args()
    fn = getattr(a, "func", None)
    if fn is None:
        p.print_help()
        return 1
    return fn(a)


if __name__ == "__main__":
    sys.exit(main())
