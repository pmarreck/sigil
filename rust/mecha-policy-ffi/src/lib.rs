//! The C ABI declared in `mecha_policy.h` (from the pinned `mecha_policy`
//! repository), implemented over the Rust `mecha-policy` crate. Symbols,
//! argument order, return codes and names match the Zig library, and sigil's
//! differential suite compares the two.
//!
//! Strings marked NUL-terminated in the header are read as C strings, as the
//! Zig library does. Where the Zig library has no defined behavior for a NULL
//! (product, dates, hashes), this one returns -1 rather than reading address
//! zero; the differential suite does not exercise those calls.

use core::ffi::{CStr, c_char};

use mecha_policy::{
	Decision, Error, HintError, HintKind, InstallDecision, InstallRequest, Request, Role,
};

/// # Safety
/// `ptr` must be null or point to a NUL-terminated string.
unsafe fn c_str<'a>(ptr: *const c_char) -> Option<&'a [u8]> {
	// SAFETY: non-null and NUL-terminated per the header's contract.
	(!ptr.is_null()).then(|| unsafe { CStr::from_ptr(ptr) }.to_bytes())
}

/// # Safety
/// A non-null `ptr` must be valid for reads of `len` bytes.
unsafe fn bytes<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
	if ptr.is_null() {
		// The Zig library slices a NULL pointer to an empty view when the
		// length is zero; anything longer has no defined behavior.
		return (len == 0).then_some(&[][..]);
	}
	// SAFETY: non-null and valid for len bytes per the header's contract.
	Some(unsafe { std::slice::from_raw_parts(ptr, len) })
}

fn error_code(e: Error) -> i32 {
	match e {
		Error::InvalidArgument => -1,
		Error::InvalidNow => -2,
	}
}

/// Evaluate one verified license payload against one admission request.
///
/// # Safety
/// Pointers must satisfy `mecha_policy.h`: `payload_ptr` valid for
/// `payload_len` bytes, strings NUL-terminated, the last two may be NULL.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn mecha_policy_decide(
	payload_ptr: *const u8,
	payload_len: usize,
	role: u8,
	product: *const c_char,
	app_major: u32,
	app_minor: u32,
	now_utc_date: *const c_char,
	clock_high_water: *const c_char,
	operation: *const c_char,
) -> i32 {
	let Some(verified_role) = Role::from_code(role) else {
		return -1;
	};
	// SAFETY: each pointer is checked or read per the header's contract.
	let (payload, product, now) = unsafe {
		(
			bytes(payload_ptr, payload_len),
			c_str(product),
			c_str(now_utc_date),
		)
	};
	let (Some(payload), Some(product), Some(now_utc_date)) = (payload, product, now) else {
		return -1;
	};
	// SAFETY: optional NUL-terminated strings per the header.
	let (clock_high_water, operation) = unsafe { (c_str(clock_high_water), c_str(operation)) };
	let req = Request {
		payload,
		verified_role,
		product,
		app_major,
		app_minor,
		now_utc_date,
		clock_high_water,
		operation,
	};
	match mecha_policy::decide(&req) {
		Ok(d) => i32::from(d.code()),
		Err(e) => error_code(e),
	}
}

/// Stable name for a decision code.
#[unsafe(no_mangle)]
pub extern "C" fn mecha_policy_reason_name(code: u8) -> *const c_char {
	Decision::ALL
		.iter()
		.find(|d| d.code() == code)
		.map_or(c"unknown".as_ptr(), |d| d.name().as_ptr())
}

/// The ABI contract version.
#[unsafe(no_mangle)]
pub extern "C" fn mecha_policy_abi_version() -> u32 {
	mecha_policy::ABI_VERSION
}

/// The package version.
#[unsafe(no_mangle)]
pub extern "C" fn mecha_policy_version() -> *const c_char {
	c"0.2.1".as_ptr()
}

/// Decide whether a verified installation certificate admits this machine.
///
/// # Safety
/// Pointers must satisfy `mecha_policy.h`; only `clock_high_water` may be NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mecha_policy_install_decide(
	cert_ptr: *const u8,
	cert_len: usize,
	product: *const c_char,
	license_sha256: *const c_char,
	machine: *const c_char,
	now_utc_date: *const c_char,
	clock_high_water: *const c_char,
) -> i32 {
	// SAFETY: each pointer is checked or read per the header's contract.
	let fields = unsafe {
		(
			bytes(cert_ptr, cert_len),
			c_str(product),
			c_str(license_sha256),
			c_str(machine),
			c_str(now_utc_date),
			c_str(clock_high_water),
		)
	};
	let (
		Some(cert_payload),
		Some(product),
		Some(license_sha256),
		Some(machine),
		Some(now_utc_date),
		clock_high_water,
	) = fields
	else {
		return -1;
	};
	let req = InstallRequest {
		cert_payload,
		product,
		license_sha256,
		machine,
		now_utc_date,
		clock_high_water,
	};
	match mecha_policy::decide_install(&req) {
		Ok(d) => i32::from(d.code()),
		Err(e) => error_code(e),
	}
}

/// Stable name for an installation-certificate code.
#[unsafe(no_mangle)]
pub extern "C" fn mecha_policy_install_reason_name(code: u8) -> *const c_char {
	InstallDecision::ALL
		.iter()
		.find(|d| d.code() == code)
		.map_or(c"unknown".as_ptr(), |d| d.name().as_ptr())
}

/// Write the 64-character machine hash and a NUL into `out_65`.
///
/// # Safety
/// `product` NUL-terminated, `raw_id` valid for `raw_len` bytes, `out_65`
/// writable for 65 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mecha_policy_machine_hash(
	product: *const c_char,
	raw_id: *const u8,
	raw_len: usize,
	out_65: *mut c_char,
) {
	// SAFETY: per the header's contract.
	let (Some(product), Some(raw)) = (unsafe { c_str(product) }, unsafe { bytes(raw_id, raw_len) })
	else {
		return;
	};
	if out_65.is_null() {
		return;
	}
	let hex = mecha_policy::machine_hash(product, raw);
	// SAFETY: out_65 is non-null and writable for 65 bytes per the header.
	unsafe {
		std::ptr::copy_nonoverlapping(hex.as_ptr(), out_65.cast::<u8>(), 64);
		*out_65.add(64) = 0;
	}
}

/// Device-hint hash with length-delimited buffers; see the header.
///
/// # Safety
/// Non-null pointers must be valid for their lengths; `out` writable for
/// `out_cap` bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn mecha_policy_hint_hash(
	product: *const u8,
	product_len: usize,
	kind: u8,
	value: *const u8,
	value_len: usize,
	out: *mut c_char,
	out_cap: usize,
) -> i32 {
	let Some(kind) = HintKind::from_code(kind) else {
		return -1;
	};
	if product.is_null() || out.is_null() || (value.is_null() && value_len != 0) {
		return -1;
	}
	if out_cap < 64 {
		return -3;
	}
	// SAFETY: non-null pointers valid for their lengths per the header.
	let (Some(product), Some(value)) = (unsafe { bytes(product, product_len) }, unsafe {
		bytes(value, value_len)
	}) else {
		return -1;
	};
	match mecha_policy::hint_hash(product, kind, value) {
		Ok(hex) => {
			// SAFETY: out is non-null and writable for out_cap >= 64 bytes.
			unsafe { std::ptr::copy_nonoverlapping(hex.as_ptr(), out.cast::<u8>(), 64) };
			64
		}
		Err(HintError::InvalidArgument) => -1,
		Err(HintError::Rejected) => -2,
	}
}
