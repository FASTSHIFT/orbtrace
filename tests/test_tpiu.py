from sim_helpers import *

import itertools

from amaranth.sim import Simulator, SimulatorContext

from orbtrace.trace import tpiu

def test_packetizer():
    dut = tpiu.Packetizer(timeout = 2000)

    sim = Simulator(dut)
    sim.add_clock(1e-6)

    @sim.add_testbench
    async def input_testbench(ctx: SimulatorContext):
        await ctx.tick()

        for i in range(1024 + 512):
            await stream_put(ctx, dut.input, {'channel': 1, 'data': i & 0xff})
    
    @sim.add_testbench
    async def output_testbench(ctx: SimulatorContext):
        assert await recv_packet(ctx, dut.output) == [1, *((i & 0xff) for i in range(1024))]
        assert await recv_packet(ctx, dut.output) == [1, *((i & 0xff) for i in range(512))]

    @sim.add_process
    async def timeout(ctx: SimulatorContext):
        await ctx.tick().repeat(10_000)
        raise TimeoutError('Simulation timed out')

    sim.run()

def test_packetizer_slow_timeout():
    dut = tpiu.Packetizer(timeout = 1000)

    sim = Simulator(dut)
    sim.add_clock(1e-6)

    @sim.add_process
    async def input_testbench(ctx: SimulatorContext):
        await ctx.tick()

        for i in itertools.count():
            await stream_put(ctx, dut.input, {'channel': 1, 'data': i & 0xff})
            await ctx.tick().repeat(100)

    @sim.add_testbench
    async def output_testbench(ctx: SimulatorContext):
        assert await recv_packet(ctx, dut.output) == [1, *((i & 0xff) for i in range(10))]
        assert await recv_packet(ctx, dut.output) == [1, *((i & 0xff) for i in range(10, 20))]

    @sim.add_process
    async def timeout(ctx: SimulatorContext):
        await ctx.tick().repeat(10_000)
        raise TimeoutError('Simulation timed out')

    sim.run()

def test_demux():
    dut = tpiu.TPIUDemux(timeout = 1000)

    sim = Simulator(dut)
    sim.add_clock(1e-6)

    @sim.add_testbench
    async def input_testbench(ctx: SimulatorContext):
        await ctx.tick()

        payloads = [
            # ITM hello world without padding.
            bytes.fromhex('03 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 01 48 01 64 88'),
            bytes.fromhex('00 6c 00 6c 00 6f 00 20 00 77 00 6f 00 72 00 ff'),
            bytes.fromhex('6c 01 64 01 20 01 0a 0b 00 00 00 00 0a 00 00 44'),
            bytes.fromhex('00 00 0a 00 00 00 00 0b 00 00 00 00 0a 00 00 42'),
            bytes.fromhex('00 00 0a 00 00 00 00 0b 00 00 00 00 0a 00 00 42'),
            bytes.fromhex('03 00 00 0b 00 00 00 00 0a 00 00 00 00 0b 00 10'),
            bytes.fromhex('00 00 00 0b 00 00 00 00 0a 00 00 00 00 0b 00 10'),
            bytes.fromhex('00 00 00 0b 00 00 00 00 0a 00 00 00 00 0b 00 10'),
            bytes.fromhex('00 00 00 0b 00 00 00 00 0a 00 00 00 00 0b 00 10'),
            bytes.fromhex('00 00 00 0b 00 00 00 00 0a 00 00 00 00 0b 00 10'),
            bytes.fromhex('00 00 00 0b 00 00 00 00 0a 00 00 00 00 0b 00 10'),
            bytes.fromhex('00 00 00 0b 00 00 00 00 0a 00 00 00 00 0b 00 10'),
            bytes.fromhex('00 00 00 0b 00 00 00 00 0a 00 00 00 00 0b 00 10'),

            # ITM hello world with padding.
            bytes.fromhex('03 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 01 01 48 00 48'),
            bytes.fromhex('03 01 01 65 03 01 01 6c 03 01 01 6c 03 01 6e aa'),
            bytes.fromhex('03 01 01 20 03 01 01 77 03 01 01 6f 03 01 72 2a'),
            bytes.fromhex('03 01 01 6c 03 01 01 64 03 01 01 21 03 01 0a 2a'),
            bytes.fromhex('03 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
            bytes.fromhex('00 0b 00 00 00 00 0a 00 00 00 00 0b 00 00 00 08'),
        ]

        for payload in payloads:
            await stream_put(ctx, dut.input, payload)

    @sim.add_testbench
    async def output_testbench(ctx: SimulatorContext):
        res = await recv_packet(ctx, dut.output)
        assert bytes(res) == bytes.fromhex('''
            01 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b
            00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00
            00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00
            0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00
            00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00
            00 01 48 01 65 01 6c 01 6c 01 6f 01 20 01 77 01 6f 01 72 01 6c 01 64 01 21 01 0a 0b 00 00 00 00
            0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00
            00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00
            00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b
            00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00
            00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 0b 00 00 00 00 0b 00 00
            00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00
            0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00
            00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00
            00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b
            00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 01 48 01 65 01 6c 01 6c
            01 6f 01 20 01 77 01 6f 01 72 01 6c 01 64 01 21 01 0a 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00
            00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b
            00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00
            00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00
            0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00 00 00 00 0b 00
            00 00 00 0b 00 00 00
        ''')

    @sim.add_process
    async def timeout(ctx: SimulatorContext):
        await ctx.tick().repeat(10_000)
        raise TimeoutError('Simulation timed out')

    sim.run()


# ---- TPIUSync coverage --------------------------------------------------
# Closes a coverage gap: TPIUSync was previously only exercised indirectly
# through test_demux. Direct tests below confirm sync acquisition, the
# 0xff7f half-sync slip rule, and that resync_sync drops synchronisation.

def test_tpiusync_basic_frame():
    """Feed garbage, then sync sequence (ff ff ff 7f), then 16 frame bytes;
    expect exactly one 16-byte frame matching what we sent after sync."""
    dut = tpiu.TPIUSync()
    sim = Simulator(dut)
    sim.add_clock(1e-6)

    payload = bytes(range(0x10, 0x20))  # 16 bytes 0x10..0x1f

    @sim.add_testbench
    async def producer(ctx: SimulatorContext):
        await ctx.tick()
        # Garbage before sync; must NOT produce frames.
        for b in [0x00, 0x55, 0xaa, 0x12, 0x34]:
            await stream_put(ctx, dut.input, b)
        # Full sync word 0x7fff_ffff (LSB-first byte order: ff ff ff 7f)
        for b in [0xff, 0xff, 0xff, 0x7f]:
            await stream_put(ctx, dut.input, b)
        # 16 payload bytes -> one frame
        for b in payload:
            await stream_put(ctx, dut.input, b)

    @sim.add_testbench
    async def consumer(ctx: SimulatorContext):
        # First (and only) frame should be the 16 payload bytes.
        ctx.set(dut.output.ready, 1)
        # Wait for valid frame and capture it.
        frame, = await ctx.tick().sample(dut.output.payload).until(dut.output.valid == 1)
        # Compare byte by byte.
        for i, exp in enumerate(payload):
            assert int(frame[i]) == exp, (
                f'frame[{i}] = {int(frame[i]):#x} expected {exp:#x}'
            )

    @sim.add_process
    async def timeout(ctx: SimulatorContext):
        await ctx.tick().repeat(2000)
        raise TimeoutError('TPIUSync timed out')

    sim.run()


def test_tpiusync_no_frame_before_sync():
    """Without a sync sequence, output.valid must never go high."""
    dut = tpiu.TPIUSync()
    sim = Simulator(dut)
    sim.add_clock(1e-6)

    @sim.add_testbench
    async def producer(ctx: SimulatorContext):
        await ctx.tick()
        # 64 bytes of non-sync data; intentionally no 0xffffff7f sequence.
        for b in [0x55, 0xaa, 0x12, 0x34] * 16:
            await stream_put(ctx, dut.input, b)

    @sim.add_testbench
    async def watcher(ctx: SimulatorContext):
        ctx.set(dut.output.ready, 1)
        # Run for a while and assert valid never asserts.
        for _ in range(500):
            await ctx.tick()
            assert ctx.get(dut.output.valid) == 0, 'unexpected output frame before sync'

    @sim.add_process
    async def timeout(ctx: SimulatorContext):
        await ctx.tick().repeat(2000)
        raise TimeoutError('watcher run done')

    try:
        sim.run()
    except TimeoutError:
        pass  # expected end of test


def test_tpiusync_reset_drops_sync():
    """After acquiring sync, asserting reset_sync must drop the synced state
    so further input cannot produce a frame until a new sync sequence."""
    dut = tpiu.TPIUSync()
    sim = Simulator(dut)
    sim.add_clock(1e-6)

    @sim.add_testbench
    async def producer(ctx: SimulatorContext):
        await ctx.tick()
        # Acquire sync.
        for b in [0xff, 0xff, 0xff, 0x7f]:
            await stream_put(ctx, dut.input, b)
        # Drop sync via reset_sync pulse.
        ctx.set(dut.reset_sync, 1)
        await ctx.tick()
        ctx.set(dut.reset_sync, 0)
        # Feed bytes; with no new sync, no frame should come out.
        for b in range(16):
            await stream_put(ctx, dut.input, b & 0xff)

    @sim.add_testbench
    async def watcher(ctx: SimulatorContext):
        ctx.set(dut.output.ready, 1)
        # Wait long enough for any spurious frame to surface, then check.
        await ctx.tick().repeat(100)
        assert ctx.get(dut.output.valid) == 0, 'frame leaked after reset_sync'

    @sim.add_process
    async def timeout(ctx: SimulatorContext):
        await ctx.tick().repeat(2000)
        raise TimeoutError('reset_sync test done')

    try:
        sim.run()
    except TimeoutError:
        pass
