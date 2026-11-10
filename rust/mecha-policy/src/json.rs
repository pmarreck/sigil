//! A strict parser for the one JSON shape policy payloads take: an object
//! whose members are strings or `null`.
//!
//! Every other shape is a schema violation in the policy, so the parser only
//! has to say whether input is such an object and, if so, return its members
//! with escapes decoded. It matches Zig 0.16's `std.json` on that domain:
//! RFC 8259 syntax, JSON whitespace only (space, tab, LF, CR), no byte-order
//! mark, no trailing content, strictly valid UTF-8, no raw control
//! characters in strings, surrogate escapes only in valid pairs, and a
//! duplicated key is an error.

/// One member: the decoded key and the decoded string value, or `None` for
/// JSON `null`.
pub(crate) type Members = Vec<(String, Option<String>)>;

struct Parser<'a> {
	s: &'a str,
	b: &'a [u8],
	i: usize,
}

impl Parser<'_> {
	fn skip_ws(&mut self) {
		while matches!(self.b.get(self.i), Some(b' ' | b'\t' | b'\n' | b'\r')) {
			self.i += 1;
		}
	}

	fn eat(&mut self, c: u8) -> Option<()> {
		(self.b.get(self.i) == Some(&c)).then(|| self.i += 1)
	}

	fn hex4(&mut self) -> Option<u32> {
		let digits = self.s.get(self.i..self.i + 4)?;
		if !digits.bytes().all(|c| c.is_ascii_hexdigit()) {
			return None;
		}
		self.i += 4;
		u32::from_str_radix(digits, 16).ok()
	}

	fn string(&mut self) -> Option<String> {
		self.eat(b'"')?;
		let mut out = String::new();
		loop {
			let c = self.s.get(self.i..)?.chars().next()?;
			match c {
				'"' => {
					self.i += 1;
					return Some(out);
				}
				'\\' => {
					self.i += 1;
					let e = *self.b.get(self.i)?;
					self.i += 1;
					let decoded = match e {
						b'"' => '"',
						b'\\' => '\\',
						b'/' => '/',
						b'b' => '\u{8}',
						b'f' => '\u{c}',
						b'n' => '\n',
						b'r' => '\r',
						b't' => '\t',
						b'u' => {
							let first = self.hex4()?;
							let scalar = match first {
								0xd800..=0xdbff => {
									self.eat(b'\\')?;
									self.eat(b'u')?;
									let second = self.hex4()?;
									if !(0xdc00..=0xdfff).contains(&second) {
										return None;
									}
									0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00)
								}
								0xdc00..=0xdfff => return None,
								_ => first,
							};
							char::from_u32(scalar)?
						}
						_ => return None,
					};
					out.push(decoded);
				}
				c if u32::from(c) < 0x20 => return None,
				c => {
					self.i += c.len_utf8();
					out.push(c);
				}
			}
		}
	}

	fn value(&mut self) -> Option<Option<String>> {
		if self.b[self.i..].starts_with(b"null") {
			self.i += 4;
			return Some(None);
		}
		self.string().map(Some)
	}
}

/// Parse `input` as an object of string-or-null members, or `None`.
pub(crate) fn parse_object(input: &[u8]) -> Option<Members> {
	let s = std::str::from_utf8(input).ok()?;
	let mut p = Parser { s, b: input, i: 0 };
	let mut members: Members = Vec::new();
	p.skip_ws();
	p.eat(b'{')?;
	p.skip_ws();
	if p.eat(b'}').is_none() {
		loop {
			p.skip_ws();
			let key = p.string()?;
			p.skip_ws();
			p.eat(b':')?;
			p.skip_ws();
			let value = p.value()?;
			if members.iter().any(|(k, _)| *k == key) {
				return None;
			}
			members.push((key, value));
			p.skip_ws();
			if p.eat(b',').is_some() {
				continue;
			}
			p.eat(b'}')?;
			break;
		}
	}
	p.skip_ws();
	(p.i == input.len()).then_some(members)
}

#[cfg(test)]
mod tests {
	use super::*;

	fn ok(doc: &[u8]) -> bool {
		parse_object(doc).is_some()
	}

	/// The accept and reject sets characterized on Zig 0.16 `std.json`.
	#[test]
	fn matches_zig_std_json_on_the_characterized_corpus() {
		let accept: &[&[u8]] = &[
			b"{\"a\":\"x\"}",
			b"{\"a\":\"x\",\"e\":null}",
			b" {\"a\":\"x\"} ",
			b"{\"a\":\"x\"}\n\n",
			b"{\"\\u0061\":\"x\"}",
			b"{\"a\":\"\\ud800\\udc00\"}",
			b"{\"a\":\"\\uD800\\uDC00\"}",
			b"{\"a\":\"\\/\"}",
			b"{\"a\" : \"x\" }",
			b"{\"a\":\"\\u0000\"}",
			b"{\"a\":\"\x7f\"}",
			b"{}",
		];
		let reject: &[&[u8]] = &[
			b"\xef\xbb\xbf{\"a\":\"x\"}",
			b"{\"a\":\"\\ud800\"}",
			b"{\"a\":\"\\udc00\"}",
			b"{\"a\":\"\x01\"}",
			b"{\"a\":\"\xed\xa0\x80\"}",
			b"{\"a\":\"\xc0\x80\"}",
			b"{\"a\":\"\xff\"}",
			b"{\"a\":\"x\",}",
			b"{\"a\":\"x\"}x",
			b"{\"a\":1}",
			b"{\"a\":\"x\",\"a\":\"y\"}",
			b"{\"a\":\"\\x\"}",
			b"{\"a\":\"x\"\x0b}",
			b"{\"a\":\"x\"\x0c}",
			b"{\"a\":\"x\"}{}",
			b"[]",
			b"[\"x\"]",
			b"{\"a\":\"\xf4\x90\x80\x80\"}",
			b"",
			b"{\"a\":nul}",
			b"{\"a\":\"\\u12\"}",
		];
		for doc in accept {
			assert!(ok(doc), "should accept {:?}", String::from_utf8_lossy(doc));
		}
		for doc in reject {
			assert!(!ok(doc), "should reject {:?}", String::from_utf8_lossy(doc));
		}
	}

	#[test]
	fn duplicate_detection_compares_decoded_keys() {
		assert!(!ok(b"{\"v\":\"1\",\"\\u0076\":\"2\"}"));
	}

	#[test]
	fn escapes_decode() {
		let m = parse_object(b"{\"k\":\"a\\nb\\u00e9\\ud83d\\ude00\"}").unwrap();
		assert_eq!(m[0].1.as_deref(), Some("a\nb\u{e9}\u{1f600}"));
	}
}
