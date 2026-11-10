#!/QOpenSys/usr/bin/sh
# rust-ibmi: installs Rust (rustc, cargo, rustfmt, clippy) under IBM i PASE.
#
# It takes the IBM Open SDK for Rust on AIX (Community Edition, AIX Toolbox), which IBM provides
# for AIX only, and adapts it to PASE: libpaseat (the *at() calls that PASE rejects), IBM Open XL
# C/C++ runtime next to the toolchain, yum libraries repackaged, cargo bound to the OpenSSL of yum,
# CA certificates. Nothing is installed in the IBM i rpm database or in /QOpenSys/usr/lib.
#
# Usage (as an administrator, in ssh or in a batch job with ALWMLTTHD(*YES)):
#   sh install.sh [-p PREFIX] [-v VERSION] RUNTIME
#     RUNTIME  IBM Open XL C/C++ for AIX runtime, downloaded by you from IBM Fix Central
#              (IBM_OPEN_XL_CPP_RUNTIME_17.1.x.y_AIX.tar.Z), or a directory that already holds
#              its libraries (libc++.a, libc++abi.a, libunwind.a)
#     -p       installation directory (default /QOpenSys/opt/rust)
#     -v       Rust version, e.g. 1.96 (default: the most recent one in the AIX Toolbox)
# Result: PREFIX/{<version>,current,runtime,runtime-tools,cargo,ca-bundle.pem,rustenv.sh}
# Then: . PREFIX/rustenv.sh && cargo new hello && cd hello && cargo run
set -e
export PATH=/QOpenSys/pkgs/bin:/QOpenSys/usr/bin
PREFIX=/QOpenSys/opt/rust
VER=
while getopts p:v: o; do
  case $o in
    p) PREFIX=$OPTARG ;;
    v) VER=$OPTARG ;;
    *) echo "usage: sh install.sh [-p PREFIX] [-v VERSION] RUNTIME"; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
RTE=${1:?usage: sh install.sh [-p PREFIX] [-v VERSION] RUNTIME (Open XL runtime .tar.Z or directory)}
HERE=$(cd "$(dirname "$0")" && pwd)
TMP=/tmp/rust-ibmi.$$
U=https://public.dhe.ibm.com/aix/freeSoftware/aixtoolbox/RPMS/ppc-7.2/rust
trap 'cd /; rm -rf $TMP' EXIT

echo "== 0. checks"
[ "$(uname -s)" = OS400 ] || { echo "ERROR: this script runs under IBM i PASE"; exit 1; }
LEVEL="$(uname -v).$(uname -r)"
echo "  IBM i $LEVEL"
case $LEVEL in
  7.[5-9]|[89].*) ;;
  *) echo "  WARNING: only IBM i 7.5 and later have been tested" ;;
esac
[ -f "$RTE" ] || [ -d "$RTE" ] || { echo "ERROR: Open XL runtime not found: $RTE"; exit 1; }
case $PREFIX in /*) ;; *) echo "ERROR: PREFIX must be an absolute path"; exit 1 ;; esac
mkdir -p $PREFIX/runtime $PREFIX/runtime-tools $PREFIX/cargo $TMP/rpms $TMP/root

echo "== 1. yum packages (compiler for C dependencies, build tools, python3.9 for this script)"
# only the missing ones: "yum install" would also upgrade the packages already installed
MISSING=
for p in gcc12 gcc12-cplusplus make-gnu cmake ninja-build git libatomic1 libz1 libopenssl3 rpm curl \
         coreutils-gnu grep-gnu sed-gnu ca-certificates-mozilla python39; do
  rpm -q $p > /dev/null 2>&1 || MISSING="$MISSING $p"
done
if [ -n "$MISSING" ]; then
  echo "  installing:$MISSING"
  yum install -y $MISSING > $TMP/yum.log 2>&1 || { tail -20 $TMP/yum.log; exit 1; }
else
  echo "  all present"
fi

echo "== 2. IBM Open SDK for Rust on AIX (AIX Toolbox)"
curl -sSf $U/ > $TMP/index.html || { echo "ERROR: cannot reach $U"; exit 1; }
if [ -z "$VER" ]; then
  VER=$(grep -o 'href="rust1\.[0-9]*-' $TMP/index.html | sed 's/href="rust//;s/-$//' | sort -t. -k2 -n | tail -1)
fi
echo "  Rust $VER"
RPM_LIST=$(grep -o "href=\"[^\"]*$VER[^\"]*\.rpm\"" $TMP/index.html | sed 's/href=//;s/"//g' \
  | grep -E "^(rust|cargo|rustfmt|clippy)$VER-|^rust$VER-(std-static|community-license)-" | sort -V \
  | awk '{ key = $0; sub(/-[0-9]+\.aix.*$/, "", key); latest[key] = $0 } END { for (k in latest) print latest[k] }')
# (one build per package: the most recent one published by IBM)
[ -n "$RPM_LIST" ] || { echo "ERROR: no Rust $VER package in the AIX Toolbox"; exit 1; }
cd $TMP/rpms
for p in $RPM_LIST; do curl -sSf -O $U/$p; echo "  $p"; done

echo "== 3. extraction (outside the IBM i rpm database: these are AIX packages)"
for f in $TMP/rpms/*.rpm; do
  rpm2cpio $f > $TMP/p.cpio
  python3.9 $HERE/tools/cpio_extract.py $TMP/p.cpio $TMP/root
done
[ -d $TMP/root/opt/freeware/lib/RustSDK/$VER ] || { echo "ERROR: RustSDK/$VER missing from the packages"; exit 1; }
rm -rf $PREFIX/$VER
cp -Rp $TMP/root/opt/freeware/lib/RustSDK/$VER $PREFIX/$VER
mkdir -p $PREFIX/$VER/share/licenses
cp -Rp $TMP/root/opt/freeware/doc/* $PREFIX/$VER/share/licenses/ 2>/dev/null || true
ln -sfn $PREFIX/$VER $PREFIX/current

echo "== 4. IBM Open XL C/C++ runtime (libc++, libc++abi, libunwind) next to the toolchain"
if [ -d "$RTE" ]; then
  for a in libc++.a libc++abi.a libunwind.a libcompiler_rt.a; do
    [ -f "$RTE/$a" ] && cp -p "$RTE/$a" $PREFIX/runtime/
  done
else
  mkdir -p $TMP/rte && cd $TMP/rte
  case $RTE in
    *.Z) uncompress -c "$RTE" | tar xf - ;;
    *.gz) gunzip -c "$RTE" | tar xf - ;;
    *) tar xf "$RTE" ;;
  esac
  for r in libc++ libc++abi libunwind; do
    b=$(ls $TMP/rte/$r.rte* $TMP/rte/*/$r.rte* 2>/dev/null | head -1)
    [ -n "$b" ] || { echo "ERROR: $r.rte not found in $RTE"; exit 1; }
    python3.9 $HERE/tools/bff_extract.py $b $TMP/rte/x-$r > /dev/null
    cp $TMP/rte/x-$r/usr/lpp/xlC/lib/*.a $PREFIX/runtime/
  done
fi
for a in libc++.a libc++abi.a libunwind.a; do
  [ -f $PREFIX/runtime/$a ] || { echo "ERROR: $a missing from the Open XL runtime"; exit 1; }
done

echo "== 5. yum libraries in the archive(member) format that rustc expects (outside the -L)"
for l in libz.so.1 libatomic.so.1; do
  a=${l%%.so*}.a; cd $TMP; rm -rf $TMP/so; mkdir -p $TMP/so; cd $TMP/so
  ar -X64 x /QOpenSys/pkgs/lib/$l shr_64.o && mv shr_64.o $l
  rm -f $PREFIX/runtime-tools/$a; ar -X64 -q $PREFIX/runtime-tools/$a $l
done

echo "== 6. cargo: OpenSSL imports from yum (a single libcrypto instance)"
B=$PREFIX/$VER/bin
[ -f $B/.cargo.orig.ibm ] || cp -p $B/.cargo.orig $B/.cargo.orig.ibm
cp -p $B/.cargo.orig.ibm $B/.cargo.orig
python3.9 $HERE/tools/xcoff_imports.py $B/.cargo.orig \
  libssl.a:libssl.so.3=libssl.so.3:shr_64.o libcrypto.a:libcrypto.so.3=libcrypto.so.3:shr_64.o \
  --libpath $PREFIX/runtime:/QOpenSys/pkgs/lib:/usr/lib:/lib > /dev/null

echo "== 7. IBM wrapper scripts: runtime and yum libraries first in LIBPATH"
for f in cargo cargo-clippy cargo-fmt clippy-driver rustc rustdoc rustfmt; do
  [ -f $B/$f ] || continue
  sed "s#^export LIBPATH=/usr/lpp/xlC/lib:#export LIBPATH=$PREFIX/runtime:/QOpenSys/pkgs/lib:/usr/lpp/xlC/lib:#" $B/$f > $B/$f.new
  mv $B/$f.new $B/$f; chmod 755 $B/$f
done

echo "== 8. CA certificates (the IBM i cert.pem is sometimes empty)"
for c in /QOpenSys/var/lib/ca-certificates/openssl/*.0; do cat "$c"; done > $PREFIX/ca-bundle.pem
echo "  $(grep -c 'BEGIN' $PREFIX/ca-bundle.pem) certificates"

echo "== 9. environment and libpaseat"
sed "s#@PREFIX@#$PREFIX#g" $HERE/rustenv.sh.in > $PREFIX/rustenv.sh
sh $HERE/paseat/build.sh $PREFIX

echo "== 10. verification"
. $PREFIX/rustenv.sh
rustc -vV | head -2
cargo -V
cd $TMP && rustc -O $RUSTFLAGS $HERE/examples/remove-dir-all.rs -o remove-dir-all && ./remove-dir-all
cd / && rm -rf $TMP
echo "Rust $VER installed in $PREFIX. To use it: . $PREFIX/rustenv.sh"
