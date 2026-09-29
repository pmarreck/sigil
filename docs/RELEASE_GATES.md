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

Rebuild-identity ruling (Einstein, 2026-09-28 22:40 EDT): commerce found that
`nix build --rebuild` of the exact validate 58c033e30 test-trust derivation
yields different bytes (9925c623...) from the reviewer-nominated executable
(d5257b77...). A derivation hash plus a commit is provenance, not artifact
identity. The 58c033e30 byte-identity evidence therefore applies ONLY to the
originally hashed artifact and cannot clear a fresh build; commerce E10 keeps
its independent exact-byte SHA-256 block. Validate owns reproducing the
difference and fixing it with a deterministic control; a NEW nomination must
pass repeated independent builds before any fresh artifact is accepted.

| Candidate (validate/yolo) | Result | Reviewer record |
|---|---|---|
| 006fb6b2b | First gated candidate. E2 = EXECUTED CRIT: `validate()` C export performed unlicensed work (production archive, empty HOME). CLI slice clean. Preserved. | candidate-006fb6b2b-linux-x86_64.md |
| 0a89aaa1b | E2 CLOSED: C ABI admits before open; reviewer's own `zig cc` consumer refused on both exports; T1/T2 correct. | candidate-0a89aaa1b-linux-x86_64.md |
| 274a16bda | Git captured-plan attempt NOT closed: fsck never executed (library could not spawn subprocesses from C); CLI depth overclaim. Superseded. | candidate-274a16bda-linux-x86_64.md |
| 357301648 | Git section 11 CLOSED: fsck executes with captured heads only; reviewer's shim committed mid-unit and the running unit judged only its capture; late-only missing-tree probe passed. Residual non-repo verdict fixed in ordinary pin 87be07bd5. | candidate-357301648-linux-x86_64.md |
| 13adfe3f4 | New export `validate_test_coverage_map` GATED over the C ABI; cap and start_round behavior verified. | candidate-13adfe3f4-linux-x86_64.md |
| 58c033e30 | Range contract + PRECEDENCE CLOSED (unlicensed bad args → auth_missing, never invalid_argument); E2 re-run clean. Pins mecha_policy 1603f7a, sigil 12baa15. **Latest accepted candidate.** | candidate-58c033e30-linux-x86_64.md |
| 569808119 | ACCEPTED 2026-09-29 (01:23 EDT): first REPRODUCIBLE candidate (owner built once + rebuilt twice; sigil and commerce sandboxed rebuilds agree; build-time control against .zig-cache leakage). Reviewer: independent sha256 of all four store files MATCH; licensing diff since 58c033e30 EMPTY (gate, fixtures, no new exports); byte-scan production bae78058 ABSENT all four test/demo pubkeys, test-trust b6e1db79 PRESENT beta+paid only; E2, precedence, last-byte clamp, start=EOF, mixed modes, expiry 10-17/10-18 all re-run and hold. Reviewer did not run a third nix build. Supersedes 58c033e30 as the accepted candidate; the test-trust bin b6e1db792c6452a997353b3c6315fe63dee4f78eb69110bdd3c172145d98c6fb is the pin commerce and validate_gui move to. | candidate-569808119-linux-x86_64.md |

Commerce (issuer side): bb134a0 / b902c46 — producer-reported E2E
integration against validate 0a89aaa1b test-trust (external artifact
hash, injected clock, 11 tests in `checks.x86_64-linux.test`); the
committed issued fixtures were independently hash-matched by the reviewer
at bb134a0 (six envelopes, byte-identical to sigil's). Not a gate
candidate; no findings against the issuer beyond its differential.
Reviewer source review of 8ef3a56 (2026-09-23, C-class, no binary,
findings/candidate-commerce-8ef3a56.md): fixtures 6/6 hash-match; lock
pins match (status 2026-09-29: accepted candidate is now validate 569808119; commerce E11d re-pin pending); C1 routes are only /health, /pubkeys, POST /paddle/webhook
with issuance only from transaction.completed; C2 signature before
admission; C4 attachment-only delivery; C5 beta EXISTING keeps prior
grant; C6 resend delivers the stored envelope; C7 dry-run before
execute; C8 adjustments recorded, no issuance. C3 INDEPENDENTLY confirms
the live-paid blocker: a later-day paid re-process would mint a new
purchase_date (Phase D).

Malformed pack trailer and truncated pack index: EXECUTED by the reviewer on
569808119 test-trust b6e1db79 (2026-09-29 05:25Z; licensed, git on PATH,
one-commit scratch repo after `git repack -a -d`). Baseline valid=true at
full depth with connectivity reached; last pack byte flipped -> rc=1,
valid=false, "Corrupt objects detected", depth structural; .idx truncated
to 20 bytes -> same. Both refuse a full-depth pass. No reviewer gap remains
on Linux x86_64 for this candidate; other OS/arch cells unexecuted.

## B. Genuinely open — owner-assigned

- validate: REPRODUCIBILITY FIXED at 569808119 (reported 2026-09-29 01:06
  EDT): cause was Zig 0.16 cache-directory names (order-dependent) reaching
  RUNPATH/.debug_line and archive member names; installPhase now re-adds
  archive members under basenames; the Nix build fails if a `_zcu.o`
  member keeps a `.zig-cache` path or bin/validate embeds `zig-cache/o/`.
  Test-trust bin/validate sha256 b6e1db792c6452a997353b3c6315fe63dee4f78e
  b69110bdd3c172145d98c6fb, narHash sha256-PQ+pXThIuLEa2lqyMCq/YUGyZKC7l+8q
  X/wq2fmUZAQ=; three bit-identical builds by validate (evidence under
  /mnt/devcache/tmp-validate-chain/repro/evidence-569808119/). Sandboxed
  `--rebuild` checks: mecha-commerce twice (05:07-05:15Z, both exit 0, no
  determinism warning; record in their docs/plan_context/phase_e11.md at
  da57a46) and sigil once (01:07-01:19 EDT, exit 0, log clean), all
  agreeing on bin b6e1db79...c6fb, lib 91263546...46d2 and the narHash.
  Caveat: every agent runs on the one Thelio host, so "independent" here
  means separate sandboxed rebuilds by separate agents, not a second
  machine; the first fetch on each was a store hit on validate's own
  output. NOMINATED by validate under section 12 (mail 2026-09-29 05:19Z):
  x86_64-linux; production `default` bin bae78058...ec75 (no license keys
  embedded, refuses every protected operation) and test-trust bin
  b6e1db79...c6fb (embeds test_beta/test_paid .pub, file sha256
  5683efb3...f8b2 / 8125b9b1...8b98, unchanged since 58c033e30); each built
  once and rebuilt twice bit-identically. Section C scope per the owner: 93
  commits since 58c033e30; license_gate.zig and fixtures unchanged; 6
  commits in ffi/c_api.zig + cli/main.c (depth levels, --test-coverage,
  --strict, precedence test), no admission code changed; the rest is
  validator behaviour. Relayed to the red team with the acceptance target
  set; ACCEPTED by the red team 2026-09-29 05:23Z (row above); pin + hash
  relayed to commerce (E11d) and validate_gui (repin target). 58c033e30 remains the last accepted
  candidate, its evidence bound to the d5257b77 artifact only.
- validate: commit the direct-ABI precedence regression test (ordinary
  pin); land popen exit-status handling + regression so the PLAN-only
  freshness exception (71a229207) can be accepted; keep every new export
  in `docs/LICENSE_ENTRYPOINTS.md` before nomination.
- mecha_license_redteam: nothing outstanding on Linux x86_64 (pack-trailer
  and truncated-index probes executed on 569808119, 2026-09-29); other
  OS/arch cells unexecuted for every candidate.
- validate_gui: repin to a post-fix validate (currently 639aaaad1, which
  predates the spawn fix); real-backend generated-repository tests
  (observable git execution, missing tool, honest depth); licensing
  adapters (import/status/About consuming the core decision); then first
  nomination with exact pin + GUI/backend evidence.
- entropy_shield: RotShield gate + import/status per contract (rev 1.3:
  Verify grant-free, Create/Update/Repair licensed); entrypoint matrix
  acceptance tests (Clear/strip rules, resource-fork conditional paths,
  debug exports removed, Verify positive with no grant and with an expired
  grant, Verify-then-Repair refused at the Repair step); first nomination.
  Trial terms remain Peter's.
- mecha-commerce: Phase D idempotency CLOSED IN LOGIC at e16f5a5
  (2026-09-28): the envelope is minted once under a put-if-absent
  `recordOnce` ledger call before any delivery; retries reuse the recorded
  bytes; a port without it fails closed; tested across a UTC day boundary
  with a control. Per-product roles per custody v1.3 at 3c237a4. STILL
  BLOCKING live PAID issuance: the durable ledger adapter (waits on Peter's
  D1-vs-Durable-Object decision); `roleFor(provider, product)` once
  per-product keys exist; confirmation Worker (separate key, hash-only,
  unknown = fail-open); move the E2E suite's validate pin to the latest
  accepted candidate (58c033e30) with the external-hash assertion.
- sigil: `keygen --hot-bundle-out` + `hot-bundle open` SHIPPED 380cd22 and
  `sigil paper` cold copies SHIPPED aae83d4 (2026-09-28; Peter's visual
  approval of the render pending); ceremony preflight script still to
  write; vector regeneration only on a coordinated schema bump.
- Peter: custody DECIDED 2026-09-28 (all six); still his: key ceremony;
  D1-vs-Durable-Object; real-send authorization; mecha_policy Mechatron
  webhook; update-contract questions (delta shape, channel switch,
  RotShield namespace).

## C. Revalidation required before ANY release clearance

Update/self-update signing domain: see `docs/UPDATE_SIGNING_CONTRACT_V1.md`
(manifest verification, anti-rollback, delta trust, rotation); acceptance
vectors in `examples/update_vectors/manifest.json`. Both apps' updaters
must pass those vectors before any release-channel claim.
Native platform trust gates (EXECUTION_CONTEXT_TRUST.md, folded 09-23):
verify the exact shipped fused executable and every helper AFTER native
signing with expected publisher; macOS new-file replacement + supported
bundle profile + stapled offline and quarantined online launch tests on
a reset VM; Windows Authenticode + expected publisher, SmartScreen/SAC/
Defender outcomes recorded separately for browser vs updater delivery;
delta targets verified in the declared representation (package vs
installed) before extraction; no client re-signing; crash rollback
subject to anti-rollback.

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
Evidence: Mechatron Prime PASS mecha-commerce@97e91e1 at
2026-09-23T14:24:09Z (packages.x86_64-linux.default +
checks.x86_64-linux.test; 8ef3a56 superseded in queue by 97e91e1 = same
code and flake.lock plus PLAN text); the E2E suite ran inside that check
against validate 58c033e30 test-trust with the external-hash assertion.
