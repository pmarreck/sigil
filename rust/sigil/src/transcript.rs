//! The signing transcript: what an Ed25519 signature in sigil covers.
//!
//! A fixed header binds the domain, the algorithm and the payload length, and
//! the payload bytes follow verbatim. Matches `src/transcript.zig`.

/// Domain separator. A signature made for any other protocol cannot verify.
pub const DOMAIN: &[u8] = b"sigil.transcript.v1";

/// Algorithm identifier for Ed25519 inside the transcript.
pub const ALGORITHM_ED25519: u8 = 1;

/// Length of the header: domain, one algorithm byte, a big-endian u64 length.
pub const HEADER_LEN: usize = DOMAIN.len() + 1 + 8;

/// The transcript header for an Ed25519 payload of `payload_len` bytes.
pub fn header(payload_len: u64) -> [u8; HEADER_LEN] {
	let mut out = [0u8; HEADER_LEN];
	out[..DOMAIN.len()].copy_from_slice(DOMAIN);
	out[DOMAIN.len()] = ALGORITHM_ED25519;
	out[DOMAIN.len() + 1..].copy_from_slice(&payload_len.to_be_bytes());
	out
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn header_layout_is_domain_algorithm_then_big_endian_length() {
		let h = header(0x0102_0304_0506_0708);
		assert_eq!(&h[..19], b"sigil.transcript.v1");
		assert_eq!(h[19], 1);
		assert_eq!(&h[20..], &[1, 2, 3, 4, 5, 6, 7, 8]);
		assert_eq!(HEADER_LEN, 28);
	}
}
