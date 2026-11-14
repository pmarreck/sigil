//! mecha_policy: the shared Mecha entitlement policy.
//!
//! The Rust counterpart of the Zig library in the `mecha_policy` repository,
//! held to it by sigil's `tests/differential`. Contract: sigil
//! `docs/MECHA_LICENSE_CONTRACT_V1.md`. Pure: no I/O and no clock. Every
//! input, including the verified payload bytes, the verifying trust role,
//! today's UTC date and the clock high-water mark, comes from the caller.
//! Dates are `YYYY-MM-DD`, all UTC; zero-padded ISO dates order
//! lexicographically, which is the only date arithmetic needed.

#![forbid(unsafe_code)]

mod json;

use sha2::{Digest, Sha256};

/// Package version, identical to the Zig library's `mecha_policy_version()`.
pub const VERSION: &str = "0.3.0";

/// ABI contract version, identical to `mecha_policy_abi_version()`.
pub const ABI_VERSION: u32 = 2;

/// Which trust role's public key verified the envelope. Each role authorizes
/// only its own grant classes, so a leaked beta key cannot mint paid grants.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
	/// The beta-license role.
	BetaLicense,
	/// The paid-license role.
	PaidLicense,
}

impl Role {
	/// The C ABI code for a role, or `None` for an unknown one.
	pub fn from_code(code: u8) -> Option<Role> {
		match code {
			0 => Some(Role::BetaLicense),
			1 => Some(Role::PaidLicense),
			_ => None,
		}
	}
}

/// The shared license decision codes. `NoLicense` and `NotAuthentic` belong
/// to layers upstream of [`decide`] and are never returned by it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
	/// The request is admitted.
	Authorized,
	/// The app holds no license.
	NoLicense,
	/// The license failed signature verification.
	NotAuthentic,
	/// The payload violates the schema.
	Malformed,
	/// The grant is for another product.
	WrongProduct,
	/// The grant's expiry date has passed.
	Expired,
	/// The app version is above the grant's ceiling.
	VersionCeiling,
	/// The verifying role may not authorize this grant class.
	ClassKeyMismatch,
	/// Today is before a date this install has already seen.
	ClockRollback,
	/// The grant does not cover the requested operation.
	OperationNotGranted,
}

impl Decision {
	/// Every variant, in code order.
	pub const ALL: [Decision; 10] = [
		Decision::Authorized,
		Decision::NoLicense,
		Decision::NotAuthentic,
		Decision::Malformed,
		Decision::WrongProduct,
		Decision::Expired,
		Decision::VersionCeiling,
		Decision::ClassKeyMismatch,
		Decision::ClockRollback,
		Decision::OperationNotGranted,
	];

	/// The C ABI code.
	pub const fn code(self) -> u8 {
		match self {
			Decision::Authorized => 0,
			Decision::NoLicense => 1,
			Decision::NotAuthentic => 2,
			Decision::Malformed => 3,
			Decision::WrongProduct => 4,
			Decision::Expired => 5,
			Decision::VersionCeiling => 6,
			Decision::ClassKeyMismatch => 7,
			Decision::ClockRollback => 8,
			Decision::OperationNotGranted => 9,
		}
	}

	/// The stable name used by status surfaces and logs.
	pub const fn name(self) -> &'static core::ffi::CStr {
		match self {
			Decision::Authorized => c"authorized",
			Decision::NoLicense => c"no_license",
			Decision::NotAuthentic => c"not_authentic",
			Decision::Malformed => c"malformed",
			Decision::WrongProduct => c"wrong_product",
			Decision::Expired => c"expired",
			Decision::VersionCeiling => c"version_ceiling",
			Decision::ClassKeyMismatch => c"class_key_mismatch",
			Decision::ClockRollback => c"clock_rollback",
			Decision::OperationNotGranted => c"operation_not_granted",
		}
	}
}

/// Installation-certificate decision codes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InstallDecision {
	/// The certificate admits this machine under this license.
	Valid,
	/// The certificate violates the schema.
	Malformed,
	/// The certificate is for another product.
	WrongProduct,
	/// The certificate binds another machine.
	OtherMachine,
	/// The certificate binds another license.
	OtherLicense,
	/// The certificate's expiry date has passed.
	Expired,
	/// Today is before a date this install has already seen.
	ClockRollback,
}

impl InstallDecision {
	/// Every variant, in code order.
	pub const ALL: [InstallDecision; 7] = [
		InstallDecision::Valid,
		InstallDecision::Malformed,
		InstallDecision::WrongProduct,
		InstallDecision::OtherMachine,
		InstallDecision::OtherLicense,
		InstallDecision::Expired,
		InstallDecision::ClockRollback,
	];

	/// The C ABI code.
	pub const fn code(self) -> u8 {
		match self {
			InstallDecision::Valid => 0,
			InstallDecision::Malformed => 1,
			InstallDecision::WrongProduct => 2,
			InstallDecision::OtherMachine => 3,
			InstallDecision::OtherLicense => 4,
			InstallDecision::Expired => 5,
			InstallDecision::ClockRollback => 6,
		}
	}

	/// The stable name used by status surfaces and logs.
	pub const fn name(self) -> &'static core::ffi::CStr {
		match self {
			InstallDecision::Valid => c"install_cert_valid",
			InstallDecision::Malformed => c"install_cert_malformed",
			InstallDecision::WrongProduct => c"install_cert_wrong_product",
			InstallDecision::OtherMachine => c"install_cert_other_machine",
			InstallDecision::OtherLicense => c"install_cert_other_license",
			InstallDecision::Expired => c"install_cert_expired",
			InstallDecision::ClockRollback => c"install_cert_clock_rollback",
		}
	}
}

/// Caller errors, deliberately never folded into a verdict.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
	/// `now_utc_date` is not a valid `YYYY-MM-DD` date.
	InvalidNow,
	/// A supplied hash is not 64 lowercase hex characters.
	InvalidArgument,
}

/// One admission request for [`decide`].
#[derive(Clone, Copy, Debug)]
pub struct Request<'a> {
	/// The exact bytes sigil verified.
	pub payload: &'a [u8],
	/// The role whose key verified them.
	pub verified_role: Role,
	/// The asking product, e.g. `mecha-validate`.
	pub product: &'a [u8],
	/// The asking build's major version.
	pub app_major: u32,
	/// The asking build's minor version; ignored for v1 grants.
	pub app_minor: u32,
	/// Today, `YYYY-MM-DD`, UTC.
	pub now_utc_date: &'a [u8],
	/// The latest date this install has seen, if stored.
	pub clock_high_water: Option<&'a [u8]>,
	/// The requested operation class; `None` is the app's default operation.
	pub operation: Option<&'a [u8]>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum GrantClass {
	Beta,
	Paddle,
	Comp,
	Demo,
}

fn class_of(provider: &str) -> Option<GrantClass> {
	match provider {
		"beta" => Some(GrantClass::Beta),
		"paddle" => Some(GrantClass::Paddle),
		"comp" => Some(GrantClass::Comp),
		"demo" => Some(GrantClass::Demo),
		_ => None,
	}
}

struct Grant {
	class: GrantClass,
	expiry: Option<String>,
	features: String,
	max_major: u32,
	max_minor: Option<u32>,
	product: String,
}

const V1_FIELDS: [&str; 11] = [
	"customer_email",
	"customer_name_canonical",
	"expiry",
	"features",
	"max_major",
	"offline_days",
	"payment_provider",
	"payment_ref",
	"product",
	"purchase_date",
	"v",
];

const V2_FIELDS: [&str; 12] = [
	"customer_email",
	"customer_name_canonical",
	"expiry",
	"features",
	"max_major",
	"max_minor",
	"offline_days",
	"payment_provider",
	"payment_ref",
	"product",
	"purchase_date",
	"v",
];

const CERT_FIELDS: [&str; 7] = [
	"cert_id",
	"expiry",
	"issued",
	"license_sha256",
	"machine",
	"product",
	"v",
];

/// The members of a typed record: every member must be a known field, every
/// field except those in `optional` must be present with a string value, and
/// an optional field may be absent or `null`. Returns field values in the
/// order of `fields`.
fn typed(
	members: &json::Members,
	fields: &[&str],
	optional: &[&str],
) -> Option<Vec<Option<String>>> {
	if members.iter().any(|(k, _)| !fields.contains(&k.as_str())) {
		return None;
	}
	fields
		.iter()
		.map(|f| match members.iter().find(|(k, _)| k == f) {
			Some((_, Some(v))) => Some(Some(v.clone())),
			Some((_, None)) | None if optional.contains(f) => Some(None),
			_ => None,
		})
		.collect()
}

fn parse_grant(payload: &[u8]) -> Option<Grant> {
	let members = json::parse_object(payload)?;
	let version = members.iter().find(|(k, _)| k == "v")?.1.clone()?;
	match version.as_str() {
		"1" => {
			let f = typed(&members, &V1_FIELDS, &["expiry"])?;
			let get = |name: &str| {
				f[V1_FIELDS
					.iter()
					.position(|n| *n == name)
					.expect("known field")]
				.clone()
			};
			let class = class_of(&get("payment_provider")?)?;
			if !is_valid_date(get("purchase_date")?.as_bytes()) {
				return None;
			}
			let expiry = get("expiry");
			if let Some(x) = &expiry
				&& !is_valid_date(x.as_bytes())
			{
				return None;
			}
			if class == GrantClass::Beta && expiry.is_none() {
				return None;
			}
			let max_major = zig_parse_u32(get("max_major")?.as_bytes())?;
			Some(Grant {
				class,
				expiry,
				features: get("features")?,
				max_major,
				max_minor: None,
				product: get("product")?,
			})
		}
		"2" => {
			let f = typed(&members, &V2_FIELDS, &[])?;
			let get = |name: &str| {
				f[V2_FIELDS
					.iter()
					.position(|n| *n == name)
					.expect("known field")]
				.clone()
			};
			let class = class_of(&get("payment_provider")?)?;
			if class != GrantClass::Paddle && class != GrantClass::Comp {
				return None;
			}
			let expiry = get("expiry")?;
			if !is_valid_date(get("purchase_date")?.as_bytes()) || !is_valid_date(expiry.as_bytes())
			{
				return None;
			}
			let max_major = canonical_u32(get("max_major")?.as_bytes())?;
			let max_minor = canonical_u32(get("max_minor")?.as_bytes())?;
			Some(Grant {
				class,
				expiry: Some(expiry),
				features: get("features")?,
				max_major,
				max_minor: Some(max_minor),
				product: get("product")?,
			})
		}
		_ => None,
	}
}

/// Zig 0.16 `std.fmt.parseInt(u32, s, 10)`, used for v1 `max_major`: an
/// optional `+` or `-`, digits with `_` separators allowed anywhere but the
/// ends, checked arithmetic. After `-` only zeros parse (to 0).
fn zig_parse_u32(s: &[u8]) -> Option<u32> {
	let (negative, digits) = match s.first()? {
		b'+' => (false, &s[1..]),
		b'-' => (true, &s[1..]),
		_ => (false, s),
	};
	if digits.first()? == &b'_' || digits.last()? == &b'_' {
		return None;
	}
	let mut acc: u32 = 0;
	for &c in digits {
		if c == b'_' {
			continue;
		}
		if !c.is_ascii_digit() {
			return None;
		}
		let digit = u32::from(c - b'0');
		if negative {
			// Zig negates each digit while the accumulator is zero; any
			// nonzero digit overflows an unsigned result.
			if digit != 0 {
				return None;
			}
			continue;
		}
		acc = acc.checked_mul(10)?.checked_add(digit)?;
	}
	Some(acc)
}

/// A base-10 u32 with no sign, no leading zeros ("0" itself allowed) and no
/// overflow. Used for the v2 version fields.
fn canonical_u32(s: &[u8]) -> Option<u32> {
	if s.is_empty() || (s.len() > 1 && s[0] == b'0') || !s.iter().all(u8::is_ascii_digit) {
		return None;
	}
	s.iter().try_fold(0u32, |acc, &c| {
		acc.checked_mul(10)?.checked_add(u32::from(c - b'0'))
	})
}

/// A real `YYYY-MM-DD` date in the proleptic Gregorian calendar.
pub fn is_valid_date(s: &[u8]) -> bool {
	if s.len() != 10 {
		return false;
	}
	for (i, &c) in s.iter().enumerate() {
		let ok = if i == 4 || i == 7 {
			c == b'-'
		} else {
			c.is_ascii_digit()
		};
		if !ok {
			return false;
		}
	}
	let d = |i: usize| u16::from(s[i] - b'0');
	let year = d(0) * 1000 + d(1) * 100 + d(2) * 10 + d(3);
	let month = d(5) * 10 + d(6);
	let day = d(8) * 10 + d(9);
	if !(1..=12).contains(&month) || day < 1 {
		return false;
	}
	let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
	let days = match month {
		4 | 6 | 9 | 11 => 30,
		2 if leap => 29,
		2 => 28,
		_ => 31,
	};
	day <= days
}

fn rolled_back(now: &[u8], high_water: Option<&[u8]>) -> bool {
	high_water.is_some_and(|h| is_valid_date(h) && now < h)
}

/// Evaluate one verified license payload against one admission request.
/// Order: schema, class/key binding, product, version ceiling, clock
/// rollback (only for a grant with an expiry), expiry, operation.
pub fn decide(req: &Request<'_>) -> Result<Decision, Error> {
	if !is_valid_date(req.now_utc_date) {
		return Err(Error::InvalidNow);
	}
	let Some(g) = parse_grant(req.payload) else {
		return Ok(Decision::Malformed);
	};
	let class_ok = match req.verified_role {
		Role::BetaLicense => g.class == GrantClass::Beta,
		Role::PaidLicense => g.class == GrantClass::Paddle || g.class == GrantClass::Comp,
	};
	if !class_ok {
		return Ok(Decision::ClassKeyMismatch);
	}
	if g.product.as_bytes() != req.product {
		return Ok(Decision::WrongProduct);
	}
	if req.app_major > g.max_major {
		return Ok(Decision::VersionCeiling);
	}
	if let Some(max_minor) = g.max_minor
		&& req.app_major == g.max_major
		&& req.app_minor > max_minor
	{
		return Ok(Decision::VersionCeiling);
	}
	// The mark guards an expiry: a clock set back can only extend a grant
	// that ends. A grant with no expiry has nothing to extend, so its mark
	// is not judged (contract section 9, 2026-11-11).
	if g.expiry.is_some() && rolled_back(req.now_utc_date, req.clock_high_water) {
		return Ok(Decision::ClockRollback);
	}
	if let Some(x) = &g.expiry
		&& req.now_utc_date > x.as_bytes()
	{
		return Ok(Decision::Expired);
	}
	if g.features != "full"
		&& let Some(op) = req.operation
		&& op != g.features.as_bytes()
	{
		return Ok(Decision::OperationNotGranted);
	}
	Ok(Decision::Authorized)
}

/// The value to persist as the clock high-water mark after an evaluation.
/// The mark is exactly the 10 bytes of a `YYYY-MM-DD` UTC date (contract
/// section 9); how an app stores and protects it on disk is its own.
pub fn next_high_water<'a>(now_utc_date: &'a [u8], stored: Option<&'a [u8]>) -> &'a [u8] {
	match stored {
		Some(s) if s > now_utc_date => s,
		_ => now_utc_date,
	}
}

/// One admission request for [`decide_install`].
#[derive(Clone, Copy, Debug)]
pub struct InstallRequest<'a> {
	/// The exact bytes sigil verified under the install-cert role key.
	pub cert_payload: &'a [u8],
	/// The asking product.
	pub product: &'a [u8],
	/// Lowercase hex SHA-256 of the imported license envelope bytes.
	pub license_sha256: &'a [u8],
	/// Lowercase hex from [`machine_hash`] for this product and machine.
	pub machine: &'a [u8],
	/// Today, `YYYY-MM-DD`, UTC.
	pub now_utc_date: &'a [u8],
	/// The latest date this install has seen, if stored.
	pub clock_high_water: Option<&'a [u8]>,
}

fn is_lower_hex64(s: &[u8]) -> bool {
	s.len() == 64
		&& s.iter()
			.all(|&c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}

/// Canonical lowercase UUID with version 7 and the RFC 9562 variant.
fn is_uuid_v7(s: &[u8]) -> bool {
	s.len() == 36
		&& s.iter().enumerate().all(|(i, &c)| {
			if matches!(i, 8 | 13 | 18 | 23) {
				c == b'-'
			} else {
				c.is_ascii_digit() || (b'a'..=b'f').contains(&c)
			}
		}) && s[14] == b'7'
		&& matches!(s[19], b'8' | b'9' | b'a' | b'b')
}

/// Decide whether a verified installation certificate admits this machine
/// under this license. Order: schema, product, license binding, machine
/// binding, clock rollback, expiry.
pub fn decide_install(req: &InstallRequest<'_>) -> Result<InstallDecision, Error> {
	if !is_valid_date(req.now_utc_date) {
		return Err(Error::InvalidNow);
	}
	if !is_lower_hex64(req.license_sha256) || !is_lower_hex64(req.machine) {
		return Err(Error::InvalidArgument);
	}
	let Some(fields) =
		json::parse_object(req.cert_payload).and_then(|m| typed(&m, &CERT_FIELDS, &[]))
	else {
		return Ok(InstallDecision::Malformed);
	};
	let field = |name: &str| -> Vec<u8> {
		let i = CERT_FIELDS
			.iter()
			.position(|n| *n == name)
			.expect("known field");
		fields[i]
			.clone()
			.expect("required fields are present")
			.into_bytes()
	};
	let (cert_id, expiry, issued) = (field("cert_id"), field("expiry"), field("issued"));
	let (license, machine, product) = (field("license_sha256"), field("machine"), field("product"));
	if field("v") != b"1"
		|| !is_uuid_v7(&cert_id)
		|| !is_valid_date(&issued)
		|| !is_valid_date(&expiry)
		|| expiry < issued
		|| !is_lower_hex64(&license)
		|| !is_lower_hex64(&machine)
	{
		return Ok(InstallDecision::Malformed);
	}
	if product != req.product {
		return Ok(InstallDecision::WrongProduct);
	}
	if license != req.license_sha256 {
		return Ok(InstallDecision::OtherLicense);
	}
	if machine != req.machine {
		return Ok(InstallDecision::OtherMachine);
	}
	if rolled_back(req.now_utc_date, req.clock_high_water) {
		return Ok(InstallDecision::ClockRollback);
	}
	if req.now_utc_date > expiry.as_slice() {
		return Ok(InstallDecision::Expired);
	}
	Ok(InstallDecision::Valid)
}

fn trim_ascii_ws(mut s: &[u8]) -> &[u8] {
	let ws = |c: &u8| matches!(c, b' ' | b'\t' | b'\r' | b'\n');
	while s.first().is_some_and(ws) {
		s = &s[1..];
	}
	while s.last().is_some_and(ws) {
		s = &s[..s.len() - 1];
	}
	s
}

fn hex_lower(digest: &[u8]) -> [u8; 64] {
	const HEX: &[u8; 16] = b"0123456789abcdef";
	let mut out = [0u8; 64];
	for (i, b) in digest.iter().enumerate() {
		out[2 * i] = HEX[usize::from(b >> 4)];
		out[2 * i + 1] = HEX[usize::from(b & 0x0f)];
	}
	out
}

/// The per-product machine fingerprint: lowercase hex SHA-256 over
/// `"mecha-install-v1" || product || 0x00 || raw id`, with the raw id trimmed
/// of ASCII whitespace and ASCII-lowercased.
pub fn machine_hash(product: &[u8], raw_id: &[u8]) -> [u8; 64] {
	let mut h = Sha256::new();
	h.update(b"mecha-install-v1");
	h.update(product);
	h.update([0u8]);
	h.update(trim_ascii_ws(raw_id).to_ascii_lowercase());
	hex_lower(&h.finalize())
}

/// Kinds of device hint the server counts devices with.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HintKind {
	/// A disk serial number.
	Disk,
	/// A network interface hardware address.
	Mac,
	/// TPM endorsement-key public bytes.
	Tpm,
}

impl HintKind {
	/// The C ABI code for a kind, or `None`.
	pub fn from_code(code: u8) -> Option<HintKind> {
		match code {
			0 => Some(HintKind::Disk),
			1 => Some(HintKind::Mac),
			2 => Some(HintKind::Tpm),
			_ => None,
		}
	}

	fn tag(self) -> &'static [u8] {
		match self {
			HintKind::Disk => b"disk",
			HintKind::Mac => b"mac",
			HintKind::Tpm => b"tpm",
		}
	}
}

/// Why no hint hash was produced.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HintError {
	/// The value identifies no device; the app omits this hint.
	Rejected,
	/// Empty product, or a product containing 0x00.
	InvalidArgument,
}

/// Per-product device-hint fingerprint: normalize the observation, then
/// lowercase hex SHA-256 over
/// `"mecha-hint-v1" || product || 0x00 || kind || 0x00 || normalized`.
pub fn hint_hash(product: &[u8], kind: HintKind, raw: &[u8]) -> Result<[u8; 64], HintError> {
	if product.is_empty() || product.contains(&0) {
		return Err(HintError::InvalidArgument);
	}
	let normalized: Vec<u8> = match kind {
		HintKind::Disk => {
			let v = trim_ascii_ws(raw);
			if v.is_empty() {
				return Err(HintError::Rejected);
			}
			v.to_ascii_lowercase()
		}
		HintKind::Mac => {
			let mut digits = Vec::with_capacity(12);
			for &c in trim_ascii_ws(raw) {
				if matches!(c, b':' | b'-' | b'.') {
					continue;
				}
				if !c.is_ascii_hexdigit() || digits.len() == 12 {
					return Err(HintError::Rejected);
				}
				digits.push(c.to_ascii_lowercase());
			}
			if digits.len() != 12 {
				return Err(HintError::Rejected);
			}
			let first = u8::from_str_radix(
				std::str::from_utf8(&digits[..2]).map_err(|_| HintError::Rejected)?,
				16,
			)
			.map_err(|_| HintError::Rejected)?;
			if first & 0x03 != 0 || digits.iter().all(|&c| c == b'0') {
				return Err(HintError::Rejected);
			}
			digits
		}
		HintKind::Tpm => {
			if raw.is_empty() {
				return Err(HintError::Rejected);
			}
			raw.iter()
				.flat_map(|b| {
					[
						b"0123456789abcdef"[usize::from(b >> 4)],
						b"0123456789abcdef"[usize::from(b & 0x0f)],
					]
				})
				.collect()
		}
	};
	let mut h = Sha256::new();
	h.update(b"mecha-hint-v1");
	h.update(product);
	h.update([0u8]);
	h.update(kind.tag());
	h.update([0u8]);
	h.update(&normalized);
	Ok(hex_lower(&h.finalize()))
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn zig_parse_u32_matches_the_characterized_table() {
		let table: &[(&[u8], Option<u32>)] = &[
			(b"1", Some(1)),
			(b"+1", Some(1)),
			(b"-0", Some(0)),
			(b"-000", Some(0)),
			(b"-0_0", Some(0)),
			(b"-1", None),
			(b"-01", None),
			(b"1_0", Some(10)),
			(b"1__0", Some(10)),
			(b"_1", None),
			(b"1_", None),
			(b"01", Some(1)),
			(b"4294967295", Some(u32::MAX)),
			(b"4294967296", None),
			(b" 1", None),
			(b"0x1", None),
			(b"1e1", None),
			(b"", None),
			(b"+", None),
			(b"-", None),
			(b"+_1", None),
		];
		for (input, expected) in table {
			assert_eq!(
				zig_parse_u32(input),
				*expected,
				"{:?}",
				String::from_utf8_lossy(input)
			);
		}
	}

	#[test]
	fn canonical_u32_refuses_signs_padding_and_overflow() {
		assert_eq!(canonical_u32(b"0"), Some(0));
		assert_eq!(canonical_u32(b"13"), Some(13));
		for bad in [&b""[..], b"01", b"+1", b"1_0", b"4294967296", b" 1"] {
			assert_eq!(canonical_u32(bad), None);
		}
	}

	#[test]
	fn date_validity_over_every_day_of_four_years() {
		// Exhaustive over 2000 (leap, divisible by 400), 2100 (not leap) and
		// two ordinary years, against a day count computed independently.
		for year in [2000u16, 2023, 2024, 2100] {
			let mut valid = 0;
			for month in 0u16..=13 {
				for day in 0u16..=32 {
					let s = format!("{year:04}-{month:02}-{day:02}");
					if is_valid_date(s.as_bytes()) {
						valid += 1;
					}
				}
			}
			let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
			assert_eq!(valid, if leap { 366 } else { 365 }, "{year}");
		}
	}

	#[test]
	fn the_clock_mark_is_judged_only_for_a_grant_with_an_expiry() {
		// examples/license_vectors: beta_valid (expiry 2026-10-17) and
		// paid_valid (no expiry).
		let dated = br#"{"customer_email":"beta-tester@example.com","customer_name_canonical":"beta tester","expiry":"2026-10-17","features":"full","max_major":"1","offline_days":"365","payment_provider":"beta","payment_ref":"beta_0001","product":"mecha-validate","purchase_date":"2026-09-17","v":"1"}"#;
		let undated = br#"{"customer_email":"customer@example.com","customer_name_canonical":"paying customer","features":"full","max_major":"1","offline_days":"365","payment_provider":"paddle","payment_ref":"txn_test_0001","product":"mecha-validate","purchase_date":"2026-09-17","v":"1"}"#;
		let ask = |payload: &'static [u8], role, mark: Option<&'static [u8]>| {
			decide(&Request {
				payload,
				verified_role: role,
				product: b"mecha-validate",
				app_major: 1,
				app_minor: 0,
				now_utc_date: b"2026-09-17",
				clock_high_water: mark,
				operation: None,
			})
		};
		let ahead = Some(&b"2026-09-20"[..]);
		assert_eq!(
			ask(dated, Role::BetaLicense, ahead),
			Ok(Decision::ClockRollback)
		);
		assert_eq!(
			ask(dated, Role::BetaLicense, None),
			Ok(Decision::Authorized)
		);
		assert_eq!(
			ask(undated, Role::PaidLicense, ahead),
			Ok(Decision::Authorized)
		);
		assert_eq!(
			ask(undated, Role::PaidLicense, None),
			Ok(Decision::Authorized)
		);
	}

	#[test]
	fn names_and_codes_are_unique() {
		let codes: std::collections::HashSet<u8> = Decision::ALL.iter().map(|d| d.code()).collect();
		assert_eq!(codes.len(), 10);
		let codes: std::collections::HashSet<u8> =
			InstallDecision::ALL.iter().map(|d| d.code()).collect();
		assert_eq!(codes.len(), 7);
	}
}
