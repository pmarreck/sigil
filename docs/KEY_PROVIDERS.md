# Signing provider boundary

## Fixed v1 behavior

The provider port does not build or alter the signed bytes — it signs exactly
what it is handed. Since 2026-08-11 (`PLAN.md` §A, decided and implemented),
what `sign.seal` hands the provider is the **signing transcript**: the fixed
`sigil.transcript.v1` header binding the algorithm and payload length, followed
by the payload bytes verbatim (see `src/transcript.zig`). The transcript is
assembled in `seal`, *above* this boundary, on purpose: if each provider built
its own, a keyfile and a YubiKey could drift into signing subtly different
bytes. `seal` then packages the returned Ed25519 signature in the existing
envelope, whose `data` field carries the raw payload — the header travels in
the signature's coverage, not in the document.

The port consists of an opaque context pointer, one capability record, and one
callback:

```text
sign(context, exact_message_bytes) -> 64-byte signature | classified error
```

There is no private-key return operation. A caller can neither request key
bytes nor supply them to `seal`. This is an API boundary, not an operating
system isolation claim: a malicious process with arbitrary memory access can
inspect its own address space. A real non-exportable guarantee must come from
hardware whose driver performs the callback without releasing the key.

## Provider #1: encrypted keyfile

`EncryptedKeyfileProvider` preserves the existing one-line
Argon2id/XChaCha20-Poly1305 keyfile. Its private context owns decryption, Ed25519
key expansion, signing, and zeroization. The public provider value contains
only opaque pointers and capability metadata. `ffi_sign.zig` no longer imports
or receives the decrypted seed or expanded secret key.

Its declared capability is:

| Field | Value |
|---|---|
| Algorithm | Ed25519 |
| Custody | encrypted keyfile |
| Private-key exposure | provider process memory |
| Availability | ready |

## Honest unavailable-provider semantics

Capability preflight runs before a provider callback. The states and errors
are deliberately separate:

| Condition | Error | Meaning |
|---|---|---|
| Requested algorithm differs from the configured key | `UnsupportedAlgorithm` | The provider cannot sign that algorithm. |
| Hardware provider has no tested driver | `ProviderDriverRequired` | No signing attempt occurred. |
| Signing must occur on an offline host | `ExternalCeremonyRequired` | Export a ceremony request through a future reviewed workflow; no in-process signing occurred. |
| A ready provider callback fails | `ProviderFailure` | The provider attempted the operation and failed. |

The custody vocabulary includes `non_exportable_hardware` and
`offline_ceremony`. This does not claim YubiKey, PIV, PKCS#11, Secure Enclave,
or air-gapped workflow support. A future hardware driver must query the actual
device and declare only the algorithm of its configured key. In particular,
the presence of a PIV interface is not proof that Ed25519 signing is available.

## Still gated on Peter or hardware-backed review

- Versioned and algorithm-tagged signing transcripts (`PLAN.md` §A).
- The wrong-passphrase CLI exit-code contract (`PLAN.md` §C).
- PKCS#11, PIV, Secure Enclave, or other hardware drivers with physical-device
  tests.
- The offline request/response ceremony, replay controls, and operator review.
- Any post-quantum algorithm or hybrid signature.
