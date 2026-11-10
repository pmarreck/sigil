//! Link the sigil archives found in `SIGIL_LIB_DIR`: `libsigil.a` and
//! `libsigil_sign.a`, from whichever implementation the builder chose. This
//! crate sees only the C ABI, so the same source links against the Zig
//! archives and the Rust ones. `SIGIL_LIB_EXTRA` names any further system
//! libraries an implementation's archives need (whitespace-separated).

use std::env;
use std::path::Path;

fn main() {
	println!("cargo:rerun-if-env-changed=SIGIL_LIB_DIR");
	println!("cargo:rerun-if-env-changed=SIGIL_LIB_EXTRA");
	let Ok(dir) = env::var("SIGIL_LIB_DIR") else {
		println!(
			"cargo:error=set SIGIL_LIB_DIR to a directory holding libsigil.a and libsigil_sign.a"
		);
		return;
	};
	for archive in ["libsigil.a", "libsigil_sign.a"] {
		let path = Path::new(&dir).join(archive);
		if !path.is_file() {
			println!("cargo:error={} is missing", path.display());
			return;
		}
		println!("cargo:rerun-if-changed={}", path.display());
	}
	println!("cargo:rustc-link-search=native={dir}");
	println!("cargo:rustc-link-lib=static=sigil_sign");
	println!("cargo:rustc-link-lib=static=sigil");
	let extra = env::var("SIGIL_LIB_EXTRA").unwrap_or_default();
	for lib in extra.split_whitespace() {
		println!("cargo:rustc-link-lib={lib}");
	}
}
