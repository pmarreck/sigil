# Future Work / Proposed Ideas

- [x] Canonical CLI migration: `test/test_cli_layout` verifies that the Zig
  executable installs as `printable-binary`, LuaJIT remains explicitly available
  as `printable-binary-luajit`, and Linux `build_all` includes APE.
- JS/Node perf: cache the parsed `character_map` inside `js/printable_binary.js` to avoid repeated fs reads in tight loops.
- Map override parity: allow `PRINTABLE_BINARY_MAP` in the WASM test harness, mirroring Node/Deno behavior.
- CI ergonomics: run `test_all` per implementation (LuaJIT, C, APE, Node) in parallel to shorten logs and isolate failures.
