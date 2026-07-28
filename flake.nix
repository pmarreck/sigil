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
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        pname = "sigil";
        version = "0.1.0";
        # Pinned to 0.16.0 ("Juicy Main", April 2026).
        zigPkg = zig-overlay.packages.${system}."0.16.0";
      in {
        packages.default = pkgs.stdenv.mkDerivation {
          inherit pname version;
          src = ./.;
          nativeBuildInputs = [ zigPkg ]
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ pkgs.patchelf ];
          dontConfigure = true;
          dontFixup = true;
          buildPhase = ''
            export HOME=$TMPDIR
            ${pkgs.lib.optionalString pkgs.stdenv.isDarwin "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS"}
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
            nativeBuildInputs = [ zigPkg ];
            dontConfigure = true;
            dontFixup = true;
            buildPhase = ''
              export HOME=$TMPDIR
              ${pkgs.lib.optionalString pkgs.stdenv.isDarwin "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS"}
              timeout 600 zig build test || { echo "Tests failed"; exit 1; }
            '';
            installPhase = ''
              mkdir -p $out
              echo "tests passed" > $out/result
            '';
          };

          # The CLI surface, exercised through the installed binary. The CLI is
          # C on purpose (it cannot @import the Zig core), so this check is also
          # the only end-to-end proof that the C ABI actually links and works.
          test-cli = pkgs.stdenvNoCC.mkDerivation {
            pname = "${pname}-test-cli";
            inherit version;
            src = ./.;
            nativeBuildInputs = [ pkgs.bash pkgs.coreutils ];
            dontConfigure = true;
            dontFixup = true;
            buildPhase = ''
              export SIGIL_BIN=${self.packages.${system}.default}/bin/sigil
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
          ];
        };
      });
}
