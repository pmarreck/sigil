# Plan background and settled decisions

Moved verbatim from PLAN.md on 2026-10-14 so the plan holds only one-line work items. Each section names the PLAN.md heading it came from.

## Invariant (former preamble)

**The one invariant:** the signature covers the payload bytes *exactly* as
supplied. sigil never canonicalizes, re-orders, or re-serializes. Corollary:
**verify BEFORE parsing** — never interpret bytes you have not authenticated.

See `docs/DESIGN.md` for the envelope format, prior art, and reasoning.

## Self-update signing boundary (Einstein request, 2026-08-27 01:50)

Position sent same night (reply in `~/Code/inbox/`): **key separation IS the
purpose separation** — a dedicated update keypair plus one-embedded-key-per-
verifying-context makes license↔update replay fail signature verification by
construction, before parsing; no transcript change wanted or needed. Sequence/
expiry/platform/SHA checks are updater policy, same split as licensing.
Current sigil APIs suffice as-is.

## LEAD: all-build core licensing contract

Canonical release-gates record (closed evidence vs open items vs
revalidation): `docs/RELEASE_GATES.md` (created 2026-09-23 at Peter's
request; red-team results are pin- and platform-specific and never
transfer).
Update signing / anti-rollback contract (owned per Peter 2026-09-23):
`docs/UPDATE_SIGNING_CONTRACT_V1.md`; spec vectors
`examples/update_vectors/manifest.json`.

Sigil coordinates the shared contract for validate, validate_gui,
entropy_shield, mecha-commerce. Canonical directive: LICENSE_OPERATIONS.md
"Current directive" section (Obsidian vault). Negotiating text:
`docs/MECHA_LICENSE_CONTRACT_V1.md` (FROZEN / PROPOSED / OPEN markings).

## Founding Beta license path

Free 15-participant Mecha Validate beta, gated by signed licenses. sigil needs
**no code**: beta = `payment_provider:"beta"` + mandatory `expiry` (decided
2026-08-12), the transcript already binds algorithm/version inside the
signature, and validate_gui has verify-before-parse live against `8c44b19`
(their 2026-08-19 report). Full definition in the 2026-08-26 reply to Einstein
(`~/Code/inbox/`), including the time-behavior table (day-inclusive expiry;
malformed expiry = data error, never "NOT AUTHENTIC"; clock rollback accepted
for a free short beta).

**Dates: my Sept 1 / Sept 30 proposal was stale on arrival.** Einstein's
same-night reply carries Peter's later decision (2026-08-25, recorded in the
orchestrator plan): **Sept 15 launch, Oct 15 00:00 EDT expiry, licenses
expiring 60 days from issue** — and the last two clauses conflict, so
**DO NOT generate the beta key or mint anything** until Peter says which
reading wins:

## A. Identify the signing method

Peter chose **binding the algorithm inside the signed bytes**. sigil now signs
a transcript rather than the bare payload:

```
transcript = "sigil.transcript.v1" ‖ u8(alg_id) ‖ u64be(payload_len) ‖ payload
```

Full field table and the reasoning for each choice in `docs/DESIGN.md`, "The
signing transcript". Specified before it was implemented, per the rule this
entry used to carry.


**Nothing was owed to existing licenses**: zero had been issued, which is the
only reason this was free to do. It would not have been free a week later.

## A2. Key rotation: no kid

The envelope carries **no key identifier**. Each app embeds exactly one public
key for its own product, per the release plan ("Signed by per-app private key;
public key embedded in app").

Rejected alternative: mecha-license v1's `kid`, which lets a verifier pick a key
without shipping a build. It was declined because choosing a key by an
identifier read out of the document means **parsing before verifying** — the one
thing this codebase's types exist to prevent. The danger is not that a wrong
`kid` would be accepted (it would fail verification); it is that adding one
legitimate reason to read unauthenticated bytes makes the next one easier to
justify.

A compromised key is handled by shipping an app update, which the revocation
design already requires on any version change.

## B. Custody flexibility

Peter wants the private key *provider* configurable — YubiKey or offline
air-gapped secret — not two finished drivers. The July 28 passphrase-encrypted
keyfile decision is not reversed; it becomes the first provider.

## Explicitly deferred (agreed over-engineering)

- A typed schema layer for the payload (`integer`/`decimal`/typed values with validation regexes). Payload v1 is: keys `[a-z0-9_]+`, values UTF-8 strings, the application interprets them. Add via `v=2` when a second consumer actually needs it — it will be additive, not a rewrite.

## Post-review remediation (2026-07-28)

Full findings: `CODE_REVIEW.md`. Every item below was reproduced by building,
linking, running or disassembling — none are speculative.

## Feature: envelope normalization

Make verification survive transport mangling — email wrapping, `>` quote
prefixes, arbitrary injected junk.

Proven safe by exhaustion: encoding all 256 byte values yields exactly 256
distinct code points, and **none** is ASCII whitespace; `>`, `<`, `\` and `"`
are all remapped to lookalikes too. So stripping is a filter over an allowlist
*derived from the codec*, not a hand-written denylist.

Security argument: normalization runs BEFORE verification and the signature
covers the *decoded* bytes, so a normalization bug can only cause a false
rejection, never a false acceptance. Availability risk, not authenticity risk.

