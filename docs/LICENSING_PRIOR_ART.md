# How other software enforces licenses — a prior-art survey

Written 2026-09-17 at Peter's request, to inform ongoing Mecha security
decisions. Sigil is the crypto layer; this document is about everything
around it — how the industry gates paid functionality, how each approach
fails, and which lessons Mecha has already absorbed or should. Companion to
`DESIGN.md`'s prior-art section, which covers envelope *formats*; this one
covers *enforcement*.

The claims here are from general industry knowledge, not fresh research.
Where a specific fact matters to a decision, verify it before relying on it.

## The one truth that frames everything

**Every check that runs on the customer's machine can be patched out by a
determined attacker with a debugger.** The binary is in their hands. No
signature scheme changes this: Ed25519 makes *forging a license* impossible
without the private key, but the attacker doesn't need to forge a license —
they can flip the branch that asks for one, or swap the embedded public key
for their own (and self-sign a "license").

Consequently the industry splits into two honest postures and one dishonest
one:

1. **Keep honest people honest** (most indie/professional software): make
   licenses unforgeable, make casual sharing inconvenient, accept that
   crackers crack, and price/support so that paying is the path of least
   resistance. Sublime Text ran for years on a license-key check that was
   publicly cracked; the business survived because its customers are
   professionals who pay for tools.
2. **Move the capability server-side** (SaaS, Adobe Creative Cloud sign-in,
   game servers): the only uncrackable check is the one that never runs on
   the client, because the *work* happens where the attacker isn't. The cost
   is that offline use dies and you now run an availability-critical service.
3. **The arms race** (Denuvo, VMProtect, themida-class packers): virtualize
   and obfuscate the check, scatter it, re-check constantly. Buys weeks to
   months of protection for AAA game launch windows, costs runtime
   performance, licensing fees, and support pain from false positives.
   Publishers routinely strip it out after the launch window. Nobody in
   productivity software wins this race, and Mecha should not enter it.

Mecha's posture is (1), with (2) reserved for what is genuinely server-side
anyway (issuance, update manifests, the confirmation endpoint). That posture
is already implicit in the release plan (fail-open revocation, 365-day
offline window); this document makes it explicit.

## The enforcement families

### Serial numbers and partial key verification (historic, weak)

The 1990s–2000s norm: an algorithm in the binary validates a typed key
(checksum, modular arithmetic). Defeated by keygens the moment one copy of
the algorithm is reverse-engineered — the validator IS the generator's
specification. Partial Key Verification (checking only a subset of the key's
invariants per release) slowed keygens slightly by making any one binary an
incomplete spec. Asymmetric signatures killed this family: a verifier that
holds only a public key specifies nothing about how to sign.

Lesson, already taken: sigil licenses are Ed25519-signed documents, not
serials. There is no keygen to write; the verifier is safe to ship, inspect,
even open-source.

### Signed license files (Mecha's family)

A document of entitlements signed by the vendor's private key, verified
offline against a public key in the binary. The professional-software
mainstream: JetBrains offline activation codes, most indie Mac/Windows
software, minisign/signify culturally adjacent, and commercial
license-as-a-service vendors (Keygen.sh — which documents Ed25519-signed
offline license files almost identical in spirit to sigil — Cryptlex,
LicenseSpring) sell exactly this.

How it breaks, in order of real-world frequency:

1. **Casual sharing** — one license file emailed to a friend. Mitigations:
   the license names its owner (social pressure; Mecha does this), machine
   fingerprinting (see node-locking below; Mecha deliberately doesn't),
   activation counting server-side (Mecha's confirmation endpoint could,
   post-beta).
2. **Binary patching** — see the one truth. Mitigation: OS code signing
   (below), scattered/repeated checks (diminishing returns), or acceptance.
3. **Embedded-key substitution** — attacker replaces the public key bytes in
   the binary, then signs their own license. This is binary patching with
   extra steps; same mitigations. It is also why *shipping test keys in
   release binaries is a real hazard*: a demo key with a published
   passphrase is a pre-substituted key. Mecha's demo-key rejection gates
   (artifact scan + functional test) exist for exactly this.
4. **Key theft from the vendor** — the only failure that breaks the crypto
   itself. Mitigations: purpose-separated keys (Mecha: license/update/beta
   split, so one theft doesn't grant everything), key-to-grant-class binding
   in verifiers (the correction recorded in `examples/embed_minimal.c`),
   revocation-by-update (drop the pubkey in the next release), and custody
   discipline (encrypted keyfile, Argon2id, secrets never in git/Nix/logs).

### Online activation and node-locking

Microsoft product activation, Adobe's serial era, most "3 seats" schemes:
the client sends a machine fingerprint (disk serial, MAC, CPU ID, hashed
composite) to an activation server, which returns a machine-bound grant.

Strengths: limits sharing without per-customer builds; enables seat counts
and revocation. Weaknesses: hardware upgrades and reinstalls strand honest
customers (the support burden is legendary); privacy optics; the server
must outlive the product or orphan every customer (a recurring end-of-life
scandal when activation servers for old products are switched off); and the
fingerprint check is still client-side, so crackers bypass it anyway — the
honest customers bear all the friction.

Lesson: Peter already chose person-bound, all-platforms licensing over
machine-binding. That choice trades some sharing leakage for zero hardware
friction and no activation-server lifetime obligation on the critical path.
Keep it. If seat abuse ever becomes measurable, the confirmation endpoint
can add *soft* activation counting (observe, notify, rate-limit resends)
without ever bricking an install.

### Floating license servers

FlexNet/FlexLM (Flexera) and its kin dominate CAD/EDA/engineering: a
customer-hosted daemon holds N seats; clients borrow tokens. Decades of
cracked vendor daemons, emulators, and a documented vulnerability history —
the daemon is just more client-side code, running on hardware the customer
controls. Survives commercially because enterprise customers are contract-
and audit-bound, not because the tech resists attack.

Lesson: enforcement rigor can come from the *relationship* (contracts,
invoices, audits) rather than the *mechanism*. Mecha's individual-customer
market has no such relationship leverage; don't copy this family.

### Hardware tokens

Dongles (Sentinel/HASP, Wibu CodeMeter) move the secret into tamper-resistant
hardware; high-value niche software still uses them. Emulators defeat older
generations; newer ones (encrypting code pages against the dongle key) are
genuinely hard. Costs: per-unit hardware, logistics, customer hatred, and
the vendor SDKs themselves have shipped serious vulnerabilities (CodeMeter's
2020 ICS advisories). On the vendor-side-custody front the same idea appears
as YubiKey/HSM-held signing keys — which is in sigil's provider roadmap and
is the *right* use of hardware: protect the vendor's key, don't tax the
customer.

Lesson: hardware belongs on the signing side (Peter's key custody), never on
the customer side for this market.

### Platform receipts and store DRM

Mac App Store receipts: a signed PKCS#7 file validated on-device against
Apple's root — structurally the same family as sigil (signed document,
offline verify). Notably, Apple's modern StoreKit 2 moved to **JWS-signed
transactions** — the industry's newest mainstream receipt system converged
on exactly the signed-compact-envelope design sigil uses. Steam wraps
executables (CEG) and is routinely cracked; its real retention mechanism is
convenience (cloud saves, updates, friends), not DRM.

Lesson: if Mecha ever ships through an app store, the store's receipt system
*replaces* the license file for that channel (a store build trusts the store
receipt; a direct build trusts the sigil license — two grant sources, one
policy module). And Steam's actual lesson is Mecha's posture (1): the update
channel and support are the retention mechanism, not the lock.

### Server-side gating

The endgame for anything truly critical. Mecha already applies it where it
belongs: issuance (the private key never ships), update manifests (signed
server-side), refund/revocation state (commerce DB is authoritative). The
apps' *scanning work* is local by product design — RotShield protecting data
airgapped is a feature — so full SaaS gating is out of scope by intent, not
oversight.

## Binary integrity: take the free protection

Apple notarization + Gatekeeper and Windows Authenticode mean a *modified*
binary either fails to launch or throws frightening warnings on modern OSes.
That is real, free, OS-enforced anti-tamper for the majority of users — a
patched pirate copy must also strip code signing, which pushes casual users
away. Self-checking beyond that (the binary hashing itself, scattered
checksums) is arms-race territory with poor returns and real false-positive
risk under legitimate conditions (translocation, AV scanners, re-signing by
IT departments). Rely on the OS layer; don't build a second one.

## Revocation and expiry, as practiced

- Perpetual-license vendors overwhelmingly enforce expiry only for
  time-limited grants (trials, betas, subscriptions) and *version ceilings*
  for perpetual ones ("free updates for 1.x") — Mecha's model exactly.
- Offline grace windows (JetBrains subscriptions license the last version
  released before lapse; many vendors tolerate ~30–365 days offline) are
  standard because the alternative — bricking software over a network
  hiccup — is commercially suicidal. Mecha's 365-day offline window and
  fail-open-on-unreachable are inside industry norms, on the generous side.
- Clock rollback: the common defense is a monotonic high-water mark
  (remember the latest time ever seen; refuse times that regress past it),
  which Mecha's plan already records. Nobody solves this perfectly offline;
  the high-water mark is the accepted standard.
- Instant offline revocation is impossible and every honest vendor documents
  the tradeoff rather than pretending otherwise (LICENSE_OPERATIONS.md
  already does).

## Decisions this survey informs

Settled, and consistent with the strongest prior art:

- Signed-document licenses, person-bound, no node-locking, no dongles.
- Purpose- and class-separated keys; verifier binds key identity to grant
  class; test keys denylisted from release artifacts.
- OS code signing as the anti-tamper layer; no obfuscation arms race.
- Fail-open revocation with offline grace + monotonic clock; expiry enforced
  for betas (UTC date contract), version ceiling for paid.

Open, where prior art has a vote:

- **Soft activation telemetry** (post-beta): the confirmation endpoint can
  count activations per license and surface anomalies to Peter without ever
  blocking — the least-hostile point on the node-locking spectrum. Decide
  after real sharing abuse is observed, not before.
- **Trial mechanics**: Peter's open question (signed trial activation vs
  no-server local evaluation). Prior art: local-only trials are trivially
  reset (delete a plist/registry key; crackers automate it) and vendors
  accept that for low-cost products; server-issued signed trial grants (one
  per email/machine) are the standard escalation and reuse the entire
  existing issuance path. The sigil-side machinery is identical either way —
  a trial is just a grant class with a short expiry — so this decision is
  pure commerce policy and can wait.
- **App-store channel**: if it ever happens, receipts become a second grant
  source behind the same policy module; nothing in sigil changes.
