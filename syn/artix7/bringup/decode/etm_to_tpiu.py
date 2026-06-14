"""etm_to_tpiu — wrap a clean, already-deframed ETM byte stream into a minimal
CoreSight TPIU formatter stream on stream-ID 2, with an FSYNC prefix, so that
orbetto (which runs its own TPIU deformatter via -t 2 and needs FSYNC to lock)
can ingest it -> Mortrall -> Perfetto.

Our capture path produces clean ETM bytes but the on-wire TPIU stream has no
FSYNC (only HSYNC), so orbetto's TPIUPump never syncs. We re-frame here:
  * 4-byte FSYNC (FF FF FF 7F) once at the start (and periodically) to lock,
  * 16-byte frames: byte0 = stream-id-2 change (0x05), bytes 1..14 = data,
    byte15 = aux holding the LSBs of the even data byte slots.

Standard CoreSight frame rules (matches orbetto TPIUPump / our deframe):
  * even byte j (0,2,..,14): if bit0=1 -> stream-id change to (byte>>1);
    if bit0=0 -> data byte whose true LSB is aux>>(j/2) & 1.
  * odd byte j (1,3,..,13): always data.
  * byte15: aux, bit (j/2) = LSB of even data byte j.

Usage: python3 etm_to_tpiu.py <etm_bytes.bin> <out.tpiu>
"""
import sys

FSYNC = bytes([0xFF, 0xFF, 0xFF, 0x7F])
STREAM = 2
FSYNC_EVERY = 16  # emit an FSYNC every N frames so a late start can still lock


def reframe(etm: bytes) -> bytes:
    out = bytearray()
    out += FSYNC
    # We place the stream-id change in even slot 0 of the FIRST frame, then
    # carry data. To keep it simple and robust, every frame starts by
    # re-asserting stream 2 in byte0 (id change, immediate), then 14 data bytes.
    i = 0
    n = len(etm)
    frame_count = 0
    while i < n:
        if frame_count and frame_count % FSYNC_EVERY == 0:
            out += FSYNC
        frame = bytearray(16)
        frame[0] = (STREAM << 1) | 1          # even slot 0: stream-id change -> 2
        aux = 0
        # fill slots 1..14 with 14 data bytes
        for k in range(1, 15):
            if i < n:
                d = etm[i]; i += 1
            else:
                d = 0x00
            if k % 2 == 0:
                # even data slot: store with LSB stripped, LSB into aux
                frame[k] = d & 0xFE
                if d & 1:
                    aux |= (1 << (k // 2))
            else:
                frame[k] = d
        frame[15] = aux
        out += frame
        frame_count += 1
    return bytes(out)


def main():
    etm = open(sys.argv[1], "rb").read()
    tpiu = reframe(etm)
    with open(sys.argv[2], "wb") as f:
        f.write(tpiu)
    print(f"wrapped {len(etm)} ETM bytes -> {len(tpiu)} TPIU bytes "
          f"(stream {STREAM}, FSYNC every {FSYNC_EVERY} frames) -> {sys.argv[2]}")


if __name__ == "__main__":
    main()
