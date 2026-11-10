//! Ed25519 verification under sigil's acceptance rules.
//!
//! These are explicit rather than inherited from a library default, because
//! Ed25519 libraries disagree on edge cases and sigil's two implementations
//! must not. The rules match `src/verify.zig` on Zig 0.16's standard library,
//! as characterized by `examples/verify_edge_vectors`:
//!
//! 1. The public key must be a canonical encoding of a curve point that is not
//!    of small order. Otherwise the key is bad, whatever the signature.
//! 2. `S` must be canonical (less than the group order).
//! 3. `R` must be a canonical encoding of a curve point with x != 0.
//! 4. Cofactored equation: `8·S·B = 8·R + 8·k·A`, with
//!    `k = SHA-512(R || A || transcript) mod L`.

use crate::transcript;
use curve25519_dalek::edwards::{CompressedEdwardsY, EdwardsPoint};
use curve25519_dalek::scalar::Scalar;
use curve25519_dalek::traits::IsIdentity;
use sha2::{Digest, Sha512};

/// Length in bytes of an Ed25519 signature.
pub const SIGNATURE_LEN: usize = 64;

/// Length in bytes of an Ed25519 public key.
pub const PUBLIC_KEY_LEN: usize = 32;

/// Why a signature was not accepted.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VerifyError {
	/// The signature does not verify over these bytes under this key. The only
	/// accusation against the document.
	BadSignature,
	/// The key is not a usable Ed25519 public key: a configuration fault, not
	/// evidence about the document.
	BadPublicKey,
}

/// True when the 255-bit field element in `bytes` (sign bit ignored) is less
/// than p = 2^255 - 19, the only encodings sigil accepts.
fn is_canonical_field(bytes: &[u8; 32]) -> bool {
	let top_all_ones = bytes[31] & 0x7f == 0x7f && bytes[1..31].iter().all(|&b| b == 0xff);
	!(top_all_ones && bytes[0] >= 0xed)
}

/// True when a canonical encoding has y = 1 or y = p - 1, the two points with
/// x = 0 (the identity and the point of order 2).
fn has_zero_x(bytes: &[u8; 32]) -> bool {
	let low_zero = bytes[1..31].iter().all(|&b| b == 0) && bytes[31] & 0x7f == 0;
	let y_is_one = bytes[0] == 1 && low_zero;
	let high_ones = bytes[1..31].iter().all(|&b| b == 0xff) && bytes[31] & 0x7f == 0x7f;
	let y_is_p_minus_one = bytes[0] == 0xec && high_ones;
	y_is_one || y_is_p_minus_one
}

fn decode_point(bytes: &[u8; 32]) -> Option<EdwardsPoint> {
	if !is_canonical_field(bytes) {
		return None;
	}
	CompressedEdwardsY(*bytes).decompress()
}

/// Verify `signature` over the sigil transcript of `payload` under
/// `public_key`. Allocation-free; the payload is streamed into the hash.
pub fn verify(
	payload: &[u8],
	signature: &[u8; SIGNATURE_LEN],
	public_key: &[u8; PUBLIC_KEY_LEN],
) -> Result<(), VerifyError> {
	let a = decode_point(public_key).ok_or(VerifyError::BadPublicKey)?;
	if a.is_small_order() {
		return Err(VerifyError::BadPublicKey);
	}

	let mut r_bytes = [0u8; 32];
	r_bytes.copy_from_slice(&signature[..32]);
	let mut s_bytes = [0u8; 32];
	s_bytes.copy_from_slice(&signature[32..]);

	let s = Option::<Scalar>::from(Scalar::from_canonical_bytes(s_bytes))
		.ok_or(VerifyError::BadSignature)?;
	if has_zero_x(&r_bytes) {
		return Err(VerifyError::BadSignature);
	}
	let r = decode_point(&r_bytes).ok_or(VerifyError::BadSignature)?;

	let mut hash = Sha512::new();
	hash.update(r_bytes);
	hash.update(public_key);
	hash.update(transcript::header(payload.len() as u64));
	hash.update(payload);
	let k = Scalar::from_bytes_mod_order_wide(&hash.finalize().into());

	// S·B - k·A - R, which is zero exactly for a cofactorless-valid signature
	// and of small order for one that is only cofactored-valid.
	let difference = EdwardsPoint::vartime_double_scalar_mul_basepoint(&k, &(-a), &s) - r;
	if difference.mul_by_cofactor().is_identity() {
		Ok(())
	} else {
		Err(VerifyError::BadSignature)
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	fn p_bytes() -> [u8; 32] {
		let mut p = [0xffu8; 32];
		p[0] = 0xed;
		p[31] = 0x7f;
		p
	}

	#[test]
	fn canonical_field_boundary_is_p() {
		let mut below = p_bytes();
		below[0] = 0xec;
		assert!(is_canonical_field(&below));
		assert!(!is_canonical_field(&p_bytes()));
		let mut top = p_bytes();
		top[0] = 0xff;
		assert!(!is_canonical_field(&top));
		// The sign bit does not participate.
		let mut signed = below;
		signed[31] |= 0x80;
		assert!(is_canonical_field(&signed));
		assert!(is_canonical_field(&[0u8; 32]));
	}

	#[test]
	fn zero_x_points_are_exactly_y_one_and_y_p_minus_one() {
		let mut one = [0u8; 32];
		one[0] = 1;
		assert!(has_zero_x(&one));
		one[31] |= 0x80;
		assert!(has_zero_x(&one), "negative zero is still x = 0");
		let mut p_minus_1 = p_bytes();
		p_minus_1[0] = 0xec;
		assert!(has_zero_x(&p_minus_1));
		let mut two = [0u8; 32];
		two[0] = 2;
		assert!(!has_zero_x(&two));
		assert!(!has_zero_x(&[0u8; 32]));
	}

	#[test]
	fn x_is_zero_exactly_for_the_points_of_order_one_and_two() {
		// On twisted Edwards curves the points with x = 0 are (0, 1) and
		// (0, -1), which are exactly those with 2P = identity. Checked over the
		// whole small-order subgroup plus mixed-order points.
		let base = curve25519_dalek::constants::ED25519_BASEPOINT_POINT;
		for torsion in curve25519_dalek::constants::EIGHT_TORSION {
			for point in [torsion, base + torsion] {
				let bytes = point.compress().to_bytes();
				assert_eq!(has_zero_x(&bytes), (point + point).is_identity());
			}
		}
	}
}
