//! Writes sigil's generated test vectors.
//!
//! From `rust/`:
//! - `cargo run -p sigil-vectors > ../examples/verify_edge_vectors/cases.tsv`
//! - `cargo run -p sigil-vectors -- sign-fixtures ../examples/sign_vectors`
//!
//! Unit tests fail if the committed files differ from what this produces.

fn main() {
	let args: Vec<String> = std::env::args().collect();
	match args.get(1).map(String::as_str) {
		None => print!("{}", sigil_vectors::corpus()),
		Some("sign-fixtures") => {
			let dir = std::path::Path::new(args.get(2).expect("sign-fixtures DIR"));
			for (name, bytes) in sigil_vectors::sign_fixtures() {
				std::fs::write(dir.join(name), bytes).expect("write fixture");
			}
		}
		Some(other) => panic!("unknown command {other}"),
	}
}
