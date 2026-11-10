//! Writes the signature edge-case corpus to stdout.
//!
//! Regenerate with `cargo run -p sigil-vectors > ../examples/verify_edge_vectors/cases.tsv`
//! from `rust/`. A unit test fails if the committed file differs from what this
//! program produces.

fn main() {
	print!("{}", sigil_vectors::corpus());
}
