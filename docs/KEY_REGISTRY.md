# Key registry (public)

Public keys only. One row per signing role, with the `.pub` file's SHA-256,
the key's raw 32-byte fingerprint in hex (`sigil pubkey --pubkey ROLE.key.pub
--format hex`), when and from which sigil commit it was generated, and which
release trusts it. A row is added in the ceremony commit together with the
outputs of the restore-assurance checks and the residual assumptions the
preflight printed. Retired keys stay listed (retired, with the date) while
any grant they signed is still valid.

## Production roles

| Role | Product | Fingerprint (hex) | .pub sha256 | Generated | Trusted by | Status |
|---|---|---|---|---|---|---|
| validate-beta-license | mecha-validate | — | — | not yet generated | — | pending ceremony |
| validate-paid-license | mecha-validate | — | — | not yet generated | — | pending ceremony |
| install-cert-validate | mecha-validate | — | — | not yet generated | — | pending ceremony (beta-critical) |
| install-cert-rotshield | mecha-rotshield | — | — | not yet generated | — | pending (RotShield launch) |
| rotshield-beta-license | mecha-rotshield | — | — | not yet generated | — | pending ceremony |
| rotshield-paid-license | mecha-rotshield | — | — | not yet generated | — | pending ceremony |
| validate-trial-license | mecha-validate | — | — | not yet generated | — | pending (trial class not built; optional at the first ceremony) |
| rotshield-trial-license | mecha-rotshield | — | — | not yet generated | — | pending (RotShield launch) |
| confirmation | both | — | — | not yet generated | — | pending (endpoint not built) |
| update (per product+channel) | both | — | — | not yet generated | — | deferred until the release publisher exists |

## Test roles (TEST ONLY; release acceptance byte-scans these OUT of every shipped artifact)

| Role | .pub sha256 | Passphrase (public by design) | Where |
|---|---|---|---|
| test-beta | 5683efb3e745a406d8531c6aa4558b77c4a311bd1fcd099f973612ef4b45f8b2 | test-beta-not-for-production | examples/license_vectors/test_beta.key.pub |
| test-paid | 8125b9b1726e6fe02d0523234f41a7dacf82ea9d6fbac99d03199583be459b98 | test-paid-not-for-production | examples/license_vectors/test_paid.key.pub |
| test-install-cert | 00f5dc63fe1c3f8a47563ff0de0cbf605abef009f3a97243cc9c1eedc0f1f7be | test-install-cert-not-for-production | examples/install_cert_vectors/test_install_cert.key.pub |
| update-test | see examples/update_vectors/update_test.key.pub | update-test-not-for-production | examples/update_vectors/ |
| demo | see examples/demo/demo.key.pub | demo-not-for-production | examples/demo/ |
