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
    printable-binary.url = "github:pmarreck/printable-binary/3f697d53f447144e9ba1b73c4217b382f32b4d62";
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay, printable-binary }:
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
        zigDepsHash = "sha256-bazuso8k9Sq8pNtPadUPYIe98ol13ZF/qfe7h476wF0=";
        zigDepsZonSha256 = "103a633ba09facda1f19b4d6c6e176d6f60a5026aa651f6064cea66a013facd4";
        zigDepsGuard =
          let actual = builtins.hashFile "sha256" ./build.zig.zon; in
          if actual == zigDepsZonSha256 then true
          else throw "build.zig.zon changed (sha256 ${actual}) but zigDepsHash was computed for ${zigDepsZonSha256}; refresh both (see the comment above zigDepsHash)";
        zigDeps = pkgs.stdenv.mkDerivation {
          pname = "${pname}-zig-deps";
          inherit version;
          src = ./.;
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
      in {
        packages.default = pkgs.stdenv.mkDerivation {
          inherit pname version;
          src = ./.;
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
            nativeBuildInputs = [ zigPkg pkgs.bash pkgs.jq pkgs.shellcheck pkgs.clang-tools pkgs.openssl pkgs.zbar pkgs.poppler-utils pkgs.qpdf pkgs.xxd pbCli ]
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
              SIGIL_SKIP_BUILD=1 timeout 900 bash ./test
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
          nativeBuildInputs = [
            zigPkg
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
