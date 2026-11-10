#!/QOpenSys/usr/bin/sh
# Builds PREFIX/runtime/libpaseat.a, linked before libc by RUSTFLAGS (-l paseat).
# Usage: sh paseat/build.sh [PREFIX]          (default /QOpenSys/opt/rust)
set -e
export PATH=/QOpenSys/pkgs/bin:/QOpenSys/usr/bin
PREFIX=${1:-/QOpenSys/opt/rust}
cd "$(dirname "$0")"
T=/tmp/paseat.$$
mkdir -p $T
# -pthread (_THREAD_SAFE): errno is *_Errno(), per thread. Without it, the library would write the
# process-wide global errno, and an emulated *at() failing on a secondary thread would leave
# errno = 0 in the calling thread. Check: dump -X64 -Tv shr_64.o imports _Errno, not errno.
gcc-12 -maix64 -pthread -D_THREAD_SAFE -O2 -Wall -fPIC -shared -static-libgcc -o $T/shr_64.o paseat.c \
       -Wl,-bE:paseat.exp -lpthread
if dump -X64 -Tv $T/shr_64.o | grep -q " errno$"; then echo "ERROR: global errno imported"; exit 1; fi
ar -X64 -q $T/libpaseat.a $T/shr_64.o
mkdir -p $PREFIX/runtime
# atomic replacement: running programs keep the version they have loaded
cp $T/libpaseat.a $PREFIX/runtime/libpaseat.a.tmp && mv -f $PREFIX/runtime/libpaseat.a.tmp $PREFIX/runtime/libpaseat.a
rm -rf $T
echo "libpaseat.a built in $PREFIX/runtime"
