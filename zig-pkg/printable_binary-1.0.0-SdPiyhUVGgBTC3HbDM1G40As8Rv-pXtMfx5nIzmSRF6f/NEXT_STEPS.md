# Next Steps

1. **Finalize Glyph Mapping**
   - Review the new 2-byte Latin Extended assignments for bytes 0x80–0xFF to ensure they match visual expectations (distinct shapes, intuitive ordering).
   - Confirm ampersand (⅋) and other updated glyphs look acceptable across common monospace fonts (Berkeley Mono, Fira Code, JetBrains Mono, etc.).

2. **Document Character Map Workflow**
   - Expand README with brief instructions on editing `character_map.txt`, running `utils/audit_character_map.lua`, and regenerating `CHARACTER_WIDTHS.md`.
   - Mention how the C, Lua, and JS implementations load the shared map (and where to set `PRINTABLE_BINARY_MAP`).

3. **CI / Automation Follow-up**
   - Integrate `utils/audit_character_map.lua` (and possibly the width report regeneration) into a pre-commit or CI step to prevent invalid maps from landing.
   - Consider adding a regression test that asserts cross-implementation encode size remains ≤ ~1.9× for representative binaries.

4. **Browser UX Polish**
   - Evaluate lazy-loading/error states for the browser map fetch (e.g., retry on failure, spinner while loading).
   - Re-run manual validation in Safari/Firefox to ensure glyph rendering still lines up.

5. **Release Checklist**
   - Update CHANGELOG / version notes summarizing the new glyph map and shared configuration file.
   - Rebuild binaries / publish npm package once documentation and automation items above are complete.
