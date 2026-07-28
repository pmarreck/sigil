// Codegen the byte<->glyph map + O(1) decode tables from the single-source
// character_map.txt (same parse rules as every other implementation), so the
// Rust impl produces byte-identical output and stays in lockstep with the map.
use std::{env, fs, path::Path};

fn main() {
    let manifest = env::var("CARGO_MANIFEST_DIR").unwrap();
    let map_path = Path::new(&manifest).join("..").join("character_map.txt");
    println!("cargo:rerun-if-changed={}", map_path.display());
    let text = fs::read_to_string(&map_path).expect("read ../character_map.txt");

    // One glyph per line in byte order; `##` = full-line comment; first
    // whitespace-delimited token is the glyph; blank lines skipped.
    let mut glyphs: Vec<&str> = Vec::new();
    for line in text.lines() {
        let line = line.trim_end_matches('\r');
        if line.is_empty() || line.starts_with("##") {
            continue;
        }
        match line.split_whitespace().next() {
            Some(tok) if !tok.is_empty() => glyphs.push(tok),
            _ => {}
        }
    }
    assert_eq!(glyphs.len(), 256, "expected 256 glyphs, got {}", glyphs.len());

    let mut map_data: Vec<u8> = Vec::new();
    let mut encode: Vec<(usize, usize)> = Vec::new();
    let mut decode_1 = [-1i16; 256];
    let mut decode_2 = [[-1i16; 64]; 32];
    let mut decode_3: Vec<(u32, u8)> = Vec::new();

    for (byte, g) in glyphs.iter().enumerate() {
        let b = g.as_bytes();
        encode.push((map_data.len(), b.len()));
        map_data.extend_from_slice(b);
        match b.len() {
            1 => decode_1[b[0] as usize] = byte as i16,
            2 => decode_2[(b[0] & 0x1F) as usize][(b[1] & 0x3F) as usize] = byte as i16,
            3 => {
                let key = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | b[2] as u32;
                decode_3.push((key, byte as u8));
            }
            n => panic!("byte {byte}: glyph is {n} bytes (expected 1-3, BMP only)"),
        }
    }
    decode_3.sort_by_key(|&(k, _)| k);

    let mut s = String::new();
    s.push_str(&format!("pub static MAP_DATA: [u8; {}] = {:?};\n", map_data.len(), map_data));
    s.push_str("pub static ENCODE: [(u16, u8); 256] = [");
    for (o, l) in &encode { s.push_str(&format!("({o},{l}),")); }
    s.push_str("];\n");
    s.push_str(&format!("pub static DECODE_1: [i16; 256] = {:?};\n", &decode_1[..]));
    s.push_str("pub static DECODE_2: [[i16; 64]; 32] = [");
    for row in &decode_2 { s.push_str(&format!("{:?},", &row[..])); }
    s.push_str("];\n");
    s.push_str(&format!("pub static DECODE_3: [(u32, u8); {}] = [", decode_3.len()));
    for (k, b) in &decode_3 { s.push_str(&format!("({k},{b}),")); }
    s.push_str("];\n");

    fs::write(Path::new(&env::var("OUT_DIR").unwrap()).join("map.rs"), s).unwrap();
}
