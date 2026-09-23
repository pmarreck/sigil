# Licensing release gates — canonical record

Maintained by the licensing contract lead (sigil). Created 2026-09-23 at
Peter's request to fold red-team evidence into owned PLAN items. Source
of evidence: `~/Code/mecha_license_redteam/findings/` (reviewer-owned,
independent). Contract: `docs/MECHA_LICENSE_CONTRACT_V1.md` (rev 1.2).

Governing principle (contract section 12): every red-team result is
PIN-specific and PLATFORM-specific. A closure on one exact artifact does
not transfer to a newer pin, another OS/arch, another app, or production
trust. Section A is history; section C is what any release must re-earn.

## A. Closed — historical, Linux x86_64 only, exact artifacts

| Candidate (validate/yolo) | Result | Reviewer record |
|---|---|---|
| 006fb6b2b | First gated candidate. E2 = EXECUTED CRIT: `validate()` C export performed unlicensed work (production archive, empty HOME). CLI slice clean. Preserved. | candidate-006fb6b2b-linux-x86_64.md |
| 0a89aaa1b | E2 CLOSED: C ABI admits before open; reviewer's own `zig cc` consumer refused on both exports; T1/T2 correct. | candidate-0a89aaa1b-linux-x86_64.md |
| 274a16bda | Git captured-plan attempt NOT closed: fsck never executed (library could not spawn subprocesses from C); CLI depth overclaim. Superseded. | candidate-274a16bda-linux-x86_64.md |
| 357301648 | Git section 11 CLOSED: fsck executes with captured heads only; reviewer's shim committed mid-unit and the running unit judged only its capture; late-only missing-tree probe passed. Residual non-repo verdict fixed in ordinary pin 87be07bd5. | candidate-357301648-linux-x86_64.md |
| 13adfe3f4 | New export `validate_test_coverage_map` GATED over the C ABI; cap and start_round behavior verified. | candidate-13adfe3f4-linux-x86_64.md |
| 58c033e30 | Range contract + PRECEDENCE CLOSED (unlicensed bad args → auth_missing, never invalid_argument); E2 re-run clean. Pins mecha_policy 1603f7a, sigil 12baa15. **Latest accepted candidate.** | candidate-58c033e30-linux-x86_64.md |

Commerce (issuer side): bb134a0 / b902c46 — producer-reported E2E
integration against validate 0a89aaa1b test-trust (external artifact
hash, injected clock, 11 tests in `checks.x86_64-linux.test`); the
committed issued fixtures were independently hash-matched by the reviewer
at bb134a0 (six envelopes, byte-identical to sigil's). Not a gate
candidate; no findings against the issuer beyond its differential.

Not independently rerun on any pin: malformed pack trailer, truncated
index (owner tests exist; reviewer coverage gap, not a defect).

## B. Genuinely open — owner-assigned

- validate: commit the direct-ABI precedence regression test (ordinary
  pin); land popen exit-status handling + regression so the PLAN-only
  freshness exception (71a229207) can be accepted; keep every new export
  in `docs/LICENSE_ENTRYPOINTS.md` before nomination.
- mecha_license_redteam: rerun malformed pack-trailer / truncated-index
  probes on the latest accepted candidate; nothing else outstanding on
  Linux x86_64.
- validate_gui: repin to a post-fix validate (currently 639aaaad1, which
  predates the spawn fix); real-backend generated-repository tests
  (observable git execution, missing tool, honest depth); licensing
  adapters (import/status/About consuming the core decision); then first
  nomination with exact pin + GUI/backend evidence.
- entropy_shield: RotShield gate + import/status per contract; entrypoint
  matrix acceptance tests (Clear/strip rules, resource-fork conditional
  paths, debug exports removed); first nomination. Trial terms remain
  Peter's.
- mecha-commerce: Phase D durable ledger idempotency — BLOCKER for live
  PAID issuance (resend must return stored bytes; waits on Peter's
  D1-vs-Durable-Object decision); `roleFor(provider, product)` once
  per-product keys exist; confirmation Worker (separate key, hash-only,
  unknown = fail-open); move the E2E suite's validate pin to the latest
  accepted candidate (58c033e30) with the external-hash assertion.
- sigil: `keygen --hot-bundle-out` + `hot-bundle open` and the ceremony
  preflight (on Peter's yes to custody (b)); vector regeneration only on
  a coordinated schema bump.
- Peter: custody decisions (a)–(f); key ceremony; D1-vs-Durable-Object;
  real-send authorization; mecha_policy Mechatron webhook.

## C. Revalidation required before ANY release clearance

Per candidate (every new pin, every app): rev-pinned per-target hashes;
E2 consumer over the raw C ABI (production empty store → auth_missing,
zero bytes, zero callbacks; test-trust paid → real work; hand-placed
test grant on production → not_authentic); T1/T2/T3 expiry with an
injected clock incl. the sweep witness; I3a/b/c import bounds with prior
grant preserved; K-rows (missing key, wrong key, wrong class); git
section 11 (captured plan, late-only corruption); coverage range and
precedence; release byte-scan asserting the four test/demo pubkeys are
absent; an inventory row for every export.

Per platform: the five advertised targets are macOS aarch64, Linux
aarch64/x86_64, Windows aarch64/x86_64. Everything above has been
executed on Linux x86_64 ONLY. The reviewer can execute only Linux
x86_64; the other four cells need owner-executed evidence with
reviewer hash-matching at minimum, or a second reviewer host, before
any platform claim.

Production trust: a positive control with real keys, only after the
ceremony; test-trust positives never satisfy it.

GUI and RotShield: acceptance names the exact validate/RotShield core pin
plus GUI/backend evidence; a core fix is not shipped in a GUI until the
GUI repins and re-nominates.

Commerce linkage: the E2E suite must pin the latest ACCEPTED candidate
and assert its external hash; issued fixtures must hash-match sigil's.
Status 2026-09-23: mecha-commerce 8ef3a56 pins validate 58c033e30
test-trust (bin d5257b77... asserted by external SHA-256), sigil 12baa15,
mecha_policy 1603f7a; issued fixtures unchanged and still hash-match
(drift test). Protocol: on each accepted nomination the lead mails
commerce the pin + test-trust bin hash; the move is one reviewed commit.
