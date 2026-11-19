//! Link the sigil libraries the builder chose: `SIGIL_LIB_DIR` holds them and
//! `SIGIL_LIBS` names them as cargo link-lib specs (`KIND=NAME`,
//! whitespace-separated). The Zig implementation is two static archives,
//! `static=sigil_sign static=sigil`. The Rust one is its CLI shape as a shared
//! library, `dylib=sigil_verify_sign`, because a Rust program cannot also link
//! a Rust static library (each bundles a standard library). This crate sees
//! only the C ABI, so the same source links against either.

use std::env;
use std::path::Path;

fn main() {
	println!("cargo:rerun-if-env-changed=SIGIL_LIB_DIR");
	println!("cargo:rerun-if-env-changed=SIGIL_LIBS");
	let (Ok(dir), Ok(libs)) = (env::var("SIGIL_LIB_DIR"), env::var("SIGIL_LIBS")) else {
		println!(
			"cargo:error=set SIGIL_LIB_DIR to the libraries' directory and SIGIL_LIBS to their link-lib specs"
		);
		return;
	};
	let specs: Vec<&str> = libs.split_whitespace().collect();
	if specs.is_empty() {
		println!("cargo:error=SIGIL_LIBS names no library");
		return;
	}
	for spec in &specs {
		let Some((kind, name)) = spec.split_once('=') else {
			println!("cargo:error=SIGIL_LIBS entry {spec} is not KIND=NAME");
			return;
		};
		let file = match kind {
			"static" => format!("lib{name}.a"),
			"dylib" => format!("lib{name}{}", env::consts::DLL_SUFFIX),
			_ => {
				println!("cargo:error=SIGIL_LIBS entry {spec}: KIND must be static or dylib");
				return;
			}
		};
		let path = Path::new(&dir).join(&file);
		if !path.is_file() {
			println!("cargo:error={} is missing", path.display());
			return;
		}
		println!("cargo:rerun-if-changed={}", path.display());
	}
	println!("cargo:rustc-link-search=native={dir}");
	for spec in specs {
		println!("cargo:rustc-link-lib={spec}");
	}
}
