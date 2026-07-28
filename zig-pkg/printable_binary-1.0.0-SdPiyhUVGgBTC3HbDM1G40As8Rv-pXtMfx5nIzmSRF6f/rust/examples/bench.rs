// Pure in-process codec throughput (no stdin/stdout I/O), to compare against the
// Zig core's codec — isolating codec speed from CLI I/O buffering.
use printable_binary::{decode, decode_into, encode, encode_into};
use std::time::Instant;

fn main() {
    let n: usize = 10_000_000;
    // deterministic pseudo-random bytes
    let data: Vec<u8> = (0..n).map(|i| (i.wrapping_mul(2654435761)) as u8).collect();
    let mut ebuf = Vec::new();
    let mut dbuf = Vec::new();
    encode_into(&data, &mut ebuf); // warm
    decode_into(&ebuf, &mut dbuf);
    assert_eq!(dbuf, data);
    let iters = 20;
    let t = Instant::now();
    for _ in 0..iters { encode_into(&data, &mut ebuf); }
    let es = t.elapsed().as_secs_f64() / iters as f64;
    let t = Instant::now();
    for _ in 0..iters { decode_into(&ebuf, &mut dbuf); }
    let ds = t.elapsed().as_secs_f64() / iters as f64;
    let mb = n as f64 / 1e6;
    println!("Rust codec (in-process): encode {:.0} MB/s ({:.2} ms), decode {:.0} MB/s ({:.2} ms)",
        mb / es, es * 1000.0, mb / ds, ds * 1000.0);
    // allocating path (fair vs Zig core, which allocates per call)
    let t = Instant::now();
    for _ in 0..iters { let _ = encode(&data); }
    let eas = t.elapsed().as_secs_f64() / iters as f64;
    let t = Instant::now();
    for _ in 0..iters { let _ = decode(&ebuf); }
    let das = t.elapsed().as_secs_f64() / iters as f64;
    println!("Rust codec (in-process, alloc/call): encode {:.0} MB/s ({:.2} ms), decode {:.0} MB/s ({:.2} ms)",
        mb / eas, eas * 1000.0, mb / das, das * 1000.0);
}
