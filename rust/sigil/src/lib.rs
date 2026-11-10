//! Verification of sigil documents: Ed25519 signatures over a transcript of
//! the exact payload bytes.
//!
//! This crate is the Rust counterpart of the Zig verifier in `src/` and is
//! held to it by the differential suite in `tests/differential`. It contains
//! no signing code, so an application that depends on it cannot mint a
//! document.

#![forbid(unsafe_code)]

mod status;

pub use status::Status;

use core::ffi::CStr;

/// Library version. Identical to the Zig implementation's `sigil_version()`.
pub const VERSION: &CStr = c"0.1.0";

/// Length in bytes of an Ed25519 signature.
pub const SIGNATURE_LEN: usize = 64;

/// Length in bytes of an Ed25519 public key.
pub const PUBLIC_KEY_LEN: usize = 32;

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn version_matches_the_package_version() {
		assert_eq!(VERSION.to_str(), Ok(env!("CARGO_PKG_VERSION")));
	}
}
