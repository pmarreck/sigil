# Key custody and issuer API — DRAFT v1 for negotiation

Status: PROPOSAL, 2026-09-19, by the licensing contract lead. Parties:
mecha-commerce (issuer, Worker), validate / entropy_shield (consumers of
the public keys), Peter (custodian). Nothing here provisions a key;
sections marked OPEN need Peter. Scope stays code/tests/planning until he
performs the ceremony. Prior decisions this builds on: online paid/beta
license keys approved (2026-09-16 22:25 EDT), separate from release/update
signing; contract rev 1.2 role binding; revocation-by-reconfirmation with
a signed attestation (MECHA_RELEASE_PLAN, 2026-07-28); Cloudflare secrets
discipline (CLOUDFLARE_OPERATIONS.md).

## 1. Key roles (PROPOSED)

One Ed25519 keypair per role. Roles are the unit of blast radius: a key
can sign only what its role means, and a consumer refuses everything else
at AUTHENTICITY (the pubkey is simply not embedded) rather than at policy.

| Role | Signs | Custody tier | Who verifies |
|---|---|---|---|
| validate-beta-license | beta grants, product mecha-validate | HOT + COLD | Validate builds (beta pubkey) |
| validate-paid-license | paddle/comp grants, mecha-validate | HOT + COLD | Validate builds |
| rotshield-beta-license | beta grants, mecha-rotshield | HOT + COLD | RotShield builds |
| rotshield-paid-license | paddle/comp grants, mecha-rotshield | HOT + COLD | RotShield builds |
| confirmation | short-dated attestations from the confirmation endpoint | HOT + COLD | both apps (confirmation pubkey) |
| update (per product, later) | release/update manifests | COLD only, attended | updaters |

Per-product split (OPEN — recommend YES): with one paid key for both
products, a wrong-product grant is refused only at policy (`wrong_product`);
with per-product keys it is refused at authenticity. Cost is two extra
keys at ceremony time, nothing at runtime.

Update keys are deliberately excluded from this ceremony: releases are
attended events, so a cold, passphrase-protected keyfile that Peter unlocks
at release time is sufficient and keeps the hot surface to five keys.

## 2. Custody tiers (PROPOSED)

- HOT = the Worker's copy, PKCS#8 (RFC 8410) held ONLY as a Cloudflare
  secret (`wrangler secret put`, value from stdin/file, never argv), one
  secret per role; commerce's `SIGNING_KEYS` map is keyed by role name.
  Never in `wrangler.jsonc`, git, the Nix store, logs, or chat.
- COLD = the sigil encrypted keyfile (Argon2id 64 MiB / t=3 / p=1 →
  XChaCha20-Poly1305) plus its passphrase (`randompassdict 6`, ~98 bits),
  stored in two physically separate places (OPEN — Peter names them, e.g.
  password manager entry + offline medium). COLD is the recovery source;
  HOT is disposable and re-derivable from COLD.
- PUBLIC = `sigil pubkey` text per role, committed to a public
  `KEY_REGISTRY.md` with the SHA-256 fingerprint of each `.pub` and exactly
  which release/version trusts it. Consumers embed from this registry.

## 3. Generating hot and cold from one seed (OPEN — needs a sigil feature)

sigil deliberately has no "open a keyfile and dump the seed" command.
The ceremony needs the SAME seed in both tiers, so the transfer must
happen at generation time only. Proposal: `sigil keygen --out ROLE.key
--pkcs8-out ROLE.pkcs8` writes the encrypted keyfile and, loudly, one
unencrypted PKCS#8 for the hot secret; the seed is wiped after both are
written. The PKCS#8 lives only long enough for `wrangler secret put`, then
is destroyed (`shred`; this is the one place a secret's destruction
outranks the fleet's no-delete rule). Alternative (rejected unless Peter
prefers): generate in WebCrypto and import the seed into a keyfile via a
`keygen --from-pkcs8`; same one-shot property, worse ergonomics.

## 4. The ceremony (PROPOSED script for Peter, ~10 minutes for five keys)

For each role: (1) `randompassdict 6`, write the passphrase into the COLD
location(s); (2) `sigil keygen --out ROLE.key --pkcs8-out ROLE.pkcs8`
(passphrase prompted, entered twice); (3) `wrangler secret put
SIGNING_KEY_<ROLE> < ROLE.pkcs8` for the production environment; (4)
`shred -u ROLE.pkcs8`; (5) `sigil pubkey --pubkey ROLE.key.pub --format c`
into the consumer's trust set and the registry. Then the BACKUP/RESTORE
TEST, mandatory before any issuance: on a clean machine, from COLD only,
unlock each keyfile and sign `examples/demo/payload.json`; the signature
must verify under the registry's `.pub` with native `sigil verify`. Record
fingerprints and the test's output in the registry commit.

## 5. Issuer API bounds (PROPOSED, binding on mecha-commerce)

- The ONLY signing entrypoint is `issueForEntitlement(entitlement_id)`.
  The Worker never exposes "sign these bytes"; there is no signing oracle,
  not even behind auth. Payload fields come from the durable ledger and
  the server-owned catalog, never from a request body or browser claim.
- Role is derived from `payment_provider` + `product` and must match the
  entitlement's class; mismatch is a hard refusal (already implemented at
  commerce 304b391 for the class half; add the product half with
  per-product keys).
- Idempotent: the same entitlement always yields the same stored envelope;
  a resend returns the stored bytes and never re-mints (a beta clock never
  restarts). Superseding grants (explicit extension, upgrade) are new
  entitlements, audited as such.
- Every issuance is logged by entitlement id + envelope SHA-256 + role +
  time; never the envelope, the email, or the name.
- Rate-limited per entitlement and per caller; no bulk endpoint except the
  audited beta command.

## 6. Confirmation endpoint bounds (PROPOSED)

Input: a license envelope SHA-256 (the app hashes its stored grant) plus
product and app version. The Worker looks the hash up in the refund/
chargeback ledger and returns a short-dated sigil envelope signed by the
`confirmation` key: `{license_sha256, status: "active"|"revoked",
issued_at, expires_at}` with `expires_at` = `issued_at + offline_days`.
It must NOT: mint or extend any license; reveal ledger fields beyond
status; accept anything but a hash (no envelope upload, so a stolen
license cannot be fished). Client semantics stay as decided: fail OPEN on
unreachable/TLS/5xx, fail CLOSED only on an authenticated `revoked`, with
a visible grace period after the window lapses.

## 7. Rotation and compromise (PROPOSED)

- Planned rotation = rotation-by-update: mint the successor role key, ship
  a release embedding BOTH pubkeys (role-bound, per rev 1.1), switch the
  Worker secret, retire the old pubkey one release later.
- Suspected compromise = drop the pubkey in the next release and re-issue
  every affected active entitlement under the successor key from the
  ledger; the ledger, not the key, is the authority on who is entitled.
  Beta keys are the likeliest leak and the cheapest to rotate.
- The registry records every rotation with dates and release versions.

## 8. What Peter decides (OPEN)

(a) per-product license keys (recommend yes); (b) the `keygen
--pkcs8-out` feature (recommend yes; sigil implements it before the
ceremony, with a unit test that the PKCS#8 public half equals the .pub);
(c) COLD locations; (d) update keys cold/attended (recommend yes, deferred
until the release publisher exists); (e) whether the confirmation key is
separate from license keys (recommend yes — an attestation must never be
mistakable for a grant).
