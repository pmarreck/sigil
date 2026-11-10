//! Signature edge-case corpus for sigil's verifier.
//!
//! Every case signs the sigil transcript (domain, algorithm, length, payload)
//! the way sigil does, then perturbs the key, R or S to reach one edge of the
//! Ed25519 acceptance rules. The expected result of each case is written by
//! hand from sigil's documented policy, never computed by running a verifier:
//!
//! - cofactored verification: `8·S·B = 8·R + 8·k·A`;
//! - `S` must be canonical (less than the group order);
//! - `A` and `R` must be canonical encodings of curve points;
//! - `R` with x = 0 (the identity and the point of order 2) is refused;
//! - every small-order public key is refused as a bad key.
//!
//! The arithmetic uses curve25519-dalek, so the corpus does not depend on the
//! Zig code it is used to test.

use curve25519_dalek::constants::{ED25519_BASEPOINT_POINT as B, EIGHT_TORSION};
use curve25519_dalek::edwards::{CompressedEdwardsY, EdwardsPoint};
use curve25519_dalek::scalar::Scalar;
use sha2::{Digest, Sha512};
use std::fmt::Write as _;

const DOMAIN: &[u8] = b"sigil.transcript.v1";
const ALGORITHM_ED25519: u8 = 1;

/// Result codes from `include/sigil.h`.
#[derive(Clone, Copy)]
enum Expect {
	Ok,
	BadSignature,
	BadPublicKey,
}

impl Expect {
	fn code(self) -> i32 {
		match self {
			Expect::Ok => 0,
			Expect::BadSignature => -1,
			Expect::BadPublicKey => -2,
		}
	}

	fn name(self) -> &'static str {
		match self {
			Expect::Ok => "ok",
			Expect::BadSignature => "bad_signature",
			Expect::BadPublicKey => "bad_public_key",
		}
	}
}

struct Case {
	name: String,
	expect: Expect,
	payload: Vec<u8>,
	signature: [u8; 64],
	public_key: [u8; 32],
}

/// The signed bytes: sigil's transcript header followed by the payload.
fn transcript(payload: &[u8]) -> Vec<u8> {
	let mut out = Vec::with_capacity(DOMAIN.len() + 9 + payload.len());
	out.extend_from_slice(DOMAIN);
	out.push(ALGORITHM_ED25519);
	out.extend_from_slice(&(payload.len() as u64).to_be_bytes());
	out.extend_from_slice(payload);
	out
}

fn hram(r: &[u8; 32], a: &[u8; 32], message: &[u8]) -> Scalar {
	let mut h = Sha512::new();
	h.update(r);
	h.update(a);
	h.update(message);
	Scalar::from_bytes_mod_order_wide(&h.finalize().into())
}

/// An RFC 8032 key derived from a fixed seed byte, so the corpus is
/// reproducible.
struct Key {
	secret: Scalar,
	prefix: [u8; 32],
	public: EdwardsPoint,
}

impl Key {
	fn from_seed(byte: u8) -> Key {
		let digest: [u8; 64] = Sha512::digest([byte; 32]).into();
		let mut clamped = [0u8; 32];
		clamped.copy_from_slice(&digest[..32]);
		clamped[0] &= 248;
		clamped[31] &= 127;
		clamped[31] |= 64;
		let secret = Scalar::from_bytes_mod_order(clamped);
		let mut prefix = [0u8; 32];
		prefix.copy_from_slice(&digest[32..]);
		Key {
			secret,
			prefix,
			public: B * secret,
		}
	}

	fn nonce(&self, message: &[u8]) -> Scalar {
		let mut h = Sha512::new();
		h.update(self.prefix);
		h.update(message);
		Scalar::from_bytes_mod_order_wide(&h.finalize().into())
	}

	/// Sign `message` with an arbitrary encoded public key and R point, using
	/// this key's secret. With the honest public key and `R = r·B` this is
	/// plain Ed25519.
	fn sign_with(
		&self,
		message: &[u8],
		public_key: &[u8; 32],
		r_point: &EdwardsPoint,
		r: Scalar,
	) -> [u8; 64] {
		let r_bytes = r_point.compress().to_bytes();
		let k = hram(&r_bytes, public_key, message);
		let s = r + k * self.secret;
		let mut sig = [0u8; 64];
		sig[..32].copy_from_slice(&r_bytes);
		sig[32..].copy_from_slice(s.as_bytes());
		sig
	}

	fn sign(&self, message: &[u8]) -> [u8; 64] {
		let r = self.nonce(message);
		self.sign_with(message, &self.public.compress().to_bytes(), &(B * r), r)
	}
}

/// Little-endian 255-bit field element with the sign bit set as given.
fn field_bytes(value_le: [u8; 32], sign: bool) -> [u8; 32] {
	let mut out = value_le;
	out[31] = (out[31] & 0x7f) | if sign { 0x80 } else { 0 };
	out
}

/// p = 2^255 - 19, little-endian.
fn p_bytes() -> [u8; 32] {
	let mut p = [0xffu8; 32];
	p[0] = 0xed;
	p[31] = 0x7f;
	p
}

/// p + small, for small values that keep the result below 2^255.
fn p_plus(small: u8) -> [u8; 32] {
	let mut v = p_bytes();
	v[0] += small;
	v
}

/// L = 2^252 + 27742317777372353535851937790883648493, little-endian.
const GROUP_ORDER: [u8; 32] = [
	0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10,
];

/// S + L as 32 little-endian bytes; fits because S < L < 2^253.
fn add_group_order(s: &[u8]) -> [u8; 32] {
	let l = GROUP_ORDER;
	let mut out = [0u8; 32];
	let mut carry = 0u16;
	for i in 0..32 {
		let sum = u16::from(s[i]) + u16::from(l[i]) + carry;
		out[i] = (sum & 0xff) as u8;
		carry = sum >> 8;
	}
	out
}

fn hex(bytes: &[u8]) -> String {
	bytes
		.iter()
		.fold(String::with_capacity(bytes.len() * 2), |mut s, b| {
			let _ = write!(s, "{b:02x}");
			s
		})
}

fn cases() -> Vec<Case> {
	let key = Key::from_seed(0xa5);
	let other = Key::from_seed(0x5a);
	let pk = key.public.compress().to_bytes();
	let payload = b"product=mecha-validate\nmax_major=1\n".to_vec();
	let message = transcript(&payload);
	let valid = key.sign(&message);
	let mut out = Vec::new();
	let mut push =
		|name: &str, expect: Expect, payload: &[u8], signature: [u8; 64], public_key: [u8; 32]| {
			out.push(Case {
				name: name.to_string(),
				expect,
				payload: payload.to_vec(),
				signature,
				public_key,
			});
		};

	push("valid", Expect::Ok, &payload, valid, pk);
	push(
		"valid_empty_payload",
		Expect::Ok,
		b"",
		key.sign(&transcript(b"")),
		pk,
	);
	push(
		"valid_embedded_nul",
		Expect::Ok,
		b"\0a\0b\0",
		key.sign(&transcript(b"\0a\0b\0")),
		pk,
	);

	let mut flipped = payload.clone();
	flipped[0] ^= 1;
	push(
		"payload_byte_flipped",
		Expect::BadSignature,
		&flipped,
		valid,
		pk,
	);
	let mut longer = payload.clone();
	longer.push(b'\n');
	push("payload_extended", Expect::BadSignature, &longer, valid, pk);
	push(
		"wrong_key",
		Expect::BadSignature,
		&payload,
		valid,
		other.public.compress().to_bytes(),
	);
	push(
		"signed_raw_payload_not_transcript",
		Expect::BadSignature,
		&payload,
		key.sign(&payload),
		pk,
	);

	let mut s_flip = valid;
	s_flip[32] ^= 1;
	push("s_byte_flipped", Expect::BadSignature, &payload, s_flip, pk);
	let mut r_flip = valid;
	r_flip[0] ^= 1;
	push("r_byte_flipped", Expect::BadSignature, &payload, r_flip, pk);

	let mut s_plus_l = valid;
	s_plus_l[32..].copy_from_slice(&add_group_order(&valid[32..]));
	push(
		"s_plus_group_order",
		Expect::BadSignature,
		&payload,
		s_plus_l,
		pk,
	);
	let mut s_max = valid;
	s_max[32..].fill(0xff);
	push("s_all_ff", Expect::BadSignature, &payload, s_max, pk);
	push(
		"signature_all_zero",
		Expect::BadSignature,
		&payload,
		[0u8; 64],
		pk,
	);

	// Every small-order point as the public key, with an otherwise valid
	// signature shape. The key is refused before the signature is examined.
	for (i, point) in EIGHT_TORSION.iter().enumerate() {
		push(
			&format!("public_key_small_order_{i}"),
			Expect::BadPublicKey,
			&payload,
			valid,
			point.compress().to_bytes(),
		);
	}
	push(
		"public_key_all_zero",
		Expect::BadPublicKey,
		&payload,
		valid,
		[0u8; 32],
	);
	push(
		"public_key_identity_negative_zero",
		Expect::BadPublicKey,
		&payload,
		valid,
		field_bytes(one(), true),
	);
	push(
		"public_key_noncanonical_y_p_plus_1",
		Expect::BadPublicKey,
		&payload,
		valid,
		p_plus(1),
	);
	push(
		"public_key_noncanonical_y_p",
		Expect::BadPublicKey,
		&payload,
		valid,
		p_plus(0),
	);

	// The smallest y with no x on the curve.
	let off_curve = (2u8..=255)
		.map(|y| {
			let mut bytes = [0u8; 32];
			bytes[0] = y;
			bytes
		})
		.find(|bytes| CompressedEdwardsY(*bytes).decompress().is_none())
		.expect("some small y is off the curve");
	push(
		"public_key_not_on_curve",
		Expect::BadPublicKey,
		&payload,
		valid,
		off_curve,
	);

	// Mixed-order public key A = a·B + T. Honest signing with a satisfies the
	// cofactored equation only; the policy is cofactored, so it verifies.
	let mixed_a = (key.public + EIGHT_TORSION[1]).compress().to_bytes();
	let r = key.nonce(&message);
	push(
		"public_key_mixed_order",
		Expect::Ok,
		&payload,
		key.sign_with(&message, &mixed_a, &(B * r), r),
		mixed_a,
	);

	// Small-order R (order 8, x != 0) with S = k·a: cofactored-valid.
	push(
		"r_small_order_8",
		Expect::Ok,
		&payload,
		key.sign_with(&message, &pk, &EIGHT_TORSION[1], Scalar::ZERO),
		pk,
	);
	// Mixed-order R = r·B + T: cofactored-valid.
	push(
		"r_mixed_order",
		Expect::Ok,
		&payload,
		key.sign_with(&message, &pk, &(B * r + EIGHT_TORSION[1]), r),
		pk,
	);
	// R with x = 0 is refused even when the equation would hold.
	push(
		"r_identity",
		Expect::BadSignature,
		&payload,
		key.sign_with(&message, &pk, &EIGHT_TORSION[0], Scalar::ZERO),
		pk,
	);
	push(
		"r_order_2",
		Expect::BadSignature,
		&payload,
		key.sign_with(&message, &pk, &EIGHT_TORSION[4], Scalar::ZERO),
		pk,
	);

	// R encoded non-canonically as y = p (which is y = 0, an order-4 point).
	// With the canonical encoding this signature would verify; the encoding
	// alone must make it fail.
	let r_noncanonical = p_plus(0);
	let k = hram(&r_noncanonical, &pk, &message);
	let mut sig = [0u8; 64];
	sig[..32].copy_from_slice(&r_noncanonical);
	sig[32..].copy_from_slice((k * key.secret).as_bytes());
	push(
		"r_noncanonical_y_p",
		Expect::BadSignature,
		&payload,
		sig,
		pk,
	);
	let r_canonical = CompressedEdwardsY(r_noncanonical)
		.decompress()
		.expect("y = p reduces to y = 0")
		.compress()
		.to_bytes();
	let k = hram(&r_canonical, &pk, &message);
	sig[..32].copy_from_slice(&r_canonical);
	sig[32..].copy_from_slice((k * key.secret).as_bytes());
	push("r_canonical_y_0_control", Expect::Ok, &payload, sig, pk);

	out
}

/// The field element 1, little-endian.
fn one() -> [u8; 32] {
	let mut v = [0u8; 32];
	v[0] = 1;
	v
}

/// The corpus as tab-separated lines: name, expected code, expected name,
/// payload, signature and public key in lowercase hex.
pub fn corpus() -> String {
	let mut out = String::from(
		"# sigil signature edge cases: name\\tcode\\tresult\\tpayload\\tsignature\\tpublic_key\n",
	);
	for case in cases() {
		let _ = writeln!(
			out,
			"{}\t{}\t{}\t{}\t{}\t{}",
			case.name,
			case.expect.code(),
			case.expect.name(),
			hex(&case.payload),
			hex(&case.signature),
			hex(&case.public_key)
		);
	}
	out
}

/// Passphrase of the generated signing fixtures. Public by design: these
/// keys are test fixtures and authorize nothing.
pub const SIGN_FIXTURE_PASSPHRASE: &str = "sign-vectors-not-for-production";

/// Cheap-parameter keyfiles and a hot bundle from fixed seeds, so the
/// signing differential can open thousands of mutations quickly. Returns
/// (file name, bytes).
pub fn sign_fixtures() -> Vec<(&'static str, Vec<u8>)> {
	use sigil_sign::{KdfParams, wrap_hot_bundle, wrap_key};
	let pass = SIGN_FIXTURE_PASSPHRASE.as_bytes();
	let cheap = KdfParams { t: 1, m: 64, p: 1 };
	let lanes = KdfParams { t: 2, m: 128, p: 2 };
	vec![
		(
			"cheap.key",
			wrap_key(&[0x5a; 32], pass, &[0x11; 16], &[0x22; 24], cheap).expect("wrap"),
		),
		(
			"cheap_lanes.key",
			wrap_key(&[0x6b; 32], pass, &[0x33; 16], &[0x44; 24], lanes).expect("wrap"),
		),
		(
			"cheap.hot.sealed",
			wrap_hot_bundle(&[0x5a; 32], pass, &[0x55; 16], &[0x66; 24], cheap).expect("wrap"),
		),
		("passphrase.txt", pass.to_vec()),
	]
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn committed_corpus_matches_the_generator() {
		let committed = include_str!("../../../examples/verify_edge_vectors/cases.tsv");
		assert_eq!(
			committed,
			corpus(),
			"regenerate examples/verify_edge_vectors/cases.tsv"
		);
	}

	#[test]
	fn committed_sign_fixtures_match_the_generator() {
		let dir =
			std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../examples/sign_vectors");
		for (name, bytes) in sign_fixtures() {
			let committed =
				std::fs::read(dir.join(name)).unwrap_or_else(|e| panic!("read {name}: {e}"));
			assert_eq!(committed, bytes, "regenerate examples/sign_vectors/{name}");
		}
	}

	#[test]
	fn case_names_are_unique() {
		let names: std::collections::HashSet<String> =
			cases().into_iter().map(|c| c.name).collect();
		assert_eq!(names.len(), cases().len());
	}

	#[test]
	fn group_order_constant_is_the_basepoint_order() {
		// L·B is the identity, and the constant is canonical-rejected by dalek
		// (L itself is not a canonical scalar).
		let l = Scalar::from_bytes_mod_order(GROUP_ORDER);
		assert_eq!(l, Scalar::ZERO);
		assert!(bool::from(
			Scalar::from_canonical_bytes(GROUP_ORDER).is_none()
		));
		let mut l_minus_1 = GROUP_ORDER;
		l_minus_1[0] -= 1;
		assert!(bool::from(
			Scalar::from_canonical_bytes(l_minus_1).is_some()
		));
	}

	#[test]
	fn honest_signature_satisfies_the_cofactorless_equation_too() {
		// Sanity check on the generator's signer, independent of any verifier
		// under test: [S]B = R + [k]A for an ordinary signature.
		let key = Key::from_seed(0xa5);
		let message = transcript(b"x");
		let sig = key.sign(&message);
		let r = CompressedEdwardsY(sig[..32].try_into().unwrap())
			.decompress()
			.unwrap();
		let s = Scalar::from_canonical_bytes(sig[32..].try_into().unwrap()).unwrap();
		let pk = key.public.compress().to_bytes();
		let k = hram(&sig[..32].try_into().unwrap(), &pk, &message);
		assert_eq!(B * s, r + k * key.public);
	}
}
