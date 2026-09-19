# license_vectors — TEST-ONLY trust and the class fixture matrix

Everything here is test trust. Passphrases are public by design
(`test-beta-not-for-production`, `test-paid-not-for-production`); release
acceptance byte-scans these public keys OUT of shipped binaries.

- `test_beta.key` / `test_paid.key` — sigil encrypted keyfiles (Argon2id +
  XChaCha20-Poly1305), the roles beta-license and paid-license.
- `test_beta.pkcs8.pem` / `test_paid.pkcs8.pem` — the SAME two seeds as
  RFC 8410 PKCS#8, for issuers that cannot open sigil keyfiles (WebCrypto in
  the mecha-commerce Worker). Derived once, offline, by a throwaway program;
  sigil deliberately has no seed-export command. An envelope signed with the
  PEM verifies under the matching `.key.pub`, so Worker-issued test licenses
  are accepted by consumers' test-trust builds end-to-end.
- `*.pubkey.hex` — the raw 32-byte public key of each role in hex; the
  vector suite asserts it equals `sigil pubkey --format hex` of the `.pub`,
  and the PEM's DER public half is checked by mecha-commerce's issuer suite
  (native `sigil verify` is the judge).
- `manifest.json` — every expected policy decision (the mecha_policy spec).
- `./generate` — regenerates the signed vectors byte-identically.
