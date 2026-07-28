{
  description = "PrintableBinary C implementation development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        zig = zig-overlay.packages.${system}."0.16.0";

        cosmoccVersion = "4.0.2";
        cosmoccHash = "sha256-6KZv7KU2rJhwfc9k6z9I6ZdfIS1KqRFLZUo8YyuD7ZY=";
        cosmoccSrc = pkgs.fetchzip {
          url = "https://cosmo.zip/pub/cosmocc/cosmocc-${cosmoccVersion}.zip";
          hash = cosmoccHash;
          stripRoot = false;
        };
        cosmoccBin = pkgs.stdenvNoCC.mkDerivation {
          pname = "cosmocc-bin";
          version = cosmoccVersion;
          src = cosmoccSrc;
          phases = [ "installPhase" ];
          installPhase = ''
            mkdir -p $out
            cp -r $src/* $out/
          '';
        };

        emscriptenFlags = "-O3 -DNDEBUG "
          + "-s STANDALONE_WASM=1 "
          + "-s FILESYSTEM=1 "
          + "-s INITIAL_MEMORY=134217728 "
          + "-DPRINTABLE_BINARY_HELP_NAME=\\\"printable-binary\\\"";

        printableBinaryNative = pkgs.stdenv.mkDerivation {
          pname = "printable-binary-c";
          version = "1.0.0";

          src = ./.;

          nativeBuildInputs = [ pkgs.clang ];

          buildPhase = ''
            clang -O3 -Wall -Wextra -I. -o printable-binary-c src/printable_binary.c
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp printable-binary-c $out/bin/
            cp character_map.txt $out/bin/character_map.txt
          '';

          meta = with pkgs.lib; {
            description = "High-performance C implementation of PrintableBinary";
            license = licenses.mit;
            platforms = platforms.unix;
          };
        };

        printableBinaryWasm = pkgs.stdenv.mkDerivation {
          pname = "printable-binary-wasm";
          version = "1.0.0";

          src = ./.;

          nativeBuildInputs = [ pkgs.emscripten ];

          buildPhase = ''
            export EM_CACHE="$TMPDIR/emscripten_cache"
            mkdir -p "$EM_CACHE"
            emcc -I. src/printable_binary.c ${emscriptenFlags} -o printable-binary.wasm
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp printable-binary.wasm $out/bin/printable-binary.wasm
            cp character_map.txt $out/bin/character_map.txt
          '';

          meta = with pkgs.lib; {
            description = "PrintableBinary compiled to WebAssembly via Emscripten";
            license = licenses.mit;
            platforms = platforms.all;
          };
        };

        # APE build - only works reliably on Linux in pure nix builds
        # On darwin, cosmocc's APE loader needs system tools; use `nix develop` + make ape
        printableBinaryApe = pkgs.stdenvNoCC.mkDerivation {
          pname = "printable-binary-ape";
          version = "1.0.0";

          src = ./.;

          nativeBuildInputs = [
            cosmoccBin
          ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
            pkgs.coreutils
          ];

          buildPhase = ''
            export PATH=${cosmoccBin}/bin:$PATH
            export HOME=$TMPDIR
            # Clear any inherited include paths that might conflict
            unset C_INCLUDE_PATH CPATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH
            cosmocc -O3 -DNDEBUG -I. -o printable-binary-ape.com src/printable_binary.c
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp printable-binary-ape.com $out/bin/printable-binary-ape.com
            cp character_map.txt $out/bin/character_map.txt
          '';

          meta = with pkgs.lib; {
            description = "PrintableBinary built as an Actually Portable Executable (Cosmopolitan, pinned ${cosmoccVersion})";
            license = licenses.mit;
            # APE pure nix build only works reliably on Linux; on darwin use nix develop + make ape
            platforms = platforms.linux;
          };
        };

        # Zig implementation
        printableBinaryZig = pkgs.stdenv.mkDerivation {
          pname = "printable-binary";
          version = "1.0.0";

          src = ./.;

          nativeBuildInputs = [ zig ];

          buildPhase = ''
            export HOME=$TMPDIR
            zig build -Doptimize=ReleaseFast
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp zig-out/bin/printable-binary $out/bin/
            cp character_map.txt $out/bin/character_map.txt
          '';

          meta = with pkgs.lib; {
            description = "PrintableBinary Zig implementation";
            license = licenses.mit;
            platforms = platforms.unix;
          };
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs =
            let
              linuxOnly = with pkgs; lib.optionals (!stdenv.isDarwin) [ valgrind perf-tools ];
            in
            with pkgs; [
              # C compilation/tools
              gcc
              clang

              # Build systems
              gnumake
              cmake
              ninja

              # Performance and profiling tools
              hyperfine
              time

              # Cross-compilation targets (optional)
              pkgsCross.mingwW64.buildPackages.gcc

              # Actually Portable Executable (cosmopolitan, pinned)
              cosmoccBin

              # Development utilities
              xxd
              hexdump
              file

              # Benchmarking and testing
              luajit
              wazero

              # Zig compiler
              zig

              # LLVM tools (for PGO profdata merge, IR analysis)
              llvmPackages.llvm

              # JavaScript/TypeScript runtime for web implementation
              deno
              nodejs_24

              # WebAssembly toolchain
              emscripten

              # Rust toolchain (native Rust GUI<->core transport implementation)
              cargo
              rustc
              clippy
              rustfmt

              # Elixir/Erlang (the ~PB compile-time sigil demo)
              elixir
            ]  ++ lib.optionals stdenv.isDarwin [ lldb ]
               ++ lib.optionals (!stdenv.isDarwin) [ gdb ]
               ++ linuxOnly;

          shellHook = ''
            echo "PrintableBinary Development Environment"
            echo "========================================"
            echo "Available compilers:"
            echo "  gcc: $(gcc --version | head -n1)"
            echo "  clang: $(clang --version | head -n1)"
            echo ""
            echo "Available tools:"
            echo "  make, cmake, ninja"
            echo "  gdb, valgrind"
            echo "  hyperfine (for benchmarking)"
            echo "  deno (for JavaScript/web implementation)"
            echo "  node (for CLI/automation tests)"
            echo "  emcc (Emscripten) for WebAssembly builds"
            echo "  cosmocc ${cosmoccVersion} (pinned) for APE builds (fat x86_64 + arm64)"
            echo "  wazero (WASI runtime for testing)"
            echo ""
            echo "Example build commands:"
            echo "  gcc -O3 -o printable-binary-c src/printable_binary.c"
            echo "  clang -O3 -march=native -o printable-binary-c src/printable_binary.c"
            echo "  emcc src/printable_binary.c ${emscriptenFlags} -o printable-binary.wasm"
            echo "  cosmocc -O3 -o printable-binary-ape.com src/printable_binary.c   # fat APE"
            echo "  make -B wasm                                                 # uses emcc"
            echo "  CONFIRM_BIG_DEP_DOWNLOAD=1 make -B ape                       # uses pinned cosmocc"
            echo "  nix build .#printableBinaryApe    # fat APE (pinned cosmocc ${cosmoccVersion})"
            echo "  nix build .#printableBinaryWasm   # wasm"
            echo "  nix build .#default               # suite (native+wasm+ape)"
            echo ""
            echo "Test JavaScript implementation:"
            echo "  deno run --allow-read --allow-env test/js/test_printable_binary.js"
            echo ""
            echo "Serve web interface (requires simple http server):"
            echo "  python3 -m http.server 8000"
            echo "  # Then open http://localhost:8000 in your browser"
            echo ""
            echo "Cross-compilation example:"
            echo "  x86_64-w64-mingw32-gcc -O3 -o printable-binary.exe src/printable_binary.c"
            echo ""
          '';

          CC = "gcc";
          CXX = "g++";
        };

        packages = {
          printableBinaryNative = printableBinaryNative;
          printableBinaryWasm = printableBinaryWasm;
          printableBinaryApe = printableBinaryApe;
          printableBinaryZig = printableBinaryZig;
          default = pkgs.symlinkJoin {
            name = "printable-binary-suite";
            paths = [ printableBinaryNative printableBinaryWasm printableBinaryZig ]
              ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ printableBinaryApe ];
          };
        };

        checks = {
          # Documentation and benchmark inventory stay in sync with the supported
          # implementations and the 256-row source-byte mapping reference.
          test-docs-benchmark-contract = pkgs.stdenvNoCC.mkDerivation {
            name = "test-docs-benchmark-contract";
            src = ./.;
            nativeBuildInputs = with pkgs; [ bash gawk gnugrep ];
            buildPhase = ''
              export HOME=$TMPDIR
              bash ./test/test_docs_benchmark_contract
            '';
            installPhase = "mkdir -p $out && touch $out/passed";
          };

          test-c = pkgs.stdenv.mkDerivation {
            name = "test-c";
            src = ./.;
            nativeBuildInputs = with pkgs; [ clang python3 xxd hexdump ];
            buildPhase = ''
              clang -O3 -Wall -Wextra -I. -o printable-binary-c src/printable_binary.c
              IMPLEMENTATION_TO_TEST=./printable-binary-c bash ./test/test
            '';
            installPhase = "mkdir -p $out && touch $out/passed";
          };

          test-zig-unit = pkgs.stdenv.mkDerivation {
            name = "test-zig-unit";
            src = ./.;
            nativeBuildInputs = [ zig ];
            buildPhase = ''
              export HOME=$TMPDIR
              zig build test
            '';
            installPhase = "mkdir -p $out && touch $out/passed";
          };

          test-zig = pkgs.stdenv.mkDerivation {
            name = "test-zig";
            src = ./.;
            nativeBuildInputs = with pkgs; [ zig python3 xxd hexdump ];
            buildPhase = ''
              export HOME=$TMPDIR
              zig build -Doptimize=ReleaseFast
              IMPLEMENTATION_TO_TEST=./zig-out/bin/printable-binary bash ./test/test
            '';
            installPhase = "mkdir -p $out && touch $out/passed";
          };

          # The installed command name is a compatibility contract: Zig is the
          # default CLI, while the source-distributed LuaJIT implementation
          # remains explicitly selectable for comparison and fallback.
          test-cli-layout = pkgs.stdenvNoCC.mkDerivation {
            name = "test-cli-layout";
            src = ./.;
            nativeBuildInputs = with pkgs; [ zig luajit ];
            buildPhase = ''
              export HOME=$TMPDIR
              patchShebangs bin/printable-binary-luajit
              zig build -Doptimize=ReleaseFast
              test -x ${printableBinaryZig}/bin/printable-binary
              test ! -e ${printableBinaryZig}/bin/printable-binary-zig
              bash ./test/test_cli_layout \
                ./zig-out/bin/printable-binary \
                ./bin/printable-binary-luajit
            '';
            installPhase = "mkdir -p $out && touch $out/passed";
          };

          test-build-all = pkgs.stdenvNoCC.mkDerivation {
            name = "test-build-all";
            src = ./.;
            nativeBuildInputs = with pkgs; [ bash ];
            buildPhase = ''
              bash ./test/test_build_all
              test -x ${printableBinaryApe}/bin/printable-binary-ape.com
            '';
            installPhase = "mkdir -p $out && touch $out/passed";
          };

          test-js = pkgs.stdenv.mkDerivation {
            name = "test-js";
            src = ./.;
            nativeBuildInputs = with pkgs; [ nodejs_24 python3 xxd hexdump ];
            buildPhase = ''
              export HOME=$TMPDIR
              patchShebangs bin/printable-binary-node.js
              IMPLEMENTATION_TO_TEST=./bin/printable-binary-node.js bash ./test/test
              bash ./test/test_node_cli_stats
            '';
            installPhase = "mkdir -p $out && touch $out/passed";
          };

          # The retained LuaJIT CLI has an explicit name but remains a supported
          # full implementation, including the common stderr throughput contract.
          test-lua = pkgs.stdenv.mkDerivation {
            name = "test-lua";
            src = ./.;
            nativeBuildInputs = with pkgs; [ luajit python3 xxd hexdump ];
            buildPhase = ''
              export HOME=$TMPDIR
              patchShebangs bin/printable-binary-luajit
              IMPLEMENTATION_TO_TEST=./bin/printable-binary-luajit bash ./test/test
            '';
            installPhase = "mkdir -p $out && touch $out/passed";
          };

          # JS library unit tests (container codec + crc32 vector-pinning, issue #1).
          # Previously orphaned (test-js runs only the cross-impl CLI suite); wired
          # in so the printable-binary-file.json container is MFIC-guarded in CI.
          test-js-unit = pkgs.stdenv.mkDerivation {
            name = "test-js-unit";
            src = ./.;
            nativeBuildInputs = with pkgs; [ nodejs_24 ];
            buildPhase = ''
              export HOME=$TMPDIR
              node test/js/test_printable_binary.js
            '';
            installPhase = "mkdir -p $out && touch $out/passed";
          };

          # Container (.pbf.json) CLI round-trip + self-verify, issue #1. Parameterized
          # by IMPLEMENTATION_TO_TEST; one check per impl as they gain -C/--container.
          test-container-node = pkgs.stdenv.mkDerivation {
            name = "test-container-node";
            src = ./.;
            nativeBuildInputs = with pkgs; [ nodejs_24 ];
            buildPhase = ''
              export HOME=$TMPDIR
              patchShebangs bin/printable-binary-node.js
              IMPLEMENTATION_TO_TEST=./bin/printable-binary-node.js bash ./test/test_container
            '';
            installPhase = "mkdir -p $out && touch $out/passed";
          };

          # Container (.pbf.json) for the Zig CLI (issue #1).
          test-container-zig = pkgs.stdenv.mkDerivation {
            name = "test-container-zig";
            src = ./.;
            nativeBuildInputs = with pkgs; [ zig ];
            buildPhase = ''
              export HOME=$TMPDIR
              zig build -Doptimize=ReleaseFast
              IMPLEMENTATION_TO_TEST=./zig-out/bin/printable-binary bash ./test/test_container
            '';
            installPhase = "mkdir -p $out && touch $out/passed";
          };

          # Cross-impl container differential: Node <-> Zig must agree (issue #1).
          test-container-cross = pkgs.stdenv.mkDerivation {
            name = "test-container-cross";
            src = ./.;
            nativeBuildInputs = with pkgs; [ zig clang nodejs_24 luajit ];
            buildPhase = ''
              export HOME=$TMPDIR
              patchShebangs bin/printable-binary-node.js bin/printable-binary-luajit
              zig build
              clang -O2 -I. -o pb-ffi src/printable_binary_ffi_main.c zig-out/lib/libprintable_binary.a
              clang -O3 -Wall -Wextra -I. -o printable-binary-c src/printable_binary.c
              for impl in ./zig-out/bin/printable-binary ./pb-ffi ./printable-binary-c ./bin/printable-binary-luajit; do
                IMPL_A=./bin/printable-binary-node.js IMPL_B="$impl" bash ./test/test_container_cross || exit 1
              done
            '';

            installPhase = "mkdir -p $out && touch $out/passed";
          };

          # Container (.pbf.json) for the C FFI CLI — dogfoods the FFI (pb_crc32 etc).
          test-container-ffi = pkgs.stdenv.mkDerivation {
            name = "test-container-ffi";
            src = ./.;
            nativeBuildInputs = with pkgs; [ zig clang ];
            buildPhase = ''
              export HOME=$TMPDIR
              zig build
              clang -O2 -I. -o pb-ffi src/printable_binary_ffi_main.c zig-out/lib/libprintable_binary.a
              IMPLEMENTATION_TO_TEST=./pb-ffi bash ./test/test_container
            '';
            installPhase = "mkdir -p $out && touch $out/passed";
          };

          # Container (.pbf.json) for the standalone C CLI (issue #1).
          test-container-c = pkgs.stdenv.mkDerivation {
            name = "test-container-c";
            src = ./.;
            nativeBuildInputs = with pkgs; [ clang ];
            buildPhase = ''
              export HOME=$TMPDIR
              clang -O3 -Wall -Wextra -I. -o printable-binary-c src/printable_binary.c
              IMPLEMENTATION_TO_TEST=./printable-binary-c bash ./test/test_container
            '';
            installPhase = "mkdir -p $out && touch $out/passed";
          };

          # Container (.pbf.json) for the Lua reference CLI (issue #1).
          test-container-lua = pkgs.stdenv.mkDerivation {
            name = "test-container-lua";
            src = ./.;
            nativeBuildInputs = with pkgs; [ luajit ];
            buildPhase = ''
              export HOME=$TMPDIR
              patchShebangs bin/printable-binary-luajit
              IMPLEMENTATION_TO_TEST=./bin/printable-binary-luajit bash ./test/test_container
            '';
            installPhase = "mkdir -p $out && touch $out/passed";
          };

          # Rust crate: in-crate tests + the transport-critical cross-impl guard
          # (Rust encode must be byte-identical to Zig over all 256 bytes).
          test-rust = pkgs.stdenv.mkDerivation {
            name = "test-rust";
            src = ./.;
            nativeBuildInputs = with pkgs; [ cargo rustc zig ];
            buildPhase = ''
              export HOME=$TMPDIR
              export CARGO_HOME=$TMPDIR/cargo
              cargo test --release --offline --manifest-path rust/Cargo.toml
              cargo build --release --offline --manifest-path rust/Cargo.toml
              zig build
              for i in $(seq 0 255); do printf "\\$(printf '%03o' "$i")"; done > allbytes
              ./rust/target/release/printable-binary-rs < allbytes > r.out 2> r.err
              grep -Eq 'Input throughput: [0-9]+[.][0-9]{2} MB read in [0-9]+[.][0-9]{3} s \([0-9]+[.][0-9]{2} MB/s\)' r.err || {
                echo "FAIL: Rust CLI did not emit input throughput" >&2
                cat r.err >&2
                exit 1
              }
              PRINTABLE_BINARY_MUTE_STATS=1 ./zig-out/bin/printable-binary < allbytes > z.out
              cmp r.out z.out || { echo "FAIL: Rust encode != Zig encode" >&2; exit 1; }
              ./rust/target/release/printable-binary-rs -d < z.out > rt.out 2> rt.err
              grep -Eq 'Input throughput: [0-9]+[.][0-9]{2} MB read in [0-9]+[.][0-9]{3} s \([0-9]+[.][0-9]{2} MB/s\)' rt.err || {
                echo "FAIL: Rust decode did not emit input throughput" >&2
                cat rt.err >&2
                exit 1
              }
              cmp allbytes rt.out || { echo "FAIL: Rust decode(Zig encode) != original" >&2; exit 1; }
              echo "Rust <-> Zig byte-identical across all 256 bytes"
            '';
            installPhase = "mkdir -p $out && touch $out/passed";
          };

          # ~PB compile-time sigil (Elixir). Runs the crate's own unit + doctest
          # suite, then the MFIC cross-impl guard: the Zig CLI is the INDEPENDENT
          # encoder oracle (Elixir did not write it), so Elixir decode/1 must
          # reproduce the original bytes for all 256 single bytes AND an 8 KiB
          # random multi-byte stream (exercises 2/3-byte glyph boundaries).
          test-elixir = pkgs.stdenv.mkDerivation {
            name = "test-elixir";
            src = ./.;
            nativeBuildInputs = with pkgs; [ elixir zig ];
            buildPhase = ''
              export HOME=$TMPDIR
              export MIX_HOME=$TMPDIR/mix
              export HEX_HOME=$TMPDIR/hex
              ( cd elixir && mix test --no-deps-check )
              zig build
              for i in $(seq 0 255); do printf "\\$(printf '%03o' "$i")"; done > allbytes
              head -c 8192 /dev/urandom > rand.bin
              PRINTABLE_BINARY_MUTE_STATS=1 ./zig-out/bin/printable-binary < allbytes > z_all.out
              PRINTABLE_BINARY_MUTE_STATS=1 ./zig-out/bin/printable-binary < rand.bin  > z_rand.out
              ( cd elixir && mix run --no-start -e '
                  for {enc, orig} <- [{"../z_all.out", "../allbytes"}, {"../z_rand.out", "../rand.bin"}] do
                    got = PrintableBinary.decode(File.read!(enc))
                    exp = File.read!(orig)
                    if got != exp, do: raise "Elixir decode(Zig encode) mismatch for #{enc}"
                  end
                  IO.puts("Elixir decode(Zig encode) == original for all-256 + 8KiB random")
              ' )
            '';
            installPhase = "mkdir -p $out && touch $out/passed";
          };

          # Dogfood the C FFI boundary: build the C FFI CLI against the Zig static
          # lib and round-trip through it (encode/decode + hexlike).
          test-ffi-cli = pkgs.stdenv.mkDerivation {
            name = "test-ffi-cli";
            src = ./.;
            nativeBuildInputs = with pkgs; [ zig clang ];
            buildPhase = ''
              export HOME=$TMPDIR
              zig build
              clang -O2 -I. -o pb-ffi src/printable_binary_ffi_main.c zig-out/lib/libprintable_binary.a
              head -c 4096 /dev/urandom > in.bin
              ./pb-ffi in.bin > encoded.bin 2> encode.stats
              grep -Eq 'Input throughput: [0-9]+[.][0-9]{2} MB read in [0-9]+[.][0-9]{3} s \([0-9]+[.][0-9]{2} MB/s\)' encode.stats || {
                echo "FFI encode did not emit input throughput" >&2
                cat encode.stats >&2
                exit 1
              }
              ./pb-ffi -d encoded.bin > out.bin 2> decode.stats
              grep -Eq 'Input throughput: [0-9]+[.][0-9]{2} MB read in [0-9]+[.][0-9]{3} s \([0-9]+[.][0-9]{2} MB/s\)' decode.stats || {
                echo "FFI decode did not emit input throughput" >&2
                cat decode.stats >&2
                exit 1
              }
              cmp in.bin out.bin || { echo "FFI CLI encode/decode roundtrip failed" >&2; exit 1; }
              ./pb-ffi -X in.bin | ./pb-ffi -X -d > outx.bin
              cmp in.bin outx.bin || { echo "FFI CLI hexlike roundtrip failed" >&2; exit 1; }
              echo "FFI CLI smoke test passed (encode/decode + hexlike through the C ABI)"
            '';
            installPhase = "mkdir -p $out && touch $out/passed";
          };

          # Continuous memory-leak detection: drive the FFI in a long-lived loop
          # and fail if RSS climbs over time (a leak) rather than plateauing.
          test-leak = pkgs.stdenv.mkDerivation {
            name = "test-leak";
            src = ./.;
            nativeBuildInputs = with pkgs; [ zig clang ];
            buildPhase = ''
              export HOME=$TMPDIR
              zig build
              clang -O2 -Isrc -o leak_harness test/leak_harness.c zig-out/lib/libprintable_binary.a
              LEAK_HARNESS=./leak_harness LEAK_SECONDS=6 bash test/leak_test
              # CLI mode: drive the C standalone's buffer_t path via --leak-seconds.
              clang -O3 -Wall -Wextra -I. -o printable-binary-c src/printable_binary.c
              IMPLEMENTATION_TO_TEST=./printable-binary-c LEAK_SECONDS=6 bash test/leak_test
            '';
            installPhase = "mkdir -p $out && touch $out/passed";
          };

          # Guard against a stale generated C header: regenerating from
          # character_map.txt must reproduce the committed character_map_embedded.h.
          test-embedded-map-sync = pkgs.stdenv.mkDerivation {
            name = "test-embedded-map-sync";
            src = ./.;
            nativeBuildInputs = with pkgs; [ luajit ];
            buildPhase = ''
              cp character_map_embedded.h committed.h
              luajit utils/generate_embedded_map.lua
              if ! diff -q committed.h character_map_embedded.h; then
                echo "character_map_embedded.h is stale; run: luajit utils/generate_embedded_map.lua" >&2
                exit 1
              fi
            '';
            installPhase = "mkdir -p $out && touch $out/passed";
          };
        } // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
          # Architecture invariant: importing the `printable_binary` Zig module
          # must emit ZERO `pb_*` C symbols (the C ABI lives only in the FFI-root
          # static lib). Two static (musl) consumers of pb otherwise collide on
          # `duplicate symbol: pb_*` under ld.lld — this blocked difz. nm is an
          # independent oracle. Linux-only: the dup-symbol hazard is specific to
          # static-musl linking (darwin links dynamically and tolerates dupes),
          # and the test's nm output parsing assumes ELF symbol naming (no Mach-O
          # leading underscore). See test/test_module_no_ffi_symbols.
          test-no-ffi-symbols = pkgs.stdenv.mkDerivation {
            name = "test-no-ffi-symbols";
            src = ./.;
            nativeBuildInputs = with pkgs; [ zig binutils ];
            buildPhase = ''
              export HOME=$TMPDIR
              bash ./test/test_module_no_ffi_symbols
            '';
            installPhase = "mkdir -p $out && touch $out/passed";
          };

          test-ape = pkgs.stdenvNoCC.mkDerivation {
            name = "test-ape";
            src = ./.;
            nativeBuildInputs = with pkgs; [ cosmoccBin coreutils python3 xxd hexdump bash ];
            buildPhase = ''
              export PATH=${cosmoccBin}/bin:$PATH
              export HOME=$TMPDIR
              unset C_INCLUDE_PATH CPATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH
              cosmocc -O3 -DNDEBUG -I. -o printable-binary-ape.com src/printable_binary.c
              chmod +x printable-binary-ape.com
              IMPLEMENTATION_TO_TEST=./printable-binary-ape.com bash ./test/test
            '';
            installPhase = "mkdir -p $out && touch $out/passed";
          };
        };
      });
}
