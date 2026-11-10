//! Minting sigil keys and documents: the Rust counterpart of `src/sign.zig`
//! and `src/ffi_sign.zig`, held to them by sigil's `tests/differential`.
//!
//! Not for products. Applications depend on the `sigil` crate, which cannot
//! sign. Nothing here returns a secret key or seed except
//! [`hot_bundle_open`], the one deliberate export for restoring an online
//! issuer.
//!
//! The formats are pure functions of their inputs: seeds, salts and nonces
//! are parameters, and only [`keygen`] and [`keygen_with_recovery`] read the
//! system entropy source.

#![forbid(unsafe_code)]

mod json;
pub mod paper;
mod pdf;
pub mod qr;

use argon2::{Algorithm, Argon2, Block, Params, Version};
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use ed25519_dalek::{Signer, SigningKey};
use zeroize::{Zeroize, Zeroizing};

/// Ed25519 seed length.
pub const SEED_LEN: usize = 32;
/// Argon2id salt length.
pub const SALT_LEN: usize = 16;
/// XChaCha20-Poly1305 nonce length.
pub const NONCE_LEN: usize = 24;
const TAG_LEN: usize = 16;
const KEY_LEN: usize = 32;

/// Format tag of a passphrase-encrypted signing keyfile.
pub const KEYFILE_VERSION: &str = "secret-key-v1";
/// Format tag of a sealed hot bundle (PKCS#8 for restoring an online issuer).
pub const HOT_BUNDLE_VERSION: &str = "hot-bundle-v1";
const KDF_NAME: &[u8] = b"Argon2id";

/// RFC 8410 PKCS#8 prefix for an Ed25519 private key; the seed follows.
const PKCS8_PREFIX: [u8; 16] = [
	0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20,
];
const PKCS8_LEN: usize = PKCS8_PREFIX.len() + SEED_LEN;

/// Argon2id cost parameters as recorded in a keyfile.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct KdfParams {
	/// Iterations.
	pub t: u32,
	/// Memory in KiB.
	pub m: u32,
	/// Lanes (at most 2^24 - 1).
	pub p: u32,
}

/// The parameters sigil writes into new keyfiles: 64 MiB, three passes.
pub const DEFAULT_KDF_PARAMS: KdfParams = KdfParams {
	t: 3,
	m: 64 * 1024,
	p: 1,
};

/// Why a signing-side operation failed. Codes match `include/sigil_sign.h`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	/// An allocation failed, including Argon2 memory for a huge `m`.
	OutOfMemory,
	/// Not a well-formed sigil keyfile or bundle.
	MalformedKeyfile,
	/// A format version or KDF this implementation does not speak.
	UnsupportedKeyfile,
	/// Wrong passphrase, or the file was altered.
	AuthFailed,
	/// The recorded Argon2 parameters are unusable.
	BadKdfParams,
	/// The file does not contain a usable key.
	BadSeed,
	/// A passphrase is required.
	EmptyPassphrase,
	/// The system entropy source could not be read.
	NoEntropy,
	/// A keyfile was offered where a hot bundle is required.
	NotHotBundle,
	/// An artifact does not fit in one QR code.
	TooLargeForQr,
}

impl Error {
	/// Every variant, for exhaustive tests.
	pub const ALL: [Error; 10] = [
		Error::OutOfMemory,
		Error::MalformedKeyfile,
		Error::UnsupportedKeyfile,
		Error::AuthFailed,
		Error::BadKdfParams,
		Error::BadSeed,
		Error::EmptyPassphrase,
		Error::NoEntropy,
		Error::NotHotBundle,
		Error::TooLargeForQr,
	];

	/// The C ABI code.
	pub const fn code(self) -> i32 {
		match self {
			Error::OutOfMemory => -10,
			Error::MalformedKeyfile => -20,
			Error::UnsupportedKeyfile => -21,
			Error::AuthFailed => -22,
			Error::BadKdfParams => -23,
			Error::BadSeed => -24,
			Error::EmptyPassphrase => -25,
			Error::NoEntropy => -26,
			Error::NotHotBundle => -27,
			Error::TooLargeForQr => -28,
		}
	}
}

/// `sigil_sign_strerror` for any code, never empty.
pub fn strerror(code: i32) -> &'static core::ffi::CStr {
	match code {
		0 => c"ok",
		-3 => c"required argument was NULL",
		-9 => c"output buffer too small",
		-10 => c"out of memory",
		-20 => c"keyfile is not a well-formed sigil keyfile",
		-21 => c"keyfile was written by a newer sigil",
		-22 => c"wrong passphrase, or the keyfile has been altered",
		-23 => c"keyfile records unusable key-derivation parameters",
		-24 => c"keyfile does not contain a usable key",
		-25 => c"a passphrase is required",
		-26 => c"could not read from the system entropy source",
		-27 => c"not a hot bundle (a keyfile cannot be opened into a seed)",
		-28 => c"artifact is too large for a single QR code",
		_ => c"unknown error",
	}
}

/// Argon2id into a 32-byte key. Memory is reserved fallibly, so a keyfile
/// recording an enormous `m` reports out-of-memory instead of aborting.
fn derive_key(
	passphrase: &[u8],
	salt: &[u8; SALT_LEN],
	params: KdfParams,
) -> Result<Zeroizing<[u8; KEY_LEN]>, Error> {
	let p = Params::new(params.m, params.t, params.p, Some(KEY_LEN))
		.map_err(|_| Error::BadKdfParams)?;
	let blocks_needed = p.block_count();
	let mut blocks: Vec<Block> = Vec::new();
	blocks
		.try_reserve_exact(blocks_needed)
		.map_err(|_| Error::OutOfMemory)?;
	blocks.resize(blocks_needed, Block::default());
	let mut key = Zeroizing::new([0u8; KEY_LEN]);
	Argon2::new(Algorithm::Argon2id, Version::V0x13, p)
		.hash_password_into_with_memory(passphrase, salt, key.as_mut(), &mut blocks)
		.map_err(|_| Error::BadKdfParams)?;
	for block in &mut blocks {
		*block = Block::default();
	}
	Ok(key)
}

/// Associated data binding the format, KDF parameters and salt.
fn aad(version: &str, params: KdfParams, salt: &[u8; SALT_LEN]) -> Vec<u8> {
	let mut out = b"sigil-".to_vec();
	out.extend_from_slice(version.as_bytes());
	out.extend_from_slice(&params.t.to_le_bytes());
	out.extend_from_slice(&params.m.to_le_bytes());
	out.extend_from_slice(&params.p.to_le_bytes());
	out.extend_from_slice(salt);
	out
}

fn seal_blob(
	version: &str,
	plaintext: &[u8],
	passphrase: &[u8],
	salt: &[u8; SALT_LEN],
	nonce: &[u8; NONCE_LEN],
	params: KdfParams,
) -> Result<Vec<u8>, Error> {
	let key = derive_key(passphrase, salt, params)?;
	let cipher = XChaCha20Poly1305::new(key.as_ref().into());
	let blob = cipher
		.encrypt(
			XNonce::from_slice(nonce),
			Payload {
				msg: plaintext,
				aad: &aad(version, params, salt),
			},
		)
		.map_err(|_| Error::OutOfMemory)?;
	let mut out = format!(
		"{{\"sigil\":\"{version}\",\"kdf\":\"Argon2id\",\"t\":{},\"m\":{},\"p\":{},\"salt\":\"",
		params.t, params.m, params.p
	)
	.into_bytes();
	out.extend_from_slice(&sigil::printable_encode(salt));
	out.extend_from_slice(b"\",\"nonce\":\"");
	out.extend_from_slice(&sigil::printable_encode(nonce));
	out.extend_from_slice(b"\",\"ciphertext\":\"");
	out.extend_from_slice(&sigil::printable_encode(&blob));
	out.extend_from_slice(b"\"}\n");
	Ok(out)
}

fn decode_exact<const N: usize>(encoded: &[u8]) -> Result<[u8; N], Error> {
	sigil::decode_lenient(encoded)
		.try_into()
		.map_err(|_| Error::MalformedKeyfile)
}

/// Open a sealed file of `version`, returning its plaintext. A file of a
/// different format is `wrong_format`.
fn open_blob<const N: usize>(
	version: &str,
	wrong_format: Error,
	file: &[u8],
	passphrase: &[u8],
) -> Result<Zeroizing<[u8; N]>, Error> {
	let w = json::parse(file).ok_or(Error::MalformedKeyfile)?;
	if w.sigil != version.as_bytes() {
		return Err(wrong_format);
	}
	if w.kdf != KDF_NAME {
		return Err(Error::UnsupportedKeyfile);
	}
	let salt: [u8; SALT_LEN] = decode_exact(&w.salt)?;
	let nonce: [u8; NONCE_LEN] = decode_exact(&w.nonce)?;
	let blob = sigil::decode_lenient(&w.ciphertext);
	if blob.len() != N + TAG_LEN {
		return Err(Error::MalformedKeyfile);
	}
	let params = KdfParams {
		t: w.t,
		m: w.m,
		p: w.p,
	};
	let key = derive_key(passphrase, &salt, params)?;
	let cipher = XChaCha20Poly1305::new(key.as_ref().into());
	let mut plaintext = cipher
		.decrypt(
			XNonce::from_slice(&nonce),
			Payload {
				msg: &blob,
				aad: &aad(version, params, &salt),
			},
		)
		.map_err(|_| Error::AuthFailed)?;
	let mut out = Zeroizing::new([0u8; N]);
	out.copy_from_slice(&plaintext);
	plaintext.zeroize();
	Ok(out)
}

/// Encrypt `seed` into keyfile text with the given salt, nonce and costs.
pub fn wrap_key(
	seed: &[u8; SEED_LEN],
	passphrase: &[u8],
	salt: &[u8; SALT_LEN],
	nonce: &[u8; NONCE_LEN],
	params: KdfParams,
) -> Result<Vec<u8>, Error> {
	seal_blob(KEYFILE_VERSION, seed, passphrase, salt, nonce, params)
}

/// Encrypt `seed`'s PKCS#8 into hot-bundle text.
pub fn wrap_hot_bundle(
	seed: &[u8; SEED_LEN],
	passphrase: &[u8],
	salt: &[u8; SALT_LEN],
	nonce: &[u8; NONCE_LEN],
	params: KdfParams,
) -> Result<Vec<u8>, Error> {
	let mut der = Zeroizing::new([0u8; PKCS8_LEN]);
	der[..PKCS8_PREFIX.len()].copy_from_slice(&PKCS8_PREFIX);
	der[PKCS8_PREFIX.len()..].copy_from_slice(seed);
	seal_blob(
		HOT_BUNDLE_VERSION,
		der.as_ref(),
		passphrase,
		salt,
		nonce,
		params,
	)
}

fn unwrap_key(keyfile: &[u8], passphrase: &[u8]) -> Result<Zeroizing<[u8; SEED_LEN]>, Error> {
	open_blob(
		KEYFILE_VERSION,
		Error::UnsupportedKeyfile,
		keyfile,
		passphrase,
	)
}

/// Sign `payload`'s transcript with the key in `keyfile` and return a
/// finished envelope.
pub fn seal(keyfile: &[u8], passphrase: &[u8], payload: &[u8]) -> Result<Vec<u8>, Error> {
	let seed = unwrap_key(keyfile, passphrase)?;
	let key = SigningKey::from_bytes(&seed);
	let mut transcript = sigil::transcript::header(payload.len() as u64).to_vec();
	transcript.extend_from_slice(payload);
	let signature = key.sign(&transcript).to_bytes();
	Ok(sigil::write_envelope(payload, &signature))
}

/// The public key of a keyfile, derived from its decrypted seed.
pub fn keyfile_public_key(keyfile: &[u8], passphrase: &[u8]) -> Result<[u8; 32], Error> {
	let seed = unwrap_key(keyfile, passphrase)?;
	Ok(SigningKey::from_bytes(&seed).verifying_key().to_bytes())
}

const BASE64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn base64(bytes: &[u8]) -> Vec<u8> {
	let mut out = Vec::with_capacity(bytes.len().div_ceil(3) * 4);
	for chunk in bytes.chunks(3) {
		let n = chunk
			.iter()
			.enumerate()
			.fold(0u32, |acc, (i, &b)| acc | u32::from(b) << (16 - 8 * i));
		for i in 0..4 {
			out.push(if i <= chunk.len() {
				BASE64[(n >> (18 - 6 * i) & 0x3f) as usize]
			} else {
				b'='
			});
		}
	}
	out
}

/// Open a hot bundle into its PKCS#8 as RFC 7468 PEM. The one function that
/// hands a private key out, by design; a keyfile is refused before any
/// decryption.
pub fn hot_bundle_open(bundle: &[u8], passphrase: &[u8]) -> Result<Zeroizing<Vec<u8>>, Error> {
	let der: Zeroizing<[u8; PKCS8_LEN]> =
		open_blob(HOT_BUNDLE_VERSION, Error::NotHotBundle, bundle, passphrase)?;
	let mut pem = Zeroizing::new(b"-----BEGIN PRIVATE KEY-----\n".to_vec());
	pem.extend_from_slice(&base64(der.as_ref()));
	pem.extend_from_slice(b"\n-----END PRIVATE KEY-----\n");
	Ok(pem)
}

fn random<const N: usize>() -> Result<Zeroizing<[u8; N]>, Error> {
	let mut out = Zeroizing::new([0u8; N]);
	getrandom::getrandom(out.as_mut()).map_err(|_| Error::NoEntropy)?;
	Ok(out)
}

/// Generate a fresh key and return its keyfile text.
pub fn keygen(passphrase: &[u8]) -> Result<Vec<u8>, Error> {
	if passphrase.is_empty() {
		return Err(Error::EmptyPassphrase);
	}
	let (seed, salt, nonce) = (
		random::<SEED_LEN>()?,
		random::<SALT_LEN>()?,
		random::<NONCE_LEN>()?,
	);
	wrap_key(&seed, passphrase, &salt, &nonce, DEFAULT_KDF_PARAMS)
}

/// Generate a fresh key and return both custody artifacts from the one seed:
/// the keyfile and the hot bundle.
pub fn keygen_with_recovery(passphrase: &[u8]) -> Result<(Vec<u8>, Vec<u8>), Error> {
	if passphrase.is_empty() {
		return Err(Error::EmptyPassphrase);
	}
	let (seed, salt, nonce) = (
		random::<SEED_LEN>()?,
		random::<SALT_LEN>()?,
		random::<NONCE_LEN>()?,
	);
	let (bundle_salt, bundle_nonce) = (random::<SALT_LEN>()?, random::<NONCE_LEN>()?);
	let keyfile = wrap_key(&seed, passphrase, &salt, &nonce, DEFAULT_KDF_PARAMS)?;
	let bundle = wrap_hot_bundle(
		&seed,
		passphrase,
		&bundle_salt,
		&bundle_nonce,
		DEFAULT_KDF_PARAMS,
	)?;
	Ok((keyfile, bundle))
}

#[cfg(test)]
mod tests {
	use super::*;

	const CHEAP: KdfParams = KdfParams { t: 1, m: 64, p: 1 };

	#[test]
	fn rfc8032_test_1_through_the_keyfile() {
		// RFC 8032 section 7.1, test 1: the seed's public key.
		let seed: [u8; 32] = std::array::from_fn(|i| {
			u8::from_str_radix(
				&"9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
					[2 * i..2 * i + 2],
				16,
			)
			.unwrap()
		});
		let file = wrap_key(&seed, b"pass", &[0x11; 16], &[0x22; 24], CHEAP).unwrap();
		let pk = keyfile_public_key(&file, b"pass").unwrap();
		let hex: String = pk.iter().map(|b| format!("{b:02x}")).collect();
		assert_eq!(
			hex,
			"d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
		);
	}

	#[test]
	fn sealed_envelope_verifies_and_wrong_passphrase_fails_authentication() {
		let file = wrap_key(&[0xa5; 32], b"pass", &[0x11; 16], &[0x22; 24], CHEAP).unwrap();
		let envelope = seal(&file, b"pass", b"payload").unwrap();
		let pk = keyfile_public_key(&file, b"pass").unwrap();
		assert_eq!(
			sigil::verify_envelope(&envelope, &pk),
			Ok(b"payload".to_vec())
		);
		assert_eq!(seal(&file, b"wrong", b"payload"), Err(Error::AuthFailed));
	}

	#[test]
	fn keyfile_and_bundle_are_not_interchangeable() {
		let file = wrap_key(&[0xa5; 32], b"pass", &[0x11; 16], &[0x22; 24], CHEAP).unwrap();
		let bundle =
			wrap_hot_bundle(&[0xa5; 32], b"pass", &[0x11; 16], &[0x22; 24], CHEAP).unwrap();
		assert_eq!(
			hot_bundle_open(&file, b"pass").map(|_| ()),
			Err(Error::NotHotBundle)
		);
		assert_eq!(seal(&bundle, b"pass", b"x"), Err(Error::UnsupportedKeyfile));
		let pem = hot_bundle_open(&bundle, b"pass").unwrap();
		assert!(pem.starts_with(b"-----BEGIN PRIVATE KEY-----\nMC4CAQAwBQYDK2VwBCIEI"));
	}

	#[test]
	fn weak_kdf_parameters_are_refused_and_huge_memory_is_out_of_memory() {
		let salt = [0x11; 16];
		assert_eq!(
			derive_key(b"p", &salt, KdfParams { t: 0, m: 64, p: 1 }).map(|_| ()),
			Err(Error::BadKdfParams)
		);
		assert_eq!(
			derive_key(b"p", &salt, KdfParams { t: 1, m: 7, p: 1 }).map(|_| ()),
			Err(Error::BadKdfParams)
		);
		assert_eq!(
			derive_key(b"p", &salt, KdfParams { t: 1, m: 15, p: 2 }).map(|_| ()),
			Err(Error::BadKdfParams)
		);
		assert_eq!(
			derive_key(b"p", &salt, KdfParams { t: 1, m: 64, p: 0 }).map(|_| ()),
			Err(Error::BadKdfParams)
		);
		assert!(derive_key(b"p", &salt, KdfParams { t: 1, m: 16, p: 2 }).is_ok());
		assert_eq!(
			derive_key(
				b"p",
				&salt,
				KdfParams {
					t: 1,
					m: u32::MAX,
					p: 1
				}
			)
			.map(|_| ()),
			Err(Error::OutOfMemory)
		);
	}

	#[test]
	fn base64_matches_rfc4648_vectors() {
		for (input, expected) in [
			("", ""),
			("f", "Zg=="),
			("fo", "Zm8="),
			("foo", "Zm9v"),
			("foob", "Zm9vYg=="),
			("fooba", "Zm9vYmE="),
			("foobar", "Zm9vYmFy"),
		] {
			assert_eq!(base64(input.as_bytes()), expected.as_bytes());
		}
	}

	#[test]
	fn error_codes_and_messages_are_distinct() {
		let codes: std::collections::HashSet<i32> = Error::ALL.iter().map(|e| e.code()).collect();
		assert_eq!(codes.len(), Error::ALL.len());
		for e in Error::ALL {
			assert_ne!(strerror(e.code()), c"unknown error");
		}
	}
}
