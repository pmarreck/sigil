//! Result codes shared with the C ABI in `include/sigil.h`.

use core::ffi::CStr;

/// Every outcome the verification API can report.
///
/// The numeric codes and messages are part of the C ABI and must stay
/// identical to the Zig implementation. Both are derived from this one enum
/// through exhaustive matches, so adding a variant without choosing its code
/// and message does not compile.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Status {
	/// Success.
	Ok,
	/// The signature does not verify under the given public key.
	BadSignature,
	/// The public key is not a usable Ed25519 key.
	BadPublicKey,
	/// A required pointer argument was null.
	NullArgument,
	/// The envelope is not a well-formed JSON object.
	MalformedJson,
	/// The envelope lacks `data`, `sigtype` or `sig`.
	MissingField,
	/// The envelope names a signature type other than Ed25519.
	UnsupportedSigtype,
	/// A printable-binary value could not be decoded.
	MalformedEncoding,
	/// The decoded signature is not 64 bytes.
	BadSignatureLength,
	/// The caller's output buffer cannot hold the payload.
	BufferTooSmall,
	/// An allocation failed.
	OutOfMemory,
}

impl Status {
	/// Every variant, for exhaustive tests and table generation.
	pub const ALL: [Status; 11] = [
		Status::Ok,
		Status::BadSignature,
		Status::BadPublicKey,
		Status::NullArgument,
		Status::MalformedJson,
		Status::MissingField,
		Status::UnsupportedSigtype,
		Status::MalformedEncoding,
		Status::BadSignatureLength,
		Status::BufferTooSmall,
		Status::OutOfMemory,
	];

	/// The message `sigil_strerror` returns for a code no variant owns.
	pub const UNKNOWN_MESSAGE: &'static CStr = c"unknown error";

	/// The C ABI code: zero for success, negative otherwise.
	pub const fn code(self) -> i32 {
		match self {
			Status::Ok => 0,
			Status::BadSignature => -1,
			Status::BadPublicKey => -2,
			Status::NullArgument => -3,
			Status::MalformedJson => -4,
			Status::MissingField => -5,
			Status::UnsupportedSigtype => -6,
			Status::MalformedEncoding => -7,
			Status::BadSignatureLength => -8,
			Status::BufferTooSmall => -9,
			Status::OutOfMemory => -10,
		}
	}

	/// The variant that owns `code`, if any.
	pub fn from_code(code: i32) -> Option<Status> {
		Status::ALL.into_iter().find(|status| status.code() == code)
	}

	/// The human-readable message, NUL-terminated for the C ABI.
	pub const fn message(self) -> &'static CStr {
		match self {
			Status::Ok => c"ok",
			Status::BadSignature => c"signature does not verify under this public key",
			Status::BadPublicKey => c"not a valid Ed25519 public key",
			Status::NullArgument => c"required argument was NULL",
			Status::MalformedJson => c"envelope is not a well-formed JSON object",
			Status::MissingField => c"envelope is missing data, sigtype or sig",
			Status::UnsupportedSigtype => c"sigtype is not \"Ed25519\"",
			Status::MalformedEncoding => c"printable-binary value could not be decoded",
			Status::BadSignatureLength => c"decoded signature was not 64 bytes",
			Status::BufferTooSmall => c"output buffer too small for the payload",
			Status::OutOfMemory => c"out of memory",
		}
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use std::collections::HashSet;

	#[test]
	fn codes_are_unique_and_only_ok_is_zero() {
		let codes: HashSet<i32> = Status::ALL.iter().map(|s| s.code()).collect();
		assert_eq!(codes.len(), Status::ALL.len());
		for status in Status::ALL {
			assert_eq!(status.code() == 0, status == Status::Ok);
			assert!(status.code() <= 0);
		}
	}

	#[test]
	fn from_code_inverts_code_over_a_range_wider_than_the_domain() {
		for status in Status::ALL {
			assert_eq!(Status::from_code(status.code()), Some(status));
		}
		let owned: HashSet<i32> = Status::ALL.iter().map(|s| s.code()).collect();
		for code in -1000..=1000 {
			assert_eq!(Status::from_code(code).is_some(), owned.contains(&code));
		}
	}

	#[test]
	fn messages_are_distinct_and_never_the_unknown_fallback() {
		let messages: HashSet<&CStr> = Status::ALL.iter().map(|s| s.message()).collect();
		assert_eq!(messages.len(), Status::ALL.len());
		for status in Status::ALL {
			assert!(!status.message().is_empty());
			assert_ne!(status.message(), Status::UNKNOWN_MESSAGE);
		}
	}
}
