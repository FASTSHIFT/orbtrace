"""pb_dump — generic protobuf wire dumper. Prints field (num,wiretype) tree of
a protobuf message to a given depth, with counts, so we can see the real
structure of a Perfetto trace without guessing field numbers.

Usage: pb_dump.py <file> [maxdepth]
"""
import sys
import collections

data = open(sys.argv[1], "rb").read()
maxdepth = int(sys.argv[2]) if len(sys.argv) > 2 else 4


def rv(b, i):
    s = 0
    r = 0
    while True:
        if i >= len(b):
            raise IndexError
        x = b[i]
        i += 1
        r |= (x & 0x7f) << s
        if not (x & 0x80):
            break
        s += 7
    return r, i


def parse(b):
    out = []
    i = 0
    n = len(b)
    while i < n:
        try:
            key, i = rv(b, i)
        except IndexError:
            break
        fn = key >> 3
        wt = key & 7
        if wt == 0:
            try:
                v, i = rv(b, i)
            except IndexError:
                break
            out.append((fn, wt, v))
        elif wt == 2:
            try:
                ln, i = rv(b, i)
            except IndexError:
                break
            if i + ln > n:
                break
            out.append((fn, wt, b[i:i + ln]))
            i += ln
        elif wt == 5:
            out.append((fn, wt, b[i:i + 4]))
            i += 4
        elif wt == 1:
            out.append((fn, wt, b[i:i + 8]))
            i += 8
        else:
            break
    return out


def could_be_msg(bs):
    if not isinstance(bs, (bytes, bytearray)) or len(bs) < 2:
        return False
    try:
        f = parse(bs)
        if not f:
            return False
        # all field numbers plausible
        return all(1 <= fn < 2000 and wt in (0, 1, 2, 5) for fn, wt, _ in f)
    except Exception:
        return False


def walk(b, depth, prefix, counter):
    flds = parse(b)
    local = collections.Counter((fn, wt) for fn, wt, _ in flds)
    for (fn, wt), c in sorted(local.items()):
        counter[(depth, fn, wt)] += c
    if depth >= maxdepth:
        return
    # recurse into the FIRST instance of each (fn) that is a message
    seen = set()
    for fn, wt, v in flds:
        if wt == 2 and fn not in seen and could_be_msg(v):
            seen.add(fn)
            walk(v, depth + 1, prefix + [fn], counter)


counter = collections.Counter()
top = parse(data)
print("top-level fields:", collections.Counter((fn, wt) for fn, wt, _ in top).most_common())
# walk into packets (field 1)
for fn, wt, v in top:
    if fn == 1 and wt == 2:
        walk(v, 1, [1], counter)

print("\n(depth, field, wiretype): count")
for k in sorted(counter):
    print(f"  d{k[0]} field {k[1]} wt {k[2]} : {counter[k]}")
