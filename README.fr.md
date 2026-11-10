# rust-ibmi : Rust sur IBM i (PASE)

**rust-ibmi** installe une **chaîne Rust qui fonctionne (rustc, cargo, rustfmt, clippy) sur IBM i 7.5**,
dans PASE, et corrige ce que PASE fait autrement qu'AIX, pour que les programmes Rust ordinaires et
leurs dépendances crates.io se compilent et s'exécutent.

[English](README.md)

> ⚠️ **Projet personnel et non officiel, fourni « tel quel », sans garantie, sans support et sans
> aucune responsabilité** (voir l'[Avertissement](#avertissement)). Ni affilié à IBM ni au projet Rust,
> ni approuvé par eux.

## Pourquoi

IBM publie l'**IBM Open SDK for Rust on AIX** (Community Edition, gratuite), dont le README cite
« IBM i 7.5 PASE » parmi les systèmes pris en charge. Mais le SDK n'existe qu'en paquets AIX (runtime
en filesets installp, RPM AIX pour `/opt/freeware`), sans procédure d'installation pour IBM i, et une
fois en place, PASE casse une partie de la bibliothèque standard de Rust :

| Constaté sous PASE (IBM i 7.5) | Effet | Correction dans rust-ibmi |
|---|---|---|
| `openat`, `fstatat`, `unlinkat`… : EINVAL dès que le répertoire n'est pas `AT_FDCWD` | `std::fs::remove_dir_all` échoue, comme toute crate qui parcourt des répertoires | **libpaseat** les émule par le chemin absolu |
| `open(O_DIRECTORY)` réussit sur un fichier ordinaire | parcours de répertoires faussé | ENOTDIR rétabli |
| `fcntl(F_DUPFD_CLOEXEC)` : EINVAL | `try_clone`, gestion des signaux de tokio | émulé par `F_DUPFD` + `FD_CLOEXEC` |
| le runtime Open XL C/C++ (`libc++`, `libunwind`) est un fileset installp AIX | rustc et tout programme Rust refusent de se charger | extrait à côté de la chaîne, jamais dans `/QOpenSys/usr/lib` |
| cargo est lié à l'OpenSSL d'AIX | deux instances de libcrypto, échecs TLS | table d'imports de cargo réécrite vers l'OpenSSL de yum |
| `cert.pem` parfois vide | `cargo` ne joint pas crates.io | magasin d'autorités construit depuis les certificats de yum |
| le `ld` de PASE refuse `-bdbg:namedsects:ss`, passé par rustc 1.98 et suivants | toute édition de liens échoue (`0711-151 SETOPT: Invalid option name`) | enveloppe `ld-pase` qui retire cette option |

libpaseat est liée **avant** la libc (`-l paseat` dans `RUSTFLAGS`) : l'éditeur de liens AIX lui
attribue alors ces symboles. C'est une petite bibliothèque C (`paseat/paseat.c`), compilée sur votre
machine par l'installeur.

## Prérequis

- **IBM i 7.5 ou plus récent** (POWER8 ou plus récent), avec l'environnement yum d'IBM
  (`/QOpenSys/pkgs`) et un accès Internet (AIX Toolbox, dépôts yum, crates.io).
- Un profil administrateur (yum installe quelques paquets : gcc 12, cmake, python 3.9, OpenSSL 3…).
- Le **runtime IBM Open XL C/C++ for AIX** (17.1.3 ou plus récent), à télécharger vous-même sur
  [IBM Fix Central](https://www.ibm.com/support/fixcentral/) (produit « IBM Open XL C/C++ for AIX »,
  fichier `IBM_OPEN_XL_CPP_RUNTIME_17.1.x.y_AIX.tar.Z`, gratuit avec un IBMid) et à copier dans l'IFS.
  Il n'est pas redistribué ici.

## Installer

En administrateur, en ssh (pas sous QSH : la résolution de noms exige un travail multithread) :

```
git clone https://github.com/Handedge/rust-ibmi.git && cd rust-ibmi
sh install.sh /home/MOI/IBM_OPEN_XL_CPP_RUNTIME_17.1.4.2_AIX.tar.Z
```

L'installeur affiche d'abord les conditions de licence d'IBM qui s'appliquent (le SDK est sous licence
IBM, pas sous celle de ce projet) et demande de taper `yes` ; pour une installation sans surveillance,
ajouter `--accept-license` (ou `-y`). Il télécharge ensuite les paquets du SDK depuis l'AIX Toolbox
d'IBM, les extrait **sans** passer par la base rpm d'IBM i, applique les adaptations à PASE, et finit en
compilant et en lançant un test de `remove_dir_all`.

Options :

- `-p PREFIXE` : répertoire d'installation (par défaut `/QOpenSys/opt/rust`).
- `-v VERSION` : version de Rust prise dans l'AIX Toolbox (par défaut : la plus récente, 1.96 aujourd'hui).
- `-s SDK` : installer depuis l'archive du SDK téléchargée chez IBM plutôt que depuis l'AIX Toolbox,
  par exemple `IBM_OPEN_SDK_FOR_RUST_COMMUNITY_1.98.0_AIX.tar.Z` (le site de téléchargement d'IBM a
  souvent une version plus récente que la Toolbox).
- L'argument du runtime peut aussi être un répertoire qui contient déjà `libc++.a`, `libc++abi.a` et
  `libunwind.a`.

| Installé | Chemin |
|---|---|
| chaîne de compilation | `PREFIXE/<version>`, `PREFIXE/current` |
| runtime Open XL, libpaseat | `PREFIXE/runtime` |
| libz, libatomic pour rustc et cargo | `PREFIXE/runtime-tools` |
| répertoire de cargo (registre, binaires installés) | `PREFIXE/cargo` |
| environnement | `PREFIXE/rustenv.sh` |

Pour le retirer : `rm -rf PREFIXE`.

## Utiliser

```
. /QOpenSys/opt/rust/rustenv.sh
cargo new hello && cd hello && cargo run
```

Les programmes construits trouvent `libpaseat.a` et le runtime Open XL grâce au chemin de recherche des
bibliothèques inscrit dedans (`-blibpath`) : ils tournent sans `rustenv.sh`, tant que
`PREFIXE/runtime` reste en place. En batch, les soumettre par
`SBMJOB CMD(CALL PGM(QP2SHELL) PARM('/chemin/du/programme')) ALWMLTTHD(*YES)`.

Exemples :

- [`examples/hello-web`](examples/hello-web) : webservice tokio + axum (`GET /hello`).
- [`examples/rust-db2`](examples/rust-db2) : CL → Rust → Db2 for i (CLI SQL de PASE, `libdb400.a`),
  dans le même travail que le programme CL appelant.
- [`examples/remove-dir-all.rs`](examples/remove-dir-all.rs) : le test qui échoue sans libpaseat.

Remarques :

- Les crates doivent prendre en charge AIX (`target_os = "aix"`) ; voir le tableau du README du SDK
  d'IBM (`PREFIXE/current/README`). C'est le cas de l'essentiel de l'écosystème : libc, tokio, mio,
  socket2, rustix, nix…
- Pas de LTO, 64 bits seulement (limites du SDK d'IBM).
- cargo peut afficher `warning: failed to connect to jobserver ... (os error 22)` : sans gravité sous PASE.
- Testé sur IBM i 7.5 (Power9, 2 cœurs) avec Rust 1.96 (AIX Toolbox) et Rust 1.98 (archive du SDK
  d'IBM) : installation en 1 à 4 min 30 ; `examples/hello-web` (tokio + axum, dépendances récupérées
  sur crates.io) construit en 2 min 30, et `GET /hello` répond. IBM i 7.3 et 7.4 ne sont pas pris en
  charge.

C'est aussi grâce à Rust sur IBM i que [deno-ibmi](https://github.com/Handedge/deno-ibmi) fait tourner
Deno sur IBM i.

## Avertissement

**Aucune responsabilité.** Projet personnel, non officiel et ludique, fourni « tel quel », sans garantie
d'aucune sorte, expresse ou implicite, et sans support. L'auteur décline toute responsabilité quant à
son utilisation et à tout dommage direct ou indirect. Voir la [LICENSE](LICENSE) (MIT).

**Non affilié.** Ni affilié, ni parrainé, ni approuvé par IBM, la Rust Foundation ou le projet Rust.
« Rust » et « Cargo » sont des marques de la Rust Foundation ; IBM, IBM i, AIX, Power et Db2 sont des
marques d'International Business Machines Corporation. Elles ne sont citées que pour décrire ce avec
quoi le projet fonctionne.

**Aucun logiciel IBM n'est distribué ici.** L'IBM Open SDK for Rust on AIX et le runtime IBM Open XL
C/C++ sont téléchargés chez IBM, par l'installeur ou par vous, et s'utilisent selon les conditions de
licence d'IBM : les License Information du programme et l'International License Agreement for
Non-Warranted Programs (textes dans `PREFIXE/current/` : `LicenseAgreement.pdf`, `license.pdf`,
`non_ibm_license*.htm`). L'installeur demande de les accepter avant d'installer quoi que ce soit. Ces
conditions n'autorisent pas la redistribution du SDK : c'est pourquoi ce projet fournit un installeur
et non un paquet Rust.

## Licence

MIT (voir [LICENSE](LICENSE)). Auteur : **Sylvain AKTEPE**.
