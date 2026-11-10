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
    mecha-policy.url = "github:pmarreck/mecha_policy/0f4a8b06755b7c4e10965ded38db70926c58d143";
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

        # The Rust CLI (rust/sigil-cli) built on one implementation's
        # archives. Its source is that crate and the two public headers
        # alone: no core crate exists in the build, so the only way into an
        # implementation is the C ABI. `libs` supplies lib/libsigil.a and
        # lib/libsigil_sign.a; `extraLibs` names the system libraries those
        # archives need beyond the Rust runtime.
        rustCli = name: libs: extraLibs: pkgs.rustPlatform.buildRustPackage {
          pname = "${pname}-${name}";
          inherit version;
          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              ./rust/sigil-cli
              ./include/sigil.h
              ./include/sigil_sign.h
            ];
          };
          cargoRoot = "rust/sigil-cli";
          buildAndTestSubdir = "rust/sigil-cli";
          cargoLock.lockFile = ./rust/sigil-cli/Cargo.lock;
          SIGIL_LIB_DIR = "${libs}/lib";
          SIGIL_LIB_EXTRA = extraLibs;
          nativeBuildInputs = [ pkgs.clippy ];
          preBuild = ''
            (cd rust/sigil-cli && cargo clippy --offline --all-targets -- -D warnings)
          '';
        };
      in {
        packages.default = pkgs.stdenv.mkDerivation {
          inherit pname version;
          src = zigSrc;
          nativeBuildInputs = [ zigPkg ]
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.patchelf ];
          dontConfigure = true;
          dontFixup = true;
          buildPhase = ''
            ${zigSetup}
            zig build -Doptimize=ReleaseFast --prefix $out
            ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
              # The CLI is C and therefore links libc. Zig bakes an FHS
              # dynamic-linker path (/lib/ld-musl-x86_64.so.1) into the ELF
              # that does not exist on NixOS, so the binary is unrunnable
              # until the interpreter is repointed at the stdenv's loader.
              DL="$(cat ${pkgs.stdenv.cc}/nix-support/dynamic-linker)"
              for f in "$out"/bin/*; do
                [ -f "$f" ] || continue
                patchelf --set-interpreter "$DL" "$f" 2>/dev/null || true
              done
            ''}
          '';
          dontInstall = true;
        };

        packages.sigil-zig = self.packages.${system}.default;

        # The Rust implementation, held to the Zig one by tests/differential.
        # It installs the same tree shape: the C headers and archives named
        # as Zig names them, so a consumer's link line does not depend on
        # which implementation it was given. Each archive is prelinked so it
        # exports exactly its header (scripts/prelink-staticlib): otherwise
        # every Rust archive carries its own standard library and two of them
        # cannot share a binary. Cargo's unit tests run in checkPhase.
        packages.sigil-rust = pkgs.rustPlatform.buildRustPackage {
          pname = "${pname}-rust";
          inherit version;
          # Only what the workspace reads: its crates (the CLI is built on
          # its own), the two headers it exports, the prelink script and the
          # header parser it calls, and the fixtures its tests compare
          # against. An edit elsewhere in the repository, another script
          # included, no longer rebuilds the Rust packages.
          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = pkgs.lib.fileset.unions [
              (pkgs.lib.fileset.difference ./rust ./rust/sigil-cli)
              ./include/sigil.h
              ./include/sigil_sign.h
              ./scripts/prelink-staticlib
              ./scripts/c-header-functions
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
          nativeBuildInputs = [ pkgs.clippy ];
          preBuild = ''
            (cd rust && cargo clippy --offline --workspace --all-targets -- -D warnings)
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p $out/lib $out/include
            cp include/sigil.h include/sigil_sign.h $out/include/
            cp ${mecha-policy}/include/mecha_policy.h $out/include/mecha_policy.h
            # crate archive -> installed archive, header it must export exactly
            for spec in sigil_ffi:libsigil.a:sigil.h \
                        sigil_sign_ffi:libsigil_sign.a:sigil_sign.h \
                        mecha_policy_ffi:libmecha_policy.a:mecha_policy.h; do
              IFS=: read -r crate installed header <<<"$spec"
              archive=$(find . -path "*/release/lib$crate.a" | head -1)
              [ -n "$archive" ] || { echo "no lib$crate.a was built" >&2; exit 1; }
              bash scripts/prelink-staticlib "$archive" "$out/include/$header" "$out/lib/$installed"
            done
            runHook postInstall
          '';
        };

        # The C CLI built on the Rust libraries: the same cli/main.c as the
        # default package, compiled by the stock C compiler. Its source is
        # cli/ alone and its headers and archives come only from the
        # sigil-rust package, so it can reach the Rust implementation through
        # the C ABI and no other way.
        packages.sigil-c-on-rust = pkgs.stdenv.mkDerivation {
          pname = "${pname}-c-on-rust";
          inherit version;
          src = pkgs.lib.fileset.toSource {
            root = ./.;
            fileset = ./cli;
          };
          dontConfigure = true;
          buildPhase = ''
            runHook preBuild
            rust=${self.packages.${system}.sigil-rust}
            $CC -std=c11 -Wall -Wextra -Werror -O2 -I "$rust/include" -I cli cli/main.c \
              "$rust/lib/libsigil.a" "$rust/lib/libsigil_sign.a" -lpthread -ldl -lm -o sigil
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            install -Dm755 sigil $out/bin/sigil
            runHook postInstall
          '';
        };

        # The Rust CLI on each library. Neither needs a system library beyond
        # what the Rust runtime links.
        packages.sigil-rust-cli-on-zig = rustCli "rust-cli-on-zig" self.packages.${system}.default "";
        packages.sigil-rust-cli-on-rust = rustCli "rust-cli-on-rust" self.packages.${system}.sigil-rust "";

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

          test = pkgs.stdenv.mkDerivation {
            pname = "${pname}-test";
            inherit version;
            src = ./.;
            nativeBuildInputs = [ zigPkg ]
              ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.patchelf ];
            dontConfigure = true;
            dontFixup = true;
            buildPhase = ''
              ${zigSetup}
              ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
                # Same baked-in FHS dynamic linker as the CLI, except a test
                # binary cannot be patched after the fact by the install step —
                # it has to run. Compile first, repoint, then run against the
                # cached (now runnable) artifacts.
                zig build test-compile
                DL="$(cat ${pkgs.stdenv.cc}/nix-support/dynamic-linker)"
                for f in $(find .zig-cache zig-out -type f -perm -u+x 2>/dev/null); do
                  patchelf --set-interpreter "$DL" "$f" 2>/dev/null || true
                done
              ''}
              timeout 600 zig build test || { echo "Tests failed"; exit 1; }
            '';
            installPhase = ''
              mkdir -p $out
              echo "tests passed" > $out/result
            '';
          };

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
            SIGIL_C_ON_RUST_OUT = self.packages.${system}.sigil-c-on-rust;
            SIGIL_RUST_ON_ZIG_OUT = self.packages.${system}.sigil-rust-cli-on-zig;
            SIGIL_RUST_ON_RUST_OUT = self.packages.${system}.sigil-rust-cli-on-rust;
            MECHA_POLICY_ZIG_OUT = self.packages.${system}.mecha-policy-zig;
            SIGIL_ZIG_CONSUMER_OUT = self.packages.${system}.zig-consumer-results;
            nativeBuildInputs = [ zigPkg pkgs.bash pkgs.jq pkgs.shellcheck pkgs.clang-tools pkgs.openssl pkgs.zbar pkgs.poppler-utils pkgs.qpdf pkgs.xxd pkgs.fd pkgs.cargo pbCli ]
              ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.patchelf ];
            dontConfigure = true;
            dontFixup = true;
            buildPhase = ''
              ${zigSetup}
              zig build
              zig build test-compile
              ${pkgs.lib.optionalString pkgs.stdenv.isLinux ''
                DL="$(cat ${pkgs.stdenv.cc}/nix-support/dynamic-linker)"
                for f in $(find .zig-cache zig-out -type f -perm -u+x 2>/dev/null); do
                  patchelf --set-interpreter "$DL" "$f" 2>/dev/null || true
                done
              ''}
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
