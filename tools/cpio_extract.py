# Extracts a "newc" cpio archive (output of rpm2cpio) into a directory.
# The cpio of PASE cannot read this format, and the AIX RPMs must not go into the IBM i rpm database.
# Usage: python3.9 cpio_extract.py ARCHIVE.cpio DESTINATION
import os
import sys


def main():
    src, root = sys.argv[1], sys.argv[2]
    d = open(src, "rb").read()
    i = 0
    while True:
        h = d[i:i + 110]
        if h[:6] not in (b"070701", b"070702"):
            sys.exit(f"{src}: not a newc cpio archive at offset {i}")
        f = [int(h[6 + 8 * k:14 + 8 * k], 16) for k in range(13)]
        mode, fsz, nsz = f[1], f[6], f[11]
        name = d[i + 110:i + 110 + nsz - 1].decode()
        i = (i + 110 + nsz + 3) & ~3
        data = d[i:i + fsz]
        i = (i + fsz + 3) & ~3
        if name == "TRAILER!!!":
            break
        p = os.path.join(root, name.lstrip("./"))
        t = mode & 0o170000
        if t == 0o040000:
            os.makedirs(p, exist_ok=True)
        elif t == 0o120000:
            os.makedirs(os.path.dirname(p), exist_ok=True)
            if not os.path.lexists(p):
                os.symlink(data.decode(), p)
        else:
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "wb") as out:
                out.write(data)
            os.chmod(p, mode & 0o7777)


if __name__ == "__main__":
    main()
