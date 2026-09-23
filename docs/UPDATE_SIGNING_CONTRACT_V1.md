# Update signing, manifest verification, rotation and anti-rollback — contract v1

Owner: sigil (licensing/signing contract lead), per Peter's 2026-09-23
request for a shared cut-release and self-update workflow for both Mecha
apps. This contract covers ONLY the signing domain: what an updater may
trust and why. Release pipeline mechanics, artifact hosting, difz
policy and platform adapters stay where they already are:
`~/Code/validate_gui/docs/MECHA_VALIDATE_RELEASE_RUNBOOK.md` (sections
Artifact hosting, Release pipeline, Full-artifact self-update, difz delta
policy) and `~/Code/validate_gui/docs/self-update-design.md`. Nothing
here authorizes a key ceremony, deployment, DNS, spending, real signing
or customer mail.

## 1. What exists (with locations)

- Purpose-separated update trust, enforced by construction and CI:
  sigil `tests/integration/update_vectors.sh` proves a license offered
  to the update key and an update manifest offered to the license key
  both fail at SIGNATURE (both directions). Vectors:
  `examples/update_vectors/` (test-only update key; valid, tampered
  payload, tampered signature, wrong key; and, as of this contract,
  rollback, equivocation and updater-too-old, all AUTHENTIC, with
  expected decisions in `examples/update_vectors/manifest.json`).
- Manifest schema `mecha-update/v1` (`manifest_valid.json`): schema,
  product, channel, sequence, version, build_id, published_at,
  expires_at, minimum_updater_version, targets[] {platform,
  architecture, full{url, sha256, bytes}, deltas[]{source_sha256,
  format, url, sha256, bytes}}.
- Verify-before-parse and byte-identical payload out (sigil core), so
  the updater hashes exactly the bytes that were signed.
- validate_gui: strict signed-manifest parser and rollback/equivocation
  rules designed (`docs/self-update-design.md` — the (sequence, exact
  payload sha256) stored pair; lower = rollback, equal+equal =
  idempotent, equal+different = equivocation, higher = evaluate) and,
  per the runbook's ownership table, implemented for the envelope and
  parser; the HTTP updater, install helpers and platform signing are
  listed there as gaps.
- difz: file and directory patches bind source and target BLAKE3
  identities and verify the reconstruction before success
  (`~/Code/difz/PLAN.md`).
- Custody: update keys are COLD and attended, per product, excluded from
  the license ceremony (`docs/CUSTODY_AND_ISSUER_API_V1.md` section 1).
- entropy_shield (RotShield): NO self-update work exists yet; its
  "Update" is a protection feature, not self-update.

## 2. Contract — manifest verification (binding on both updaters)

1. The updater embeds exactly one update public key per (product,
   channel) trust set; nothing else may verify a manifest.
2. Verify the sigil envelope BEFORE parsing; parse the exact returned
   bytes; reject on any schema, type or unknown-field error; require
   `schema == "mecha-update/v1"` and `product`, `channel` equal to the
   updater's own; select the exact (platform, architecture) target or
   refuse.
3. `sha256` is the sole authority for every artifact and delta; `url`
   is a hint (content-addressed paths are a convention, not trust);
   `bytes` is checked before hashing. `full.sha256` is the DOWNLOAD
   package identity; the optional `full.installed_sha256` (ruled
   2026-09-23, additive in v1 since nothing has shipped) is the
   INSTALLED payload identity, which is what `deltas[].source_sha256`
   refers to on platforms where package and installed bytes differ
   (Windows). `deltas[].format` is an opaque token matched exactly;
   the launch token is difz's stable format name (to be frozen by
   validate_gui/difz; fixtures updated then). A reconstructed delta target is
   verified against the manifest's FULL `sha256` — the signed manifest,
   not the patch, is the authority on what got installed.
4. Freshness: `now > expires_at` is a STALE manifest: never install,
   never replace the last accepted manifest, never advance the stored
   sequence. (`manifest_valid.json` itself is stale by wall clock,
   which is why updaters inject `now`.)
5. `minimum_updater_version` greater than the running updater refuses
   without advancing stored state (the app needs a full update first).

## 3. Contract — anti-rollback

- Persist per (product, channel) the pair (accepted sequence, sha256 of
  the exact verified payload bytes). Compare every verified manifest to
  it: lower sequence = ROLLBACK, refuse; equal sequence + equal digest =
  already accepted (idempotent); equal sequence + different digest =
  EQUIVOCATION, refuse with a security-class warning and keep the last
  accepted manifest; higher = evaluate sections 2/4. Malformed stored
  state (not 64 lowercase hex, sequence 0) is treated as absent and
  reported, never as authorization.
- Immutable publication: `manifests/<channel>/SEQUENCE.sigil` is never
  rewritten; the channel pointer is not trust (a stale pointer means "no
  update", never "downgrade"). A channel switch is an explicit user
  action starting from the new channel's own stored pair.
- The stored pair advances only after the full section 2 checks pass
  and the install transaction is durably staged, never on discovery.

## 4. Contract — deltas

A delta is trusted only through the signed sequence manifest that lists
it (source_sha256, format, sha256, bytes) and, always, through the
reconstructed target matching the manifest's full sha256. Consequence:
a regenerated patch whose bytes differ is NOT covered by any existing
manifest and must not be served under the old descriptor. Two
compliant shapes, OPEN for Peter: (a) precompute deltas at cut time
only and sign them inside the sequence manifest; evicted pairs fall
back to the full artifact and are never regenerated; or (b) allow
background regeneration with a separate signed delta descriptor
(`mecha-delta/v1`: product, channel, target_sha256, source_sha256,
patch_sha256, bytes, format) signed by a DELTA role key that may be hot
— its blast radius is bounded because the client still verifies the
reconstructed target against the sequence manifest's full sha256, so a
forged descriptor can at worst cause a failed reconstruction and a
fallback to the full artifact. The patch worker never holds any key;
descriptor signing is a separate step. RULED 2026-09-23 (lead; Peter may
override): (a) for v1 — a regenerated patch is served only if its bytes
hash-equal an already-signed descriptor, else the full artifact; deltas
are a pure cache with no new key and no new client trust. Conditions:
regeneration uses the exact difz binary and parameters of cut time
(publisher pins the difz artifact hash beside the descriptor) so a difz
upgrade cannot silently defeat the cache; inequality is a counted miss,
never a retry loop. (b) stays OPEN for Peter if misses become
measurable. difz's internal BLAKE3 source/target binding remains an
independent second check inside the patch.

## 5. Contract — rotation and compromise (update keys)

- Planned rotation: a bridge release, signed by the OLD key, embeds
  both old and new update public keys; subsequent manifests are signed
  by the new key; the following release drops the old key. Sequence
  numbering continues monotonically across the rotation; the stored
  pair is unaffected. No manifest is ever re-signed under a new key
  with an already-used sequence (that would be equivocation).
- Compromise of an update key is the worst case in this design: any
  client trusting it will accept a signed malicious manifest. Honest
  limits and mitigations: (i) custody — cold, attended, never online;
  (ii) the platform's native code signature (notarization,
  Authenticode) is a SECOND, independent authority the attacker does
  not hold, and updaters must require both before install (the runbook
  already requires native verification); (iii) recovery = a bridge
  release under the compromised key is impossible to trust, so
  recovery is out-of-band reinstall from the public site with the new
  key embedded, plus revocation of the old key in every later build.
  Nothing bounds how long an un-updated client keeps the old trust.

## 6. Gaps and owned work

- validate_gui: HTTP discovery with backoff; install transaction and
  platform adapters (macOS bundle verification, Windows in-use
  replacement, Nix/package-managed delegation); production update key
  embedding after its ceremony; consume `examples/update_vectors/
  manifest.json` as the acceptance spec.
- entropy_shield: everything above from scratch, sharing the same
  contract and vectors; nothing exists yet.
- Release tooling: the `./release` command set described in the runbook
  (measure, manifest from uploaded objects, sign through sigil, upload
  immutable sequence manifest, promote pointer last, receipt) — existing
  implementation status to be confirmed by validate_gui.
- sigil: vectors shipped with this contract; a `mecha-delta/v1`
  descriptor vector set only if Peter picks shape (b).
- Peter: delta shape (a)/(b); update-key ceremony (separate from
  license keys); artifact home (R2/CDN) and retention per the runbook.

## 7. Contract questions

1. Delta regeneration shape (a) vs (b) (section 4).
2. Is `expires_at` a hard refusal for INSTALL only, or also for
   "already installed" health confirmation? (Proposed: install only.)
3. Channel switching semantics for a client moving beta -> stable:
   confirm "explicit user action, new channel's own stored pair".
4. RotShield: same manifest schema and channel names, or a separate
   product namespace with its own sequence? (Proposed: same schema,
   product `mecha-rotshield`, independent sequence per product+channel.)
