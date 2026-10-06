# Key ceremony v1: the shortest path to a licensed October 15 beta

Status: runbook, 2026-09-29; role inventory and session checklist 2026-10-06. Authority: only Peter runs it, on his say-so;
nothing here generates a production secret until he does. Custody terms are
`docs/CUSTODY_AND_ISSUER_API_V1.md` v1.3 (decided 2026-09-28); this file is
the executable order of operations plus what remains his alone.

## 0. What the October 15 beta actually needs

TWO online production keys: `validate-beta-license` (signs beta and alpha
grants, class `beta`, mandatory `expiry`) and `install-cert-validate`
(signs installation certificates; required for every phase, the beta
included, per Peter 2026-10-01 15:41 EDT). The paid key is not needed until sales open; the RotShield keys not
until RotShield ships; the confirmation key not until the confirmation
endpoint exists. Because a second ceremony costs a second isolated session,
the recommendation is to generate `validate-beta-license`,
`install-cert-validate` AND `validate-paid-license` in one sitting and
provision ONLY the first two secrets to the Worker now. Everything else stays cold.

## 0a. Role inventory (2026-10-06, Peter's walking brief H1)

Every signing role the contract names today. "Generate now" is the
recommendation for the attended session; Peter decides at the session.

| Role | Product | Signs | Needed by | Custody after the session | Generate now? |
|---|---|---|---|---|---|
| validate-beta-license | mecha-validate | beta and alpha grants (class `beta`) | Oct 15 beta | online Worker secret + 2 cold copies | YES |
| install-cert-validate | mecha-validate | installation certificates (§15) | Oct 15 beta | online Worker secret + 2 cold copies | YES |
| validate-paid-license | mecha-validate | paid grants: plastic now, concrete (payload v2) later | paid launch | cold only | YES (saves a second session) |
| validate-trial-license | mecha-validate | free trial grants (§14.2) | trial launch; trial class not built yet | cold only | OPTIONAL, Peter's call |
| rotshield-beta-license, rotshield-paid-license, install-cert-rotshield, rotshield-trial-license | mecha-rotshield | as the Validate rows | RotShield launch | not generated | no |
| confirmation | both | hash-only confirmation responses | endpoint not built | not generated | no |
| update (per product and channel) | both | release descriptors | release publisher | not generated | no |

Not signing roles, and never generated in a ceremony: the trial-meter MAC
key (app-embedded, §14.2), device hints (§15.1, hashes only) and the five
TEST roles in `KEY_REGISTRY.md`.

## 0b. Attended-session checklist (about 30 minutes for three keys)

Peter brings, decided before the session starts:

- [ ] The ceremony host: a machine with Nix and this repo, offline-capable.
      Full-disk encryption on, swap off or encrypted.
- [ ] Two cold media on different physical devices, and where each will
      live afterwards (§5 item 1).
- [ ] A printer for the paper copies. The pages hold only sealed,
      passphrase-encrypted bytes, so the print path sees nothing usable.
- [ ] Commerce's production Cloudflare account logged in for `wrangler`, and
      commerce's confirmation that the production Worker exists to hold
      `SIGNING_KEY_<ROLE>`. If it does not exist yet, step 2.5 waits: the
      keys stay cold and the hot bundle allows a later put without a second
      ceremony.
- [ ] `randompassdict` on the host, and paper or the cold media for writing
      each passphrase by hand.
- [ ] Decision: three keys, or four with `validate-trial-license`.

sigil provides beforehand: a CI-passing sigil commit to build from, a green
`./ceremony-preflight --rehearse` on that commit (last run 2026-10-06 on
thelio: 20 ok, 0 failed, hex paper read back by poppler, zbar, basenc and
xxd), and fresh paper samples for Peter's visual approval (I2).

During the session, in order: preflight with `--media A --media B
--rehearse --strict` on the ceremony host; then section 2 for each role;
online put only for the beta and install-cert roles; registry commit with
the residual assumptions the preflight printed.

After the session: `.pub` files handed to validate and commerce; Peter
approves the isolated restore (§3 (iii)); Peter authorizes the founder
license send (§4).

## 1. Preflight (Peter, ~5 minutes, any day before; repeat on the day)

```
./build                                  # from a committed, CI-passing sigil
./ceremony-preflight --media /path/A --media /path/B --rehearse --strict
```

Green means: tooling present, no swap, core dumps off, TMPDIR in RAM, two
media on different devices, and the full path (keygen, hot bundle, openssl
identity check, sign/verify, paper read back by poppler and zbar, negative
controls) passed on throwaway TEST keys that were then wiped. It prints the
residual assumptions it cannot check; those go into the registry commit as
stated assumptions. Anything red stops the ceremony.

## 2. The ceremony (Peter, ~15 minutes for three keys)

On the prepared host, fresh shell, `ulimit -c 0`, offline except for step 5.
For each ROLE in `validate-beta-license`, `install-cert-validate`,
`validate-paid-license`:

1. `randompassdict 6`, written by hand into BOTH cold media (never typed on
   a command line; sigil prompts for it, twice).
2. `sigil keygen --out ROLE.key --hot-bundle-out ROLE.hot.sealed`
   (writes the sealed keyfile, the sealed hot bundle, `ROLE.key.pub`).
3. `sigil paper --key ROLE.key --hot-bundle ROLE.hot.sealed --pubkey
   ROLE.key.pub --label "Mecha Validate ROLE (production)" --out ROLE.pdf`;
   print it; scan the QR with a phone to see it reads; store the printout
   with medium A. Copy `ROLE.key`, `ROLE.hot.sealed`, `ROLE.pdf` to BOTH
   media. Keep `ROLE.key.pub` for the registry.
4. Identity check, offline (custody 2 (ii)(a)):
   `sigil hot-bundle open ROLE.hot.sealed | openssl pkey -pubout -outform DER
   | tail -c 32 | od -An -tx1` must equal
   `sigil pubkey --pubkey ROLE.key.pub --format hex`. Record both.
5. Beta and install-cert roles only, the online step (commerce's account,
   production environment, nothing else): `sigil hot-bundle open
   ROLE.hot.sealed | wrangler secret put SIGNING_KEY_<ROLE> --env
   production`. Never to a file. The paid key stays cold.
6. Registry: add the row to `docs/KEY_REGISTRY.md` with fingerprint, `.pub`
   sha256 (`sha256sum ROLE.key.pub`), date, sigil commit, and paste the
   preflight's residual-assumption list into the commit message. Commit and
   push. Then hand `ROLE.key.pub` to validate (embed via `sigil pubkey
   --format zig`) and to commerce (`/pubkeys`).
7. Wipe the working directory (it held only sealed artifacts and the .pub).

## 3. Production restore assurance (mandatory before any issuance)

- (i) TEST-roles rehearsal: done by `--rehearse` in step 1; repeat if any
  tooling changed since.
- (ii) OFFLINE identity check: step 2.4, both keys.
- (iii) Production-controlled isolated restore (custody 2 (ii)(b)): a
  production-account Worker environment with issuance routes disabled and no
  customer traffic; the restored secret signs `examples/demo/payload.json`;
  verified by native `sigil verify` under the registry `.pub`. Commerce
  builds the environment; Peter runs the put; sigil verifies the output.
  Separately approved by Peter; never staging.

## 4. Production-trust positive control (the gate nothing has passed yet)

Every acceptance so far is test trust. The control that makes a release
clearable: validate's PRODUCTION artifact (embedding the registry `.pub`)
imports a REAL beta license that commerce's production Worker issued with
the real key, and performs a licensed scan; the red team verifies the
license under the registry `.pub` with native `sigil verify` and re-runs the
E2 pair on that artifact. Concretely: commerce issues one founder license to
Peter's own address (his explicit real-send authorization), Peter imports it
in the GUI and the CLI, and the artifacts and evidence are nominated per
contract §12 with trust domain `production`.

## 5. Exactly what remains Peter's (nothing else can substitute)

1. Choose and name the two cold media, and where they live afterwards.
2. Run the preflight and the ceremony (sections 1 and 2): ~15 minutes.
3. Provision the two online secrets with `wrangler secret put` (step 2.5).
4. DONE: the durable ledger is a Durable Object (Peter 2026-10-01,
   reconfirmed 2026-10-02). It is beta-critical (custody section 5), and
   commerce owns the adapter.
5. Approve the production-controlled isolated restore (section 3 (iii)).
6. Authorize the first real send: the founder license to himself
   (section 4), then the beta invitations.
7. Confirm the expiry wording (section 6) or change it explicitly.
8. The mecha_policy Mechatron webhook (one sudo one-liner, unrelated to keys).

## 6. Expiry: the approved contract, executed

Approved (2026-08-27 decision, UTC contract 2026-09-17): beta `expiry` =
`purchase_date` + 1 calendar month, end-of-month clamped, UTC, day-inclusive.
Dry-run executed 2026-09-29 with a payload signed under the test-beta key and
evaluated by `mecha-policy decide` (product mecha-validate, app major 1):

| Minted (UTC) | expiry | authorized through | first refused (UTC) | in EST |
|---|---|---|---|---|
| 2026-10-15 | 2026-11-15 | 2026-11-15 | 2026-11-16 00:00 | 2026-11-15 19:00 |
| 2026-10-31 | 2026-11-30 | 2026-11-30 | 2026-12-01 00:00 | 2026-11-30 19:00 |

Evaluated: 10-14 authorized (no not-before), 10-15, 11-14, 11-15 authorized;
11-16 and 12-14 expired. LPM's "November 14 midnight EST" is
2026-11-14T05:00Z, which is not a date boundary the frozen payload can
express, and "60 days" from 10-15 would be 12-14; both differ from the
approved contract and from what commerce mints. No new semantics are adopted
here. If Peter wants a cohort-wide fixed end date instead, the payload can
carry it (`expiry` is any date) but the mint rule changes and he must say so.

## 7. Milestones (coordination targets, not customer-policy approvals)

| Date | Owner | Deliverable |
|---|---|---|
| Oct 2 (SLIPPED) | Peter + sigil | preflight green with `--rehearse --strict` on the ceremony host; ceremony scheduled. Rehearsal re-run green on thelio 2026-10-06; the strict run waits for the host and media |
| Oct 2-5 (SLIPPED) | Peter | ceremony (section 2) |
| by Oct 9 (revised 2026-10-06) | Peter + sigil | attended session per section 0b; registry rows pushed; `.pub` handed to validate and commerce. The Oct 7 production-trust control needs the production key, so it moves to just after the session; later than Oct 9 squeezes the Oct 12 recovery rehearsal |
| Oct 5 | validate_gui + validate | staged licensing: GUI import/status/About against the accepted core (569808119 or later), test trust; validate production build embeds the registry `.pub` |
| Oct 7 | commerce + validate_gui | native artifact download, import, licensed scan on a hosted build; production-trust positive control (section 4) with the founder license |
| Oct 12 | commerce + Peter | invitation dry-run previews (section 6 table), recovery rehearsal: cold copy -> `hot-bundle open` -> isolated restore (section 3 (iii)) |
| Oct 15 | commerce + Peter | invitations and downloads |
