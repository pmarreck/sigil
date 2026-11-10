//! Printable cold copies: one PDF page per sealed artifact, with a QR code,
//! the same bytes as typeable hex, and identifying text. A port of
//! `src/paper.zig`; the layout arithmetic is f32 in the same order, so both
//! implementations emit the same PDF bytes.

use crate::pdf::{self, Font, Page, Rect, Text};
use crate::qr::{self, EcLevel};
use sha2::{Digest, Sha256};

/// What a page holds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
	/// A passphrase-encrypted signing keyfile.
	Keyfile,
	/// A sealed hot bundle.
	HotBundle,
}

/// One sealed artifact to print.
pub struct Artifact<'a> {
	/// What it is.
	pub kind: Kind,
	/// Human label, e.g. the role name.
	pub label: &'a [u8],
	/// File name to restore it to.
	pub filename: &'a [u8],
	/// The sealed bytes.
	pub bytes: &'a [u8],
	/// The public key, when known.
	pub pubkey: Option<[u8; 32]>,
}

const PAGE_W: f32 = 612.0;
const PAGE_H: f32 = 792.0;
const MARGIN: f32 = 54.0;
const MAX_LINE_CHARS: usize = 92;
const TITLE_MAX_CHARS: usize = 60;
const HEX_COLS: usize = 64;
const HEX_GROUP: usize = 8;
const QR_LEVEL: EcLevel = EcLevel::M;
const QR_SIDE: f32 = 252.0;

struct Cursor {
	y: f32,
	texts: Vec<Text>,
}

impl Cursor {
	fn line(&mut self, font: Font, size: f32, leading: f32, text: &[u8]) {
		self.texts.push(Text {
			font,
			size,
			x: MARGIN,
			y: self.y,
			text: text.to_vec(),
		});
		self.y -= leading;
	}

	/// Wrap at the last space within `max` bytes, as the Zig layout does.
	fn paragraph(&mut self, font: Font, size: f32, leading: f32, text: &[u8], max: usize) {
		let mut start = 0;
		while start < text.len() {
			let mut end = text.len().min(start + max);
			if end < text.len()
				&& let Some(sp) = text[start..end].iter().rposition(|&c| c == b' ')
				&& sp > 0
			{
				end = start + sp;
			}
			self.line(font, size, leading, &text[start..end]);
			start = end;
			while start < text.len() && text[start] == b' ' {
				start += 1;
			}
		}
	}

	fn gap(&mut self, pts: f32) {
		self.y -= pts;
	}
}

fn kind_noun(kind: Kind) -> &'static str {
	match kind {
		Kind::Keyfile => "keyfile",
		Kind::HotBundle => "hot bundle",
	}
}

fn cat(parts: &[&[u8]]) -> Vec<u8> {
	parts.concat()
}

fn hex_lower(bytes: &[u8]) -> Vec<u8> {
	bytes
		.iter()
		.flat_map(|b| format!("{b:02x}").into_bytes())
		.collect()
}

fn compose_page(
	art: &Artifact<'_>,
	date: &[u8],
	version: &[u8],
	digits: &[u8],
	code: &qr::Code,
) -> Page {
	let mut c = Cursor {
		y: PAGE_H - MARGIN,
		texts: Vec::new(),
	};
	let mut rects = Vec::new();

	c.paragraph(
		Font::HelveticaBold,
		15.0,
		18.0,
		&cat(&[b"sigil cold copy: ", art.label]),
		TITLE_MAX_CHARS,
	);
	let subtitle: &[u8] = match art.kind {
		Kind::Keyfile => {
			b"Sealed signing keyfile (Argon2id + XChaCha20-Poly1305). Inert without its passphrase."
		}
		Kind::HotBundle => {
			b"Sealed hot bundle: PKCS#8 for restore-to-online. Inert without its passphrase."
		}
	};
	c.line(Font::Helvetica, 11.0, 16.0, subtitle);
	c.gap(4.0);

	let purpose = match art.kind {
		Kind::Keyfile => cat(&[
			b"This page is a cold copy of the ",
			art.label,
			b" signing keyfile. The bytes are encrypted at rest under the key's passphrase, so the page is useless to anyone without it. To restore: scan the QR code, or type the text form below, and hex-decode it into a file named ",
			art.filename,
			b"; spaces and line breaks are ignored. The decoded file must have the SHA-256 shown here.",
		]),
		Kind::HotBundle => cat(&[
			b"This page is a cold copy of the ",
			art.label,
			b" hot bundle, the sealed PKCS#8 form of the same key, made at generation for putting the key back into the online issuer. The bytes are encrypted at rest under the key's passphrase, so the page is useless to anyone without it. To restore: scan the QR code, or type the text form below, and hex-decode it into a file named ",
			art.filename,
			b"; spaces and line breaks are ignored. The decoded file must have the SHA-256 shown here.",
		]),
	};
	c.paragraph(Font::Helvetica, 9.0, 11.5, &purpose, MAX_LINE_CHARS);
	c.line(
		Font::Helvetica,
		9.0,
		11.5,
		b"Decode the typed text (Linux, then macOS):",
	);
	c.paragraph(
		Font::Courier,
		9.0,
		11.5,
		&cat(&[
			b"tr -d ' \\n' < typed.txt | basenc --base16 -d > ",
			art.filename,
		]),
		MAX_LINE_CHARS,
	);
	c.paragraph(
		Font::Courier,
		9.0,
		11.5,
		&cat(&[b"xxd -r -p typed.txt > ", art.filename]),
		MAX_LINE_CHARS,
	);
	c.line(
		Font::Helvetica,
		9.0,
		11.5,
		match art.kind {
			Kind::Keyfile => b"Then sign with:",
			Kind::HotBundle => b"Then, and only through a pipe, never into a file:",
		},
	);
	let command = match art.kind {
		Kind::Keyfile => cat(&[b"sigil sign --key ", art.filename, b" <payload>"]),
		Kind::HotBundle => cat(&[
			b"sigil hot-bundle open ",
			art.filename,
			b" | wrangler secret put SIGNING_KEY_<ROLE>",
		]),
	};
	c.paragraph(Font::Courier, 9.0, 11.5, &command, MAX_LINE_CHARS);
	c.gap(6.0);

	let digest = Sha256::digest(art.bytes);
	c.line(
		Font::Courier,
		9.0,
		11.5,
		&cat(&[b"Created ", date, b" with sigil ", version]),
	);
	c.line(
		Font::Courier,
		9.0,
		11.5,
		&cat(&[
			b"Artifact ",
			art.filename,
			format!(
				" ({} bytes, a sigil {})",
				art.bytes.len(),
				kind_noun(art.kind)
			)
			.as_bytes(),
		]),
	);
	c.line(
		Font::Courier,
		9.0,
		11.5,
		&cat(&[b"SHA-256 ", &hex_lower(&digest)]),
	);
	if let Some(pk) = art.pubkey {
		c.line(
			Font::Courier,
			9.0,
			11.5,
			&cat(&[b"Public key (hex) ", &hex_lower(&pk)]),
		);
	}
	c.gap(10.0);

	let module: f32 = QR_SIDE / code.size as f32;
	let top = c.y;
	for row in 0..code.size {
		let mut x = 0;
		while x < code.size {
			if !code.get(x, row) {
				x += 1;
				continue;
			}
			let start = x;
			while x < code.size && code.get(x, row) {
				x += 1;
			}
			rects.push(Rect {
				x: MARGIN + start as f32 * module,
				y: top - (row + 1) as f32 * module,
				w: (x - start) as f32 * module,
				h: module,
			});
		}
	}
	c.y = top - QR_SIDE;
	c.gap(18.0);

	c.line(
		Font::Helvetica,
		9.0,
		12.0,
		b"Text form (hex, 8 groups of 8 per line; the QR holds the same digits, no spaces):",
	);
	for chunk in digits.chunks(HEX_COLS) {
		let grouped: Vec<u8> = chunk.chunks(HEX_GROUP).collect::<Vec<_>>().join(&b' ');
		c.line(Font::Courier, 9.0, 11.0, &grouped);
	}

	Page {
		width: PAGE_W,
		height: PAGE_H,
		texts: c.texts,
		rects,
	}
}

/// Render one page per artifact. `date` is the caller's `YYYY-MM-DD` so the
/// output is reproducible.
pub fn render(
	artifacts: &[Artifact<'_>],
	date: &[u8],
	version: &[u8],
) -> Result<Vec<u8>, qr::DataTooLong> {
	let mut pages = Vec::with_capacity(artifacts.len());
	for art in artifacts {
		let digits: Vec<u8> = art
			.bytes
			.iter()
			.flat_map(|b| format!("{b:02X}").into_bytes())
			.collect();
		let code = qr::encode_bytes(&digits, QR_LEVEL)?;
		pages.push(compose_page(art, date, version, &digits, &code));
	}
	Ok(pdf::render(&pages))
}
