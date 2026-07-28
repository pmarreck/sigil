
## 2026-06-27 — src/printable_binary.c is compiled by THREE toolchains; clang-clean ≠ all-clean
Added container support to the standalone C (`src/printable_binary.c`) and the
`test-container-c` check (clang `-O3 -Wall -Wextra`) passed — but I pushed without
building the WASM/APE targets. The emscripten build broke: my container block
called `buffer_free`, which is `#ifndef __EMSCRIPTEN__`-guarded (so it doesn't
exist in WASM), failing `printableBinaryWasm` and the `default`/`nix`/`All Garnix`
aggregates that depend on it.
**Lesson:** `src/printable_binary.c` is built by clang (native), emscripten (WASM),
AND cosmocc (APE) — each with different defines/guards. Before pushing changes to
it, build `nix build .#printableBinaryWasm` (and `.#printableBinaryApe`) locally,
not just the clang container check. A native-clang pass does NOT catch
`__EMSCRIPTEN__`-guarded-symbol regressions.
