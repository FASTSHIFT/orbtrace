"""Export trace pipeline Amaranth modules to Verilog wrappers for OOC synthesis.

Stream payloads with complex layouts (ArrayLayout / StructLayout) cannot be
exposed directly as top-level Amaranth ports, so each DUT is wrapped to
flatten the stream interface into plain signals.
"""
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..'))

from amaranth import Module, Elaboratable, Signal, Cat
from amaranth.back import verilog

from orbtrace.trace.orbflow import ChecksumAppender, SuperFramer
from orbtrace.trace.cobs import COBSEncoder
from orbtrace.trace.tpiu import TPIUDemux, TPIUSync


def _wrap_packet8(dut_factory, name, has_bypass=False, bypass_width=8):
    """Wrap a module whose I/O are Packet(8, has_last=True) streams (+ optional 8-bit bypass)."""
    class W(Elaboratable):
        def __init__(self):
            self.in_valid = Signal(); self.in_ready = Signal()
            self.in_data  = Signal(8); self.in_last  = Signal()
            self.out_valid = Signal(); self.out_ready = Signal()
            self.out_data  = Signal(8); self.out_last  = Signal()
            if has_bypass:
                self.bp_valid = Signal(); self.bp_ready = Signal()
                self.bp_data  = Signal(bypass_width)
                self.bypass_sel = Signal()
        def elaborate(self, platform):
            m = Module()
            m.submodules.dut = dut = dut_factory()
            m.d.comb += [
                dut.input.valid.eq(self.in_valid),
                self.in_ready.eq(dut.input.ready),
                dut.input.payload.data.eq(self.in_data),
                dut.input.payload.last.eq(self.in_last),
                self.out_valid.eq(dut.output.valid),
                dut.output.ready.eq(self.out_ready),
                self.out_data.eq(dut.output.payload.data),
                self.out_last.eq(dut.output.payload.last),
            ]
            if has_bypass:
                m.d.comb += [
                    dut.input_bypass.valid.eq(self.bp_valid),
                    self.bp_ready.eq(dut.input_bypass.ready),
                    dut.input_bypass.payload.eq(self.bp_data),
                    dut.bypass.eq(self.bypass_sel),
                ]
            return m
    return W


def _wrap_tpiu_demux():
    """TPIUDemux input is ArrayLayout(8,16) — pack 16 bytes as a 128-bit signal
    on the wrapper boundary, deal with byte-lane indexing inside."""
    class W(Elaboratable):
        def __init__(self):
            self.in_valid = Signal(); self.in_ready = Signal()
            self.in_frame = Signal(128)              # 16 bytes packed
            self.bp_valid = Signal(); self.bp_ready = Signal()
            self.bp_data  = Signal(8)
            self.bypass_sel = Signal()
            self.out_valid = Signal(); self.out_ready = Signal()
            self.out_data  = Signal(8); self.out_last = Signal()
        def elaborate(self, platform):
            m = Module()
            m.submodules.dut = dut = TPIUDemux(timeout=7_500_000)
            # ArrayLayout(8,16): index 0 is byte 0; map to bits [7:0] of in_frame.
            m.d.comb += dut.input.valid.eq(self.in_valid)
            m.d.comb += self.in_ready.eq(dut.input.ready)
            for i in range(16):
                m.d.comb += dut.input.payload[i].eq(self.in_frame[i*8:(i+1)*8])
            m.d.comb += [
                dut.input_bypass.valid.eq(self.bp_valid),
                self.bp_ready.eq(dut.input_bypass.ready),
                dut.input_bypass.payload.eq(self.bp_data),
                dut.bypass.eq(self.bypass_sel),
                self.out_valid.eq(dut.output.valid),
                dut.output.ready.eq(self.out_ready),
                self.out_data.eq(dut.output.payload.data),
                self.out_last.eq(dut.output.payload.last),
            ]
            return m
    return W


def _wrap_tpiu_sync():
    """TPIUSync: input is an 8-bit stream, output is ArrayLayout(8,16) (a
    128-bit TPIU frame). Flatten the frame to a 128-bit signal on the boundary.
    This is the byte-aligning front-end: it locks 0xFFFFFF7F, filters 0x7FFF
    half-syncs, and emits aligned 16-byte frames (IHI0014Q / TPIU formatter)."""
    class W(Elaboratable):
        def __init__(self):
            self.in_valid = Signal(); self.in_ready = Signal()
            self.in_data  = Signal(8)
            self.reset_sync = Signal()
            self.out_valid = Signal(); self.out_ready = Signal()
            self.out_frame = Signal(128)
        def elaborate(self, platform):
            m = Module()
            m.submodules.dut = dut = TPIUSync()
            m.d.comb += [
                dut.input.valid.eq(self.in_valid),
                self.in_ready.eq(dut.input.ready),
                dut.input.payload.eq(self.in_data),
                dut.reset_sync.eq(self.reset_sync),
                self.out_valid.eq(dut.output.valid),
                dut.output.ready.eq(self.out_ready),
            ]
            for i in range(16):
                m.d.comb += self.out_frame[i*8:(i+1)*8].eq(dut.output.payload[i])
            return m
    return W


def export(WCls, name, ports_attrs):
    w = WCls()
    ports = [getattr(w, a) for a in ports_attrs]
    out = os.path.join(os.path.dirname(__file__), f'{name}.v')
    open(out, 'w').write(verilog.convert(w, name=name, ports=ports))
    print(f'  -> {out}')


def main():
    # ChecksumAppender
    export(_wrap_packet8(ChecksumAppender, 'checksum_appender'),
           'checksum_appender',
           ['in_valid','in_ready','in_data','in_last',
            'out_valid','out_ready','out_data','out_last'])
    # COBSEncoder (append_delimiter=True, the variant used in core.py)
    export(_wrap_packet8(lambda: COBSEncoder(append_delimiter=True), 'cobs_encoder'),
           'cobs_encoder',
           ['in_valid','in_ready','in_data','in_last',
            'out_valid','out_ready','out_data','out_last'])
    # SuperFramer (parameters from core.py)
    export(_wrap_packet8(lambda: SuperFramer(7_500_000, 65536), 'super_framer'),
           'super_framer',
           ['in_valid','in_ready','in_data','in_last',
            'out_valid','out_ready','out_data','out_last'])
    # TPIUDemux
    export(_wrap_tpiu_demux(), 'tpiu_demux',
           ['in_valid','in_ready','in_frame',
            'bp_valid','bp_ready','bp_data','bypass_sel',
            'out_valid','out_ready','out_data','out_last'])
    # TPIUSync (byte-aligning front-end: lock 0xFFFFFF7F, filter 0x7FFF)
    export(_wrap_tpiu_sync(), 'tpiu_sync',
           ['in_valid','in_ready','in_data','reset_sync',
            'out_valid','out_ready','out_frame'])


if __name__ == '__main__':
    main()
