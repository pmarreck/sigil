# Key custody and issuer API — DRAFT v1.1 for negotiation

Status: PROPOSAL, revised 2026-09-19 after Einstein's review of v1 (five
corrections, all adopted below). Parties: mecha-commerce (issuer, Worker),
validate / entropy_shield (consumers of public keys), Peter (custodian).
Nothing here provisions a key; sections marked OPEN need Peter. Scope stays
code/tests/planning until he performs the ceremony. Builds on: online
paid/beta license keys approved (2026-09-16 22:25 EDT), separate from
release/update signing; contract rev 1.2 role binding; revocation-by-
reconfirmation with a signed attestation (MECHA_RELEASE_PLAN, decided
2026-07-28); Cloudflare secrets discipline (CLOUDFLARE_OPERATIONS.md).

## 1. Key roles (PROPOSED)

One Ed25519 keypair per role.

| Role | Signs | Custody | Who verifies |
|---|---|---|---|
| validate-beta-license | beta grants, mecha-validate | HOT + COLD | Validate builds |
| validate-paid-license | paddle/comp grants, mecha-validate | HOT + COLD | Validate builds |
| rotshield-beta-license | beta grants, mecha-rotshield | HOT + COLD | RotShield builds |
| rotshield-paid-license | paddle/comp grants, mecha-rotshield | HOT + COLD | RotShield builds |
| confirmation | short-dated attestations (see 6) | HOT + COLD, own Worker | both apps |
| update (per product, later) | release/update manifests | COLD only, attended | updaters |

What the split does and does not buy (correction 4): per-product keys make
CROSS-PRODUCT misuse fail at authenticity (the other product never embeds
the key). SAME-PRODUCT class confusion (a paid payload signed by the beta
key) is still caught only by the role/class policy binding of contract
rev 1.1 section 4 — that check remains mandatory in every verifier and is
not made redundant by anything here. Five secrets inside one Worker do
not isolate a whole-Worker compromise: an attacker with the Worker's
secret store has every hot license key. The actual limit of the hot tier
is therefore: a Worker compromise is recoverable by re-issuance from the
ledger under successor keys plus a release that drops the old pubkeys
(section 7); it is not prevented by secret separation. To shrink blast
radius by Worker, the `confirmation` key lives in its OWN Worker (an
attestation signer must not share a compromise domain with grant
issuers); per-product issuer Workers are OPEN — cost is operational, not
technical.

Per-product split (OPEN — recommend yes) and update keys excluded from
this ceremony (cold, attended, deferred until the release publisher
exists) are unchanged from v1.

## 2. Custody tiers (PROPOSED, corrected for recovery)

- HOT = the Worker's copy: PKCS#8 (RFC 8410) held only as a Cloudflare
  secret (`wrangler secret put` reading stdin, never argv), one secret per
  role. Never in `wrangler.jsonc`, git, the Nix store, logs, or chat.
- COLD = TWO artifacts per role, produced together at generation time
  from one seed, both sealed under the role's passphrase (`randompassdict
  6`, ~98 bits) with sigil's keyfile sealing (Argon2id 64 MiB / t=3 / p=1
  → XChaCha20-Poly1305):
  (i) `ROLE.key` — the sigil keyfile, for attended sigil-native signing;
  (ii) `ROLE.hot.sealed` — the sealed PKCS#8 "hot bundle", whose ONLY
  purpose is restore-to-online. sigil gains `hot-bundle open
  ROLE.hot.sealed` which writes the plaintext PKCS#8 to STDOUT and
  nothing else, for piping straight into `wrangler secret put`. This is
  a purpose-specific recovery artifact created at generation, NOT a
  generic export from keyfiles; `ROLE.key` still cannot be opened into a
  seed by any command. (Correction 1; OPEN — needs Peter's approval
  together with `keygen --hot-bundle-out`.)
  Stored in two physically separate places (OPEN — Peter names them).
- PUBLIC = `sigil pubkey` text per role in a public `KEY_REGISTRY.md`
  with each `.pub`'s SHA-256 and exactly which release trusts it.

Recovery is proven, not assumed (correction 1): the ceremony REHEARSAL
uses the TEST roles end to end — `keygen` → `hot-bundle open` piped into
a development-environment secret → the Worker issues a license → native
`sigil verify` under the registry `.pub` — before any production key is
generated, and the same drill is repeated with production COLD artifacts
against a non-production Worker environment as the backup/restore test.

## 3. Plaintext never touches persistent storage (correction 2)

`shred` is not secure erasure on ZFS, snapshotted, compressed or SSD
storage (GNU documents the assumption); Thelio runs ZFS. The v1 "shred
the PKCS#8" step and its policy exception are WITHDRAWN. Instead, the
plaintext PKCS#8 exists only as a pipe: `sigil hot-bundle open ... |
wrangler secret put ...` (and at generation, `keygen` writes only the two
SEALED artifacts — no plaintext file is ever created). Ceremony host
requirements: swap off or encrypted (`swapon --show` empty), core dumps
disabled (`ulimit -c 0`), TMPDIR on tmpfs, no shell history capture of
passphrases (they are prompted, never typed on a command line), and the
session run from a fresh shell. These are checked by a `sigil ceremony
--preflight` helper (OPEN feature; a script is acceptable) that refuses
to proceed when any check fails.

## 4. The ceremony (PROPOSED, ~10 minutes for five keys)

Preflight (section 3). Then for each role: (1) `randompassdict 6`; record
the passphrase in the COLD locations; (2) `sigil keygen --out ROLE.key
--hot-bundle-out ROLE.hot.sealed` (passphrase prompted twice; both
artifacts sealed; seed wiped); (3) `sigil hot-bundle open ROLE.hot.sealed
| wrangler secret put SIGNING_KEY_<ROLE> --env production` (passphrase
prompted); (4) `sigil pubkey --pubkey ROLE.key.pub --format c` into the
consumer trust set; registry entry with fingerprint. Then the
BACKUP/RESTORE TEST from COLD only, on a clean machine, into a
non-production Worker environment, ending in a native `sigil verify` of
a Worker-issued envelope — mandatory before any issuance. Record the
drill's output in the registry commit.

## 5. Issuer API bounds (PROPOSED, binding on mecha-commerce)

- The ONLY signing entrypoint is `issueForEntitlement(entitlement_id)`.
  No route signs caller-supplied bytes, even behind auth. Payload fields
  come from the durable ledger and the server-owned catalog, never from a
  request body or browser claim.
- Role is derived from `payment_provider` + `product` and must match the
  entitlement's class and product; mismatch is a hard refusal.
- Idempotent: the same entitlement always yields the same stored
  envelope; resend returns stored bytes and never re-mints; superseding
  grants (extension, upgrade, re-issue under a successor key) are new,
  audited entitlements linked to the original.
- Issuance audit log = entitlement id + envelope SHA-256 + role + time;
  never the envelope, email or name.
- Rate-limited per entitlement and caller; no bulk path except the
  audited beta command.

## 6. Confirmation endpoint bounds (PROPOSED, scope per correction 5)

Prior approval and cadence: the endpoint, its triggers (version change or
`offline_days` elapsed) and fail-open semantics were decided in
MECHA_RELEASE_PLAN on 2026-07-28 (License revocation) and listed as
shared-infrastructure item 8. This draft adds NO new traffic or cadence;
it only bounds the key and the message. Privacy stays as decided there
and in the telemetry policy: the request carries a license SHA-256,
product and app version only; no PII; IPs stripped at the CDN.

The attestation is a sigil envelope signed by the `confirmation` role
(a distinct key in its own Worker, so no grant verifier can ever accept
an attestation as a grant, and vice versa) with payload
`{schema:"mecha-confirmation/v1", license_sha256, product, status,
issued_at, expires_at}`. Binding: purpose by schema + role key; identity
by `license_sha256` which the client must compare to its own stored
grant's hash; freshness by `issued_at`/`expires_at` with `expires_at =
issued_at + offline_days`, and the client rejects an attestation whose
`issued_at` is older than its last accepted one (replay). `status` is
one of `active` | `revoked` | `unknown`. An UNKNOWN hash (not in the
ledger) yields `unknown`, which the client treats exactly like an
unreachable server — fail OPEN — never as revoked; only an authenticated
`revoked` closes. The endpoint must not mint, extend, or return any
ledger field beyond `status`.

## 7. Retirement vs compromise (PROPOSED, corrected)

Two different procedures (correction 3):

- PLANNED RETIREMENT never removes a pubkey while any grant it signed can
  still be valid. Paid grants are perpetual within `max_major`, so a
  retired license key's pubkey stays embedded, role-bound, for the life
  of that major version; retirement only stops NEW issuance under it.
  Removal is allowed at a major-version boundary (old grants are outside
  `max_major` anyway) or once the ledger shows every grant it signed has
  been re-issued AND delivered (resend confirmation), whichever first.
- EMERGENCY COMPROMISE: mint the successor role key; re-issue every active
  entitlement under it from the ledger and deliver through the customer
  channel; ship a release that drops the compromised pubkey. Honest
  limit: clients that never update keep both the old trust and the
  attacker's forgeries — automatic online revocation cannot constrain an
  old offline binary; the update-on-version-change trigger and the
  `offline_days` window bound how long that lasts for honest customers,
  and forgers were never customers. The registry records both procedures
  with dates and versions.

## 8. What Peter decides (OPEN)

(a) per-product license keys (recommend yes); (b) the paired `keygen
--hot-bundle-out` / `hot-bundle open` feature — a purpose-specific,
sealed, generation-time recovery artifact rather than any export from
keyfiles (recommend yes; implemented TDD with tests that the opened
PKCS#8's public half equals the .pub and that `ROLE.key` alone still
cannot be opened into a seed); (c) COLD locations; (d) update keys cold
and attended, deferred (recommend yes); (e) the confirmation key separate
AND in its own Worker (recommend yes; no new confirmation traffic is
implied — cadence is the 2026-07-28 decision); (f) per-product issuer
Workers (optional; cost is operational).
