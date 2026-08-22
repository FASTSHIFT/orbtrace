.syntax unified
.thumb
.global _start
@ Simplest possible ETM stimulus: an infinite tight self-branch loop.
@ Every iteration executes exactly ONE taken direct branch (b .), which the
@ ETMv4 traces as ONE E (executed) Atom element. No memory access, no calls,
@ no exceptions, no data -- the ONLY P0 element ever generated is "E".
@
@ Hand-derivation of the ETM instruction stream (IHI0064H.b 6.4.13):
@   * A tight run of E atoms is packed into Atom Format 6 packets.
@   * Format 6 header = 0b11 A CCCCC ; atoms = (COUNT+3) initial E + 1 final(A).
@   * Max all-E run: A=0, COUNT=0b10100(20) -> 24 E atoms -> header 0xD4.
@   * So the steady-state instruction trace is a stream of 0xD4 bytes, each
@     meaning "24 taken branches", plus the periodic A-Sync (>=11x 0x00, 0x80)
@     + Trace Info (0x01 ...) + Address packet that bracket each sync window.
@ This is trivial to verify byte-for-byte against a physical capture without
@ any decoder.
_start:
loop:
    b loop        @ 0xE7FE : branch to self, always taken -> one E atom / iter
