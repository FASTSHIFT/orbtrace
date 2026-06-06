# Cross-clock-domain (CDC) tests for the trace->sys AsyncFIFO.
#
# Background: in trace/core.py the trace path crosses from the `trace` clock
# domain (recovered TRACECLK) into the `sys` domain through an AsyncFIFO:
#   trace_fifo = AsyncFIFOBuffered(... , {'write': 'trace', 'read': 'sys'})
# Red-team review flagged this CDC as the one path NOT covered by the existing
# single-clock unit tests, and the most likely place on real hardware to drop
# bytes / hit metastability. These tests run the AsyncFIFO with two genuinely
# different clocks and assert nothing is lost, duplicated or reordered.

from sim_helpers import *

from amaranth.lib import data
from amaranth.sim import Simulator, SimulatorContext

from orbtrace.stream import AsyncFIFOBuffered


def _run_cdc(write_period, read_period, n_items, depth=4):
    """Drive an AsyncFIFOBuffered across two clock domains and check integrity.

    write_period / read_period: clock periods (s) for the 'write' and 'read'
    domains. Different values exercise real fast->slow / slow->fast crossings.
    """
    dut = AsyncFIFOBuffered(8, depth)

    sim = Simulator(dut)
    sim.add_clock(write_period, domain='write')
    sim.add_clock(read_period, domain='read')

    received = []

    @sim.add_testbench
    async def producer(ctx: SimulatorContext):
        for i in range(n_items):
            value = i & 0xff
            ctx.set(dut.input.valid, 1)
            ctx.set(dut.input.payload, value)
            # Hold until accepted in the write domain.
            await ctx.tick('write').until(dut.input.ready == 1)
            ctx.set(dut.input.valid, 0)
        ctx.set(dut.input.valid, 0)

    @sim.add_testbench
    async def consumer(ctx: SimulatorContext):
        ctx.set(dut.output.ready, 1)
        while len(received) < n_items:
            payload, = await ctx.tick('read').sample(dut.output.payload).until(dut.output.valid == 1)
            received.append(int(payload))
        ctx.set(dut.output.ready, 0)

    @sim.add_process
    async def timeout(ctx: SimulatorContext):
        await ctx.tick('write').repeat(100_000)
        raise TimeoutError('CDC simulation timed out (possible lost item)')

    sim.run()

    expected = [i & 0xff for i in range(n_items)]
    assert received == expected, (
        f'CDC integrity failure: expected {expected[:8]}... got {received[:8]}... '
        f'(lost/dup/reorder); len exp={len(expected)} got={len(received)}'
    )


def test_cdc_fast_write_slow_read():
    # trace domain faster than sys domain (data bursts in faster than drained).
    _run_cdc(write_period=1e-6, read_period=3.7e-6, n_items=64)


def test_cdc_slow_write_fast_read():
    # sys domain faster than trace domain.
    _run_cdc(write_period=3.7e-6, read_period=1e-6, n_items=64)


def test_cdc_near_equal_clocks():
    # Close but non-integer-related periods exercise drift / beat conditions.
    _run_cdc(write_period=1e-6, read_period=1.03e-6, n_items=128)


def test_cdc_deeper_fifo():
    # Larger depth, fast producer: stresses fill/drain without overflow loss.
    _run_cdc(write_period=1e-6, read_period=2.1e-6, n_items=200, depth=16)
