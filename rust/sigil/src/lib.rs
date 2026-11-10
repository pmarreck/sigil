//! Verification of sigil documents: Ed25519 signatures over a transcript of
//! the exact payload bytes, carried in a printable-binary JSON envelope.
//!
//! This crate is the Rust counterpart of the Zig verifier in `src/` and is
//! held to it by the differential suite in `tests/differential`. It contains
//! no signing code, so an application that depends on it cannot mint a
//! document.

#![forbid(unsafe_code)]

pub mod envelope;
mod glyphs;
mod printable;
mod status;
pub mod transcript;
pub mod verify;

pub use envelope::{Error, public_key_from_text, public_key_to_text, verify_envelope};
pub use status::Status;
pub use verify::{PUBLIC_KEY_LEN, SIGNATURE_LEN, VerifyError, verify};

use core::ffi::CStr;

/// Library version. Identical to the Zig implementation's `sigil_version()`.
pub const VERSION: &CStr = c"0.1.0";

impl From<Error> for Status {
	fn from(e: Error) -> Status {
		match e {
			Error::MalformedJson => Status::MalformedJson,
			Error::MissingField => Status::MissingField,
			Error::UnsupportedSigtype => Status::UnsupportedSigtype,
			Error::MalformedEncoding => Status::MalformedEncoding,
			Error::BadSignatureLength => Status::BadSignatureLength,
			Error::BadSignature => Status::BadSignature,
			Error::BadPublicKey => Status::BadPublicKey,
		}
	}
}

impl From<VerifyError> for Status {
	fn from(e: VerifyError) -> Status {
		Status::from(Error::from(e))
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn version_matches_the_package_version() {
		assert_eq!(VERSION.to_str(), Ok(env!("CARGO_PKG_VERSION")));
	}
}
