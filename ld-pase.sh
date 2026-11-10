#!/QOpenSys/usr/bin/sh
# Linker wrapper for rustc under IBM i PASE (installed as PREFIX/bin/ld-pase, used through
# RUSTFLAGS "-C linker=..."). The PASE ld is older than the AIX 7.3 one and rejects options that
# recent rustc versions pass: they are removed here, everything else goes to ld unchanged.
#   -bdbg:namedsects:ss   (rustc 1.98 and later): "SETOPT: Invalid option name: NAMEDSECTS"
for a in "$@"; do
  shift
  case $a in
    -bdbg:namedsects*) ;;
    *) set -- "$@" "$a" ;;
  esac
done
exec /QOpenSys/usr/bin/ld "$@"
