//! The C ABI declared in `include/sigil.h`, implemented over the `sigil`
//! crate. The header is the contract: symbol names, argument order, NULL
//! handling, result codes and messages match the Zig implementation exactly,
//! and the differential suite compares the two.
//!
//! This is the only place in the verifier that uses `unsafe`. Every pointer is
//! checked for NULL before use, and binary data is always pointer plus length.
//! The core never panics on input; were it to, an `extern "C"` function aborts
//! rather than unwinding into the caller.

use core::ffi::{c_char, c_int};

use sigil::{PUBLIC_KEY_LEN, SIGNATURE_LEN, Status};

fn code(status: Status) -> c_int {
	status.code()
}

/// Borrow `len` bytes at `ptr`.
///
/// # Safety
/// `ptr` must be non-null and valid for reads of `len` bytes for the
/// duration of the borrow, as the header requires of the caller.
unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
	// SAFETY: guaranteed by the caller, per the header's contract.
	unsafe { std::slice::from_raw_parts(ptr, len) }
}

/// Borrow a fixed-size array at `ptr`.
///
/// # Safety
/// `ptr` must be non-null and valid for reads of `N` bytes.
unsafe fn array<'a, const N: usize>(ptr: *const u8) -> &'a [u8; N] {
	// SAFETY: guaranteed by the caller; [u8; N] has alignment 1.
	unsafe { &*ptr.cast::<[u8; N]>() }
}

/// Verify a detached signature over raw bytes.
///
/// # Safety
/// Non-null pointers must be valid for the lengths the header documents.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sigil_verify(
	payload: *const u8,
	payload_len: usize,
	sig: *const u8,
	public_key: *const u8,
) -> c_int {
	if payload.is_null() || sig.is_null() || public_key.is_null() {
		return code(Status::NullArgument);
	}
	// SAFETY: non-null, and the caller guarantees the documented lengths.
	let (payload, sig, key) = unsafe {
		(
			bytes(payload, payload_len),
			array::<SIGNATURE_LEN>(sig),
			array::<PUBLIC_KEY_LEN>(public_key),
		)
	};
	match sigil::verify(payload, sig, key) {
		Ok(()) => code(Status::Ok),
		Err(e) => code(Status::from(e)),
	}
}

/// Verify an envelope and copy the authenticated payload out.
///
/// # Safety
/// Non-null pointers must be valid for the lengths the header documents;
/// `payload_out` must be writable for `payload_out_cap` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sigil_verify_envelope(
	envelope: *const c_char,
	envelope_len: usize,
	public_key: *const u8,
	payload_out: *mut u8,
	payload_out_cap: usize,
	payload_len_out: *mut usize,
) -> c_int {
	if envelope.is_null() || public_key.is_null() || payload_len_out.is_null() {
		return code(Status::NullArgument);
	}
	if payload_out.is_null() && payload_out_cap != 0 {
		return code(Status::NullArgument);
	}
	// SAFETY: non-null, and the caller guarantees the documented lengths.
	let (envelope, key) = unsafe {
		(
			bytes(envelope.cast(), envelope_len),
			array::<PUBLIC_KEY_LEN>(public_key),
		)
	};
	let payload = match sigil::verify_envelope(envelope, key) {
		Ok(payload) => payload,
		Err(e) => return code(Status::from(e)),
	};
	// SAFETY: checked non-null above.
	unsafe { *payload_len_out = payload.len() };
	if payload.len() > payload_out_cap {
		return code(Status::BufferTooSmall);
	}
	if !payload.is_empty() {
		// SAFETY: payload.len() <= cap, so payload_out is non-null and writable.
		unsafe { std::ptr::copy_nonoverlapping(payload.as_ptr(), payload_out, payload.len()) };
	}
	code(Status::Ok)
}

/// Render a public key as the one-line `.pub` text form.
///
/// # Safety
/// `public_key` must be valid for 32 bytes; `out` writable for `out_cap`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sigil_public_key_to_text(
	public_key: *const u8,
	out: *mut c_char,
	out_cap: usize,
	out_len: *mut usize,
) -> c_int {
	if public_key.is_null() || out_len.is_null() {
		return code(Status::NullArgument);
	}
	// SAFETY: non-null, 32 readable bytes per the header.
	let text = sigil::public_key_to_text(unsafe { array::<PUBLIC_KEY_LEN>(public_key) });
	// SAFETY: checked non-null above.
	unsafe { *out_len = text.len() };
	if text.len() > out_cap {
		return code(Status::BufferTooSmall);
	}
	if out.is_null() {
		return code(Status::NullArgument);
	}
	// SAFETY: text.len() <= out_cap and out is non-null and writable.
	unsafe { std::ptr::copy_nonoverlapping(text.as_ptr(), out.cast::<u8>(), text.len()) };
	code(Status::Ok)
}

/// Parse a public-key file body into 32 bytes.
///
/// # Safety
/// `text` must be valid for `text_len` bytes; `public_key_out` writable for 32.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sigil_public_key_from_text(
	text: *const c_char,
	text_len: usize,
	public_key_out: *mut u8,
) -> c_int {
	if text.is_null() || public_key_out.is_null() {
		return code(Status::NullArgument);
	}
	// SAFETY: non-null, valid for text_len bytes per the header.
	match sigil::public_key_from_text(unsafe { bytes(text.cast(), text_len) }) {
		Ok(key) => {
			// SAFETY: public_key_out is non-null and writable for 32 bytes.
			unsafe { std::ptr::copy_nonoverlapping(key.as_ptr(), public_key_out, PUBLIC_KEY_LEN) };
			code(Status::Ok)
		}
		Err(e) => code(Status::from(e)),
	}
}

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
	SIGNATURE_LEN
}

/// Length in bytes of a public key.
#[unsafe(no_mangle)]
pub extern "C" fn sigil_public_key_len() -> usize {
	PUBLIC_KEY_LEN
}
