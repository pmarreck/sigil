//! The C ABI declared in `include/sigil_sign.h`, implemented over the Rust
//! `sigil-sign` crate, matching `src/ffi_sign.zig` call for call: NULL
//! checks in the same order, the same codes and messages, and the same
//! output-buffer contract. tests/differential/sign compares the two.
//!
//! This is the only place in the signing library that uses `unsafe`.

use core::ffi::{CStr, c_char, c_int};

use sigil_sign::Error;
use sigil_sign::paper::{Artifact, Kind};

const OK: c_int = 0;
const NULL_ARGUMENT: c_int = -3;
const BUFFER_TOO_SMALL: c_int = -9;

/// # Safety
/// A non-null `ptr` must be valid for reads of `len` bytes.
unsafe fn bytes<'a>(ptr: *const c_char, len: usize) -> Option<&'a [u8]> {
	// SAFETY: guaranteed by the caller per the header.
	(!ptr.is_null()).then(|| unsafe { std::slice::from_raw_parts(ptr.cast::<u8>(), len) })
}

/// Write `src` out under the header's buffer contract: report the length,
/// refuse a short buffer, then refuse a NULL one.
///
/// # Safety
/// `out_len` must be valid; a non-null `out` must be writable for `out_cap`.
unsafe fn copy_out(src: &[u8], out: *mut c_char, out_cap: usize, out_len: *mut usize) -> c_int {
	// SAFETY: out_len is checked non-null by every caller.
	unsafe { *out_len = src.len() };
	if src.len() > out_cap {
		return BUFFER_TOO_SMALL;
	}
	if out.is_null() {
		return NULL_ARGUMENT;
	}
	// SAFETY: src.len() <= out_cap and out is writable for out_cap bytes.
	unsafe { std::ptr::copy_nonoverlapping(src.as_ptr(), out.cast::<u8>(), src.len()) };
	OK
}

fn code(e: Error) -> c_int {
	e.code()
}

/// Generate a fresh key; write its keyfile text into `out`.
///
/// # Safety
/// Pointers must satisfy `sigil_sign.h`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sigil_keygen(
	passphrase: *const c_char,
	passphrase_len: usize,
	out: *mut c_char,
	out_cap: usize,
	out_len: *mut usize,
) -> c_int {
	// SAFETY: per the header.
	let Some(pw) = (unsafe { bytes(passphrase, passphrase_len) }) else {
		return NULL_ARGUMENT;
	};
	if out_len.is_null() {
		return NULL_ARGUMENT;
	}
	match sigil_sign::keygen(pw) {
		// SAFETY: out_len checked; out per the header.
		Ok(keyfile) => unsafe { copy_out(&keyfile, out, out_cap, out_len) },
		Err(e) => code(e),
	}
}

/// Sign `payload` with the key in `keyfile`; write the envelope into `out`.
///
/// # Safety
/// Pointers must satisfy `sigil_sign.h`.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn sigil_seal(
	keyfile: *const c_char,
	keyfile_len: usize,
	passphrase: *const c_char,
	passphrase_len: usize,
	payload: *const u8,
	payload_len: usize,
	out: *mut c_char,
	out_cap: usize,
	out_len: *mut usize,
) -> c_int {
	// SAFETY: per the header.
	let (kf, pw, p) = unsafe {
		(
			bytes(keyfile, keyfile_len),
			bytes(passphrase, passphrase_len),
			bytes(payload.cast(), payload_len),
		)
	};
	let (Some(kf), Some(pw), Some(p)) = (kf, pw, p) else {
		return NULL_ARGUMENT;
	};
	if out_len.is_null() {
		return NULL_ARGUMENT;
	}
	match sigil_sign::seal(kf, pw, p) {
		// SAFETY: out_len checked; out per the header.
		Ok(envelope) => unsafe { copy_out(&envelope, out, out_cap, out_len) },
		Err(e) => code(e),
	}
}

/// Derive a keyfile's public key (requires the passphrase).
///
/// # Safety
/// Pointers must satisfy `sigil_sign.h`; `public_key_out` writable for 32.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sigil_keyfile_public_key(
	keyfile: *const c_char,
	keyfile_len: usize,
	passphrase: *const c_char,
	passphrase_len: usize,
	public_key_out: *mut u8,
) -> c_int {
	// SAFETY: per the header.
	let (kf, pw) = unsafe {
		(
			bytes(keyfile, keyfile_len),
			bytes(passphrase, passphrase_len),
		)
	};
	let (Some(kf), Some(pw)) = (kf, pw) else {
		return NULL_ARGUMENT;
	};
	if public_key_out.is_null() {
		return NULL_ARGUMENT;
	}
	match sigil_sign::keyfile_public_key(kf, pw) {
		Ok(pk) => {
			// SAFETY: public_key_out is writable for 32 bytes per the header.
			unsafe { std::ptr::copy_nonoverlapping(pk.as_ptr(), public_key_out, pk.len()) };
			OK
		}
		Err(e) => code(e),
	}
}

/// Generate a key and both custody artifacts from the one seed.
///
/// # Safety
/// Pointers must satisfy `sigil_sign.h`.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn sigil_keygen_with_recovery(
	passphrase: *const c_char,
	passphrase_len: usize,
	keyfile_out: *mut c_char,
	keyfile_cap: usize,
	keyfile_len: *mut usize,
	bundle_out: *mut c_char,
	bundle_cap: usize,
	bundle_len: *mut usize,
) -> c_int {
	// SAFETY: per the header.
	let Some(pw) = (unsafe { bytes(passphrase, passphrase_len) }) else {
		return NULL_ARGUMENT;
	};
	if keyfile_len.is_null() || bundle_len.is_null() {
		return NULL_ARGUMENT;
	}
	let (keyfile, bundle) = match sigil_sign::keygen_with_recovery(pw) {
		Ok(pair) => pair,
		Err(e) => return code(e),
	};
	// SAFETY: both length pointers checked non-null.
	unsafe {
		*keyfile_len = keyfile.len();
		*bundle_len = bundle.len();
	}
	if keyfile.len() > keyfile_cap || bundle.len() > bundle_cap {
		return BUFFER_TOO_SMALL;
	}
	// SAFETY: lengths checked; outputs per the header.
	let rc = unsafe { copy_out(&keyfile, keyfile_out, keyfile_cap, keyfile_len) };
	if rc != OK {
		return rc;
	}
	// SAFETY: as above.
	unsafe { copy_out(&bundle, bundle_out, bundle_cap, bundle_len) }
}

/// Open a hot bundle into PKCS#8 PEM text.
///
/// # Safety
/// Pointers must satisfy `sigil_sign.h`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sigil_hot_bundle_open(
	bundle: *const c_char,
	bundle_len: usize,
	passphrase: *const c_char,
	passphrase_len: usize,
	out: *mut c_char,
	out_cap: usize,
	out_len: *mut usize,
) -> c_int {
	// SAFETY: per the header.
	let (b, pw) = unsafe { (bytes(bundle, bundle_len), bytes(passphrase, passphrase_len)) };
	let (Some(b), Some(pw)) = (b, pw) else {
		return NULL_ARGUMENT;
	};
	if out_len.is_null() {
		return NULL_ARGUMENT;
	}
	match sigil_sign::hot_bundle_open(b, pw) {
		// SAFETY: out_len checked; out per the header.
		Ok(pem) => unsafe { copy_out(&pem, out, out_cap, out_len) },
		Err(e) => code(e),
	}
}

/// `sigil_paper_artifact` from the header.
#[repr(C)]
pub struct SigilPaperArtifact {
	kind: c_int,
	label: *const c_char,
	filename: *const c_char,
	bytes: *const u8,
	bytes_len: usize,
	pubkey: *const u8,
}

/// Render printable cold copies, one page per artifact.
///
/// # Safety
/// `artifacts` must point to `count` valid entries; strings NUL-terminated;
/// `pubkey` NULL or 32 bytes; `date` NUL-terminated.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sigil_paper_render(
	artifacts: *const SigilPaperArtifact,
	count: usize,
	date: *const c_char,
	out: *mut c_char,
	out_cap: usize,
	out_len: *mut usize,
) -> c_int {
	if artifacts.is_null() || date.is_null() || out_len.is_null() || count == 0 {
		return NULL_ARGUMENT;
	}
	// SAFETY: artifacts points to count entries per the header.
	let entries = unsafe { std::slice::from_raw_parts(artifacts, count) };
	let mut list = Vec::with_capacity(count);
	for a in entries {
		if a.label.is_null() || a.filename.is_null() || a.bytes.is_null() {
			return NULL_ARGUMENT;
		}
		// SAFETY: non-null, NUL-terminated strings and a byte buffer of
		// bytes_len per the header; pubkey NULL or 32 bytes.
		let art = unsafe {
			Artifact {
				kind: if a.kind == 1 {
					Kind::HotBundle
				} else {
					Kind::Keyfile
				},
				label: CStr::from_ptr(a.label).to_bytes(),
				filename: CStr::from_ptr(a.filename).to_bytes(),
				bytes: std::slice::from_raw_parts(a.bytes, a.bytes_len),
				pubkey: (!a.pubkey.is_null()).then(|| *a.pubkey.cast::<[u8; 32]>()),
			}
		};
		list.push(art);
	}
	// SAFETY: date checked non-null and NUL-terminated per the header.
	let date = unsafe { CStr::from_ptr(date) }.to_bytes();
	match sigil_sign::paper::render(&list, date, b"0.1.0") {
		// SAFETY: out_len checked; out per the header.
		Ok(pdf) => unsafe { copy_out(&pdf, out, out_cap, out_len) },
		Err(_) => code(Error::TooLargeForQr),
	}
}

/// Human-readable name for a signing code. Never NULL.
#[unsafe(no_mangle)]
pub extern "C" fn sigil_sign_strerror(code: c_int) -> *const c_char {
	sigil_sign::strerror(code).as_ptr()
}
