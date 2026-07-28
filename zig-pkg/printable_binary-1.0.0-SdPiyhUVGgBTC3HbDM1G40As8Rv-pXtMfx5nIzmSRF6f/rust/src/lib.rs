//! PrintableBinary — Rust implementation of the raw byte<->printable-UTF-8 codec.
//!
//! Produces byte-identical output to the Zig/C/Lua/JS implementations (same
//! `character_map.txt`). Built for a Rust-GUI <-> Zig-core transport: the
//! `*_into` variants reuse a caller-owned buffer for zero per-message allocation.
include!(concat!(env!("OUT_DIR"), "/map.rs"));

/// Worst-case encoded length: every byte maps to at most a 3-byte glyph.
#[inline]
pub fn encode_bound(len: usize) -> usize {
    len * 3
}

/// Encode raw bytes to printable-binary UTF-8 (allocating).
pub fn encode(input: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(encode_bound(input.len()));
    encode_into(input, &mut out);
    out
}

/// Encode into a caller-owned buffer (cleared, then filled). Reuses the buffer's
/// allocation across calls — zero allocations per message after warm-up.
pub fn encode_into(input: &[u8], out: &mut Vec<u8>) {
    out.clear();
    out.reserve(encode_bound(input.len()));
    for &b in input {
        let (off, len) = ENCODE[b as usize];
        let (off, len) = (off as usize, len as usize);
        out.extend_from_slice(&MAP_DATA[off..off + len]);
    }
}

#[inline]
fn utf8_len(b: u8) -> usize {
    if b < 0x80 { 1 } else if b < 0xE0 { 2 } else if b < 0xF0 { 3 } else { 4 }
}

/// Decode printable-binary UTF-8 back to raw bytes (allocating). Unrecognized
/// sequences pass through unchanged, matching the other implementations.
pub fn decode(input: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(input.len());
    decode_into(input, &mut out);
    out
}

/// Decode into a caller-owned buffer (cleared, then filled).
pub fn decode_into(input: &[u8], out: &mut Vec<u8>) {
    out.clear();
    let mut i = 0;
    while i < input.len() {
        let b0 = input[i];
        let mut len = utf8_len(b0);
        if i + len > input.len() {
            len = input.len() - i;
        }
        let mut matched = false;
        match len {
            1 => {
                let v = DECODE_1[b0 as usize];
                if v >= 0 {
                    out.push(v as u8);
                    i += 1;
                    matched = true;
                }
            }
            2 => {
                let v = DECODE_2[(b0 & 0x1F) as usize][(input[i + 1] & 0x3F) as usize];
                if v >= 0 {
                    out.push(v as u8);
                    i += 2;
                    matched = true;
                }
            }
            3 => {
                let key = ((input[i] as u32) << 16) | ((input[i + 1] as u32) << 8) | input[i + 2] as u32;
                if let Ok(idx) = DECODE_3.binary_search_by_key(&key, |&(k, _)| k) {
                    out.push(DECODE_3[idx].1);
                    i += 3;
                    matched = true;
                }
            }
            _ => {}
        }
        if !matched {
            out.extend_from_slice(&input[i..i + len]);
            i += len;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_all_256_single_bytes() {
        for b in 0u16..256 {
            let b = b as u8;
            let dec = decode(&encode(&[b]));
            assert_eq!(dec, vec![b], "byte {b:#04x} did not round-trip");
        }
    }

    #[test]
    fn round_trip_mixed_buffer() {
        let mut data: Vec<u8> = (0u16..256).map(|x| x as u8).collect();
        data.extend_from_slice(b"Hello, World!\x00\xff\n\t");
        assert_eq!(decode(&encode(&data)), data);
    }

    #[test]
    fn zero_alloc_into_matches_allocating() {
        let data = b"transport \x00\x01\xfe\xff frame";
        let mut ebuf = Vec::new();
        encode_into(data, &mut ebuf);
        assert_eq!(ebuf, encode(data));
        let mut dbuf = Vec::new();
        decode_into(&ebuf, &mut dbuf);
        assert_eq!(dbuf, data.to_vec());
    }
}
