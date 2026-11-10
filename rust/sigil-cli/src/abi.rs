//! The C ABI of `include/sigil.h` and `include/sigil_sign.h`, declared by
//! hand: the CLI's only way into an implementation. Every function either
//! header declares is declared here, with the header's constants. The tests
//! below and tests/test_rust_cli_boundary hold this file to the headers.

use core::ffi::{c_char, c_int};

// ── include/sigil.h ─────────────────────────────────────────────────────────

pub const SIGIL_OK: c_int = 0;
pub const SIGIL_ERR_BAD_SIGNATURE: c_int = -1;
pub const SIGIL_ERR_BAD_PUBLIC_KEY: c_int = -2;
pub const SIGIL_ERR_NULL_ARGUMENT: c_int = -3;
pub const SIGIL_ERR_MALFORMED_JSON: c_int = -4;
pub const SIGIL_ERR_MISSING_FIELD: c_int = -5;
pub const SIGIL_ERR_UNSUPPORTED_SIGTYPE: c_int = -6;
pub const SIGIL_ERR_MALFORMED_ENCODING: c_int = -7;
pub const SIGIL_ERR_BAD_SIGNATURE_LENGTH: c_int = -8;
pub const SIGIL_ERR_BUFFER_TOO_SMALL: c_int = -9;
pub const SIGIL_ERR_OUT_OF_MEMORY: c_int = -10;

// ── include/sigil_sign.h ────────────────────────────────────────────────────

pub const SIGIL_ERR_MALFORMED_KEYFILE: c_int = -20;
pub const SIGIL_ERR_UNSUPPORTED_KEYFILE: c_int = -21;
pub const SIGIL_ERR_AUTH_FAILED: c_int = -22;
pub const SIGIL_ERR_BAD_KDF_PARAMS: c_int = -23;
pub const SIGIL_ERR_BAD_SEED: c_int = -24;
pub const SIGIL_ERR_EMPTY_PASSPHRASE: c_int = -25;
pub const SIGIL_ERR_NO_ENTROPY: c_int = -26;
pub const SIGIL_ERR_NOT_HOT_BUNDLE: c_int = -27;
pub const SIGIL_ERR_TOO_LARGE_FOR_QR: c_int = -28;
pub const SIGIL_PAPER_KEYFILE: c_int = 0;
pub const SIGIL_PAPER_HOT_BUNDLE: c_int = 1;

/// `sigil_paper_artifact`: one page of a paper cold copy.
#[repr(C)]
pub struct SigilPaperArtifact {
	pub kind: c_int,
	pub label: *const c_char,
	pub filename: *const c_char,
	pub bytes: *const u8,
	pub bytes_len: usize,
	pub pubkey: *const u8,
}

unsafe extern "C" {
	// include/sigil.h
	pub fn sigil_verify(
		payload: *const u8,
		payload_len: usize,
		sig: *const u8,
		public_key: *const u8,
	) -> c_int;
	pub fn sigil_verify_envelope(
		envelope: *const c_char,
		envelope_len: usize,
		public_key: *const u8,
		payload_out: *mut u8,
		payload_out_cap: usize,
		payload_len_out: *mut usize,
	) -> c_int;
	pub fn sigil_public_key_to_text(
		public_key: *const u8,
		out: *mut c_char,
		out_cap: usize,
		out_len: *mut usize,
	) -> c_int;
	pub fn sigil_public_key_from_text(
		text: *const c_char,
		text_len: usize,
		public_key_out: *mut u8,
	) -> c_int;
	pub fn sigil_strerror(code: c_int) -> *const c_char;
	pub fn sigil_version() -> *const c_char;
	pub fn sigil_signature_len() -> usize;
	pub fn sigil_public_key_len() -> usize;

	// include/sigil_sign.h
	pub fn sigil_keygen(
		passphrase: *const c_char,
		passphrase_len: usize,
		out: *mut c_char,
		out_cap: usize,
		out_len: *mut usize,
	) -> c_int;
	pub fn sigil_seal(
		keyfile: *const c_char,
		keyfile_len: usize,
		passphrase: *const c_char,
		passphrase_len: usize,
		payload: *const u8,
		payload_len: usize,
		out: *mut c_char,
		out_cap: usize,
		out_len: *mut usize,
	) -> c_int;
	pub fn sigil_keyfile_public_key(
		keyfile: *const c_char,
		keyfile_len: usize,
		passphrase: *const c_char,
		passphrase_len: usize,
		public_key_out: *mut u8,
	) -> c_int;
	pub fn sigil_keygen_with_recovery(
		passphrase: *const c_char,
		passphrase_len: usize,
		keyfile_out: *mut c_char,
		keyfile_cap: usize,
		keyfile_len: *mut usize,
		bundle_out: *mut c_char,
		bundle_cap: usize,
		bundle_len: *mut usize,
	) -> c_int;
	pub fn sigil_hot_bundle_open(
		bundle: *const c_char,
		bundle_len: usize,
		passphrase: *const c_char,
		passphrase_len: usize,
		out: *mut c_char,
		out_cap: usize,
		out_len: *mut usize,
	) -> c_int;
	pub fn sigil_paper_render(
		artifacts: *const SigilPaperArtifact,
		count: usize,
		date: *const c_char,
		out: *mut c_char,
		out_cap: usize,
		out_len: *mut usize,
	) -> c_int;
	pub fn sigil_sign_strerror(code: c_int) -> *const c_char;
}

#[cfg(test)]
mod tests {
	//! Hold this file to the headers: the same functions with the same number
	//! of parameters, and every `#define` with the same value.

	use std::collections::BTreeMap;

	const HEADERS: [&str; 2] = [
		include_str!("../../../include/sigil.h"),
		include_str!("../../../include/sigil_sign.h"),
	];
	const ABI: &str = include_str!("abi.rs");

	/// Function name to parameter count, from declarations that start at
	/// column 0 (as scripts/c-header-functions reads them).
	fn header_functions() -> BTreeMap<String, usize> {
		let mut found = BTreeMap::new();
		for header in HEADERS {
			let mut rest = header;
			while let Some(open) = rest.find('(') {
				let line_start = rest[..open].rfind('\n').map_or(0, |i| i + 1);
				let head = &rest[line_start..open];
				let close = rest[open..].find(')').map_or(rest.len(), |i| open + i);
				let starts_like_type = head.starts_with(|c: char| c.is_ascii_alphabetic());
				if starts_like_type && !head.starts_with("typedef") && !head.contains(';') {
					let name: String = head
						.chars()
						.rev()
						.take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
						.collect::<Vec<_>>()
						.into_iter()
						.rev()
						.collect();
					let params = rest[open + 1..close].trim();
					let count = if params == "void" {
						0
					} else {
						params.split(',').count()
					};
					found.insert(name, count);
				}
				rest = &rest[close.min(rest.len() - 1) + 1..];
			}
		}
		found
	}

	fn abi_functions() -> BTreeMap<String, usize> {
		// Only the declarations, not this test module's own source.
		let decls = ABI.split("#[cfg(test)]").next().unwrap_or_default();
		let marker = "pub fn ";
		let mut found = BTreeMap::new();
		for (start, _) in decls.match_indices(marker) {
			let after = &decls[start + marker.len()..];
			let Some(open) = after.find('(') else {
				continue;
			};
			let close = after.find(')').unwrap_or(after.len());
			let params = after[open + 1..close]
				.split(',')
				.filter(|p| !p.trim().is_empty())
				.count();
			found.insert(after[..open].to_string(), params);
		}
		found
	}

	#[test]
	fn declares_exactly_the_header_functions_with_their_arity() {
		let header = header_functions();
		assert_eq!(header.len(), 15, "parsed {header:?}");
		assert_eq!(abi_functions(), header);
	}

	#[test]
	fn every_header_constant_has_its_value() {
		let mut checked = 0;
		for header in HEADERS {
			for line in header.lines() {
				let mut words = line.split_whitespace();
				if words.next() != Some("#define") {
					continue;
				}
				let (Some(name), Some(value)) = (words.next(), words.next()) else {
					continue;
				};
				if value.parse::<i32>().is_err() {
					continue;
				}
				let want = format!("pub const {name}: c_int = {value};");
				assert!(ABI.contains(&want), "abi.rs lacks `{want}`");
				checked += 1;
			}
		}
		assert!(checked >= 21, "only {checked} constants checked");
	}
}
