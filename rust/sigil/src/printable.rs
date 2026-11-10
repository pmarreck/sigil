//! printable-binary, as sigil uses it: every byte maps to one glyph, and
//! decoding is strict.
//!
//! The decoder matches the Zig package's `validate(input, 0)` followed by
//! `decode` at the pinned commit, including its lookup rules: a sequence's
//! length comes from its lead byte alone (`< 0x80` one byte, `< 0xE0` two,
//! `< 0xF0` three, otherwise four), continuation bytes must have the form
//! `10xxxxxx`, a two-byte sequence is looked up by the lead byte's low five
//! bits, and four-byte sequences never match.

use crate::glyphs::GLYPHS;
use std::sync::OnceLock;

/// Encode `bytes` as printable-binary UTF-8.
pub fn encode(bytes: &[u8]) -> Vec<u8> {
	let mut out = Vec::with_capacity(bytes.len() * 3);
	for &b in bytes {
		out.extend_from_slice(GLYPHS[usize::from(b)]);
	}
	out
}

struct DecodeTables {
	one: [Option<u8>; 256],
	two: [[Option<u8>; 64]; 32],
	three: std::collections::HashMap<[u8; 3], u8>,
}

fn tables() -> &'static DecodeTables {
	static TABLES: OnceLock<DecodeTables> = OnceLock::new();
	TABLES.get_or_init(|| {
		let mut t = DecodeTables {
			one: [None; 256],
			two: [[None; 64]; 32],
			three: std::collections::HashMap::new(),
		};
		for (byte, glyph) in (0u8..=255).zip(GLYPHS) {
			match *glyph {
				[b0] => t.one[usize::from(b0)] = Some(byte),
				[b0, b1] => t.two[usize::from(b0 & 0x1f)][usize::from(b1 & 0x3f)] = Some(byte),
				[b0, b1, b2] => {
					t.three.insert([b0, b1 & 0x3f, b2 & 0x3f], byte);
				}
				_ => unreachable!("printable-binary glyphs are one to three bytes"),
			}
		}
		t
	})
}

fn sequence_len(lead: u8) -> usize {
	match lead {
		0x00..=0x7f => 1,
		0x80..=0xdf => 2,
		0xe0..=0xef => 3,
		_ => 4,
	}
}

/// Decode printable-binary text, or `None` if any sequence is not a glyph.
pub fn decode_strict(text: &[u8]) -> Option<Vec<u8>> {
	let t = tables();
	let mut out = Vec::with_capacity(text.len());
	let mut i = 0;
	while i < text.len() {
		let len = sequence_len(text[i]);
		let seq = text.get(i..i + len)?;
		if seq[1..].iter().any(|&c| c & 0xc0 != 0x80) {
			return None;
		}
		let byte = match *seq {
			[b0] => t.one[usize::from(b0)],
			[b0, b1] => t.two[usize::from(b0 & 0x1f)][usize::from(b1 & 0x3f)],
			[b0, b1, b2] => t.three.get(&[b0, b1 & 0x3f, b2 & 0x3f]).copied(),
			_ => None,
		}?;
		out.push(byte);
		i += len;
	}
	Some(out)
}

#[cfg(test)]
mod tests {
	use super::*;

	/// Parse `character_map.txt` the way every printable-binary implementation
	/// does: skip blank lines and `##` comments, take the first
	/// whitespace-delimited token of each remaining line.
	fn parse_map(text: &str) -> Vec<Vec<u8>> {
		text.lines()
			.map(|l| l.trim_end_matches('\r'))
			.filter(|l| !l.is_empty() && !l.starts_with("##"))
			.filter_map(|l| l.split_whitespace().next())
			.map(|tok| tok.as_bytes().to_vec())
			.collect()
	}

	#[test]
	fn glyph_table_matches_the_pinned_character_map() {
		// Set by the flake (package build and dev shell) to the pinned source.
		// Missing is a failure, not a skip: an unchecked table proves nothing.
		let path = std::env::var("SIGIL_PB_CHARACTER_MAP")
			.expect("SIGIL_PB_CHARACTER_MAP must name the pinned character_map.txt");
		let map = parse_map(&std::fs::read_to_string(path).expect("read the pinned character map"));
		assert_eq!(map.len(), 256);
		for (byte, (expected, actual)) in map.iter().zip(GLYPHS).enumerate() {
			assert_eq!(expected.as_slice(), actual, "glyph for byte {byte:#04x}");
		}
	}

	#[test]
	fn every_byte_round_trips_and_glyphs_are_distinct() {
		let all: Vec<u8> = (0u8..=255).collect();
		assert_eq!(decode_strict(&encode(&all)), Some(all));
		let distinct: std::collections::HashSet<&[u8]> = GLYPHS.iter().copied().collect();
		assert_eq!(distinct.len(), 256);
	}

	#[test]
	fn empty_text_decodes_to_empty_bytes() {
		assert_eq!(decode_strict(b""), Some(Vec::new()));
	}

	#[test]
	fn non_glyphs_are_refused() {
		for bad in [
			&b" "[..],
			b"\"",
			b"\\",
			b"\xf0\x9f\x98\x80",
			b"\xe2",
			b"\xc2",
			b"\xc2\x41",
		] {
			assert_eq!(decode_strict(bad), None, "{bad:?}");
		}
	}

	#[test]
	fn two_byte_lookup_uses_only_the_low_five_bits_of_the_lead() {
		// Matches the Zig decoder: a continuation byte used as a lead aliases
		// the glyph whose lead has the same low five bits.
		let glyph = GLYPHS
			.iter()
			.position(|g| g.len() == 2 && g[0] == 0xc2)
			.expect("a C2 glyph exists");
		let mut aliased = GLYPHS[glyph].to_vec();
		aliased[0] = 0x82;
		assert_eq!(decode_strict(&aliased), Some(vec![glyph as u8]));
	}
}
