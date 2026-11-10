//! The C ABI declared in `include/sigil.h`, implemented over the `sigil`
//! crate. The header is the contract: symbol names, argument order, result
//! codes and messages match the Zig implementation exactly, and the
//! differential suite compares the two.
//!
//! This is the only place in the verifier that uses `unsafe`.

use core::ffi::{c_char, c_int};

use sigil::Status;

/// Human-readable name for a result code. Never null.
#[unsafe(no_mangle)]
pub extern "C" fn sigil_strerror(code: c_int) -> *const c_char {
	match Status::from_code(code) {
		Some(status) => status.message().as_ptr(),
		None => Status::UNKNOWN_MESSAGE.as_ptr(),
	}
}

/// Library version as a NUL-terminated string.
#[unsafe(no_mangle)]
pub extern "C" fn sigil_version() -> *const c_char {
	sigil::VERSION.as_ptr()
}

/// Length in bytes of a signature.
#[unsafe(no_mangle)]
pub extern "C" fn sigil_signature_len() -> usize {
	sigil::SIGNATURE_LEN
}

/// Length in bytes of a public key.
#[unsafe(no_mangle)]
pub extern "C" fn sigil_public_key_len() -> usize {
	sigil::PUBLIC_KEY_LEN
}
