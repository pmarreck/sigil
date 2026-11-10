//! QR code encoder, byte mode, all 40 versions and 4 error-correction levels.
//! A line-for-line port of `src/qr.zig`, so both implementations draw the
//! same module matrix for the same bytes (tests/differential/sign compares
//! the rendered PDFs byte for byte).
//!
//! Technique: Reed-Solomon over GF(2^8) with the 0x11D primitive, block
//! interleaving per the version/EC table, zigzag placement, all eight masks
//! scored by the four penalty rules, BCH-protected format and version fields
//! (ISO/IEC 18004).

// The mask and padding conditions are written `n % k == 0`, as in the
// standard and in src/qr.zig, so the two can be compared line by line.
#![allow(clippy::manual_is_multiple_of)]

/// Error-correction level; the discriminant is the format-information code.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EcLevel {
	/// Medium, about 15% recovery.
	M,
	/// Low, about 7%.
	L,
	/// High, about 30%.
	H,
	/// Quartile, about 25%.
	Q,
}

impl EcLevel {
	fn format_code(self) -> u32 {
		match self {
			EcLevel::M => 0,
			EcLevel::L => 1,
			EcLevel::H => 2,
			EcLevel::Q => 3,
		}
	}

	fn table_index(self) -> usize {
		match self {
			EcLevel::L => 0,
			EcLevel::M => 1,
			EcLevel::Q => 2,
			EcLevel::H => 3,
		}
	}
}

/// The data does not fit in a version-40 symbol at this level.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DataTooLong;

/// An encoded symbol: `size` x `size` modules, row-major, 1 = dark.
pub struct Code {
	/// QR version, 1 to 40.
	pub version: u8,
	/// Modules per side.
	pub size: usize,
	modules: Vec<u8>,
}

impl Code {
	/// Whether the module at column `x`, row `y` is dark.
	pub fn get(&self, x: usize, y: usize) -> bool {
		self.modules[y * self.size + x] == 1
	}
}

#[derive(Clone, Copy)]
struct BlockInfo {
	ec_per_block: u8,
	g1_blocks: u8,
	g1_data: u16,
	g2_blocks: u8,
	g2_data: u16,
}

const fn bi(
	ec_per_block: u8,
	g1_blocks: u8,
	g1_data: u16,
	g2_blocks: u8,
	g2_data: u16,
) -> BlockInfo {
	BlockInfo {
		ec_per_block,
		g1_blocks,
		g1_data,
		g2_blocks,
		g2_data,
	}
}

const TOTAL_CODEWORDS: [u16; 40] = [
	26, 44, 70, 100, 134, 172, 196, 242, 292, 346, 404, 466, 532, 581, 655, 733, 815, 901, 991,
	1085, 1156, 1258, 1364, 1474, 1588, 1706, 1828, 1921, 2051, 2185, 2323, 2465, 2611, 2761, 2876,
	3034, 3196, 3362, 3532, 3706,
];

const BLOCK_TABLE: [[BlockInfo; 4]; 40] = [
	[
		bi(7, 1, 19, 0, 0),
		bi(10, 1, 16, 0, 0),
		bi(13, 1, 13, 0, 0),
		bi(17, 1, 9, 0, 0),
	],
	[
		bi(10, 1, 34, 0, 0),
		bi(16, 1, 28, 0, 0),
		bi(22, 1, 22, 0, 0),
		bi(28, 1, 16, 0, 0),
	],
	[
		bi(15, 1, 55, 0, 0),
		bi(26, 1, 44, 0, 0),
		bi(18, 2, 17, 0, 0),
		bi(22, 2, 13, 0, 0),
	],
	[
		bi(20, 1, 80, 0, 0),
		bi(18, 2, 32, 0, 0),
		bi(26, 2, 24, 0, 0),
		bi(16, 4, 9, 0, 0),
	],
	[
		bi(26, 1, 108, 0, 0),
		bi(24, 2, 43, 0, 0),
		bi(18, 2, 15, 2, 16),
		bi(22, 2, 11, 2, 12),
	],
	[
		bi(18, 2, 68, 0, 0),
		bi(16, 4, 27, 0, 0),
		bi(24, 4, 19, 0, 0),
		bi(28, 4, 15, 0, 0),
	],
	[
		bi(20, 2, 78, 0, 0),
		bi(18, 4, 31, 0, 0),
		bi(18, 2, 14, 4, 15),
		bi(26, 4, 13, 1, 14),
	],
	[
		bi(24, 2, 97, 0, 0),
		bi(22, 2, 38, 2, 39),
		bi(22, 4, 18, 2, 19),
		bi(26, 4, 14, 2, 15),
	],
	[
		bi(30, 2, 116, 0, 0),
		bi(22, 3, 36, 2, 37),
		bi(20, 4, 16, 4, 17),
		bi(24, 4, 12, 4, 13),
	],
	[
		bi(18, 2, 68, 2, 69),
		bi(26, 4, 43, 1, 44),
		bi(24, 6, 19, 2, 20),
		bi(28, 6, 15, 2, 16),
	],
	[
		bi(20, 4, 81, 0, 0),
		bi(30, 1, 50, 4, 51),
		bi(28, 4, 22, 4, 23),
		bi(24, 3, 12, 8, 13),
	],
	[
		bi(24, 2, 92, 2, 93),
		bi(22, 6, 36, 2, 37),
		bi(26, 4, 20, 6, 21),
		bi(28, 7, 14, 4, 15),
	],
	[
		bi(26, 4, 107, 0, 0),
		bi(22, 8, 37, 1, 38),
		bi(24, 8, 20, 4, 21),
		bi(22, 12, 11, 4, 12),
	],
	[
		bi(30, 3, 115, 1, 116),
		bi(24, 4, 40, 5, 41),
		bi(20, 11, 16, 5, 17),
		bi(24, 11, 12, 5, 13),
	],
	[
		bi(22, 5, 87, 1, 88),
		bi(24, 5, 41, 5, 42),
		bi(30, 5, 24, 7, 25),
		bi(24, 11, 12, 7, 13),
	],
	[
		bi(24, 5, 98, 1, 99),
		bi(28, 7, 45, 3, 46),
		bi(24, 15, 19, 2, 20),
		bi(30, 3, 15, 13, 16),
	],
	[
		bi(28, 1, 107, 5, 108),
		bi(28, 10, 46, 1, 47),
		bi(28, 1, 22, 15, 23),
		bi(28, 2, 14, 17, 15),
	],
	[
		bi(30, 5, 120, 1, 121),
		bi(26, 9, 43, 4, 44),
		bi(28, 17, 22, 1, 23),
		bi(28, 2, 14, 19, 15),
	],
	[
		bi(28, 3, 113, 4, 114),
		bi(26, 3, 44, 11, 45),
		bi(26, 17, 21, 4, 22),
		bi(26, 9, 13, 16, 14),
	],
	[
		bi(28, 3, 107, 5, 108),
		bi(26, 3, 41, 13, 42),
		bi(30, 15, 24, 5, 25),
		bi(28, 15, 15, 10, 16),
	],
	[
		bi(28, 4, 116, 4, 117),
		bi(26, 17, 42, 0, 0),
		bi(28, 17, 22, 6, 23),
		bi(30, 19, 16, 6, 17),
	],
	[
		bi(28, 2, 111, 7, 112),
		bi(28, 17, 46, 0, 0),
		bi(30, 7, 24, 16, 25),
		bi(24, 34, 13, 0, 0),
	],
	[
		bi(30, 4, 121, 5, 122),
		bi(28, 4, 47, 14, 48),
		bi(30, 11, 24, 14, 25),
		bi(30, 16, 15, 14, 16),
	],
	[
		bi(30, 6, 117, 4, 118),
		bi(28, 6, 45, 14, 46),
		bi(30, 11, 24, 16, 25),
		bi(30, 30, 16, 2, 17),
	],
	[
		bi(26, 8, 106, 4, 107),
		bi(28, 8, 47, 13, 48),
		bi(30, 7, 24, 22, 25),
		bi(30, 22, 15, 13, 16),
	],
	[
		bi(28, 10, 114, 2, 115),
		bi(28, 19, 46, 4, 47),
		bi(28, 28, 22, 6, 23),
		bi(30, 33, 16, 4, 17),
	],
	[
		bi(30, 8, 122, 4, 123),
		bi(28, 22, 45, 3, 46),
		bi(30, 8, 23, 26, 24),
		bi(30, 12, 15, 28, 16),
	],
	[
		bi(30, 3, 117, 10, 118),
		bi(28, 3, 45, 23, 46),
		bi(30, 4, 24, 31, 25),
		bi(30, 11, 15, 31, 16),
	],
	[
		bi(30, 7, 116, 7, 117),
		bi(28, 21, 45, 7, 46),
		bi(30, 1, 23, 37, 24),
		bi(30, 19, 15, 26, 16),
	],
	[
		bi(30, 5, 115, 10, 116),
		bi(28, 19, 47, 10, 48),
		bi(30, 15, 24, 25, 25),
		bi(30, 23, 15, 25, 16),
	],
	[
		bi(30, 13, 115, 3, 116),
		bi(28, 2, 46, 29, 47),
		bi(30, 42, 24, 1, 25),
		bi(30, 23, 15, 28, 16),
	],
	[
		bi(30, 17, 115, 0, 0),
		bi(28, 10, 46, 23, 47),
		bi(30, 10, 24, 35, 25),
		bi(30, 19, 15, 35, 16),
	],
	[
		bi(30, 17, 115, 1, 116),
		bi(28, 14, 46, 21, 47),
		bi(30, 29, 24, 19, 25),
		bi(30, 11, 15, 46, 16),
	],
	[
		bi(30, 13, 115, 6, 116),
		bi(28, 14, 46, 23, 47),
		bi(30, 44, 24, 7, 25),
		bi(30, 59, 16, 1, 17),
	],
	[
		bi(30, 12, 121, 7, 122),
		bi(28, 12, 47, 26, 48),
		bi(30, 39, 24, 14, 25),
		bi(30, 22, 15, 41, 16),
	],
	[
		bi(30, 6, 121, 14, 122),
		bi(28, 6, 47, 34, 48),
		bi(30, 46, 24, 10, 25),
		bi(30, 2, 15, 64, 16),
	],
	[
		bi(30, 17, 122, 4, 123),
		bi(28, 29, 46, 14, 47),
		bi(30, 49, 24, 10, 25),
		bi(30, 24, 15, 46, 16),
	],
	[
		bi(30, 4, 122, 18, 123),
		bi(28, 13, 46, 32, 47),
		bi(30, 48, 24, 14, 25),
		bi(30, 42, 15, 32, 16),
	],
	[
		bi(30, 20, 117, 4, 118),
		bi(28, 40, 47, 7, 48),
		bi(30, 43, 24, 22, 25),
		bi(30, 10, 15, 67, 16),
	],
	[
		bi(30, 19, 118, 6, 119),
		bi(28, 18, 47, 31, 48),
		bi(30, 34, 24, 34, 25),
		bi(30, 20, 15, 61, 16),
	],
];

const ALIGNMENT_TABLE: [&[u8]; 40] = [
	&[],
	&[6, 18],
	&[6, 22],
	&[6, 26],
	&[6, 30],
	&[6, 34],
	&[6, 22, 38],
	&[6, 24, 42],
	&[6, 26, 46],
	&[6, 28, 50],
	&[6, 30, 54],
	&[6, 32, 58],
	&[6, 34, 62],
	&[6, 26, 46, 66],
	&[6, 26, 48, 70],
	&[6, 26, 50, 74],
	&[6, 30, 54, 78],
	&[6, 30, 56, 82],
	&[6, 30, 58, 86],
	&[6, 34, 62, 90],
	&[6, 28, 50, 72, 94],
	&[6, 26, 50, 74, 98],
	&[6, 30, 54, 78, 102],
	&[6, 28, 54, 80, 106],
	&[6, 32, 58, 84, 110],
	&[6, 30, 58, 86, 114],
	&[6, 34, 62, 90, 118],
	&[6, 26, 50, 74, 98, 122],
	&[6, 30, 54, 78, 102, 126],
	&[6, 26, 52, 78, 104, 130],
	&[6, 30, 56, 82, 108, 134],
	&[6, 34, 60, 86, 112, 138],
	&[6, 30, 58, 86, 114, 142],
	&[6, 34, 62, 90, 118, 146],
	&[6, 30, 54, 78, 102, 126, 150],
	&[6, 24, 50, 76, 102, 128, 154],
	&[6, 28, 54, 80, 106, 132, 158],
	&[6, 32, 58, 84, 110, 136, 162],
	&[6, 26, 54, 82, 110, 138, 166],
	&[6, 30, 58, 86, 114, 142, 170],
];

fn block_info(version: u8, level: EcLevel) -> BlockInfo {
	BLOCK_TABLE[usize::from(version) - 1][level.table_index()]
}

fn data_codewords(version: u8, level: EcLevel) -> usize {
	let b = block_info(version, level);
	usize::from(b.g1_blocks) * usize::from(b.g1_data)
		+ usize::from(b.g2_blocks) * usize::from(b.g2_data)
}

fn count_bits(version: u8) -> u32 {
	if version <= 9 { 8 } else { 16 }
}

fn byte_capacity(version: u8, level: EcLevel) -> usize {
	(data_codewords(version, level) * 8 - 4 - count_bits(version) as usize) / 8
}

const fn gf_tables() -> ([u8; 512], [u8; 256]) {
	let mut exp = [0u8; 512];
	let mut log = [0u8; 256];
	let mut x: u16 = 1;
	let mut i = 0;
	while i < 255 {
		exp[i] = x as u8;
		x <<= 1;
		if x & 0x100 != 0 {
			x ^= 0x11d;
		}
		i += 1;
	}
	while i < 512 {
		exp[i] = exp[i - 255];
		i += 1;
	}
	let mut j = 0;
	while j < 255 {
		log[exp[j] as usize] = j as u8;
		j += 1;
	}
	(exp, log)
}

const GF: ([u8; 512], [u8; 256]) = gf_tables();

fn gf_mul(a: u8, b: u8) -> u8 {
	if a == 0 || b == 0 {
		return 0;
	}
	GF.0[usize::from(GF.1[usize::from(a)]) + usize::from(GF.1[usize::from(b)])]
}

fn rs_generator(n: usize) -> Vec<u8> {
	let mut g = vec![1u8];
	for i in 0..n {
		let root = GF.0[i];
		g.push(0);
		for j in (1..g.len()).rev() {
			g[j] ^= gf_mul(g[j - 1], root);
		}
	}
	g
}

fn rs_encode(data: &[u8], ec: &mut [u8]) {
	let generator = rs_generator(ec.len());
	let n = ec.len();
	ec.fill(0);
	for &d in data {
		let factor = d ^ ec[0];
		ec.copy_within(1..n, 0);
		ec[n - 1] = 0;
		if factor != 0 {
			for j in 0..n {
				ec[j] ^= gf_mul(generator[j + 1], factor);
			}
		}
	}
}

fn bch_remainder(value: u32, poly: u32, poly_bits: u32, total_bits: u32) -> u32 {
	let mut v = value << (poly_bits - 1);
	let mut i = total_bits - 1;
	loop {
		if (v >> i) & 1 != 0 {
			v ^= poly << (i - (poly_bits - 1));
		}
		if i == poly_bits - 1 {
			break;
		}
		i -= 1;
	}
	v
}

fn format_bits(level: EcLevel, mask: u8) -> u32 {
	let data = (level.format_code() << 3) | u32::from(mask);
	((data << 10) | bch_remainder(data, 0x537, 11, 15)) ^ 0x5412
}

fn version_bits(version: u8) -> u32 {
	let data = u32::from(version);
	(data << 12) | bch_remainder(data, 0x1f25, 13, 18)
}

fn choose_version(len: usize, level: EcLevel) -> Result<u8, DataTooLong> {
	(1..=40u8)
		.find(|&v| byte_capacity(v, level) >= len)
		.ok_or(DataTooLong)
}

struct BitWriter<'a> {
	buf: &'a mut [u8],
	pos: usize,
}

impl BitWriter<'_> {
	fn put(&mut self, value: u32, count: u32) {
		for i in (0..count).rev() {
			if (value >> i) & 1 != 0 {
				self.buf[self.pos / 8] |= 0x80 >> (self.pos % 8);
			}
			self.pos += 1;
		}
	}
}

/// Encode `data` in byte mode at `level`, choosing the smallest version.
pub fn encode_bytes(data: &[u8], level: EcLevel) -> Result<Code, DataTooLong> {
	let version = choose_version(data.len(), level)?;
	let size = 17 + 4 * usize::from(version);
	let b = block_info(version, level);
	let n_data = data_codewords(version, level);
	let n_total = usize::from(TOTAL_CODEWORDS[usize::from(version) - 1]);

	let mut data_cw = vec![0u8; n_data];
	let mut w = BitWriter {
		buf: &mut data_cw,
		pos: 0,
	};
	w.put(0b0100, 4);
	w.put(data.len() as u32, count_bits(version));
	for &byte in data {
		w.put(u32::from(byte), 8);
	}
	let capacity_bits = n_data * 8;
	let terminator = 4.min(capacity_bits - w.pos) as u32;
	w.put(0, terminator);
	if w.pos % 8 != 0 {
		let fill = (8 - w.pos % 8) as u32;
		w.put(0, fill);
	}
	let mut pad: u8 = 0xec;
	while w.pos < capacity_bits {
		w.put(u32::from(pad), 8);
		pad ^= 0xec ^ 0x11;
	}

	let n_blocks = usize::from(b.g1_blocks) + usize::from(b.g2_blocks);
	let ec_len = usize::from(b.ec_per_block);
	let block_len = |k: usize| {
		if k < usize::from(b.g1_blocks) {
			usize::from(b.g1_data)
		} else {
			usize::from(b.g2_data)
		}
	};
	let mut ec_all = vec![0u8; n_blocks * ec_len];
	let mut offset = 0;
	for k in 0..n_blocks {
		let len = block_len(k);
		rs_encode(
			&data_cw[offset..offset + len],
			&mut ec_all[k * ec_len..(k + 1) * ec_len],
		);
		offset += len;
	}
	let mut fin = Vec::with_capacity(n_total);
	let max_len = if b.g2_blocks != 0 {
		usize::from(b.g2_data)
	} else {
		usize::from(b.g1_data)
	};
	for i in 0..max_len {
		let mut offset = 0;
		for k in 0..n_blocks {
			let len = block_len(k);
			if i < len {
				fin.push(data_cw[offset + i]);
			}
			offset += len;
		}
	}
	for i in 0..ec_len {
		for k in 0..n_blocks {
			fin.push(ec_all[k * ec_len + i]);
		}
	}
	debug_assert_eq!(fin.len(), n_total);

	let mut modules = vec![0u8; size * size];
	let mut reserved = vec![0u8; size * size];
	place_function_patterns(&mut modules, &mut reserved, size, version);
	place_data(&mut modules, &reserved, size, &fin);

	let mut best_mask = 0u8;
	let mut best_penalty = u32::MAX;
	for mask in 0..8u8 {
		let mut trial = modules.clone();
		apply_mask(&mut trial, &reserved, size, mask);
		place_format(&mut trial, size, level, mask);
		let p = penalty(&trial, size);
		if p < best_penalty {
			best_penalty = p;
			best_mask = mask;
		}
	}
	apply_mask(&mut modules, &reserved, size, best_mask);
	place_format(&mut modules, size, level, best_mask);
	if version >= 7 {
		place_version(&mut modules, size, version);
	}
	Ok(Code {
		version,
		size,
		modules,
	})
}

fn set(modules: &mut [u8], n: usize, x: usize, y: usize, dark: bool) {
	modules[y * n + x] = u8::from(dark);
}

fn place_function_patterns(modules: &mut [u8], reserved: &mut [u8], n: usize, version: u8) {
	for (cx, cy) in [(0, 0), (n - 7, 0), (0, n - 7)] {
		for dy in -1isize..=7 {
			for dx in -1isize..=7 {
				let (x, y) = (cx as isize + dx, cy as isize + dy);
				if x < 0 || y < 0 || x >= n as isize || y >= n as isize {
					continue;
				}
				let (ux, uy) = (x as usize, y as usize);
				let in_ring = (0..=6).contains(&dx)
					&& (0..=6).contains(&dy)
					&& (dx == 0
						|| dx == 6 || dy == 0
						|| dy == 6 || ((2..=4).contains(&dx) && (2..=4).contains(&dy)));
				set(modules, n, ux, uy, in_ring);
				reserved[uy * n + ux] = 1;
			}
		}
	}
	for i in 8..n - 8 {
		set(modules, n, i, 6, i % 2 == 0);
		set(modules, n, 6, i, i % 2 == 0);
		reserved[6 * n + i] = 1;
		reserved[i * n + 6] = 1;
	}
	let centers = ALIGNMENT_TABLE[usize::from(version) - 1];
	if let Some(&last) = centers.last() {
		for &cy in centers {
			for &cx in centers {
				if (cx == 6 && cy == 6) || (cx == 6 && cy == last) || (cx == last && cy == 6) {
					continue;
				}
				for dy in -2isize..=2 {
					for dx in -2isize..=2 {
						let x = (isize::from(cx) + dx) as usize;
						let y = (isize::from(cy) + dy) as usize;
						set(modules, n, x, y, dx.abs().max(dy.abs()) != 1);
						reserved[y * n + x] = 1;
					}
				}
			}
		}
	}
	for i in 0..9 {
		reserved[8 * n + i] = 1;
		reserved[i * n + 8] = 1;
	}
	for i in 0..8 {
		reserved[8 * n + (n - 1 - i)] = 1;
		reserved[(n - 1 - i) * n + 8] = 1;
	}
	set(modules, n, 8, n - 8, true);
	if version >= 7 {
		for i in 0..18 {
			reserved[(n - 11 + i % 3) * n + i / 3] = 1;
			reserved[(i / 3) * n + (n - 11 + i % 3)] = 1;
		}
	}
}

fn place_data(modules: &mut [u8], reserved: &[u8], n: usize, codewords: &[u8]) {
	let total_bits = codewords.len() * 8;
	let mut bit = 0;
	let mut upward = true;
	let mut x = n as isize - 1;
	while x > 0 {
		if x == 6 {
			x -= 1;
		}
		for step in 0..n {
			let y = if upward { n - 1 - step } else { step };
			for dx in 0..2 {
				let xx = (x - dx) as usize;
				if reserved[y * n + xx] != 0 {
					continue;
				}
				let mut dark = false;
				if bit < total_bits {
					dark = (codewords[bit / 8] >> (7 - bit % 8)) & 1 != 0;
					bit += 1;
				}
				set(modules, n, xx, y, dark);
			}
		}
		upward = !upward;
		x -= 2;
	}
}

fn mask_bit(mask: u8, x: usize, y: usize) -> bool {
	match mask {
		0 => (x + y) % 2 == 0,
		1 => y % 2 == 0,
		2 => x % 3 == 0,
		3 => (x + y) % 3 == 0,
		4 => (y / 2 + x / 3) % 2 == 0,
		5 => (x * y) % 2 + (x * y) % 3 == 0,
		6 => ((x * y) % 2 + (x * y) % 3) % 2 == 0,
		_ => ((x + y) % 2 + (x * y) % 3) % 2 == 0,
	}
}

fn apply_mask(modules: &mut [u8], reserved: &[u8], n: usize, mask: u8) {
	for y in 0..n {
		for x in 0..n {
			if reserved[y * n + x] == 0 && mask_bit(mask, x, y) {
				modules[y * n + x] ^= 1;
			}
		}
	}
}

fn place_format(modules: &mut [u8], n: usize, level: EcLevel, mask: u8) {
	let bits = format_bits(level, mask);
	for i in 0..15 {
		let dark = (bits >> (14 - i)) & 1 != 0;
		let first = match i {
			0..=5 => (i, 8),
			6 => (7, 8),
			7 => (8, 8),
			8 => (8, 7),
			_ => (8, 14 - i),
		};
		set(modules, n, first.0, first.1, dark);
		let second = if i < 7 {
			(8, n - 1 - i)
		} else {
			(n - 15 + i, 8)
		};
		set(modules, n, second.0, second.1, dark);
	}
}

fn place_version(modules: &mut [u8], n: usize, version: u8) {
	let bits = version_bits(version);
	for i in 0..18 {
		let dark = (bits >> i) & 1 != 0;
		set(modules, n, i / 3, n - 11 + i % 3, dark);
		set(modules, n, n - 11 + i % 3, i / 3, dark);
	}
}

fn penalty(modules: &[u8], n: usize) -> u32 {
	let mut score = 0u32;
	for a in 0..n {
		let (mut run_row, mut run_col) = (1u32, 1u32);
		for b in 1..n {
			if modules[a * n + b] == modules[a * n + b - 1] {
				run_row += 1;
				if run_row == 5 {
					score += 3;
				} else if run_row > 5 {
					score += 1;
				}
			} else {
				run_row = 1;
			}
			if modules[b * n + a] == modules[(b - 1) * n + a] {
				run_col += 1;
				if run_col == 5 {
					score += 3;
				} else if run_col > 5 {
					score += 1;
				}
			} else {
				run_col = 1;
			}
		}
	}
	for y in 0..n - 1 {
		for x in 0..n - 1 {
			let v = modules[y * n + x];
			if v == modules[y * n + x + 1]
				&& v == modules[(y + 1) * n + x]
				&& v == modules[(y + 1) * n + x + 1]
			{
				score += 3;
			}
		}
	}
	const P1: [u8; 11] = [1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0];
	const P2: [u8; 11] = [0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1];
	for a in 0..n {
		let mut b = 0;
		while b + 11 <= n {
			let row = |k: usize| modules[a * n + b + k];
			let col = |k: usize| modules[(b + k) * n + a];
			if (0..11).all(|k| row(k) == P1[k]) || (0..11).all(|k| row(k) == P2[k]) {
				score += 40;
			}
			if (0..11).all(|k| col(k) == P1[k]) || (0..11).all(|k| col(k) == P2[k]) {
				score += 40;
			}
			b += 1;
		}
	}
	let dark: usize = modules.iter().map(|&m| usize::from(m)).sum();
	let percent = dark * 100 / (n * n);
	let lower = percent / 5 * 5;
	let upper = lower + 5;
	let dl = lower.abs_diff(50);
	let du = upper.abs_diff(50);
	score + (dl.min(du) / 5 * 10) as u32
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn format_bits_match_the_iso_table() {
		// ISO/IEC 18004 Table C.1: level M, mask 0 is 101010000010010.
		assert_eq!(format_bits(EcLevel::M, 0), 0b101010000010010);
		assert_eq!(format_bits(EcLevel::L, 0), 0b111011111000100);
	}

	#[test]
	fn version_bits_match_the_iso_table() {
		// ISO/IEC 18004 Table D.1: version 7 is 000111110010010100.
		assert_eq!(version_bits(7), 0b000111110010010100);
	}

	#[test]
	fn capacity_boundaries() {
		assert_eq!(byte_capacity(1, EcLevel::M), 14);
		assert_eq!(byte_capacity(40, EcLevel::M), 2331);
		assert!(encode_bytes(&[b'A'; 2331], EcLevel::M).is_ok());
		assert_eq!(
			encode_bytes(&[b'A'; 2332], EcLevel::M).err(),
			Some(DataTooLong)
		);
	}
}
