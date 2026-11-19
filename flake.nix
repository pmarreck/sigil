{
  description = "sigil — verify Ed25519-signed documents whose payload stays human-scannable";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # Pin Zig explicitly via mitchellh/zig-overlay, which exposes every
    # release as a named attr. Insulates this project from upstream nixpkgs
    # jumping Zig versions unannounced.
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # The printable-binary CLI at the commit whose character map sigil's
    # envelopes use (build.zig.zon pin). Test oracle only: decodes the
    # renewal vectors' embedded envelopes (contract section 14.3).
    printable-binary.url = "github:pmarreck/printable-binary/cdefa95e4590fa016967e0e6ccb3b96c19c44c7e";
    # The Zig mecha_policy at the commit the licensing contract pins: the
    # oracle the Rust mecha-policy crate is held to by tests/differential,
    # and the source of the mecha_policy.h header both implement.
    mecha-policy.url = "github:pmarreck/mecha_policy/0ee2a70aaa517c3e1ff6ab7a6ebcbe9413c7149c";
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay, printable-binary, mecha-policy }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        pbCli = printable-binary.packages.${system}.printableBinaryZig;
        pname = "sigil";
        version = "0.1.0";
        # Pinned to 0.16.0 ("Juicy Main", April 2026).
        zigPkg = zig-overlay.packages.${system}."0.16.0";

        # Nix build sandboxes have no network, so the Zig dependency tree is
        # fetched once in a fixed-output derivation (which Nix grants network
        # access precisely because the output hash is declared up front) and
        # then copied into the cache of every real build.
        #
        # To refresh after build.zig.zon changes: set zigDepsHash to
        # pkgs.lib.fakeHash, run `nix build --rebuild` on the zig-deps
        # derivation, paste the hash it prints, and set zigDepsZonSha256 to
        # `sha256sum build.zig.zon`. Both move together or evaluation stops.
        #
        # Why the guard: Nix never refetches a fixed-output path whose hash it
        # already holds, so a stale hash keeps "working" on every machine that
        # built it before the pin moved, and fails only on a clean machine.
        # That happened: printable-binary moved to 3f697d5 while this stayed
        # at the old tree (found on a fresh Mac, 2026-10-06).
        zigDepsHash = "sha256-Li9rgNf+CIx9xHVNdMxKPr0+L7eBWS5/wcJo71f0+Y4=";
        zigDepsZonSha256 = "7dbed0212c18f8fdfe76ec94a1e578808dc4041e0f31817309c6efe61d1daa49";
        zigDepsGuard =
          let actual = builtins.hashFile "sha256" ./build.zig.zon; in
          if actual == zigDepsZonSha256 then true
          else throw "build.zig.zon changed (sha256 ${actual}) but zigDepsHash was computed for ${zigDepsZonSha256}; refresh both (see the comment above zigDepsHash)";
        # The Zig package's source is exactly what build.zig.zon declares in
        # `.paths`, read from that file, so the two cannot drift. A file the
        # build needs but the package does not declare fails here, as it would
        # for a downstream consumer fetching the package; an edit outside the
        # declared paths (docs, tests, examples, the Rust workspace) no longer
        # rebuilds the Zig package.
        zonPaths =
          let
            parts = builtins.split "\\.paths = \\.\\{" (builtins.readFile ./build.zig.zon);
            block = builtins.head (builtins.split "}" (builtins.elemAt parts 2));
            names = map builtins.head
              (builtins.filter builtins.isList (builtins.split "\"([^\"]+)\"" block));
            escapes = builtins.filter (n: builtins.match "(.*/)?\\.\\.(/.*)?|/.*" n != null) names;
          in
          if builtins.length parts != 3 then throw "build.zig.zon must contain exactly one `.paths = .{` block"
          else if names == [ ] then throw "build.zig.zon's .paths names nothing"
          else if escapes != [ ] then throw "build.zig.zon .paths must stay inside the package: ${toString escapes}"
          else names;
        zigSrc = pkgs.lib.fileset.toSource {
          root = ./.;
          fileset = pkgs.lib.fileset.unions (map (p: ./. + "/${p}") zonPaths);
        };

        zigDeps = pkgs.stdenv.mkDerivation {
          pname = "${pname}-zig-deps";
          inherit version;
          src = zigSrc;
          nativeBuildInputs = [ zigPkg pkgs.git pkgs.cacert ];
          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          outputHash = assert zigDepsGuard; zigDepsHash;
          dontConfigure = true;
          dontFixup = true;
          dontPatchShebangs = true;
          buildPhase = ''
            export HOME=$TMPDIR
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            mkdir -p $ZIG_GLOBAL_CACHE_DIR
            export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            export GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
            zig build --fetch=all
          '';
          # Zig 0.16 unpacks fetched deps into a project-local `zig-pkg/` and
          # also leaves the downloaded tarball in the global cache's `p/`.
          # Capture exactly ONE tree, `zig-pkg/` when present, else `p/`:
          # copying both put a redundant tarball in the output and made the
          # hash depend on which trees appeared (2026-10-06).
          installPhase = ''
            mkdir -p $out
            if [ -d zig-pkg ]; then cp -r zig-pkg $out/zig-pkg
            elif [ -d "$TMPDIR/zig-cache/p" ]; then cp -r "$TMPDIR/zig-cache/p" $out/p; fi
            if [ ! -d $out/zig-pkg ] && [ ! -d $out/p ]; then
              echo "zig build --fetch=all produced no package directory" >&2
              exit 1
            fi
          '';
        };

        # Prelude shared by every derivation that runs `zig build`.
        zigSetup = ''
          export HOME=$TMPDIR
          export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
          mkdir -p $ZIG_GLOBAL_CACHE_DIR
          if [ -d ${zigDeps}/p ]; then
            cp -r ${zigDeps}/p $ZIG_GLOBAL_CACHE_DIR/p
            chmod -R u+w $ZIG_GLOBAL_CACHE_DIR
          fi
          if [ -d ${zigDeps}/zig-pkg ]; then
            cp -r ${zigDeps}/zig-pkg ./zig-pkg
            chmod -R u+w ./zig-pkg
          fi
          ${pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isDarwin "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS"}
        '';

        # The Zig build for the musl target (Linux only): the shipped static
        # CLI and the musl archives the static Rust CLI on the Zig core links.
        # A derivation of its own, so a consumer that overrides
        # packages.default to build the verifier library for its own target
        # (validate_gui substitutes the default build line) never rewrites it.
        sigilZigMusl = pkgs.stdenv.mkDerivation {
          pname = "${pname}-zig-musl";
          inherit version;
          src = zigSrc;
          nativeBuildInputs = [ zigPkg ];
          dontConfigure = true;
          dontFixup = true;
          buildPhase = ''
            ${zigSetup}
            zig build -Dtarget=${pkgs.stdenv.hostPlatform.parsed.cpu.name}-linux-musl \
              -Doptimize=ReleaseFast --prefix $out
            # This derivation skips the fixup phase that would strip debug
            # information. The symbol table stays for the nm-based checks.
            strip --strip-debug $out/bin/sigil
          '';
          dontInstall = true;
        };


        # sigil's verification library alone, built for a Zig target: the
        # supported way for a product to link the verifier on its own
        # target, instead of overriding packages.default. `zig build
        # verify-lib` installs lib/libsigil.a and include/sigil.h, with no
        # signing library or CLI in the build graph. -Dcpu=baseline keeps the
        # build machine's CPU features out. For macOS targets the archive
        # gets Apple-consumable members (build.zig installStaticLib). Exposed
        # as legacyPackages.<system>.verifyLibraryFor TARGET, and built for
        # every target in verifyLibTargets by verify-lib-results, which
        # tests/integration/verify_lib.sh judges.
        verifyLibCommand = target: prefix:
          "zig build verify-lib -Dtarget=${target} -Dcpu=baseline -Doptimize=ReleaseFast --prefix ${prefix}";
        verifyLibraryFor = target: pkgs.stdenv.mkDerivation {
          pname = "${pname}-verify-${target}";
          inherit version;
          src = zigSrc;
          nativeBuildInputs = [ zigPkg ];
          dontConfigure = true;
          dontFixup = true;
          dontInstall = true;
          buildPhase = ''
            ${zigSetup}
            ${verifyLibCommand target "$out"}
          '';
        };
        # The products' targets (validate_gui: macOS arm64, Windows x86_64
        # and arm64, Linux x86_64 glibc) plus Linux musl.
        verifyLibTargets = [
          "x86_64-linux-gnu"
          "x86_64-linux-musl"
          "aarch64-macos.14.0"
          "x86_64-windows-gnu"
          "aarch64-windows-gnu"
        ];

        # nixpkgs' musl cross package set for this machine's architecture
        # (Linux only). It links dynamically against musl (crt-static off),
        # so it can build the Rust CLI-shape shared library and run cargo's
        # test binaries. Static executables use pkgsStatic instead. Both use
        # cross compilers from the cache; pkgsMusl's native rustc is not.
        muslCross = {
          x86_64 = pkgs.pkgsCross.musl64;
          aarch64 = pkgs.pkgsCross.aarch64-multiplatform-musl;
        }.${pkgs.stdenv.hostPlatform.parsed.cpu.name};

        # The Rust workspace on one Rust platform. It installs the three
        # archives and pkg-config modules in `out`, and the CLI shape as a
        # shared library in `shared`, for the Rust CLI: a Rust program
        # linking a Rust static library would carry two standard libraries.
        # Cargo's unit tests run in checkPhase. With `lint`, cargo fmt and
        # Clippy gate the build first.
        rustWorkspace = { suffix, rustPlatform, lint }: rustPlatform.buildRustPackage ({
          pname = "${pname}-${suffix}";
          inherit version;
          outputs = [ "out" "shared" ];
          # Only what the workspace reads: its crates (the CLI is built on
          # its own), the two headers it exports, and the fixtures its tests
          # compare against. An edit elsewhere in the repository does not
          # rebuild the Rust packages.
          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              (pkgs.lib.fileset.difference ./rust ./rust/sigil-cli)
              ./include/sigil.h
              ./include/sigil_sign.h
              ./examples/verify_edge_vectors
              ./examples/sign_vectors
            ];
          };
          cargoRoot = "rust";
          buildAndTestSubdir = "rust";
          cargoLock.lockFile = ./rust/Cargo.lock;
          # The pinned printable-binary alphabet, read by the Rust glyph-table
          # test so the committed table cannot drift from the Zig side's map.
          SIGIL_PB_CHARACTER_MAP = "${printable-binary}/character_map.txt";
          installPhase = ''
            runHook preInstall
            mkdir -p $out/lib $out/include
            cp include/sigil.h include/sigil_sign.h $out/include/
            cp ${mecha-policy}/include/mecha_policy.h $out/include/mecha_policy.h
            # built (crate library name) -> installed
            built() {
              local f
              f=$(find . -path "*/release/$1" | head -1)
              [ -n "$f" ] || { echo "no $1 was built" >&2; exit 1; }
              echo "$f"
            }
            for spec in sigil_verify_capi:libsigil \
                        sigil_verify_policy_capi:libsigil_verify_policy \
                        sigil_verify_sign_capi:libsigil_verify_sign; do
              IFS=: read -r crate installed <<<"$spec"
              cp "$(built "lib$crate.a")" "$out/lib/$installed.a"
            done
            mkdir -p $shared/lib
            cp "$(built libsigil_verify_sign_capi${pkgs.stdenv.hostPlatform.extensions.sharedLibrary})" \
              "$shared/lib/libsigil_verify_sign${pkgs.stdenv.hostPlatform.extensions.sharedLibrary}"
            bash ${./scripts/write-pkgconfig} rust "$out" ${version}
            runHook postInstall
          '';
        } // pkgs.lib.optionalAttrs lint {
          nativeBuildInputs = [ pkgs.clippy pkgs.rustfmt ];
          preBuild = ''
            (cd rust && cargo fmt --check)
            (cd rust && cargo clippy --offline --workspace --all-targets -- -D warnings)
          '';
        });

        # The Rust workspace on musl (Linux), sigil's one libc: its tests run
        # on musl, the static C CLI on the Rust core links its archive, and
        # the test-only Rust CLI on Rust loads its shared library.
        sigilRustMusl = rustWorkspace {
          suffix = "rust-musl";
          rustPlatform = muslCross.rustPlatform;
          lint = false;
        };

        # The Rust CLI (rust/sigil-cli) built on one implementation's
        # libraries. Its source is that crate and the two public headers
        # alone: no core crate exists in the build, so the only way into an
        # implementation is the C ABI. `libDir` holds the libraries and
        # `libs` names them as cargo link-lib specs (KIND=NAME); they must be
        # built for the same libc as `rustPlatform`. On Linux the shipped
        # pair uses pkgsStatic (static musl, no loader, no shared library);
        # static glibc is not used, because the standard library would still
        # reach getaddrinfo and getpwuid_r, which need glibc's shared
        # libraries at run time. With `lint`, cargo fmt and Clippy gate the
        # build. Release builds eliminate dead code (fat LTO, one codegen
        # unit, --gc-sections).
        rustCli = { name, libDir, libs, rustPlatform, lint }:
          rustPlatform.buildRustPackage ({
          pname = "${pname}-${name}";
          inherit version;
          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./rust/sigil-cli
              # The workspace's formatting rules, which cargo fmt finds in
              # the parent directory.
              ./rust/rustfmt.toml
              ./include/sigil.h
              ./include/sigil_sign.h
            ];
          };
          cargoRoot = "rust/sigil-cli";
          buildAndTestSubdir = "rust/sigil-cli";
          cargoLock.lockFile = ./rust/sigil-cli/Cargo.lock;
          SIGIL_LIB_DIR = libDir;
          SIGIL_LIBS = libs;
        } // pkgs.lib.optionalAttrs lint {
          nativeBuildInputs = [ pkgs.clippy pkgs.rustfmt ];
          preBuild = ''
            (cd rust/sigil-cli && cargo fmt --check)
            (cd rust/sigil-cli && cargo clippy --offline --all-targets -- -D warnings)
          '';
        });
      in {
        packages.default = pkgs.stdenv.mkDerivation {
          inherit pname version;
          src = zigSrc;
          nativeBuildInputs = [ zigPkg ];
          dontConfigure = true;
          dontFixup = true;
          buildPhase = ''
            ${zigSetup}
            zig build -Doptimize=ReleaseFast --prefix $out
            ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
              # The shipped CLI is a fully static musl executable: no
              # dynamic loader and no shared library, so the one file runs
              # on any Linux of its architecture, including a key-ceremony
              # machine (SCS 2026-11-19). It replaces the native build's
              # CLI. The archives above stay native, the flavor glibc
              # consumers link and the C harnesses test. The CLI's link
              # drops dead code (build.zig, --gc-sections).
              # tests/test_shipped_cli_self_contained holds it to no
              # interpreter, no NEEDED entry and no store path.
              install -Dm755 ${sigilZigMusl}/bin/sigil "$out/bin/sigil"
            ''}
            # The headers and the pkg-config modules a C consumer links
            # through, the same modules the Rust package installs
            # (scripts/write-pkgconfig). The policy module names the pinned
            # mecha_policy, whose archive needs libquadmath from a stock x86_64
            # Linux toolchain (a known mecha_policy defect, PLAN). Other
            # platforms are untested.
            mkdir -p $out/include
            cp include/sigil.h include/sigil_sign.h $out/include/
            bash ${./scripts/write-pkgconfig} zig "$out" ${version} ${self.packages.${system}.mecha-policy-zig} \
              ${pkgs.lib.optionalString (pkgs.stdenv.isLinux && pkgs.stdenv.hostPlatform.isx86_64) "-lquadmath"}
          '';
          dontInstall = true;
        };

        packages.sigil-zig = self.packages.${system}.default;

        # The Rust implementation, held to the Zig one by tests/differential.
        # It installs the same headers as the Zig package, but follows Rust's
        # rule of one Rust static library per program: every Rust staticlib
        # bundles its own standard library, so two in one link conflict. So
        # there is one archive per program shape, each built by a thin crate
        # (rust/sigil-*-capi): libsigil.a (verify), libsigil_verify_policy.a
        # (a licensed application) and libsigil_verify_sign.a (the CLI).
        # Both packages install the same pkg-config modules
        # (scripts/write-pkgconfig), so a consumer's link line does not depend
        # on which implementation it was given (rustWorkspace above).
        # This native build is the glibc flavor that the C harnesses link
        # (whether it stays, beside the musl one, awaits SCS; PLAN). It also
        # runs the workspace's formatting and Clippy gates.
        packages.sigil-rust = rustWorkspace {
          suffix = "rust";
          rustPlatform = pkgs.rustPlatform;
          lint = true;
        };

        # The C CLI built on the Rust libraries: the same cli/main.c as the
        # default package, compiled by the stock C compiler. Its source is
        # cli/ alone and its headers and archives come only from the
        # sigil-rust package, so it can reach the Rust implementation through
        # the C ABI and no other way.
        packages.sigil-c-on-rust = (if pkgs.stdenv.isLinux then pkgs.pkgsStatic.stdenv else pkgs.stdenv).mkDerivation {
          pname = "${pname}-c-on-rust";
          inherit version;
          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = ./cli;
          };
          dontConfigure = true;
          # The link line is the package's sigil-verify-sign pkg-config
          # module, as for any C consumer. On Linux the result is a fully
          # static executable: nixpkgs' static musl toolchain, linking the
          # musl build of the Rust archive (sigilRustMusl). No loader, no
          # shared library. Function and data sections plus --gc-sections
          # drop every function the CLI cannot reach, the Rust archive's
          # included.
          nativeBuildInputs = [ pkgs.pkg-config ];
          buildPhase = ''
            runHook preBuild
            export PKG_CONFIG_PATH=${if pkgs.stdenv.isLinux then sigilRustMusl else self.packages.${system}.sigil-rust}/lib/pkgconfig
            read -r -a flags <<<"$(pkg-config --cflags --libs sigil-verify-sign)"
            $CC -std=c11 -Wall -Wextra -Werror -O2 -ffunction-sections -fdata-sections \
              ${pkgs.lib.optionalString pkgs.stdenv.isLinux "-static"} -Wl,--gc-sections \
              -I cli cli/main.c "''${flags[@]}" -o sigil
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            install -Dm755 sigil $out/bin/sigil
            runHook postInstall
          '';
        };

        # The Rust CLI on each library: the two Zig archives, which combine
        # freely (the shipped `zig` pair, a fully static executable on
        # Linux), or the Rust CLI shape as a shared library, which keeps its
        # own standard library inside (a Rust program cannot also link a
        # Rust static library; this pair is test-only and links that library
        # dynamically, against musl on Linux).
        packages.sigil-rust-cli-on-zig = rustCli {
          name = "rust-cli-on-zig";
          libDir = if pkgs.stdenv.isLinux then "${sigilZigMusl}/lib"
            else "${self.packages.${system}.default}/lib";
          libs = "static=sigil_sign static=sigil";
          rustPlatform = if pkgs.stdenv.isLinux then pkgs.pkgsStatic.rustPlatform else pkgs.rustPlatform;
          lint = false;
        };
        packages.sigil-rust-cli-on-rust = rustCli {
          name = "rust-cli-on-rust";
          libDir = if pkgs.stdenv.isLinux then "${sigilRustMusl.shared}/lib"
            else "${self.packages.${system}.sigil-rust.shared}/lib";
          libs = "dylib=sigil_verify_sign";
          rustPlatform = if pkgs.stdenv.isLinux then muslCross.rustPlatform else pkgs.rustPlatform;
          # The crate's formatting and Clippy gates run here.
          lint = true;
        };

        # The pinned Zig mecha_policy as a product tree (archive and header),
        # for the policy differential. Its own package installs only the
        # archive; the header comes from the same pinned source.
        packages.mecha-policy-zig = pkgs.runCommandLocal "mecha-policy-zig" { } ''
          mkdir -p $out/lib $out/include
          ln -s ${mecha-policy.packages.${system}.default}/lib/libmecha_policy.a $out/lib/libmecha_policy.a
          ln -s ${mecha-policy}/include/mecha_policy.h $out/include/mecha_policy.h
        '';

        # The downstream Zig consumer (tests/zig_consumer) compiled once here,
        # so its cross-target builds rerun only when the Zig package or the
        # consumer changes, not on every ./test. Its source is the Zig
        # package's declared paths, the consumer, and the conformance program
        # the consumer links. Each step's exit status and log are recorded as
        # data instead of failing this build, so
        # tests/integration/zig_consumer.sh reports every target on its own;
        # the conformance program is installed for that suite to run and
        # inspect. The steps run concurrently.
        # The Zig unit tests, run once per change to the Zig package's own
        # sources (build.zig.zon `.paths`) rather than on every ./test, and
        # inside the sandbox rather than in the dev shell. The run's exit
        # status and log are recorded as data instead of failing this build,
        # so ./test reports them as its "Zig Unit Tests" suite, failure
        # included. On Linux they run on musl, sigil's one libc, as static
        # executables.
        packages.zig-unit-test-results = pkgs.stdenv.mkDerivation {
          pname = "${pname}-zig-unit-test-results";
          inherit version;
          src = zigSrc;
          nativeBuildInputs = [ zigPkg ];
          dontConfigure = true;
          dontFixup = true;
          dontInstall = true;
          buildPhase = ''
            ${zigSetup}
            mkdir -p $out
            # On Linux the tests run on musl, sigil's one libc (SCS
            # 2026-11-19), as static executables like the shipped CLI.
            run_tests() {
              timeout 600 zig build test --summary all \
                ${pkgs.lib.optionalString pkgs.stdenv.isLinux "-Dtarget=${pkgs.stdenv.hostPlatform.parsed.cpu.name}-linux-musl"}
            }
            if run_tests >"$out/log" 2>&1; then
              echo 0 >"$out/rc"
            else
              echo $? >"$out/rc"
            fi
          '';
        };

        # The two macOS cross-builds that tests/integration/macos_archive.sh
        # inspects, run once per change to the Zig package's own sources
        # instead of in the working tree on every ./test. Each target's exit
        # status, log and installed tree are recorded as data instead of
        # failing this build, so the suite reports each target on its own.
        packages.macos-archive-results = pkgs.stdenv.mkDerivation {
          pname = "${pname}-macos-archive-results";
          inherit version;
          src = zigSrc;
          nativeBuildInputs = [ zigPkg ];
          dontConfigure = true;
          dontFixup = true;
          dontInstall = true;
          buildPhase = ''
            ${zigSetup}
            mkdir -p $out
            # target T: one cross-build into $out/T, with its own cache.
            target() {
              if zig build -Dtarget="$1" --prefix "$out/$1" --cache-dir "$TMPDIR/cache-$1" \
                  >"$out/$1.log" 2>&1; then
                echo 0 >"$out/$1.rc"
              else
                echo $? >"$out/$1.rc"
              fi
            }
            target aarch64-macos &
            a=$!
            target x86_64-macos &
            b=$!
            wait "$a"; wait "$b"
          '';
        };

        # verifyLibraryFor's build for every target in verifyLibTargets, run
        # concurrently and recorded as data ($out/T.rc, T.log, T/), with the
        # target list in $out/targets, so tests/integration/verify_lib.sh
        # reports each target on its own. The command is verifyLibraryFor's.
        packages.verify-lib-results = pkgs.stdenv.mkDerivation {
          pname = "${pname}-verify-lib-results";
          inherit version;
          src = zigSrc;
          nativeBuildInputs = [ zigPkg ];
          dontConfigure = true;
          dontFixup = true;
          dontInstall = true;
          buildPhase = ''
            ${zigSetup}
            mkdir -p $out
            target() {
              if ${verifyLibCommand "$1" "\"$out/$1\""} --cache-dir "$TMPDIR/cache-$1" \
                  >"$out/$1.log" 2>&1; then
                echo 0 >"$out/$1.rc"
              else
                echo $? >"$out/$1.rc"
              fi
            }
            pids=()
            for t in ${pkgs.lib.escapeShellArgs verifyLibTargets}; do
              echo "$t" >>"$out/targets"
              target "$t" &
              pids+=("$!")
            done
            for p in "''${pids[@]}"; do wait "$p"; done
          '';
        };

        # The library for any Zig target (see verifyLibraryFor above).
        legacyPackages.verifyLibraryFor = verifyLibraryFor;

        packages.zig-consumer-results = pkgs.stdenv.mkDerivation {
          pname = "${pname}-zig-consumer-results";
          inherit version;
          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions ((map (p: ./. + "/${p}") zonPaths) ++ [
              ./tests/zig_consumer
              ./tests/conformance/verify_conformance.c
            ]);
          };
          nativeBuildInputs = [ zigPkg ]
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.patchelf ];
          dontConfigure = true;
          dontFixup = true;
          dontInstall = true;
          buildPhase = ''
            ${zigSetup}
            root=$PWD
            pkg=()
            [ -d "$root/zig-pkg" ] && pkg=(--system "$root/zig-pkg")
            mkdir -p $out/steps
            # step NAME ARGS...: one zig build of the consumer, its own cache.
            step() {
              local name=$1; shift
              if (cd "$root/tests/zig_consumer" && zig build "''${pkg[@]}" \
                  --cache-dir "$TMPDIR/cache-$name" "$@") >"$out/steps/$name.log" 2>&1; then
                echo 0 >"$out/steps/$name.rc"
              else
                echo $? >"$out/steps/$name.rc"
              fi
            }
            pids=()
            while IFS= read -r t; do
              [ -n "$t" ] || continue
              step "resolve-$t" resolve "-Dtarget=$t" &
              pids+=($!)
            done < "$root/tests/zig_consumer/targets"
            step install install --prefix "$out" &
            pids+=($!)
            for p in "''${pids[@]}"; do wait "$p"; done
            ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
              # Zig writes an FHS loader path; repoint it at the stdenv loader
              # so the suite can run the program on NixOS.
              exe=$out/bin/verify_conformance
              if [ -f "$exe" ]; then
                patchelf --set-interpreter "$(cat ${pkgs.stdenv.cc}/nix-support/dynamic-linker)" "$exe"
              fi
            ''}
          '';
        };

        # NOTE: don't key on ${system} here — flake-utils.eachDefaultSystem
        # already wraps the returned attrs in ${system}. Writing
        # `checks.${system} = ...` produces checks.<sys>.<sys>, which CI
        # silently skips.
        checks = {
          build = self.packages.${system}.default;

          # The Zig unit tests, judged from the recorded run (see
          # zig-unit-test-results) so flake check fails on a failing test
          # without running the tests a second time.
          test = pkgs.runCommandLocal "${pname}-test-${version}" { } ''
            r=${self.packages.${system}.zig-unit-test-results}
            cat "$r/log"
            [ "$(cat "$r/rc")" = 0 ] || { echo "Zig unit tests failed (exit $(cat "$r/rc"))"; exit 1; }
            mkdir -p $out
            echo "tests passed" > $out/result
          '';

          # The architecture invariant that keeps "a product cannot sign" true:
          # nm reads the shipped artifact rather than our intentions about it.
          # Linux-only — the assertion is about symbol tables, and the parsing
          # here assumes ELF naming.
          test-symbols = pkgs.stdenvNoCC.mkDerivation {
            pname = "${pname}-test-symbols";
            inherit version;
            src = ./.;
            nativeBuildInputs = [ pkgs.bash pkgs.binutils pkgs.gawk pkgs.gnugrep ];
            dontConfigure = true;
            dontFixup = true;
            buildPhase = ''
              export SIGIL_LIBDIR=${self.packages.${system}.default}/lib
              export SIGIL_FIXTUREDIR=${self.packages.${system}.default}/test-fixtures
              bash ./tests/test_no_signing_symbols
            '';
            installPhase = ''
              mkdir -p $out
              echo "symbol separation holds" > $out/result
            '';
          };

          # The CLI surface, exercised through the installed binary. The CLI is
          # C on purpose (it cannot @import the Zig core), so this check is also
          # the only end-to-end proof that the C ABI actually links and works.
          # THE CI gate: run ./test — the same entry point a human runs — not a
          # hand-picked subset of it. The subset approach failed twice in two
          # days: the transcript change broke the conformance suite while CI
          # stayed green (that suite wasn't a check), and the "fix" promoted
          # only the suite that had already bitten, leaving Harness Guards and
          # Lint still unwired. Peter's phrasing, 2026-08-13: "Isn't the whole
          # point of CI, TO RUN THE TESTS?" If ./test gains a suite tomorrow,
          # CI runs it with no flake edit; the two can no longer drift.
          test-all = pkgs.stdenv.mkDerivation {
            pname = "${pname}-test-all";
            inherit version;
            src = ./.;
            # The Rust implementation is handed to the suite by path, already
            # built: a sandboxed check cannot run a nested nix build.
            SIGIL_RUST_OUT = self.packages.${system}.sigil-rust;
            # The shipped Zig package, for its pkg-config modules.
            SIGIL_ZIG_PACKAGE_OUT = self.packages.${system}.default;
            SIGIL_C_ON_RUST_OUT = self.packages.${system}.sigil-c-on-rust;
            SIGIL_RUST_ON_ZIG_OUT = self.packages.${system}.sigil-rust-cli-on-zig;
            SIGIL_RUST_ON_RUST_OUT = self.packages.${system}.sigil-rust-cli-on-rust;
            MECHA_POLICY_ZIG_OUT = self.packages.${system}.mecha-policy-zig;
            SIGIL_ZIG_CONSUMER_OUT = self.packages.${system}.zig-consumer-results;
            SIGIL_ZIG_UNIT_TESTS_OUT = self.packages.${system}.zig-unit-test-results;
            SIGIL_MACOS_ARCHIVE_OUT = self.packages.${system}.macos-archive-results;
            SIGIL_VERIFY_LIB_OUT = self.packages.${system}.verify-lib-results;
            nativeBuildInputs = [ zigPkg pkgs.bash pkgs.jq pkgs.shellcheck pkgs.clang-tools pkgs.openssl pkgs.zbar pkgs.poppler-utils pkgs.qpdf pkgs.xxd pkgs.fd pkgs.cargo pkgs.pkg-config pbCli ]
              # lld: the differential suites link the archives with GNU ld and lld.
              ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.lld ];
            dontConfigure = true;
            dontFixup = true;
            buildPhase = ''
              ${zigSetup}
              # The suites run against the shipped artifacts, linked into
              # zig-out exactly as ./build links them, not against a second
              # build made here. (The Zig unit tests are reported from
              # zig-unit-test-results, so nothing here compiles them.)
              d=${self.packages.${system}.default}
              mkdir -p zig-out/bin zig-out/lib zig-out/test-fixtures
              ln -s "$d/bin/sigil" zig-out/bin/sigil
              ln -s "$d/lib/libsigil.a" "$d/lib/libsigil_sign.a" zig-out/lib/
              ln -s "$d/test-fixtures/libsigil_module_probe.a" zig-out/test-fixtures/
              # Four frontend and library pairs each run the CLI and integration
              # suites, so the whole run is several minutes; the limit only
              # catches a hang.
              SIGIL_SKIP_BUILD=1 timeout 1800 bash ./test
            '';
            installPhase = ''
              mkdir -p $out
              echo "./test passed" > $out/result
            '';
          };

          # The customer link path: stock gcc, never zig cc, linking libsigil.a
          # exactly the way an embedder (Validate's GUI, RotShield) will. Kept
          # as a named check for local debugging granularity; CI runs test-all,
          # which includes this suite via ./test.
          test-conformance = pkgs.stdenv.mkDerivation {
            pname = "${pname}-test-conformance";
            inherit version;
            src = ./.;
            nativeBuildInputs = [ zigPkg pkgs.bash ];
            dontConfigure = true;
            dontFixup = true;
            buildPhase = ''
              ${zigSetup}
              zig build
              bash ./tests/test_c_conformance
            '';
            installPhase = ''
              mkdir -p $out
              echo "conformance tests passed" > $out/result
            '';
          };

          test-cli = pkgs.stdenvNoCC.mkDerivation {
            pname = "${pname}-test-cli";
            inherit version;
            src = ./.;
            # The CLI suite's independent oracles (openssl, poppler, zbar, qpdf,
            # xxd) must be here too, or this granular check fails on its own.
            nativeBuildInputs = with pkgs; [
              bash coreutils gnugrep gnused diffutils jq
              openssl zbar poppler-utils qpdf xxd
            ];
            dontConfigure = true;
            dontFixup = true;
            buildPhase = ''
              export SIGIL_BIN=${self.packages.${system}.default}/bin/sigil
              export TMPDIR=''${TMPDIR:-/tmp}
              bash ./tests/cli/test_cli
            '';
            installPhase = ''
              mkdir -p $out
              echo "cli tests passed" > $out/result
            '';
          };
        };

        devShells.default = pkgs.mkShell {
          SIGIL_PB_CHARACTER_MAP = "${printable-binary}/character_map.txt";
          nativeBuildInputs = [
            zigPkg
            # Rust toolchain for the port under rust/, from the pinned nixpkgs.
            pkgs.cargo
            pkgs.rustc
            pkgs.clippy
            pkgs.rustfmt
            pkgs.hyperfine
            pkgs.jq
            # The differential suites link the archives with GNU ld and lld,
            # products through each package's pkg-config modules.
            pkgs.lld
            pkgs.pkg-config
            # Linters for the masked-return-value class (tests/test_lint).
            # Zig rejects unused return values at compile time; C and Bash
            # make the same check opt-in, so these are that opt-in. The gate
            # FAILS rather than skips when they are absent — a control that
            # vanishes with its tool is indistinguishable from a clean repo.
            pkgs.shellcheck
            pkgs.clang-tools # clang-tidy: cert-err33-c
            # Independent oracle for the hot-bundle PKCS#8 in tests/cli/test_cli.
            pkgs.openssl
            # Independent oracles for the paper (QR-in-PDF) cold copies:
            # poppler rasterizes and extracts text, zbar decodes the QR.
            pkgs.zbar
            pkgs.poppler-utils
            pkgs.qpdf
            # xxd -r -p is the macOS decode command the paper page prints.
            pkgs.xxd
            pbCli
          ];
        };
      });
}
