//! The JSON envelope and public-key text, matching `src/envelope.zig`.
//!
//! The envelope is transport only and is never signed. Verification runs over
//! the decoded `data` bytes, so an envelope may be reformatted and still
//! verify. Payload bytes are only ever returned after they verified.

use crate::printable;
use crate::verify::{self, PUBLIC_KEY_LEN, SIGNATURE_LEN, VerifyError};

/// The only signature type sigil speaks. Not authenticated; a usability check.
pub const SIGTYPE: &[u8] = b"Ed25519";

/// Leading token of a public-key file.
pub const PUBKEY_PREFIX: &[u8] = b"sigil-pubkey-v1 ";

/// Why an envelope or key text was refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	/// Not well-formed, not an object, invalid UTF-8, or a duplicated field.
	MalformedJson,
	/// `data`, `sigtype` or `sig` is absent.
	MissingField,
	/// `sigtype` is not "Ed25519".
	UnsupportedSigtype,
	/// A printable-binary value does not decode.
	MalformedEncoding,
	/// The decoded signature is not 64 bytes.
	BadSignatureLength,
	/// The signature does not verify.
	BadSignature,
	/// The public key is not usable.
	BadPublicKey,
}

impl From<VerifyError> for Error {
	fn from(e: VerifyError) -> Error {
		match e {
			VerifyError::BadSignature => Error::BadSignature,
			VerifyError::BadPublicKey => Error::BadPublicKey,
		}
	}
}

/// ASCII bytes a valid envelope can contain: printable-binary's ASCII subset
/// plus the JSON structure characters. Everything else below 0x80 is
/// transport noise (line folds, reply prefixes, tabs) and is dropped.
const ALLOWED_ASCII: &[u8] =
	b".0123456789@ABCDEFGHIJKLMNOPQRSTUVWXYZ^_abcdefghijklmnopqrstuvwxyz{}\":,";

fn normalize(envelope: &[u8]) -> Vec<u8> {
	let mut keep = [false; 128];
	for &c in ALLOWED_ASCII {
		keep[usize::from(c)] = true;
	}
	envelope
		.iter()
		.copied()
		.filter(|&c| c >= 0x80 || keep[usize::from(c)])
		.collect()
}

struct Wire<'a> {
	data: &'a [u8],
	sigtype: &'a [u8],
	sig: &'a [u8],
}

fn scan_string<'a>(s: &'a [u8], i: &mut usize) -> Result<&'a [u8], Error> {
	if s.get(*i) != Some(&b'"') {
		return Err(Error::MalformedJson);
	}
	*i += 1;
	let start = *i;
	let len = s[start..]
		.iter()
		.position(|&c| c == b'"')
		.ok_or(Error::MalformedJson)?;
	*i = start + len + 1;
	Ok(&s[start..start + len])
}

/// Parse the normalized envelope: an object of string fields with no escapes.
/// Duplicate known fields are refused; unknown fields are ignored.
fn parse(s: &[u8]) -> Result<Wire<'_>, Error> {
	if s.first() != Some(&b'{') {
		return Err(Error::MalformedJson);
	}
	let mut i = 1;
	let (mut data, mut sigtype, mut sig) = (None, None, None);
	if s.get(i) == Some(&b'}') {
		i += 1;
	} else {
		loop {
			let key = scan_string(s, &mut i)?;
			if s.get(i) != Some(&b':') {
				return Err(Error::MalformedJson);
			}
			i += 1;
			let value = scan_string(s, &mut i)?;
			let slot = match key {
				b"data" => Some(&mut data),
				b"sigtype" => Some(&mut sigtype),
				b"sig" => Some(&mut sig),
				_ => None,
			};
			if let Some(slot) = slot {
				if slot.is_some() {
					return Err(Error::MalformedJson);
				}
				*slot = Some(value);
			}
			match s.get(i) {
				Some(b',') => i += 1,
				Some(b'}') => {
					i += 1;
					break;
				}
				_ => return Err(Error::MalformedJson),
			}
		}
	}
	if i != s.len() {
		return Err(Error::MalformedJson);
	}
	Ok(Wire {
		data: data.ok_or(Error::MissingField)?,
		sigtype: sigtype.ok_or(Error::MissingField)?,
		sig: sig.ok_or(Error::MissingField)?,
	})
}

fn decode_field(encoded: &[u8]) -> Result<Vec<u8>, Error> {
	printable::decode_strict(encoded).ok_or(Error::MalformedEncoding)
}

/// Verify an envelope and return its authenticated payload.
pub fn verify_envelope(
	envelope: &[u8],
	public_key: &[u8; PUBLIC_KEY_LEN],
) -> Result<Vec<u8>, Error> {
	let clean = normalize(envelope);
	if std::str::from_utf8(&clean).is_err() {
		return Err(Error::MalformedJson);
	}
	let wire = parse(&clean)?;
	if wire.sigtype != SIGTYPE {
		return Err(Error::UnsupportedSigtype);
	}
	let payload = decode_field(wire.data)?;
	let sig = decode_field(wire.sig)?;
	let sig: &[u8; SIGNATURE_LEN] = sig
		.as_slice()
		.try_into()
		.map_err(|_| Error::BadSignatureLength)?;
	verify::verify(&payload, sig, public_key)?;
	Ok(payload)
}

/// Render a public key as a one-line `.pub` file body.
pub fn public_key_to_text(public_key: &[u8; PUBLIC_KEY_LEN]) -> Vec<u8> {
	let mut out = PUBKEY_PREFIX.to_vec();
	out.extend_from_slice(&printable::encode(public_key));
	out.push(b'\n');
	out
}

fn trim(mut s: &[u8]) -> &[u8] {
	let ws = |c: &u8| matches!(c, b' ' | b'\t' | b'\r' | b'\n');
	while s.first().is_some_and(ws) {
		s = &s[1..];
	}
	while s.last().is_some_and(ws) {
		s = &s[..s.len() - 1];
	}
	s
}

/// Parse a public-key file body. Surrounding whitespace and a missing prefix
/// are tolerated; anything that is not exactly a key is refused.
pub fn public_key_from_text(text: &[u8]) -> Result<[u8; PUBLIC_KEY_LEN], Error> {
	let prefix = trim(PUBKEY_PREFIX);
	let mut body = trim(text);
	if let Some(rest) = body.strip_prefix(prefix) {
		body = trim(rest);
	}
	if body.is_empty() {
		return Err(Error::MalformedEncoding);
	}
	decode_field(body)?
		.as_slice()
		.try_into()
		.map_err(|_| Error::MalformedEncoding)
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn public_key_text_round_trips_over_keys_covering_every_byte() {
		for start in (0u16..256).step_by(32) {
			let key: [u8; 32] = std::array::from_fn(|i| (start as usize + i) as u8);
			let text = public_key_to_text(&key);
			assert!(text.starts_with(PUBKEY_PREFIX) && text.ends_with(b"\n"));
			assert_eq!(public_key_from_text(&text), Ok(key));
			let bare = &text[PUBKEY_PREFIX.len()..];
			assert_eq!(
				public_key_from_text(bare),
				Ok(key),
				"missing prefix is tolerated"
			);
		}
	}

	#[test]
	fn public_key_text_refuses_wrong_lengths_and_empty_bodies() {
		assert_eq!(public_key_from_text(b""), Err(Error::MalformedEncoding));
		assert_eq!(
			public_key_from_text(b"sigil-pubkey-v1"),
			Err(Error::MalformedEncoding)
		);
		assert_eq!(
			public_key_from_text(&printable::encode(&[0u8; 31])),
			Err(Error::MalformedEncoding)
		);
		assert_eq!(
			public_key_from_text(&printable::encode(&[0u8; 33])),
			Err(Error::MalformedEncoding)
		);
	}

	#[test]
	fn envelope_structure_errors_are_classified() {
		let key = [0u8; 32];
		assert_eq!(verify_envelope(b"", &key), Err(Error::MalformedJson));
		assert_eq!(verify_envelope(b"{}", &key), Err(Error::MissingField));
		assert_eq!(
			verify_envelope(b"{\"data\":\"a\",\"data\":\"a\"}", &key),
			Err(Error::MalformedJson)
		);
		assert_eq!(
			verify_envelope(b"{\"data\":\"a\",\"sigtype\":\"RSA\",\"sig\":\"a\"}", &key),
			Err(Error::UnsupportedSigtype)
		);
		assert_eq!(
			verify_envelope(
				b"{\"data\":\"a\",\"sigtype\":\"Ed25519\",\"sig\":\"a\"}",
				&key
			),
			Err(Error::BadSignatureLength)
		);
		assert_eq!(
			verify_envelope(b"{\"data\":\"a\"} ", &key),
			Err(Error::MissingField),
			"trailing space is transport noise"
		);
		assert_eq!(
			verify_envelope(b"{\"data\":\"a\"}x", &key),
			Err(Error::MalformedJson)
		);
		assert_eq!(
			verify_envelope(b"{\"data\":\"\xff\"}", &key),
			Err(Error::MalformedJson),
			"invalid UTF-8"
		);
	}
}
