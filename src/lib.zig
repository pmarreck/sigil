//! sigil — verify Ed25519-signed documents whose payload stays human-scannable.
//!
//! This is the importable Zig module and the whole public surface for embedders.
//! It contains NO C exports; those live in `ffi.zig`, which is the root of the
//! static library. Keeping them apart means a Zig consumer that imports `sigil`
//! emits no `sigil_*` symbols and so cannot collide at link time with another
//! static library, and means this module never needs libc.
//!
//! Envelope (transport only, never signed):
//!   {"data":"<printable-binary of payload>","sigtype":"Ed25519",
//!    "sig":"<printable-binary of raw signature>"}
//!
//! THE ONE INVARIANT: the signature covers the payload bytes EXACTLY as given.
//! sigil never canonicalizes, re-orders, or re-serializes. Corollary: verify
//! BEFORE parsing — never interpret bytes you have not authenticated.

const core = @import("verify.zig");
const envelope = @import("envelope.zig");

// ── The Ed25519 primitive ───────────────────────────────────────────────────

pub const public_key_len = core.public_key_len;
pub const signature_len = core.signature_len;
pub const Error = core.Error;
pub const verify = core.verify;

// ── The JSON envelope ───────────────────────────────────────────────────────

pub const EnvelopeError = envelope.EnvelopeError;
pub const VerifyEnvelopeError = envelope.VerifyEnvelopeError;
pub const sigtype = envelope.sigtype;

/// Verify an envelope and return its AUTHENTICATED payload bytes.
pub const verifyEnvelope = envelope.verifyEnvelope;

/// Serialize an already-signed payload into the envelope. Holds no key
/// material: it cannot sign, only package.
pub const writeEnvelope = envelope.write;

// ── Public key files ────────────────────────────────────────────────────────

pub const pubkey_prefix = envelope.pubkey_prefix;
pub const publicKeyToText = envelope.publicKeyToText;
pub const publicKeyFromText = envelope.publicKeyFromText;

test {
    _ = core;
    _ = envelope;
}
