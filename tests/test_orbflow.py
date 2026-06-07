"""Unit tests for trace/orbflow.py modules.

Closes a coverage gap: orbflow.py was at 0% line coverage despite the modules
being part of the production trace pipeline (and now also targeted by Stage-2
OOC synthesis). These tests exercise ChecksumAppender directly.
"""
from sim_helpers import *

from amaranth.sim import Simulator, SimulatorContext

from orbtrace.trace.orbflow import ChecksumAppender


def _checksum(data):
    """Reference: 8-bit running subtraction, matching the RTL's
    `checksum <= checksum - input.data`. Result is taken modulo 256."""
    s = 0
    for b in data:
        s = (s - b) & 0xff
    return s


def _run_checksum_case(packets):
    """Feed `packets` (list[bytes]) through ChecksumAppender; assert each output
    packet equals `bytes(p) + bytes([checksum(p)])`."""
    dut = ChecksumAppender()
    sim = Simulator(dut)
    sim.add_clock(1e-6)

    @sim.add_testbench
    async def producer(ctx: SimulatorContext):
        await ctx.tick()
        for p in packets:
            await send_packet(ctx, dut.input, p)

    @sim.add_testbench
    async def consumer(ctx: SimulatorContext):
        for p in packets:
            got = await recv_packet(ctx, dut.output)
            assert bytes(got) == bytes(p) + bytes([_checksum(p)]), (
                f'checksum mismatch: input={list(p)} '
                f'got={got} expected={list(p)+[_checksum(p)]}'
            )

    @sim.add_process
    async def timeout(ctx: SimulatorContext):
        await ctx.tick().repeat(20_000)
        raise TimeoutError('checksum sim timed out')

    sim.run()


def test_checksum_single_byte_packet():
    _run_checksum_case([b'\x42'])


def test_checksum_short_packet():
    _run_checksum_case([bytes([1, 2, 3, 4])])


def test_checksum_zero_byte():
    # Single zero -> checksum is also 0
    _run_checksum_case([b'\x00'])


def test_checksum_wraparound():
    # Sum of 0xff, 0x01 = 0x100 -> wraps; checksum = -(0xff+0x01) & 0xff = 0
    _run_checksum_case([bytes([0xff, 0x01])])


def test_checksum_back_to_back_packets():
    # Multiple packets; checksum state must reset between packets.
    _run_checksum_case([
        bytes([0x10, 0x20, 0x30]),
        bytes([0xaa, 0xbb]),
        bytes([0xff, 0xff, 0xff, 0xff]),
    ])


def test_checksum_long_packet():
    _run_checksum_case([bytes(range(256))])
