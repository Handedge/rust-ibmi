# Standalone extractor for AIX installp images (BFF "backup by name" format).
# Layout: 0x48-byte file header (big-endian, magic 0x09006BEA),
# then per record: 0x44-byte header (little-endian), NUL-terminated name
# aligned on 8, 0x28-byte trailer, data.
# Record magic: 0xEA6B (raw), 0xEA6C (pack(1)-style Huffman), 0xEA6D.
# Records start on an 8-byte boundary: after each entry, we scan for the
# next header (symbolic links have a different layout from
# regular files).
import os
import stat
import struct
import sys

FILE_HEADER = ">IIIII8sII8sII8sIII"
RECORD_HEADER = "<HHIIIIIIIIIIIIIII"
RECORD_TRAILER = "<IIIIIIIIII"
MAGICS = (0xEA6B, 0xEA6C, 0xEA6D)
RECORD_HEADER_SIZE = struct.calcsize(RECORD_HEADER)
RECORD_TRAILER_SIZE = struct.calcsize(RECORD_TRAILER)


def unpack(data, output_size):
    """Canonical Huffman of pack(1): levels, number of leaves per level,
    leaves, then the bit stream (most significant bit first)."""
    pos = 0
    levels = data[pos]; pos += 1
    leaves = list(data[pos:pos + levels]); pos += levels
    leaves[-1] += 1                       # the last level carries the end marker
    tree = []
    for n in leaves:
        tree.append(data[pos:pos + n]); pos += n
    leaves[-1] += 1
    # internal nodes per level, computed bottom-up
    internal_nodes = [0] * levels
    for level in range(levels - 2, -1, -1):
        internal_nodes[level] = (internal_nodes[level + 1] + leaves[level + 1]) // 2
    output = bytearray()
    level = code = 0
    for byte in data[pos:]:
        for i in range(7, -1, -1):
            code = (code << 1) | ((byte >> i) & 1)
            if code >= internal_nodes[level]:
                idx = code - internal_nodes[level]
                if idx >= len(tree[level]):          # end marker
                    return bytes(output)
                output.append(tree[level][idx])
                if len(output) == output_size:
                    return bytes(output)
                code = level = 0
            else:
                level += 1
    return bytes(output)


def read_name(d, pos):
    end = d.index(b"\0", pos)
    return d[pos:end].decode("latin-1"), (end + 8) & ~7


def next_header(d, pos):
    pos = (pos + 7) & ~7
    while pos + 4 <= len(d):
        if struct.unpack_from("<H", d, pos + 2)[0] in MAGICS and d[pos + 1] == 0x0B:
            return pos
        pos += 8
    return len(d)


def extract(src, output=None):
    d = open(src, "rb").read()
    if struct.unpack_from(">I", d, 0)[0] != 0x09006BEA:
        sys.exit("not a BFF file")
    pos = struct.calcsize(FILE_HEADER)
    while pos + RECORD_HEADER_SIZE <= len(d):
        h = struct.unpack_from(RECORD_HEADER, d, pos)
        magic, mode, size, packed_size = h[1], h[4], h[7], h[15]
        if magic not in MAGICS:
            break
        name, p = read_name(d, pos + RECORD_HEADER_SIZE)
        p += RECORD_TRAILER_SIZE
        print(f"{magic:#x}\t{mode:o}\t{size}\t{packed_size}\t{name}")
        if (mode & 0o170000) == stat.S_IFREG and size > 0:
            raw = d[p:p + packed_size]
            content = unpack(raw, size) if magic == 0xEA6C else raw
            if len(content) != size:
                print(f"  WARNING: {len(content)} bytes instead of {size}")
            if output:
                target = os.path.normpath(os.path.join(output, name.lstrip("./")))
                if target.startswith(os.path.normpath(output)):
                    os.makedirs(os.path.dirname(target), exist_ok=True)
                    open(target, "wb").write(content)
            p += packed_size
        pos = next_header(d, p)


if __name__ == "__main__":
    extract(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
