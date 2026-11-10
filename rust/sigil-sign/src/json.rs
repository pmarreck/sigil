//! The keyfile's JSON: a strict RFC 8259 reader that matches Zig 0.16's
//! `std.json` as sigil uses it for keyfiles.
//!
//! Known fields are typed (strings, or canonical integers for the KDF
//! parameters); unknown fields may hold any JSON value, which is validated
//! and skipped, so older keyfiles with a `public` field still open. A known
//! field may appear once; unknown fields may repeat. Nesting depth is
//! unbounded and handled without recursion.

/// The fields of a sealed keyfile or hot bundle, decoded.
pub(crate) struct Wire {
	pub sigil: Vec<u8>,
	pub kdf: Vec<u8>,
	pub t: u32,
	pub m: u32,
	pub p: u32,
	pub salt: Vec<u8>,
	pub nonce: Vec<u8>,
	pub ciphertext: Vec<u8>,
}

struct Reader<'a> {
	s: &'a str,
	b: &'a [u8],
	i: usize,
}

impl Reader<'_> {
	fn ws(&mut self) {
		while matches!(self.b.get(self.i), Some(b' ' | b'\t' | b'\n' | b'\r')) {
			self.i += 1;
		}
	}

	fn peek(&self) -> Option<u8> {
		self.b.get(self.i).copied()
	}

	fn eat(&mut self, c: u8) -> Option<()> {
		(self.peek() == Some(c)).then(|| self.i += 1)
	}

	fn literal(&mut self, word: &[u8]) -> Option<()> {
		self.b[self.i..]
			.starts_with(word)
			.then(|| self.i += word.len())
	}

	fn hex4(&mut self) -> Option<u32> {
		let digits = self.s.get(self.i..self.i + 4)?;
		if !digits.bytes().all(|c| c.is_ascii_hexdigit()) {
			return None;
		}
		self.i += 4;
		u32::from_str_radix(digits, 16).ok()
	}

	/// A string token, escapes decoded.
	fn string(&mut self) -> Option<Vec<u8>> {
		self.eat(b'"')?;
		let mut out = String::new();
		loop {
			let c = self.s.get(self.i..)?.chars().next()?;
			match c {
				'"' => {
					self.i += 1;
					return Some(out.into_bytes());
				}
				'\\' => {
					self.i += 1;
					let e = self.peek()?;
					self.i += 1;
					out.push(match e {
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
					});
				}
				c if u32::from(c) < 0x20 => return None,
				c => {
					self.i += c.len_utf8();
					out.push(c);
				}
			}
		}
	}

	fn digits(&mut self) -> usize {
		let start = self.i;
		while self.peek().is_some_and(|c| c.is_ascii_digit()) {
			self.i += 1;
		}
		self.i - start
	}

	/// A number token in strict JSON grammar; returns its text.
	fn number(&mut self) -> Option<&[u8]> {
		let start = self.i;
		let _ = self.eat(b'-');
		match self.peek()? {
			b'0' => self.i += 1,
			b'1'..=b'9' => {
				self.digits();
			}
			_ => return None,
		}
		if self.eat(b'.').is_some() && self.digits() == 0 {
			return None;
		}
		if matches!(self.peek(), Some(b'e' | b'E')) {
			self.i += 1;
			if matches!(self.peek(), Some(b'+' | b'-')) {
				self.i += 1;
			}
			if self.digits() == 0 {
				return None;
			}
		}
		Some(&self.b[start..self.i])
	}

	/// Validate and skip one value of any type, without recursion.
	fn skip_value(&mut self) -> Option<()> {
		let mut open: Vec<u8> = Vec::new();
		loop {
			self.ws();
			match self.peek()? {
				b'{' => {
					self.i += 1;
					self.ws();
					if self.eat(b'}').is_none() {
						open.push(b'{');
						self.string()?;
						self.ws();
						self.eat(b':')?;
						continue;
					}
				}
				b'[' => {
					self.i += 1;
					self.ws();
					if self.eat(b']').is_none() {
						open.push(b'[');
						continue;
					}
				}
				b'"' => {
					self.string()?;
				}
				b't' => self.literal(b"true")?,
				b'f' => self.literal(b"false")?,
				b'n' => self.literal(b"null")?,
				_ => {
					self.number()?;
				}
			}
			// A value is complete: close containers until another value is due.
			loop {
				let Some(&top) = open.last() else {
					return Some(());
				};
				self.ws();
				match self.peek()? {
					b',' => {
						self.i += 1;
						if top == b'{' {
							self.ws();
							self.string()?;
							self.ws();
							self.eat(b':')?;
						}
						break;
					}
					b']' if top == b'[' => {
						self.i += 1;
						open.pop();
					}
					b'}' if top == b'{' => {
						self.i += 1;
						open.pop();
					}
					_ => return None,
				}
			}
		}
	}
}

/// A canonical non-negative integer: "0" or digits without a leading zero,
/// fitting `max`.
fn canonical(digits: &[u8], max: u32) -> Option<u32> {
	if digits.is_empty()
		|| (digits[0] == b'0' && digits.len() > 1)
		|| !digits.iter().all(u8::is_ascii_digit)
	{
		return None;
	}
	let v = digits.iter().try_fold(0u32, |acc, &c| {
		acc.checked_mul(10)?.checked_add(u32::from(c - b'0'))
	})?;
	(v <= max).then_some(v)
}

/// Parse a keyfile or hot bundle, or `None` if it is not a well-formed one.
pub(crate) fn parse(input: &[u8]) -> Option<Wire> {
	let s = std::str::from_utf8(input).ok()?;
	let mut r = Reader { s, b: input, i: 0 };
	let mut sigil = None;
	let mut kdf = None;
	let (mut t, mut m, mut p) = (None, None, None);
	let (mut salt, mut nonce, mut ciphertext) = (None, None, None);
	r.ws();
	r.eat(b'{')?;
	r.ws();
	if r.eat(b'}').is_none() {
		loop {
			r.ws();
			let key = r.string()?;
			r.ws();
			r.eat(b':')?;
			r.ws();
			let string_slot = match key.as_slice() {
				b"sigil" => Some(&mut sigil),
				b"kdf" => Some(&mut kdf),
				b"salt" => Some(&mut salt),
				b"nonce" => Some(&mut nonce),
				b"ciphertext" => Some(&mut ciphertext),
				_ => None,
			};
			if let Some(slot) = string_slot {
				if slot.is_some() {
					return None;
				}
				*slot = Some(r.string()?);
			} else {
				let int_slot = match key.as_slice() {
					b"t" => Some((&mut t, u32::MAX)),
					b"m" => Some((&mut m, u32::MAX)),
					b"p" => Some((&mut p, 0x00ff_ffff)),
					_ => None,
				};
				if let Some((slot, max)) = int_slot {
					if slot.is_some() {
						return None;
					}
					let text = r.number()?;
					*slot = Some(canonical(text, max)?);
				} else {
					r.skip_value()?;
				}
			}
			r.ws();
			if r.eat(b',').is_some() {
				continue;
			}
			r.eat(b'}')?;
			break;
		}
	}
	r.ws();
	if r.i != input.len() {
		return None;
	}
	Some(Wire {
		sigil: sigil?,
		kdf: kdf?,
		t: t?,
		m: m?,
		p: p?,
		salt: salt?,
		nonce: nonce?,
		ciphertext: ciphertext?,
	})
}

#[cfg(test)]
mod tests {
	use super::*;

	const BASE: &str = "\"sigil\":\"v\",\"kdf\":\"k\",\"t\":1,\"m\":64,\"p\":1,\"salt\":\"s\",\"nonce\":\"n\",\"ciphertext\":\"c\"";

	fn with(extra: &str) -> Option<Wire> {
		parse(format!("{{{BASE}{extra}}}").as_bytes())
	}

	/// The accept and reject sets characterized on Zig 0.16 `std.json`.
	#[test]
	fn unknown_fields_follow_zig_std_json() {
		for ok in [
			",\"x\":[1,{\"a\":[true,false,null,-0.5e3]}]",
			",\"x\":{\"a\":1,\"a\":2}",
			",\"x\":1,\"x\":2",
			",\"x\":-0",
			",\"x\":1E+2",
			"",
		] {
			assert!(with(ok).is_some(), "should accept {ok}");
		}
		for bad in [
			",\"x\":01",
			",\"x\":-",
			",\"x\":1.",
			",\"x\":tru",
			",\"x\":[1,]",
			",\"x\":\"\\ud800\"",
			",\"t\":1",
			",",
			"x",
		] {
			assert!(with(bad).is_none(), "should reject {bad}");
		}
	}

	#[test]
	fn kdf_parameters_must_be_canonical_integers() {
		for (spelling, accepted) in [
			("1", true),
			("0", true),
			("\"1\"", false),
			("1.0", false),
			("1e0", false),
			("-0", false),
			("01", false),
			("null", false),
		] {
			let doc = format!(
				"{{\"sigil\":\"v\",\"kdf\":\"k\",\"t\":{spelling},\"m\":64,\"p\":1,\"salt\":\"s\",\"nonce\":\"n\",\"ciphertext\":\"c\"}}"
			);
			assert_eq!(parse(doc.as_bytes()).is_some(), accepted, "t = {spelling}");
		}
		let p_max = "{\"sigil\":\"v\",\"kdf\":\"k\",\"t\":1,\"m\":64,\"p\":16777215,\"salt\":\"s\",\"nonce\":\"n\",\"ciphertext\":\"c\"}";
		assert!(parse(p_max.as_bytes()).is_some());
		assert!(parse(p_max.replace("16777215", "16777216").as_bytes()).is_none());
		let m_max = p_max
			.replace("16777215", "1")
			.replace("\"m\":64", "\"m\":4294967295");
		assert!(parse(m_max.as_bytes()).is_some());
		assert!(parse(m_max.replace("4294967295", "4294967296").as_bytes()).is_none());
	}

	#[test]
	fn deep_nesting_in_an_unknown_field_does_not_recurse() {
		let depth = 100_000;
		let extra = format!(",\"x\":{}{}", "[".repeat(depth), "]".repeat(depth));
		assert!(with(&extra).is_some());
	}
}
