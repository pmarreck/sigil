//! Minimal PDF 1.4 writer for the paper cold copies: standard Type 1 fonts,
//! text runs and filled rectangles. A port of `src/pdf.zig` that produces the
//! same bytes for the same pages.

/// One of the three standard fonts the pages use.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Font {
	/// Helvetica.
	Helvetica,
	/// Helvetica Bold.
	HelveticaBold,
	/// Courier.
	Courier,
}

impl Font {
	fn resource_name(self) -> &'static str {
		match self {
			Font::Helvetica => "/F1",
			Font::HelveticaBold => "/F2",
			Font::Courier => "/F3",
		}
	}

	fn base_font(self) -> &'static str {
		match self {
			Font::Helvetica => "/Helvetica",
			Font::HelveticaBold => "/Helvetica-Bold",
			Font::Courier => "/Courier",
		}
	}
}

/// A run of text at a position.
pub struct Text {
	/// Font.
	pub font: Font,
	/// Size in points.
	pub size: f32,
	/// Left edge.
	pub x: f32,
	/// Baseline.
	pub y: f32,
	/// The text, in WinAnsi bytes.
	pub text: Vec<u8>,
}

/// A filled rectangle.
pub struct Rect {
	/// Left edge.
	pub x: f32,
	/// Bottom edge.
	pub y: f32,
	/// Width.
	pub w: f32,
	/// Height.
	pub h: f32,
}

/// One page.
pub struct Page {
	/// Width in points.
	pub width: f32,
	/// Height in points.
	pub height: f32,
	/// Text runs, drawn after the rectangles.
	pub texts: Vec<Text>,
	/// Filled rectangles.
	pub rects: Vec<Rect>,
}

/// Format `v` the way Zig 0.16's `{d:.2}` does, then trim: take the
/// shortest decimal digits that round-trip the f32, round them to two places
/// half away from zero, drop trailing zeros and a bare point, and write
/// negative zero as "0". Rust's own `{:.2}` rounds the exact binary value
/// half to even, which differs on values such as 1.005 and 0.125.
pub(crate) fn fmt_num(v: f32) -> String {
	let sci = format!("{v:e}");
	let (negative, body) = match sci.strip_prefix('-') {
		Some(rest) => (true, rest),
		None => (false, sci.as_str()),
	};
	let (mantissa, exponent) = body.split_once('e').expect("{:e} always has an exponent");
	let exponent: i32 = exponent.parse().expect("integer exponent");
	let digits: Vec<u8> = mantissa
		.bytes()
		.filter(u8::is_ascii_digit)
		.map(|d| d - b'0')
		.collect();
	// value = 0.d1 d2 d3... x 10^(exponent + 1): the point sits after
	// `point` digits of `digits` (padded with zeros on either side).
	let point = exponent + 1;
	let digit_at = |i: i32| -> u8 {
		if i < 0 || i as usize >= digits.len() {
			0
		} else {
			digits[i as usize]
		}
	};
	let int_len = point.max(1);
	// Integer digits (at least one) and two fractional digits.
	let mut out: Vec<u8> = Vec::new();
	for k in 0..int_len {
		let idx = k - (int_len - point);
		out.push(digit_at(idx));
	}
	out.push(digit_at(point));
	out.push(digit_at(point + 1));
	if digit_at(point + 2) >= 5 {
		let mut i = out.len();
		loop {
			if i == 0 {
				out.insert(0, 1);
				break;
			}
			i -= 1;
			if out[i] == 9 {
				out[i] = 0;
			} else {
				out[i] += 1;
				break;
			}
		}
	}
	let frac = out.split_off(out.len() - 2);
	let mut s = String::new();
	if negative {
		s.push('-');
	}
	s.extend(out.iter().map(|d| char::from(b'0' + d)));
	s.push('.');
	s.extend(frac.iter().map(|d| char::from(b'0' + d)));
	while s.ends_with('0') {
		s.pop();
	}
	if s.ends_with('.') {
		s.pop();
	}
	if s == "-0" { "0".to_string() } else { s }
}

fn put_escaped(out: &mut Vec<u8>, text: &[u8]) {
	out.push(b'(');
	for &c in text {
		match c {
			b'(' | b')' | b'\\' => {
				out.push(b'\\');
				out.push(c);
			}
			b'\n' => out.extend_from_slice(b"\\n"),
			b'\r' => out.extend_from_slice(b"\\r"),
			_ => out.push(c),
		}
	}
	out.push(b')');
}

fn content_stream(page: &Page) -> Vec<u8> {
	let mut c = Vec::new();
	for r in &page.rects {
		c.extend_from_slice(
			format!(
				"{} {} {} {} re\nf\n",
				fmt_num(r.x),
				fmt_num(r.y),
				fmt_num(r.w),
				fmt_num(r.h)
			)
			.as_bytes(),
		);
	}
	for t in &page.texts {
		c.extend_from_slice(
			format!(
				"BT\n{} {} Tf\n{} {} Td\n",
				t.font.resource_name(),
				fmt_num(t.size),
				fmt_num(t.x),
				fmt_num(t.y)
			)
			.as_bytes(),
		);
		put_escaped(&mut c, &t.text);
		c.extend_from_slice(b" Tj\nET\n");
	}
	c
}

/// Serialize `pages` as a PDF file.
pub fn render(pages: &[Page]) -> Vec<u8> {
	let mut out: Vec<u8> = b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n".to_vec();
	let n_objects = 5 + 2 * pages.len();
	let mut offsets = vec![0usize; n_objects + 1];

	offsets[1] = out.len();
	out.extend_from_slice(b"1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");

	offsets[2] = out.len();
	let kids: Vec<String> = (0..pages.len())
		.map(|i| format!("{} 0 R", 6 + 2 * i))
		.collect();
	out.extend_from_slice(
		format!(
			"2 0 obj\n<< /Type /Pages /Count {} /Kids [{}] >>\nendobj\n",
			pages.len(),
			kids.join(" ")
		)
		.as_bytes(),
	);

	for (i, f) in [Font::Helvetica, Font::HelveticaBold, Font::Courier]
		.into_iter()
		.enumerate()
	{
		offsets[3 + i] = out.len();
		out.extend_from_slice(
			format!(
				"{} 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont {} /Encoding /WinAnsiEncoding >>\nendobj\n",
				3 + i,
				f.base_font()
			)
			.as_bytes(),
		);
	}

	for (i, page) in pages.iter().enumerate() {
		let page_obj = 6 + 2 * i;
		let content_obj = page_obj + 1;
		offsets[page_obj] = out.len();
		out.extend_from_slice(
			format!(
				"{page_obj} 0 obj\n<< /Type /Page\n/Parent 2 0 R\n/MediaBox [0 0 {} {}]\n/Resources << /Font << /F1 3 0 R /F2 4 0 R /F3 5 0 R >> >>\n/Contents {content_obj} 0 R >>\nendobj\n",
				fmt_num(page.width),
				fmt_num(page.height)
			)
			.as_bytes(),
		);
		let content = content_stream(page);
		offsets[content_obj] = out.len();
		out.extend_from_slice(
			format!(
				"{content_obj} 0 obj\n<< /Length {} >>\nstream\n",
				content.len()
			)
			.as_bytes(),
		);
		out.extend_from_slice(&content);
		out.extend_from_slice(b"\nendstream\nendobj\n");
	}

	let xref_at = out.len();
	out.extend_from_slice(format!("xref\n0 {}\n0000000000 65535 f \n", n_objects + 1).as_bytes());
	for offset in &offsets[1..] {
		out.extend_from_slice(format!("{offset:0>10} 00000 n \n").as_bytes());
	}
	out.extend_from_slice(
		format!(
			"trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref_at}\n%%EOF\n",
			n_objects + 1
		)
		.as_bytes(),
	);
	out
}

#[cfg(test)]
mod tests {
	use super::*;

	/// Characterized on Zig 0.16: `{d:.2}` of each f32, before trimming. The
	/// literals are the probe's inputs, kept verbatim.
	#[test]
	#[allow(clippy::approx_constant, clippy::excessive_precision)]
	fn number_format_matches_zig() {
		let table: &[(f32, &str)] = &[
			(0.125, "0.13"),
			(0.375, "0.38"),
			(0.625, "0.63"),
			(0.875, "0.88"),
			(1.005, "1.01"),
			(2.675, "2.68"),
			(12.625, "12.63"),
			(1.125, "1.13"),
			(0.005, "0.01"),
			(0.015, "0.02"),
			(0.025, "0.03"),
			(0.995, "1"),
			(-0.001, "0"),
			(-0.004, "0"),
			(-0.005, "-0.01"),
			(99.995, "100"),
			(471.875, "471.88"),
			(3.14159, "3.14"),
			(1e-9, "0"),
			(1234567.875, "1234567.9"),
			(0.0, "0"),
			(-0.0, "0"),
			(612.0, "612"),
			(54.0, "54"),
			(11.5, "11.5"),
		];
		for &(v, expected) in table {
			assert_eq!(fmt_num(v), expected, "{v:e}");
		}
	}
}
