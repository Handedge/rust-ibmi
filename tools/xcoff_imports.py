# Reads and rewrites the import table (.loader section) of an XCOFF64 executable.
# Usage: xcoff_imports.py FILE                          -> prints the imports
#        xcoff_imports.py FILE base:member=base:member ... [--libpath PATH]
# The table is rebuilt at the same length: the difference is absorbed
# by padding the search path (entry 0) with trailing ':' characters.
import struct
import sys


def read_imports(d):
    magic, nscns, _, _, opthdr, _, _ = struct.unpack_from(">HHIQHHI", d, 0)
    if magic != 0x01F7:
        sys.exit(f"not an XCOFF64 file (magic {magic:#x})")
    pos = 24 + opthdr
    for _ in range(nscns):
        name = d[pos:pos + 8].rstrip(b"\0")
        scnptr = struct.unpack_from(">Q", d, pos + 32)[0]
        if name == b".loader":
            ver, nsyms, nreloc, istlen, nimpid, stlen, impoff = struct.unpack_from(">IIIIIIQ", d, scnptr)
            start = scnptr + impoff
            raw = bytes(d[start:start + istlen])
            fields = raw.split(b"\0")
            ids = [fields[i * 3:i * 3 + 3] for i in range(nimpid)]
            return start, istlen, ids
        pos += 72
    sys.exit("no .loader section")


def main():
    path = sys.argv[1]
    d = bytearray(open(path, "rb").read())
    start, istlen, ids = read_imports(d)
    replacements, libpath = {}, None
    args = sys.argv[2:]
    while args:
        a = args.pop(0)
        if a == "--libpath":
            libpath = args.pop(0).encode()
        else:
            g, right = a.split("=")
            replacements[tuple(g.encode().split(b":"))] = right.encode().split(b":")
    for i, (p, b, m) in enumerate(ids):
        print(i, p.decode()[:90], b.decode(), m.decode())
    if not replacements and libpath is None:
        return
    new_ids = [list(x) for x in ids]
    for x in new_ids[1:]:
        key = (x[1], x[2])
        if key in replacements:
            x[1], x[2] = replacements[key]
    if libpath is not None:
        new_ids[0][0] = libpath
    # each import: path (empty here) \0 base \0 member \0
    body = b"".join(b"\0".join(x) + b"\0" for x in new_ids[1:])
    room = istlen - len(body) - len(new_ids[0][1]) - len(new_ids[0][2]) - 3
    if room < len(new_ids[0][0]):
        sys.exit(f"table too long by {len(new_ids[0][0]) - room} bytes")
    head = new_ids[0][0] + b":" * (room - len(new_ids[0][0]))
    table = head + b"\0" + new_ids[0][1] + b"\0" + new_ids[0][2] + b"\0" + body
    assert len(table) == istlen
    d[start:start + istlen] = table
    open(path, "wb").write(d)
    print("--- after rewrite")
    for i, (p, b, m) in enumerate(read_imports(d)[2]):
        print(i, p.decode()[:90], b.decode(), m.decode())


if __name__ == "__main__":
    main()
