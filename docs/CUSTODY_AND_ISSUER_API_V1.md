# Key custody and issuer API — DRAFT v1.2 for negotiation

Status: PROPOSAL, revised 2026-09-19 after Einstein's reviews of v1 (five
corrections) and v1.1 (four more), all adopted below. The sealed hot
bundle (section 2) and per-product issuer Workers (section 1) are NEW
owner choices this draft introduces, not already-approved work; they are
listed in section 8 as such. Parties: mecha-commerce (issuer, Worker),
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

Recovery assurance, stated per check (v1.2): (i) The end-to-end REHEARSAL
uses the TEST roles ONLY — `keygen` → `hot-bundle open` piped into a
development secret → the Worker issues → native `sigil verify` under the
registry `.pub`. It proves the mechanism works; it proves nothing about
any production key. (ii) Production keys NEVER enter a non-production
Worker or staging environment: that would extend the production trust
boundary. Production restore assurance is two checks: (a) OFFLINE
identity check on the isolated ceremony host — open the sealed hot
bundle from COLD and verify its PKCS#8 public half equals the registry
`.pub`; proves the COLD artifact restores the correct identity, does NOT
prove Worker acceptance; (b) a production-controlled isolated Worker
environment — same account, same secret handling and access controls,
issuance routes disabled, no customer traffic — into which the restored
secret is put, then signs `examples/demo/payload.json`, verified by
native `sigil verify`; proves Worker-side restore of the real key without
any customer issuance. Neither check exercises customer fulfillment; that
is by design.

## 3. Minimizing plaintext persistence (correction 2; reductions, not guarantees)

`shred` is not secure erasure on ZFS, snapshotted, compressed or SSD
storage (GNU documents the assumption); Thelio runs ZFS. The v1 "shred
the PKCS#8" step and its policy exception are WITHDRAWN. Instead, the
plaintext PKCS#8 exists only as a pipe: `sigil hot-bundle open ... |
wrangler secret put ...` (and at generation, `keygen` writes only the two
SEALED artifacts — sigil itself never creates a plaintext file). What
this does and does not prove (v1.2): it removes sigil's own persistent
writes; it does NOT prove that wrangler, the Node runtime, the kernel
(swap), or any logging layer never persists the piped bytes. Ceremony
host requirements are therefore stated as REDUCTIONS, not guarantees:
run on a host with full-disk encryption and no swap configured at the OS
level (an empty `swapon --show` shows no active swap, not that swap is
encrypted), core dumps disabled (`ulimit -c 0`), TMPDIR on tmpfs,
passphrases prompted never typed on a command line, a fresh shell, and
wrangler run with logging at its minimum. A `ceremony --preflight` helper
(OPEN; a script is acceptable) checks what is checkable and prints the
residual assumptions it cannot check, rather than claiming proof.

## 4. The ceremony (PROPOSED, ~10 minutes for five keys)

Preflight (section 3). Then for each role: (1) `randompassdict 6`; record
the passphrase in the COLD locations; (2) `sigil keygen --out ROLE.key
--hot-bundle-out ROLE.hot.sealed` (passphrase prompted twice; both
artifacts sealed; seed wiped); (3) `sigil hot-bundle open ROLE.hot.sealed
| wrangler secret put SIGNING_KEY_<ROLE> --env production` (passphrase
prompted); (4) `sigil pubkey --pubkey ROLE.key.pub --format c` into the
consumer trust set; registry entry with fingerprint. Then the restore
assurance exactly as section 2 splits it, in this order and all
mandatory before any issuance: (i) the TEST-roles-only end-to-end
rehearsal (already done before generation; repeat if tooling changed);
(ii) the OFFLINE production identity check on the isolated ceremony host
(open each sealed hot bundle from COLD, compare the PKCS#8 public half to
the registry .pub); (iii) the separately approved production-controlled
isolated restore (section 2 (ii)(b)) — never a staging or
non-production environment. Record each check's output and its stated
scope in the registry commit.

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

- PLANNED RETIREMENT never removes a pubkey while any grant it signed is
  still within its supported `max_major` — and `max_major` can span
  several major versions, so a major boundary alone proves nothing;
  retirement only stops NEW issuance under the key. DEFAULT: retired
  verification keys stay embedded, role-bound, for ALL still-valid
  supported grants — a customer confirming a replacement hash from one
  install proves nothing about their other Windows/Mac/Linux or offline
  installs, and mail delivery proves nothing at all. Any earlier removal
  is a separate, explicit owner policy decision, never inferred from
  delivery or partial confirmation evidence, and never a forced lockout.
- EMERGENCY COMPROMISE: mint the successor role key; re-issue every active
  entitlement under it from the ledger and deliver through the customer
  channel; ship a release that drops the compromised pubkey. Honest
  limit (v1.2): a client running an old binary keeps both the old trust
  and the attacker's forgeries, and NOTHING here bounds how long —
  fail-open reconfirmation plus an `offline_days` value imposes no hard
  exposure bound. Exposure for a given client ends only when that client
  updates to a release without the pubkey, or receives an authenticated
  response it acts on; both depend on that client's reachability, its
  update behavior, and an actual authenticated response. Forgers were
  never customers; honest customers on old offline binaries are simply
  unaffected by the compromise until they update. The registry records both procedures
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
