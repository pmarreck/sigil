# sigil — Plan

Ed25519-signed document verification, shared by **Mecha Validate** and
**Mecha Rotshield**. On the critical path to revenue: neither product ships
without offline license verification.

Background and settled decisions: docs/plan_context/decisions_and_background.md. Completed items: docs/PLAN_LOG.md.

## In Progress

- [x] Downstream Zig artifact contract (2026-10-13 12:40 EDT): Zig 0.16 `dependency("sigil").artifact("sigil")` panicked "ambiguous" because the CLI and verifier library shared the artifact name. CLI renamed to `sigil-cli`, still installed as bin/sigil; macOS registers the verifier without installing Zig's archive. tests/zig_consumer + tests/integration/zig_consumer.sh: resolves on 5 targets, links the C conformance program, no signing exports. Red 7/7 before the fix.
- [x] Pinned printable-binary cdefa95 for validate's transitive freshness gate: Zig package and CLI oracle; upstream added a Roc CLI only, character map unchanged; ./test 780/780, Nix test-all green; sigil package hash relayed (done 2026-10-14 14:28 EDT, 56be89b).
- [ ] Repin to mecha_policy 0f4a8b0: validate staged it in candidate 18 (14:56 EDT; red at cfdfb9d on all 3 vectors plus an injected now of 2026-02-30, complete ./test green), uncommitted under its JPEG provider hold. Closes when cand18 is committed and nominated. Commerce done 2026-10-13 13:35 EDT (eeba2b7, pins e3a61ab + 0f4a8b0, 45/45): builders proven over 6,930 dates; operator `expires` and Paddle `occurred_at` accepted rolled-forward dates (fixed red-first, shared src/calendar.mjs); differentials fail on cfdfb9d as expected. Residual: test-only injected-clock parsers accept date-only input; production feeds only the Worker's ISO clock. RotShield done 2026-10-13 13:30 EDT (sigil e3a61ab, mecha_policy 0f4a8b0; selector removed; 13/13 consumer unit controls, all 80 eval rows and 5 KATs; application Create without credentials still RED until runtime wiring).
- [x] OCT5c-3 review (2026-10-10, commerce 18c5166, source only; F1-F5 fixed at dea2ba3, R1 missing-genesis restore fixed at 524c3ee, closed in source 13:40 EDT; acceptance waits on the owner-gated OCT12 deployed rehearsal): F1 high, no fail-closed fence between ledger loss and restore (a redelivered paid webhook mints a second license); F2 export unbounded vs 16 MiB restore cap; F3 custody ruling: bulk export signed-only, bearer for per-customer actions only; F4 per-key restore in a real Durable Object needs batching and a measured max-size rehearsal; F5 409 recovery in the OCT5c-4 runbook. F1 gates ALL live issuance (paid, beta, admin, activation, refresh, renewal). Re-review the changed surface and the real interleaving assumptions: input gates close only during storage operations, so any non-storage await (crypto.subtle, fetch) between the conflict check and the writes would let another request in.
- [x] RotShield positive certificate control added 2026-10-10 18:45 EDT: cert_rotshield_valid binds the genuine RotShield beta grant (license_vectors/wrong_product.sigil) to the RotShield machine hash, with expiry, other-machine, other-license, cross-product and rollback negatives. mecha_policy cfdfb9d decides all 7 rows as written. Paid pair added 18:50 EDT at entropy_shield's request: v2_rotshield_valid (ceiling 1.2, refused at 1.3 and 2.0, beta-key twin refused) and cert_rotshield_paid_valid (6 evals); mecha_policy cfdfb9d agrees on all 15 new rows.
- [ ] Gate (2026-10-10 19:45 EDT): validate's next nomination (cand20b nominated uncommitted 2026-10-14 19:17 EDT with sigil 7929c28 and mecha_policy 0f4a8b0; review starts at its commit; candidate 7 bc9c7bfe…05bb superseded) gets a full fresh review: rebuild, four hashes, license-surface diff from ba8f1adb7, key scan, full matrix, then red team. ba8f1adb7 evidence does not transfer.
- [x] Gate: red-team review of ba8f1adb7: NOT ACCEPTED, impossible dates admit on test-trust (cfdfb9d calendar regression); all other held rows passed; recorded in RELEASE_GATES (done 2026-10-14 14:48 EDT, red team a8e4bd7).
- [ ] Gate: RotShield first nomination (commit, four hashes, entrypoint list) once test-trust admission is green; then the entrypoint matrix.
- [ ] Gate: validate_gui commits its core repin (committed pin e3cdb68 was never nominated) to a pre-checked or accepted core, then nominates.
- [ ] Gate: commerce local workerd ledger rehearsal plus test-key import into ba8f1adb7 test-trust; OCT12 deployed rehearsal stays owner-gated. Provisional ba8f1adb7 identity (bin 961b1b17…1195) and fixture pair relayed 2026-10-10 20:05 EDT, pending red-team acceptance; commerce reruns the import on the first accepted §15 candidate before repin. Retarget: ba8f1adb7 was not accepted (2026-10-14), so the import moves to validate's next nominated candidate.
- [ ] BDFN 2026-10-01 16:55 EDT: validate_gui (Mecha Validate) and entropy_shield (Mecha RotShield) must refuse to run main features without a properly signed license (+ installation certificate). Directive sent with pins and acceptance tests; sigil tracks nominations. Reading CORRECTED 2026-10-10 (audit): the app always opens to import/status. RotShield Verify is the explicit §13 exception (2026-09-28 "no license for verify"; C1 2026-10-06): it needs no grant and no installation certificate, whether the copy was never licensed, is expired, or runs an uncovered major. Create, Update and Repair need license AND certificate (§15). The Oct 1 line "never-licensed RotShield refuses all" was an unconfirmed sigil gloss and is withdrawn.

### Self-update signing boundary (Einstein request, 2026-08-27 01:50)

### LEAD: all-build core licensing contract (Peter directive 2026-09-17 12:27 EDT)

- [ ] Red-team slice 1 (2026-09-19 15:50 EDT): artifact hashes matched; CLI behavior clean on both builds (no bypass). OPEN FINDING: export fn validate() at validate ffi/c_api.zig:1280 has no admitUnit — source-evidenced ungated FFI export; validate asked to gate/remove + direct-FFI denial test. validate_gui CONFIRMED three callers of the ungated export (2026-09-19 15:51 EDT): gui/src/ffi.rs:61 (full_validate), validate-serve main.zig:389 doValidate (the ORDINARY backend single-file path: validate_one + VALIDATE_SAMPLE), and the coverage NULL-fallback at main.zig:208 — so E2 is the GUI's normal path, not an opt-in edge. Recorded by them as acceptance blockers; call sites sent to validate. validate CONFIRMED (15:59 EDT) both git routes are LIVE walks (fsck --full whole object DB; own checksum walk iterates .git/objects live) — section 11 gap confirmed; closure = capture heads + loose/pack listing at unit start, validate exactly that set, connectivity bounded to captured heads, post-capture test. Sequencing: validate() fix pin first, git captured-plan pin second, each a separate nomination; 006fb6b2b preserved.
- [ ] OPEN for Peter (carried in contract §2): name canonicalization (recommend: name as display, verified email as identity); signed evaluation grants (keep 250GB/7-day metering inside a signed grant vs plain short-expiry cert — metering removal deletes the only mutable-counter state worth protecting).

- [x] Live-issuance persistence blocker CLOSED IN CODE (audit 2026-10-10): issueForEntitlement mints once under ledger recordOnce (put-if-absent) and every resend reuses the stored bytes; the Durable Object ledger (commerce 631a2b5) implements recordOnce, D1 removed (23ae2ab). Byte-identical resend after restore is tested on the CLI file ledger (commerce tests/cli/beta.test.bash) and, for the Worker, only against a fake Durable Object (commerce 18c5166, OCT5c-3; sigil source review 2026-10-10). Real Durable Object transaction, concurrency and eviction behavior is unproven. Open for live issuance: OCT5c-4 runbook (replay Paddle notifications newer than the backup), the deployed recovery rehearsal (OCT12), deployment and production keys (the last three owner-gated).
- [ ] Ceremony (SLIPPED from Oct 2-5): Peter picks a slot by Oct 9 (asked 2026-10-06 with inventory + checklist, runbook §0a/§0b, a4991ec); commerce asked whether the production Worker exists. Was: preflight green on the ceremony host with Peter; ceremony scheduled (Peter's action; sigil verifies outputs afterwards).
- [ ] Peter: approve the hex paper samples (emailed 2026-10-06).
- [ ] Peter: GUI demos before the ceremony - refusal-only (1) or a labeled test-trust demo build (2)? Emailed 2026-10-06 17:40 EDT; validate_gui told no production keys or real licenses exist.
- [ ] Production Worker waits on Peter (commerce onboarding checklist F2).
- [x] macOS static libraries Apple-consumable: build.zig re-archives the exact Zig member bytes (zig ar p, then zig ar --format=darwin, deterministic) so members are 8-byte aligned and readable; tests/integration/ macos_archive.sh guards both Mac archs. — 2026-10-06 18:35 EDT — 2026-10-06 18:30 EDT
- [x] Owner trial and purchase workflow recorded as contract 14.5 (rev 2.1 draft), owners coordinated, 3 conflicts queued for the owner (done 2026-10-14 17:45 EDT).
- [x] Forever-per-version licensing recorded as contract 16 (rev 3.0 draft): payload v3 without expiry, update entitlement as ledger state, Pro as features "pro", certificate v2 without expiry; refund question revised to r3 (done 2026-10-20 13:55 EDT).
- [ ] Payload v3 and certificate v2 vectors (perpetual paid grant, pro features, undated certificate, superseding order, update-entitlement decision table) under test roles, then mecha_policy ABI 3; commerce agreed 2026-10-20 13:35 EDT, apps pending.
- [ ] Owner answers: walking-brief sigil-purchase-refund-month, sigil-three-os-limit, sigil-trial-scan-limit; then revise 14.5 and 15.1 and send commerce vectors.
- [ ] Signed one-month trial vectors (examples/trial_vectors) under test per-product trial roles, hand-written expects, before mecha_policy changes.
- [ ] Trial class and roles in mecha_policy (one month per contract 14.5), driven by the trial vectors above. A Windows 11 TPM run of PCP_EKPUB is still owed by an app team before tpm is relied on.
- [ ] After the ceremony: verify registry row + identity-check outputs; relay the production `.pub` to validate and commerce; then the production-trust positive control per KEY_CEREMONY_V1 section 4.

### Founding Beta license path (defined 2026-08-26; dates corrected same night)

- [ ] Then: key ceremony (docs/CUSTODY_AND_ISSUER_API_V1.md section 4) -> `mecha-commerce beta invite --product mecha-validate --file testers.csv` (15 names/emails from Peter) mints and ledgers the licenses; hand validate_gui the beta pubkey via `sigil pubkey --format c`. (Superseded the hand-signing plan 2026-09-19.)
- [ ] validate_gui owns the expiry gate + its tests (injected `today`); they have the definition and an expired-but-genuinely-signed test-license recipe as of tonight. (Correction with the new dates sent 2026-08-26; the gate logic itself is date-agnostic.)
- [ ] **mecha-commerce Phase E continues** (field names DECIDED 2026-08-12: release-plan set; beta = `payment_provider:"beta"` + mandatory short expiry). Remaining: JS verifier, worker cutover, vector regeneration, durable cross-impl fixture, validate core swap. Tracked in mecha-commerce/PLAN.md Phase E.
- [ ] **New scope from Peter (2026-08-04, relayed by Einstein), broken out below.** His words: *"sigil must serve as a maximally-correct and secure certificate signer; I'm still deciding on how I will provide the private key (yubikey or offline airgapped secret etc.; it should be flexible enough to be configurable for both) but it looks like Ed25519 will be the starting signature format unless something PQC-related is proven/usable; signing method should be specified in the cert or sig somehow for futureproofing."* Followed by *"please add these to a PLAN.md and work down the list."*

### A. Identify the signing method — DECIDED 2026-08-11 (Peter), IMPLEMENTED

### A2. Key rotation — DECIDED 2026-08-11 (Peter): no `kid`

### B. Custody flexibility (Peter, 2026-08-04)

### C. Exit-code contract inconsistency (found 2026-08-04)

- [ ] `--help` says exit 1 means "NOT AUTHENTIC ... Only 1 ever means a document was rejected on its merits", but a **wrong passphrase** also exits 1. A passphrase is not a document and it is not being rejected on its merits. Same misclassification family as the OOM and low-order-key bugs already fixed. Not changed on the spot: it is a documented CLI contract with an existing test pinning it, so it wants a deliberate choice (probably 77 EX_NOPERM, or 65) rather than a midnight edit.

## Next

- [ ] Evaluate whether Sigil belongs in UNIX MAIL REDUX's S/MIME certificate lifecycle at all; default to keeping the standards-specific work in the mail project unless a concrete shared custody abstraction pays for the coupling. If Sigil participates, limit it to operator policy, purpose-separated key custody, or an offline issuance ceremony, and delegate CMS, X.509, ASN.1/DER, and MIME canonicalization to an established independent implementation. Never reuse the custom `sigil.transcript.v1` envelope or any license/update key for mail. Curiosity poke: the existing provider signs Sigil's domain-separated transcript; standards-compliant CMS signatures require a distinct protocol path and key, plus interoperability tests against Apple Mail and an external verifier.
- [ ] Write INTENT.md with the gather-project-intentions skill (PROJECT_OVERVIEW.md is retired fleet-wide; none exists here).
- [ ] Hand Mecha Validate and Mecha Rotshield an integration note: link `libsigil.a` only, embed the key via `sigil pubkey --format c|zig`, and implement the confirmation policy from docs/DESIGN.md (monotonic clock high-water mark; fail open on network error, closed only on an explicit revoked response; grace period rather than a midnight lockout).
- [ ] The confirmation endpoint itself + a short-dated attestation envelope. Server-side, so a separate piece of work — but the format is already settled (it is just another sigil envelope).
- [ ] Benchmark gate (`./bm`) once verification is on a hot path anywhere.

## Deferred — raise with Peter rather than deciding

- [ ] **i18n groundwork.** The canonical brief wants prepare-phase i18n at app construction, but sigil's CLI is an internal fulfillment tool that Peter alone runs; customers never see it. Deferring on scope-discipline grounds. Say the word and it gets the `--lang` scaffolding.

## Decided (see docs/DESIGN.md for the full reasoning)

## Explicitly deferred (agreed over-engineering)

## Completed

## Post-review remediation (2026-07-28 deep-code-review, 5 agents)

### Blocked on Peter
- [ ] **`features` shape** — the entitlement lever for the capability tiers (detection free; repair/creation gated). Deliberately not invented. The README's example envelope stays on the old placeholder names until this lands, since regenerating it means signing a payload we would then have to change again.
- [ ] The release plan needs both decisions above written back into it — Einstein's call, not mine; it is a business document with an existing documented precedence problem (the two-app vs three-app bundle price).

### High, still open

- [ ] `--json` implemented only by `verify`.
- [x] `pubkey --out` honored for every format (hex, c and zig had printed to stdout); five-format test, stdout bytes unchanged against the pre-fix build (done 2026-10-14 16:05 EDT).

### Feature: envelope normalization (Peter, 2026-07-28)

- [ ] Stage 1 (pre-parse): strip `\t\n\r` and space from the whole envelope. JSON-safe and value-safe. Fixes hard-wrapping.
- [ ] Stage 2 (post-parse, per value): strip any code point outside the 256-symbol alphabet from `data` and `sig`. Fixes `>` prefixes.
- [ ] Default on, with a stderr warning when normalization changed something.
- [ ] Constraint to enforce: stage 1 is only safe while every envelope field is printable-binary or a fixed token. Reject unknown fields.

### Deferred / ideas

- [ ] **Mutation-test the suite.** It has never been mutation-tested; the FFI leak gap was found that way and is unlikely to be the only one. Every surviving mutant names an invalid region of the suite.
- [ ] **Elixir: NIF + pure-Elixir sigil, tested differentially** (Peter's idea, 2026-07-28). Ed25519 is already in `:crypto` (OTP 24+), so a pure version is ~100 lines once printable-binary decode is ported. The differential suite is the point: an oracle causally independent of the Zig. Zigler handles NIF build integration, and Zig cross-compilation solves the historic "NIFs are miserable to deploy" problem — which is itself the story worth telling in that community. Candidate libs chosen by ecosystem *gap*: z7z (absent), printable_binary (no equivalent), validate (absent), sigil. Scheduler discipline differs per lib: short/hot → plain NIF, long-running → dirty CPU-bound schedulers.
- [ ] Envelope malleability is broader than documented (JSON `\u` escapes, alternate printable-binary encodings). Not a forgery, but the envelope must never be used as an identifier. Documentation fix.
- [ ] `verify.zig:43` uses cofactored verification; `verifyStrict` is the cofactorless alternative. Undocumented and untested. Matters only if sigil ever verifies a third-party key.
