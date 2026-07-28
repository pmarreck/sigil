// Minimal CLI for cross-impl verification + the transport smoke path.
// (Provisional surface — the full CLI is a "specifics" decision still pending.)
// Default: encode stdin->stdout. `-d`/`--decode`: decode stdin->stdout.
use printable_binary::{decode, encode};
use std::io::{Read, Write};
use std::time::Instant;

fn stats_enabled() -> bool {
    !matches!(
        std::env::var("PRINTABLE_BINARY_MUTE_STATS").ok().as_deref(),
        Some("1" | "true" | "yes")
    )
}

fn main() {
    let decode_mode = std::env::args().skip(1).any(|a| a == "-d" || a == "--decode");
    let started_at = Instant::now();
    let mut input = Vec::new();
    std::io::stdin().read_to_end(&mut input).expect("read stdin");
    let input_bytes_read = input.len();
    let out = if decode_mode { decode(&input) } else { encode(&input) };
    let mut stdout = std::io::stdout().lock();
    stdout.write_all(&out).expect("write stdout");
    stdout.flush().expect("flush stdout");

    if stats_enabled() {
        let elapsed_seconds = started_at.elapsed().as_secs_f64().max(0.0005);
        let megabytes = input_bytes_read as f64 / 1_000_000.0;
        eprintln!(
            "Input throughput: {megabytes:.2} MB read in {elapsed_seconds:.3} s ({:.2} MB/s)",
            megabytes / elapsed_seconds
        );
    }
}
