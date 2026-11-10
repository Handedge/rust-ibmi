# rust-ibmi: Rust on IBM i (PASE)

**rust-ibmi** installs a working **Rust toolchain (rustc, cargo, rustfmt, clippy) on IBM i 7.5**, inside
PASE, and fixes what PASE does differently from AIX, so that ordinary Rust programs and crates.io
dependencies build and run.

[Français](README.fr.md)

> ⚠️ **Personal, unofficial project, provided "as is", without warranty, support or liability of any
> kind** (see the [Disclaimer](#disclaimer)). Not affiliated with or endorsed by IBM or the Rust project.

## Why

IBM publishes the **IBM Open SDK for Rust on AIX** (free Community Edition), and its README lists
"IBM i 7.5 PASE" among the supported systems. But the SDK only ships as AIX packages (installp runtime
filesets, AIX RPMs for `/opt/freeware`), with no IBM i installation path, and once it is in place PASE
breaks parts of the Rust standard library:

| Observed under PASE (IBM i 7.5) | Effect | Fix in rust-ibmi |
|---|---|---|
| `openat`, `fstatat`, `unlinkat`…: EINVAL whenever the directory is not `AT_FDCWD` | `std::fs::remove_dir_all` fails, and every crate that walks directories | **libpaseat** emulates them through the absolute path |
| `open(O_DIRECTORY)` succeeds on a regular file | wrong directory traversal | ENOTDIR restored |
| `fcntl(F_DUPFD_CLOEXEC)`: EINVAL | `try_clone`, tokio's signal driver | emulated with `F_DUPFD` + `FD_CLOEXEC` |
| the Open XL C/C++ runtime (`libc++`, `libunwind`) is an AIX installp fileset | rustc and every Rust program fail to load | extracted next to the toolchain, never into `/QOpenSys/usr/lib` |
| cargo is linked against the AIX OpenSSL | two libcrypto instances, TLS failures | cargo's import table rewritten to the OpenSSL of yum |
| `cert.pem` is sometimes empty | `cargo` cannot reach crates.io | CA bundle built from the yum certificates |
| the PASE `ld` rejects `-bdbg:namedsects:ss`, passed by rustc 1.98 and later | every link fails (`0711-151 SETOPT: Invalid option name`) | `ld-pase` wrapper that drops this option |

libpaseat is linked **before** libc (`-l paseat` in `RUSTFLAGS`): the AIX linker then binds these
symbols to it. It is a small C library (`paseat/paseat.c`), built on your machine by the installer.

## Requirements

- **IBM i 7.5 or later** (POWER8 or later), with the IBM yum environment (`/QOpenSys/pkgs`) and
  Internet access (AIX Toolbox, yum repositories, crates.io).
- An administrator profile (yum installs a few packages: gcc 12, cmake, python 3.9, OpenSSL 3…).
- The **IBM Open XL C/C++ for AIX runtime** (17.1.3 or later), which you download yourself from
  [IBM Fix Central](https://www.ibm.com/support/fixcentral/) (product "IBM Open XL C/C++ for AIX",
  file `IBM_OPEN_XL_CPP_RUNTIME_17.1.x.y_AIX.tar.Z`, free with an IBMid) and copy to the IFS.
  It is not redistributed here.

## Install

As an administrator, in ssh (not QSH: name resolution needs a multithread-capable job):

```
git clone https://github.com/Handedge/rust-ibmi.git && cd rust-ibmi
sh install.sh /home/ME/IBM_OPEN_XL_CPP_RUNTIME_17.1.4.2_AIX.tar.Z
```

The installer first shows the IBM license terms that apply (the SDK is licensed by IBM, not by this
project) and asks you to type `yes`; for an unattended installation, add `--accept-license` (or `-y`).
It then downloads the SDK packages from the IBM AIX Toolbox, extracts them **without** going through the
IBM i rpm database, applies the PASE adaptations, and ends by compiling and running a `remove_dir_all`
test.

Options:

- `-p PREFIX`: installation directory (default `/QOpenSys/opt/rust`).
- `-v VERSION`: Rust version from the AIX Toolbox (default: the most recent one, 1.96 today).
- `-s SDK`: install from the SDK archive you downloaded from IBM instead of the AIX Toolbox, e.g.
  `IBM_OPEN_SDK_FOR_RUST_COMMUNITY_1.98.0_AIX.tar.Z` (IBM's download site often has a newer version
  than the Toolbox).
- The runtime argument can also be a directory that already holds `libc++.a`, `libc++abi.a` and
  `libunwind.a`.

| Installed | Path |
|---|---|
| toolchain | `PREFIX/<version>`, `PREFIX/current` |
| Open XL runtime, libpaseat | `PREFIX/runtime` |
| libz, libatomic for rustc and cargo | `PREFIX/runtime-tools` |
| cargo home (registry, installed binaries) | `PREFIX/cargo` |
| environment | `PREFIX/rustenv.sh` |

To remove it: `rm -rf PREFIX`.

## Use

```
. /QOpenSys/opt/rust/rustenv.sh
cargo new hello && cd hello && cargo run
```

Programs you build find `libpaseat.a` and the Open XL runtime through the library search path written
into them (`-blibpath`), so they run without `rustenv.sh`, as long as `PREFIX/runtime` stays in place.
In batch, submit them with `SBMJOB CMD(CALL PGM(QP2SHELL) PARM('/path/to/program')) ALWMLTTHD(*YES)`.

Examples:

- [`examples/hello-web`](examples/hello-web): tokio + axum web service (`GET /hello`).
- [`examples/rust-db2`](examples/rust-db2): CL → Rust → Db2 for i (SQL CLI of PASE, `libdb400.a`),
  in the same job as the calling CL program.
- [`examples/remove-dir-all.rs`](examples/remove-dir-all.rs): the test that fails without libpaseat.

Notes:

- Crates must support AIX (`target_os = "aix"`); see the table in the IBM SDK README
  (`PREFIX/current/README`). Most of the ecosystem does: libc, tokio, mio, socket2, rustix, nix…
- No LTO, 64-bit only (IBM SDK limitations).
- cargo may print `warning: failed to connect to jobserver ... (os error 22)`: harmless under PASE.
- Tested on IBM i 7.5 (Power9, 2 cores) with Rust 1.96 (AIX Toolbox) and Rust 1.98 (IBM SDK archive):
  installation in 1 to 4.5 minutes; `examples/hello-web` (tokio + axum, dependencies fetched from
  crates.io) built in 2.5 minutes and served `GET /hello`. IBM i 7.4 and earlier are not supported: the installer refuses them.

Rust on IBM i is also how [deno-ibmi](https://github.com/Handedge/deno-ibmi) runs Deno on IBM i.

## Disclaimer

**No liability.** Personal, unofficial hobby project, provided "as is", without warranty of any kind,
express or implied, and without support. The author accepts no responsibility for any use of it or for
any direct or indirect damage. See the [LICENSE](LICENSE) (MIT).

**Not affiliated.** Not affiliated with, sponsored or endorsed by IBM, the Rust Foundation or the Rust
project. "Rust" and "Cargo" are trademarks of the Rust Foundation; IBM, IBM i, AIX, Power and Db2 are
trademarks of International Business Machines Corporation. They are used only to describe what this
project works with.

**IBM software is not distributed here.** The IBM Open SDK for Rust on AIX and the IBM Open XL C/C++
runtime are downloaded by the installer or by you, from IBM, and used under IBM's license terms: the
IBM License Information of the program and the International License Agreement for Non-Warranted
Programs (texts in `PREFIX/current/`: `LicenseAgreement.pdf`, `license.pdf`, `non_ibm_license*.htm`).
The installer asks you to accept them before installing anything. These terms do not allow the SDK to
be redistributed, which is why this project ships an installer and not a Rust package.

## License

MIT (see [LICENSE](LICENSE)). Author: **Sylvain AKTEPE**.
