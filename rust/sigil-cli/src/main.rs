//! The sigil command-line interface in Rust, over the C ABI only.
//!
//! A port of cli/main.c: the same options, messages, exit codes and output
//! bytes, so tests/cli and every integration suite run unchanged against it.
//! It declares the two headers' functions itself (`abi`) and depends on no
//! sigil crate, so it reaches an implementation only through the exported
//! functions. It is built against the Zig archives and the Rust ones alike.
//!
//! Output goes straight to file descriptors 1 and 2, as C stdio does, rather
//! than through Rust's `Stdout`, which treats a closed descriptor as success.
//! SIGPIPE is restored to its default, as a C program has it.

// The whole ABI is declared on purpose, so the declarations can be held to
// the headers; the CLI does not call every function or use every code.
#[allow(dead_code)]
mod abi;

use core::ffi::{CStr, c_char, c_int};
use std::ffi::{CString, OsStr};
use std::fs::{File, OpenOptions, Permissions};
use std::io::{self, BufRead, Read};
use std::os::fd::IntoRawFd;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

use zeroize::Zeroizing;

use abi::{SIGIL_OK, SigilPaperArtifact};

// sysexits.h conventions, as cli/main.c and cli/exit_codes.h spell them.
const EX_OK: i32 = 0;
const EX_REJECTED: i32 = 1;
const EX_USAGE: i32 = 64;
const EX_DATAERR: i32 = 65;
const EX_NOINPUT: i32 = 66;
const EX_SOFTWARE: i32 = 70;
const EX_IOERR: i32 = 74;
const EX_TEMPFAIL: i32 = 75;

/// A license is bytes; this is mercy.
const MAX_INPUT: usize = 16 * 1024 * 1024;

// ── Presentation ────────────────────────────────────────────────────────────

/// The presentation switches; `main` resolves color, the parser the rest.
struct Ui {
	color: bool,
	simple: bool,
	quiet: bool,
}

impl Ui {
	fn ok(&self) -> &'static [u8] {
		if self.color { b"\x1b[32m" } else { b"" }
	}
	fn bad(&self) -> &'static [u8] {
		if self.color { b"\x1b[31m" } else { b"" }
	}
	fn dim(&self) -> &'static [u8] {
		if self.color { b"\x1b[2m" } else { b"" }
	}
	fn off(&self) -> &'static [u8] {
		if self.color { b"\x1b[0m" } else { b"" }
	}
	fn mark_ok(&self) -> &'static [u8] {
		if self.simple {
			b"OK"
		} else {
			"\u{2713}".as_bytes()
		}
	}
	fn mark_bad(&self) -> &'static [u8] {
		if self.simple {
			b"FAILED"
		} else {
			"\u{2717}".as_bytes()
		}
	}
	/// Status goes to stderr so stdout stays pipeable data.
	fn note(&self, parts: &[&[u8]]) {
		if !self.quiet {
			err(parts);
		}
	}
}

/// Write every byte to a descriptor, as `fwrite` plus `fflush` would.
fn write_fd(fd: c_int, mut bytes: &[u8]) -> bool {
	while !bytes.is_empty() {
		// SAFETY: `bytes` is a valid slice for the duration of the call.
		let n = unsafe { libc::write(fd, bytes.as_ptr().cast(), bytes.len()) };
		if n < 0 {
			if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
				continue;
			}
			return false;
		}
		let written = usize::try_from(n).unwrap_or(0);
		if written == 0 {
			return false;
		}
		bytes = &bytes[written..];
	}
	true
}

fn concat(parts: &[&[u8]]) -> Vec<u8> {
	parts.concat()
}

/// A diagnostic on stderr. Failure to write one is not itself reported.
fn err(parts: &[&[u8]]) {
	let _ = write_fd(2, &concat(parts));
}

/// Unchecked stdout, as `printf` is: its failures surface nowhere.
fn out(parts: &[&[u8]]) {
	let _ = write_fd(1, &concat(parts));
}

fn die_usage(msg: &str, arg: Option<&[u8]>) {
	match arg {
		Some(arg) => err(&[b"sigil: ", msg.as_bytes(), b": ", arg, b"\n"]),
		None => err(&[b"sigil: ", msg.as_bytes(), b"\n"]),
	}
	err(&[b"Try 'sigil --help'.\n"]);
}

fn cstr_bytes(ptr: *const c_char) -> &'static [u8] {
	if ptr.is_null() {
		return b"";
	}
	// SAFETY: the headers promise a static NUL-terminated string.
	unsafe { CStr::from_ptr(ptr) }.to_bytes()
}

fn strerror(code: c_int) -> &'static [u8] {
	// SAFETY: sigil_strerror takes any code and never returns NULL.
	cstr_bytes(unsafe { abi::sigil_strerror(code) })
}

fn sign_strerror(code: c_int) -> &'static [u8] {
	// SAFETY: sigil_sign_strerror takes any code and never returns NULL.
	cstr_bytes(unsafe { abi::sigil_sign_strerror(code) })
}

fn version() -> &'static [u8] {
	// SAFETY: sigil_version returns a static string.
	cstr_bytes(unsafe { abi::sigil_version() })
}

/// The C library's message for an OS error, as `strerror(errno)` prints it.
fn os_error(e: &io::Error) -> Vec<u8> {
	let code = e.raw_os_error().unwrap_or(libc::EIO);
	// SAFETY: strerror returns a valid string; it is copied before any other
	// call could overwrite it.
	let msg = unsafe { CStr::from_ptr(libc::strerror(code)) };
	msg.to_bytes().to_vec()
}

fn plural(n: usize) -> &'static [u8] {
	if n == 1 { b"" } else { b"s" }
}

fn decimal(n: impl ToString) -> Vec<u8> {
	n.to_string().into_bytes()
}

// ── Paths ───────────────────────────────────────────────────────────────────

/// "-" and "@stdin" mean standard input.
fn is_stdin_path(p: &[u8]) -> bool {
	p == b"-" || p == b"@stdin"
}

/// "-" and "@stdout" mean standard output, "@stderr" standard error.
fn resolve_out(p: &[u8]) -> Option<c_int> {
	match p {
		b"-" | b"@stdout" => Some(1),
		b"@stderr" => Some(2),
		_ => None,
	}
}

fn os(path: &[u8]) -> &OsStr {
	OsStr::from_bytes(path)
}

/// Read a whole file (or stdin), refusing anything of MAX_INPUT bytes or
/// more, exactly where cli/main.c's doubling buffer refuses it.
fn read_all(path: &[u8]) -> Result<Vec<u8>, i32> {
	let mut buf = Vec::new();
	let limit = u64::try_from(MAX_INPUT).unwrap_or(u64::MAX);
	let read = if is_stdin_path(path) {
		io::stdin().lock().take(limit).read_to_end(&mut buf)
	} else {
		match File::open(os(path)) {
			Ok(file) => file.take(limit).read_to_end(&mut buf),
			Err(e) => {
				err(&[b"sigil: cannot read ", path, b": ", &os_error(&e), b"\n"]);
				return Err(EX_NOINPUT);
			}
		}
	};
	if buf.len() >= MAX_INPUT {
		let max = decimal(MAX_INPUT);
		err(&[b"sigil: ", path, b" is larger than ", &max, b" bytes\n"]);
		return Err(EX_IOERR);
	}
	if read.is_err() {
		err(&[b"sigil: error reading ", path, b"\n"]);
		return Err(EX_IOERR);
	}
	Ok(buf)
}

/// How `write_all` creates a file.
#[derive(Clone, Copy)]
struct WriteMode {
	/// Fail if it already exists (O_EXCL).
	exclusive: bool,
	/// Create 0600, not 0644: key material.
	secret: bool,
}

const PLAIN: WriteMode = WriteMode {
	exclusive: false,
	secret: false,
};

/// Write bytes to a path, honoring @stdout, @stderr and "-". One open(2)
/// decides existence and mode, as in cli/main.c.
fn write_all(path: &[u8], buf: &[u8], mode: WriteMode) -> i32 {
	let ok = if let Some(fd) = resolve_out(path) {
		write_fd(fd, buf)
	} else {
		let mut options = OpenOptions::new();
		options
			.write(true)
			.mode(if mode.secret { 0o600 } else { 0o644 });
		if mode.exclusive {
			options.create_new(true);
		} else {
			options.create(true).truncate(true);
		}
		let file = match options.open(os(path)) {
			Ok(file) => file,
			Err(e) if e.raw_os_error() == Some(libc::EEXIST) => {
				err(&[
					b"sigil: ",
					path,
					b" already exists; refusing to overwrite it.\n",
				]);
				err(&[
					b"       Losing a signing key is unrecoverable. Move it aside, or pass --force.\n",
				]);
				return EX_IOERR;
			}
			Err(e) => {
				err(&[b"sigil: cannot write ", path, b": ", &os_error(&e), b"\n"]);
				return EX_IOERR;
			}
		};
		// --force reuses the same open so the mode is still explicit, and an
		// existing 0644 file gets tightened rather than inherited.
		if mode.secret
			&& let Err(e) = file.set_permissions(Permissions::from_mode(0o600))
		{
			err(&[
				b"sigil: cannot restrict permissions on ",
				path,
				b": ",
				&os_error(&e),
				b"\n",
			]);
			return EX_IOERR;
		}
		let fd = file.into_raw_fd();
		let wrote = write_fd(fd, buf);
		// SAFETY: fd was just released from the File and is closed once.
		let closed = unsafe { libc::close(fd) } == 0;
		wrote && closed
	};
	if !ok {
		err(&[b"sigil: error writing ", path, b"\n"]);
		return EX_IOERR;
	}
	EX_OK
}

// ── Passphrases ─────────────────────────────────────────────────────────────

type Secret = Zeroizing<Vec<u8>>;

fn chomp(s: &mut Vec<u8>) {
	while matches!(s.last(), Some(b'\n' | b'\r')) {
		s.pop();
	}
}

/// Read one whole line from stdin, growing as needed. Bounded, but past the
/// bound it reports and fails instead of truncating. Grown by copying into a
/// fresh buffer so no reallocation leaves plaintext behind unwiped.
fn read_line_untruncated() -> Result<Secret, i32> {
	let stdin = io::stdin();
	let mut lock = stdin.lock();
	let mut buf: Secret = Zeroizing::new(Vec::with_capacity(256));
	let mut eof = false;
	loop {
		// fgetc's view: a read error ends the line just as end of input does.
		let next = match lock.fill_buf() {
			Ok(available) => available.first().copied(),
			Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
			Err(_) => None,
		};
		let Some(byte) = next else {
			eof = true;
			break;
		};
		lock.consume(1);
		if byte == b'\n' {
			break;
		}
		if buf.len() >= MAX_INPUT {
			let max = decimal(MAX_INPUT);
			err(&[
				b"sigil: passphrase exceeds ",
				&max,
				b" bytes; refusing to truncate it\n",
			]);
			return Err(EX_USAGE);
		}
		if buf.len() + 1 >= buf.capacity() {
			let mut grown: Secret = Zeroizing::new(Vec::with_capacity(buf.capacity() * 2));
			grown.extend_from_slice(&buf);
			buf = grown;
		}
		buf.push(byte);
	}
	if eof && buf.is_empty() {
		return Err(EX_NOINPUT);
	}
	// A trailing \r from a CRLF pipe.
	chomp(&mut buf);
	Ok(buf)
}

/// Read a passphrase without echoing it. Falls back to a plain read when
/// stdin is not a terminal, so a pipeline works.
fn prompt_passphrase(prompt: &[u8]) -> Result<Secret, i32> {
	err(&[prompt]);
	// SAFETY: termios is plain data, filled by tcgetattr before any use.
	let mut old: libc::termios = unsafe { core::mem::zeroed() };
	let mut restore = false;
	// SAFETY: fd 0 and a valid termios pointer.
	if unsafe { libc::isatty(0) } == 1 && unsafe { libc::tcgetattr(0, &raw mut old) } == 0 {
		let mut quiet = old;
		quiet.c_lflag &= !libc::ECHO;
		// SAFETY: fd 0 and a valid termios pointer.
		restore = unsafe { libc::tcsetattr(0, libc::TCSAFLUSH, &raw const quiet) } == 0;
	}
	let line = read_line_untruncated();
	if restore {
		// SAFETY: restoring the settings read above.
		unsafe { libc::tcsetattr(0, libc::TCSAFLUSH, &raw const old) };
	}
	err(&[b"\n"]);
	if matches!(line, Err(EX_NOINPUT)) {
		err(&[b"sigil: no passphrase supplied\n"]);
	}
	line
}

/// Either from --passphrase-file (which may be "-"/"@stdin") or interactively.
fn obtain_passphrase(pass_file: Option<&[u8]>, prompt: &[u8]) -> Result<Secret, i32> {
	match pass_file {
		Some(path) => {
			let mut raw: Secret = Zeroizing::new(read_all(path)?);
			chomp(&mut raw);
			Ok(raw)
		}
		None => prompt_passphrase(prompt),
	}
}

// ── Help ────────────────────────────────────────────────────────────────────

const USAGE: &str = "Usage: sigil <command> [options]

Verify and mint Ed25519-signed documents. The payload is signed exactly as
supplied (inside a fixed transcript header that binds the algorithm), so
the JSON envelope may be reformatted freely.

Commands:
  verify <envelope> --pubkey <path>   check a signature; payload to stdout
  sign <payload> --key <keyfile>      sign bytes into an envelope
  keygen --out <keyfile>              mint a new signing key
  pubkey --key <keyfile>              print the public key to embed
  hot-bundle open <bundle>            sealed PKCS#8 recovery bundle -> PEM on stdout
  paper --key <keyfile> [--hot-bundle <bundle>] [--pubkey <path>]
        --label <text> --out <pdf>    printable QR cold copies, one page each

Common options:
  -o, --out <path>       where to write; '-'/'@stdout' for standard output
      --passphrase-file <path>   read the passphrase instead of prompting
      --hot-bundle-out <path>    keygen: also write the sealed recovery bundle
      --date <YYYY-MM-DD>        paper: the date printed on the page (default today)
      --json             machine-readable result on stdout
  -q, --quiet            no status output; rely on the exit code
      --no-color         never emit ANSI color
      --simple           plain ASCII, no color, no symbols
  -h, --help             this help
      --about            one-line description, version, platform

Paths: '-' or '@stdin' reads standard input; '-', '@stdout' or '@stderr'
writes there. Anything after '--' is treated as a path, never a switch.

Exit codes: 0 verified; 1 NOT AUTHENTIC (the signature does not check
out); 64 usage; 65 the input is not a well-formed envelope; 66 missing
input; 70 internal error; 74 I/O; 75 temporary failure, retry may work.
Only 1 ever means a document was rejected on its merits.
";

fn usage(fd: c_int) -> i32 {
	let _ = write_fd(fd, USAGE.as_bytes());
	EX_USAGE
}

fn about() {
	let os_name: &[u8] = if cfg!(target_os = "linux") {
		b"linux"
	} else if cfg!(target_os = "macos") {
		b"macos"
	} else if cfg!(target_os = "windows") {
		b"windows"
	} else {
		b"unknown"
	};
	let arch: &[u8] = if cfg!(target_arch = "x86_64") {
		b"x86_64"
	} else if cfg!(target_arch = "aarch64") {
		b"aarch64"
	} else {
		b"unknown"
	};
	out(&[
		b"sigil ",
		version(),
		" \u{2014} verify Ed25519-signed documents (".as_bytes(),
		os_name,
		b"/",
		arch,
		b")\n",
	]);
}

// ── Argument parsing ────────────────────────────────────────────────────────

#[derive(Default)]
struct Opts<'a> {
	positional: Option<&'a [u8]>,
	pubkey: Option<&'a [u8]>,
	key: Option<&'a [u8]>,
	out: Option<&'a [u8]>,
	pubkey_out: Option<&'a [u8]>,
	hot_bundle_out: Option<&'a [u8]>,
	hot_bundle: Option<&'a [u8]>,
	label: Option<&'a [u8]>,
	date: Option<&'a [u8]>,
	passphrase_file: Option<&'a [u8]>,
	format: Option<&'a [u8]>,
	json: bool,
	force: bool,
}

/// Why parsing stopped early.
enum Stop {
	/// --help, --about or --version was answered; do no work.
	Answered,
	/// A usage error, already reported.
	Exit(i32),
}

/// Windows callers may spell switches with a leading '/'. Only short,
/// switch-looking tokens are rewritten, never an absolute path.
fn normalize(a: &[u8]) -> Vec<u8> {
	if a.first() != Some(&b'/') || a.len() == 1 {
		return a.to_vec();
	}
	if a[1..].contains(&b'/') || a.len() > 24 {
		return a.to_vec();
	}
	[b"-", &a[1..]].concat()
}

fn is_help(a: &[u8]) -> bool {
	matches!(a, b"-h" | b"--help" | b"-?")
}

/// Later arguments override earlier ones: every option assigns, and the last
/// assignment wins.
fn parse_opts<'a>(
	args: &'a [Vec<u8>],
	start: usize,
	o: &mut Opts<'a>,
	ui: &mut Ui,
) -> Result<(), Stop> {
	let mut no_more_switches = false;
	let mut i = start;
	while i < args.len() {
		let original = args[i].as_slice();
		let a = if no_more_switches {
			original.to_vec()
		} else {
			normalize(original)
		};
		if !no_more_switches && a == b"--" {
			no_more_switches = true;
			i += 1;
			continue;
		}
		if !no_more_switches && a.len() >= 2 && a[0] == b'-' {
			if is_help(&a) {
				usage(1);
				return Err(Stop::Answered);
			}
			if a == b"--about" {
				about();
				return Err(Stop::Answered);
			}
			if a == b"--version" {
				out(&[version(), b"\n"]);
				return Err(Stop::Answered);
			}
			let slot: Option<&mut Option<&'a [u8]>> = match a.as_slice() {
				b"--pubkey" => Some(&mut o.pubkey),
				b"--key" | b"-k" => Some(&mut o.key),
				b"--out" | b"-o" => Some(&mut o.out),
				b"--pubkey-out" => Some(&mut o.pubkey_out),
				b"--hot-bundle-out" => Some(&mut o.hot_bundle_out),
				b"--hot-bundle" => Some(&mut o.hot_bundle),
				b"--label" => Some(&mut o.label),
				b"--date" => Some(&mut o.date),
				b"--passphrase-file" => Some(&mut o.passphrase_file),
				b"--format" | b"-f" => Some(&mut o.format),
				_ => None,
			};
			if let Some(slot) = slot {
				if i + 1 >= args.len() {
					die_usage("option needs a value", Some(&a));
					return Err(Stop::Exit(EX_USAGE));
				}
				i += 1;
				*slot = Some(args[i].as_slice());
			} else {
				match a.as_slice() {
					b"--json" => o.json = true,
					b"--force" => o.force = true,
					b"--quiet" | b"-q" => ui.quiet = true,
					b"--no-color" | b"--no-colour" | b"--no-ansi" => ui.color = false,
					b"--simple" => {
						ui.simple = true;
						ui.color = false;
					}
					_ => {
						die_usage("unknown option", Some(original));
						return Err(Stop::Exit(EX_USAGE));
					}
				}
			}
			i += 1;
			continue;
		}
		if o.positional.is_some() {
			die_usage("unexpected extra argument", Some(original));
			return Err(Stop::Exit(EX_USAGE));
		}
		o.positional = Some(original);
		i += 1;
	}
	Ok(())
}

/// Parse a subcommand's options; `Err` is the exit code to return now.
fn parse<'a>(args: &'a [Vec<u8>], start: usize, ui: &mut Ui) -> Result<Opts<'a>, i32> {
	let mut o = Opts::default();
	match parse_opts(args, start, &mut o, ui) {
		Ok(()) => Ok(o),
		Err(Stop::Answered) => Err(EX_OK),
		Err(Stop::Exit(code)) => Err(code),
	}
}

// ── verify ──────────────────────────────────────────────────────────────────

/// Turning a verify result into an exit code (cli/exit_codes.h): anything
/// meaning "could not determine" never renders as "determined invalid".
fn verify_exit_code(code: c_int) -> i32 {
	match code {
		abi::SIGIL_OK => EX_OK,
		abi::SIGIL_ERR_BAD_SIGNATURE => EX_REJECTED,
		abi::SIGIL_ERR_MALFORMED_JSON
		| abi::SIGIL_ERR_MISSING_FIELD
		| abi::SIGIL_ERR_UNSUPPORTED_SIGTYPE
		| abi::SIGIL_ERR_MALFORMED_ENCODING
		| abi::SIGIL_ERR_BAD_SIGNATURE_LENGTH => EX_DATAERR,
		abi::SIGIL_ERR_BAD_PUBLIC_KEY => EX_USAGE,
		abi::SIGIL_ERR_OUT_OF_MEMORY => EX_TEMPFAIL,
		// Our bug, or a code from a newer library: never accuse a document of
		// forgery on the strength of a result this CLI does not understand.
		_ => EX_SOFTWARE,
	}
}

/// RFC 8259 escaping into at most `cap - 1` bytes, as cli/json.h writes into
/// a `cap`-byte buffer.
fn json_escape(input: &[u8], cap: usize) -> Vec<u8> {
	const HEX: &[u8; 16] = b"0123456789abcdef";
	let mut full = Vec::new();
	for &b in input {
		match b {
			b'"' => full.extend_from_slice(b"\\\""),
			b'\\' => full.extend_from_slice(b"\\\\"),
			0x08 => full.extend_from_slice(b"\\b"),
			0x0c => full.extend_from_slice(b"\\f"),
			b'\n' => full.extend_from_slice(b"\\n"),
			b'\r' => full.extend_from_slice(b"\\r"),
			b'\t' => full.extend_from_slice(b"\\t"),
			b if b < 0x20 => {
				full.extend_from_slice(b"\\u00");
				full.push(HEX[usize::from(b >> 4)]);
				full.push(HEX[usize::from(b & 0xf)]);
			}
			b => full.push(b),
		}
	}
	full.truncate(cap.saturating_sub(1));
	full
}

fn public_key_from_text(text: &[u8], pk: &mut [u8; 64]) -> c_int {
	// SAFETY: text is valid for its length; pk holds sigil_public_key_len()
	// bytes, which callers check against its size first.
	unsafe { abi::sigil_public_key_from_text(text.as_ptr().cast(), text.len(), pk.as_mut_ptr()) }
}

fn public_key_len() -> usize {
	// SAFETY: no arguments.
	unsafe { abi::sigil_public_key_len() }
}

fn cmd_verify(args: &[Vec<u8>], ui: &mut Ui) -> i32 {
	let o = match parse(args, 2, ui) {
		Ok(o) => o,
		Err(code) => return code,
	};
	let Some(positional) = o.positional else {
		die_usage("verify needs an envelope path (use '-' for stdin)", None);
		return EX_USAGE;
	};
	let Some(pubkey) = o.pubkey else {
		die_usage("verify needs --pubkey <path>", None);
		return EX_USAGE;
	};
	let env = match read_all(positional) {
		Ok(v) => v,
		Err(code) => return code,
	};
	let pubtext = match read_all(pubkey) {
		Ok(v) => v,
		Err(code) => return code,
	};
	let mut pk = [0u8; 64];
	if public_key_len() > pk.len() {
		return EX_IOERR;
	}
	let r = public_key_from_text(&pubtext, &mut pk);
	if r != SIGIL_OK {
		err(&[
			b"sigil: ",
			pubkey,
			b" is not a public key: ",
			strerror(r),
			b"\n",
		]);
		return EX_USAGE;
	}
	// printable-binary only ever expands, so the envelope's length is always
	// a sufficient buffer for the payload.
	let mut payload = vec![0u8; env.len() + 1];
	let mut payload_len = 0usize;
	// SAFETY: every pointer is valid for the length passed with it.
	let r = unsafe {
		abi::sigil_verify_envelope(
			env.as_ptr().cast(),
			env.len(),
			pk.as_ptr(),
			payload.as_mut_ptr(),
			env.len(),
			&raw mut payload_len,
		)
	};
	if r != SIGIL_OK {
		if o.json {
			let esc = json_escape(strerror(r), 512);
			out(&[
				b"{\"verified\":false,\"code\":",
				&decimal(r),
				b",\"error\":\"",
				&esc,
				b"\"}\n",
			]);
		} else if !ui.quiet {
			if r == abi::SIGIL_ERR_BAD_SIGNATURE {
				err(&[
					ui.bad(),
					ui.mark_bad(),
					ui.off(),
					b" ",
					positional,
					b": ",
					strerror(r),
					b"\n",
				]);
			} else {
				err(&[
					b"sigil: could not verify ",
					positional,
					b": ",
					strerror(r),
					b"\n",
				]);
			}
		}
		return verify_exit_code(r);
	}
	let payload = &payload[..payload_len.min(env.len())];
	if o.json {
		out(&[
			b"{\"verified\":true,\"payload_bytes\":",
			&decimal(payload.len()),
			b"}\n",
		]);
	} else {
		// The payload is the output, and --quiet does not suppress it.
		let status = write_all(o.out.unwrap_or(b"-"), payload, PLAIN);
		if status != EX_OK {
			return status;
		}
		if !ui.quiet {
			let n = decimal(payload.len());
			err(&[
				ui.ok(),
				ui.mark_ok(),
				ui.off(),
				b" verified ",
				positional,
				b" (",
				&n,
				b" byte",
				plural(payload.len()),
				b")\n",
			]);
		}
	}
	EX_OK
}

// ── sign ────────────────────────────────────────────────────────────────────

fn cmd_sign(args: &[Vec<u8>], ui: &mut Ui) -> i32 {
	let o = match parse(args, 2, ui) {
		Ok(o) => o,
		Err(code) => return code,
	};
	let Some(positional) = o.positional else {
		die_usage("sign needs a payload path (use '-' for stdin)", None);
		return EX_USAGE;
	};
	let Some(key) = o.key else {
		die_usage("sign needs --key <keyfile>", None);
		return EX_USAGE;
	};
	if is_stdin_path(positional) && o.passphrase_file.is_some_and(is_stdin_path) {
		die_usage("payload and passphrase cannot both come from stdin", None);
		return EX_USAGE;
	}
	let keyfile = match read_all(key) {
		Ok(v) => v,
		Err(code) => return code,
	};
	let payload = match read_all(positional) {
		Ok(v) => v,
		Err(code) => return code,
	};
	let pass = match obtain_passphrase(o.passphrase_file, b"Passphrase: ") {
		Ok(p) => p,
		Err(code) => return code,
	};
	// Three bytes per payload byte is printable-binary's worst case.
	let cap = payload.len() * 3 + 1024;
	let mut env = vec![0u8; cap];
	let mut env_len = 0usize;
	// SAFETY: every pointer is valid for the length passed with it.
	let r = unsafe {
		abi::sigil_seal(
			keyfile.as_ptr().cast(),
			keyfile.len(),
			pass.as_ptr().cast(),
			pass.len(),
			payload.as_ptr(),
			payload.len(),
			env.as_mut_ptr().cast(),
			cap,
			&raw mut env_len,
		)
	};
	if r != SIGIL_OK {
		err(&[
			b"sigil: ",
			ui.bad(),
			ui.mark_bad(),
			ui.off(),
			b" cannot sign: ",
			sign_strerror(r),
			b"\n",
		]);
		return if r == abi::SIGIL_ERR_AUTH_FAILED {
			EX_REJECTED
		} else {
			EX_IOERR
		};
	}
	let status = write_all(o.out.unwrap_or(b"-"), &env[..env_len.min(cap)], PLAIN);
	if status != EX_OK {
		return status;
	}
	let n = decimal(payload.len());
	ui.note(&[
		ui.ok(),
		ui.mark_ok(),
		ui.off(),
		b" signed ",
		positional,
		b" (",
		&n,
		b" byte",
		plural(payload.len()),
		b") -> ",
		o.out.unwrap_or(b"stdout"),
		b"\n",
	]);
	EX_OK
}

// ── keygen ──────────────────────────────────────────────────────────────────

fn cmd_keygen(args: &[Vec<u8>], ui: &mut Ui) -> i32 {
	let o = match parse(args, 2, ui) {
		Ok(o) => o,
		Err(code) => return code,
	};
	let Some(key_path) = o.out.or(o.positional) else {
		die_usage("keygen needs --out <keyfile>", None);
		return EX_USAGE;
	};
	let pub_default;
	let pub_path = match o.pubkey_out {
		Some(p) => p,
		None => {
			// cli/main.c formats into 1024 bytes and refuses what would not fit.
			if key_path.len() + 4 >= 1024 {
				err(&[b"sigil: key path is too long\n"]);
				return EX_USAGE;
			}
			pub_default = [key_path, b".pub"].concat();
			pub_default.as_slice()
		}
	};
	let pass = match obtain_passphrase(o.passphrase_file, b"Passphrase for the new key: ") {
		Ok(p) => p,
		Err(code) => return code,
	};
	// Only confirm when we prompted: a typo would make the key unopenable.
	if o.passphrase_file.is_none() {
		let confirm = match obtain_passphrase(None, b"Confirm passphrase: ") {
			Ok(p) => p,
			Err(code) => return code,
		};
		if *pass != *confirm {
			err(&[b"sigil: passphrases do not match; no key was written.\n"]);
			return EX_USAGE;
		}
	}
	let mut keyfile = vec![0u8; 4096];
	let mut keyfile_len = 0usize;
	let mut bundle = vec![0u8; 4096];
	let mut bundle_len = 0usize;
	let r = if o.hot_bundle_out.is_some() {
		// Both custody artifacts from one seed, in one call.
		// SAFETY: every pointer is valid for the length passed with it.
		unsafe {
			abi::sigil_keygen_with_recovery(
				pass.as_ptr().cast(),
				pass.len(),
				keyfile.as_mut_ptr().cast(),
				4096,
				&raw mut keyfile_len,
				bundle.as_mut_ptr().cast(),
				4096,
				&raw mut bundle_len,
			)
		}
	} else {
		// SAFETY: every pointer is valid for the length passed with it.
		unsafe {
			abi::sigil_keygen(
				pass.as_ptr().cast(),
				pass.len(),
				keyfile.as_mut_ptr().cast(),
				4096,
				&raw mut keyfile_len,
			)
		}
	};
	if r != SIGIL_OK {
		err(&[b"sigil: cannot generate a key: ", sign_strerror(r), b"\n"]);
		return if r == abi::SIGIL_ERR_EMPTY_PASSPHRASE {
			EX_USAGE
		} else {
			EX_IOERR
		};
	}
	let keyfile = &keyfile[..keyfile_len.min(4096)];
	let secret = WriteMode {
		exclusive: !o.force,
		secret: true,
	};
	let status = write_all(key_path, keyfile, secret);
	if status != EX_OK {
		return status;
	}
	if let Some(bundle_path) = o.hot_bundle_out {
		let status = write_all(bundle_path, &bundle[..bundle_len.min(4096)], secret);
		if status != EX_OK {
			return status;
		}
	}
	let mut pk = [0u8; 64];
	// SAFETY: every pointer is valid for the length passed with it; pk holds
	// sigil_public_key_len() bytes.
	let r = unsafe {
		abi::sigil_keyfile_public_key(
			keyfile.as_ptr().cast(),
			keyfile.len(),
			pass.as_ptr().cast(),
			pass.len(),
			pk.as_mut_ptr(),
		)
	};
	if r != SIGIL_OK {
		err(&[
			b"sigil: wrote ",
			key_path,
			b" but could not derive its public key: ",
			sign_strerror(r),
			b"\n",
		]);
		return EX_IOERR;
	}
	let mut pub_text = [0u8; 512];
	let mut pub_text_len = 0usize;
	// SAFETY: every pointer is valid for the length passed with it.
	let r = unsafe {
		abi::sigil_public_key_to_text(
			pk.as_ptr(),
			pub_text.as_mut_ptr().cast(),
			512,
			&raw mut pub_text_len,
		)
	};
	if r != SIGIL_OK {
		err(&[b"sigil: cannot render the public key: ", strerror(r), b"\n"]);
		return EX_IOERR;
	}
	let public = WriteMode {
		exclusive: !o.force,
		secret: false,
	};
	let status = write_all(pub_path, &pub_text[..pub_text_len.min(512)], public);
	if status != EX_OK {
		return status;
	}
	ui.note(&[
		ui.ok(),
		ui.mark_ok(),
		ui.off(),
		b" wrote ",
		key_path,
		b" (secret, encrypted) and ",
		pub_path,
		b" (public)\n",
	]);
	if let Some(bundle_path) = o.hot_bundle_out {
		ui.note(&[
			ui.dim(),
			b"  and ",
			bundle_path,
			b" (sealed recovery bundle: open it only into `wrangler secret put`)",
			ui.off(),
			b"\n",
		]);
	}
	ui.note(&[
		ui.dim(),
		b"  Back up both. Lose the keyfile or the passphrase and you cannot\n  sign again; every already-issued license keeps working.",
		ui.off(),
		b"\n",
	]);
	EX_OK
}

// ── pubkey ──────────────────────────────────────────────────────────────────

/// The key as a C or Zig array declaration, eight bytes to a line.
fn emit_byte_array(decl: &[u8], pk: &[u8], open: &[u8], close: &[u8]) -> Vec<u8> {
	let mut s = [decl, open].concat();
	for (i, b) in pk.iter().enumerate() {
		if i % 8 == 0 {
			s.extend_from_slice(b"\n    ");
		}
		s.extend_from_slice(format!("0x{b:02x},").as_bytes());
		if !(i % 8 == 7 || i + 1 == pk.len()) {
			s.push(b' ');
		}
	}
	s.push(b'\n');
	s.extend_from_slice(close);
	s.push(b'\n');
	s
}

/// The `pubkey --format` values.
#[derive(Clone, Copy)]
enum PubkeyFormat {
	Text,
	Raw,
	Hex,
	C,
	Zig,
}

impl PubkeyFormat {
	fn parse(s: &[u8]) -> Option<Self> {
		match s {
			b"text" => Some(Self::Text),
			b"raw" => Some(Self::Raw),
			b"hex" => Some(Self::Hex),
			b"c" => Some(Self::C),
			b"zig" => Some(Self::Zig),
			_ => None,
		}
	}
}

fn cmd_pubkey(args: &[Vec<u8>], ui: &mut Ui) -> i32 {
	let o = match parse(args, 2, ui) {
		Ok(o) => o,
		Err(code) => return code,
	};
	let Some(src) = o.key.or(o.pubkey).or(o.positional) else {
		die_usage("pubkey needs --key <keyfile> or --pubkey <path>", None);
		return EX_USAGE;
	};
	// A usage error comes before the passphrase is read or the key unlocked:
	// a mistyped format must not cost a key derivation.
	let format_arg = o.format.unwrap_or(b"text");
	let Some(format) = PubkeyFormat::parse(format_arg) else {
		die_usage(
			"unknown --format (want text, hex, raw, c or zig)",
			Some(format_arg),
		);
		return EX_USAGE;
	};
	let raw = match read_all(src) {
		Ok(v) => v,
		Err(code) => return code,
	};
	let mut pk = [0u8; 64];
	let r = if o.key.is_some() {
		// Deriving the key from a keyfile means decrypting it; reading a .pub
		// file needs no passphrase.
		let pass = match obtain_passphrase(o.passphrase_file, b"Passphrase: ") {
			Ok(p) => p,
			Err(code) => return code,
		};
		// SAFETY: every pointer is valid for the length passed with it.
		unsafe {
			abi::sigil_keyfile_public_key(
				raw.as_ptr().cast(),
				raw.len(),
				pass.as_ptr().cast(),
				pass.len(),
				pk.as_mut_ptr(),
			)
		}
	} else {
		public_key_from_text(&raw, &mut pk)
	};
	if r != SIGIL_OK {
		let why = if o.key.is_some() {
			sign_strerror(r)
		} else {
			strerror(r)
		};
		err(&[
			b"sigil: cannot read a public key from ",
			src,
			b": ",
			why,
			b"\n",
		]);
		return if o.key.is_some() && r == abi::SIGIL_ERR_AUTH_FAILED {
			EX_REJECTED
		} else {
			EX_USAGE
		};
	}
	let n = public_key_len();
	if n > pk.len() {
		return EX_IOERR;
	}
	let pk = &pk[..n];
	let destination = o.out.unwrap_or(b"-");
	let rendered = match format {
		PubkeyFormat::Text => {
			let mut text = [0u8; 512];
			let mut len = 0usize;
			// SAFETY: every pointer is valid for the length passed with it.
			let r = unsafe {
				abi::sigil_public_key_to_text(
					pk.as_ptr(),
					text.as_mut_ptr().cast(),
					512,
					&raw mut len,
				)
			};
			if r != SIGIL_OK {
				err(&[b"sigil: ", strerror(r), b"\n"]);
				return EX_IOERR;
			}
			return write_all(destination, &text[..len.min(512)], PLAIN);
		}
		PubkeyFormat::Raw => return write_all(destination, pk, PLAIN),
		PubkeyFormat::Hex => {
			let mut s: Vec<u8> = pk
				.iter()
				.flat_map(|b| format!("{b:02x}").into_bytes())
				.collect();
			s.push(b'\n');
			s
		}
		PubkeyFormat::C => emit_byte_array(
			b"static const unsigned char SIGIL_PUBLIC_KEY[32] = ",
			pk,
			b"{",
			b"};",
		),
		PubkeyFormat::Zig => {
			emit_byte_array(b"pub const sigil_public_key: [32]u8 = .", pk, b"{", b"};")
		}
	};
	// cli/main.c renders into 512 bytes, NUL included.
	if rendered.len() >= 512 {
		err(&[b"sigil: public key rendering overflowed\n"]);
		return EX_IOERR;
	}
	write_all(destination, &rendered, PLAIN)
}

// ── hot-bundle ──────────────────────────────────────────────────────────────

/// `hot-bundle open <bundle>`: the private key goes to stdout only, so the
/// one sanctioned use (a pipe into `wrangler secret put`) is also the only
/// one expressible.
fn cmd_hot_bundle(args: &[Vec<u8>], ui: &mut Ui) -> i32 {
	if args.len() < 3 {
		die_usage("hot-bundle needs a verb: open <bundle>", None);
		return EX_USAGE;
	}
	let verb = normalize(&args[2]);
	if is_help(&verb) {
		usage(1);
		return EX_OK;
	}
	if verb == b"--about" {
		about();
		return EX_OK;
	}
	if verb != b"open" {
		die_usage("unknown hot-bundle verb (want: open)", Some(&args[2]));
		return EX_USAGE;
	}
	let o = match parse(args, 3, ui) {
		Ok(o) => o,
		Err(code) => return code,
	};
	let Some(positional) = o.positional else {
		die_usage(
			"hot-bundle open needs a bundle path (use '-' for stdin)",
			None,
		);
		return EX_USAGE;
	};
	if let Some(destination) = o.out
		&& resolve_out(destination) != Some(1)
	{
		die_usage(
			"hot-bundle open writes the private key to stdout only; pipe it into `wrangler secret put` rather than a file",
			Some(destination),
		);
		return EX_USAGE;
	}
	if is_stdin_path(positional) && o.passphrase_file.is_some_and(is_stdin_path) {
		die_usage("bundle and passphrase cannot both come from stdin", None);
		return EX_USAGE;
	}
	let bundle = match read_all(positional) {
		Ok(v) => v,
		Err(code) => return code,
	};
	let pass = match obtain_passphrase(o.passphrase_file, b"Passphrase: ") {
		Ok(p) => p,
		Err(code) => return code,
	};
	const PEM_CAP: usize = 1024;
	let mut pem: Secret = Zeroizing::new(vec![0u8; PEM_CAP]);
	let mut pem_len = 0usize;
	// SAFETY: every pointer is valid for the length passed with it.
	let r = unsafe {
		abi::sigil_hot_bundle_open(
			bundle.as_ptr().cast(),
			bundle.len(),
			pass.as_ptr().cast(),
			pass.len(),
			pem.as_mut_ptr().cast(),
			PEM_CAP,
			&raw mut pem_len,
		)
	};
	if r != SIGIL_OK {
		err(&[
			b"sigil: ",
			ui.bad(),
			ui.mark_bad(),
			ui.off(),
			b" cannot open ",
			positional,
			b": ",
			sign_strerror(r),
			b"\n",
		]);
		return match r {
			abi::SIGIL_ERR_AUTH_FAILED => EX_REJECTED,
			abi::SIGIL_ERR_NOT_HOT_BUNDLE
			| abi::SIGIL_ERR_MALFORMED_KEYFILE
			| abi::SIGIL_ERR_UNSUPPORTED_KEYFILE => EX_DATAERR,
			_ => EX_IOERR,
		};
	}
	let status = write_all(b"-", &pem[..pem_len.min(PEM_CAP)], PLAIN);
	if status != EX_OK {
		return status;
	}
	ui.note(&[
		ui.ok(),
		ui.mark_ok(),
		ui.off(),
		b" opened ",
		positional,
		b": PKCS#8 PEM on stdout. Never write it to a file.\n",
	]);
	EX_OK
}

// ── paper ───────────────────────────────────────────────────────────────────

fn basename_of(p: &[u8]) -> &[u8] {
	p.iter()
		.rposition(|&c| c == b'/')
		.map_or(p, |i| &p[i + 1..])
}

fn is_iso_date(d: &[u8]) -> bool {
	d.len() == 10
		&& d[4] == b'-'
		&& d[7] == b'-'
		&& d.iter()
			.enumerate()
			.all(|(i, c)| i == 4 || i == 7 || c.is_ascii_digit())
}

/// Today's local date as YYYY-MM-DD, or `None` where strftime's would not
/// be ten characters.
fn today() -> Option<Vec<u8>> {
	// SAFETY: time(NULL) and localtime_r with a zeroed, writable tm.
	let mut tm: libc::tm = unsafe { core::mem::zeroed() };
	let now = unsafe { libc::time(core::ptr::null_mut()) };
	if unsafe { libc::localtime_r(&raw const now, &raw mut tm) }.is_null() {
		return None;
	}
	let date = format!(
		"{:04}-{:02}-{:02}",
		i64::from(tm.tm_year) + 1900,
		tm.tm_mon + 1,
		tm.tm_mday
	);
	(date.len() == 10).then(|| date.into_bytes())
}

/// Printable cold copies of sealed artifacts. Reads sealed bytes only; no
/// passphrase, nothing decrypted. --date makes the output reproducible.
fn cmd_paper(args: &[Vec<u8>], ui: &mut Ui) -> i32 {
	let o = match parse(args, 2, ui) {
		Ok(o) => o,
		Err(code) => return code,
	};
	if o.key.is_none() && o.hot_bundle.is_none() {
		die_usage(
			"paper needs --key <keyfile> and/or --hot-bundle <bundle>",
			None,
		);
		return EX_USAGE;
	}
	let Some(label) = o.label else {
		die_usage(
			"paper needs --label <text> saying what the key is for",
			None,
		);
		return EX_USAGE;
	};
	let Some(destination) = o.out else {
		die_usage("paper needs --out <pdf> ('-' for stdout)", None);
		return EX_USAGE;
	};
	if let Some(date) = o.date
		&& !is_iso_date(date)
	{
		die_usage("--date must be YYYY-MM-DD", Some(date));
		return EX_USAGE;
	}
	let date = match o.date {
		Some(d) => d.to_vec(),
		None => match today() {
			Some(d) => d,
			None => {
				err(&[b"sigil: cannot read today's date; pass --date\n"]);
				return EX_IOERR;
			}
		},
	};
	let key = match o.key.map(read_all).transpose() {
		Ok(v) => v,
		Err(code) => return code,
	};
	let bundle = match o.hot_bundle.map(read_all).transpose() {
		Ok(v) => v,
		Err(code) => return code,
	};
	let mut pk = [0u8; 64];
	let mut have_pk = false;
	if let Some(pubkey) = o.pubkey {
		let pubtext = match read_all(pubkey) {
			Ok(v) => v,
			Err(code) => return code,
		};
		let r = public_key_from_text(&pubtext, &mut pk);
		if r != SIGIL_OK {
			err(&[
				b"sigil: ",
				pubkey,
				b" is not a public key: ",
				strerror(r),
				b"\n",
			]);
			return EX_USAGE;
		}
		have_pk = true;
	}
	// argv strings cannot hold a NUL, so these conversions cannot fail.
	let (Ok(label_c), Ok(date_c)) = (CString::new(label), CString::new(date)) else {
		return EX_USAGE;
	};
	let mut names = Vec::new();
	let mut arts = Vec::new();
	for (kind, path, bytes) in [
		(abi::SIGIL_PAPER_KEYFILE, o.key, key.as_deref()),
		(abi::SIGIL_PAPER_HOT_BUNDLE, o.hot_bundle, bundle.as_deref()),
	] {
		let (Some(path), Some(bytes)) = (path, bytes) else {
			continue;
		};
		let Ok(name) = CString::new(basename_of(path)) else {
			return EX_USAGE;
		};
		names.push(name);
		arts.push((kind, bytes));
	}
	let artifacts: Vec<SigilPaperArtifact> = arts
		.iter()
		.zip(&names)
		.map(|(&(kind, bytes), name)| SigilPaperArtifact {
			kind,
			label: label_c.as_ptr(),
			filename: name.as_ptr(),
			bytes: bytes.as_ptr(),
			bytes_len: bytes.len(),
			pubkey: if have_pk {
				pk.as_ptr()
			} else {
				core::ptr::null()
			},
		})
		.collect();
	let render = |pdf: &mut Vec<u8>, len: &mut usize| {
		// SAFETY: the artifacts point into buffers that outlive the call, and
		// pdf is writable for its length.
		unsafe {
			abi::sigil_paper_render(
				artifacts.as_ptr(),
				artifacts.len(),
				date_c.as_ptr(),
				pdf.as_mut_ptr().cast(),
				pdf.len(),
				len,
			)
		}
	};
	let mut pdf = vec![0u8; 256 * 1024];
	let mut pdf_len = 0usize;
	let mut r = render(&mut pdf, &mut pdf_len);
	if r == abi::SIGIL_ERR_BUFFER_TOO_SMALL {
		pdf.resize(pdf_len, 0);
		r = render(&mut pdf, &mut pdf_len);
	}
	if r != SIGIL_OK {
		err(&[
			b"sigil: ",
			ui.bad(),
			ui.mark_bad(),
			ui.off(),
			b" cannot render the page: ",
			sign_strerror(r),
			b"\n",
		]);
		return if r == abi::SIGIL_ERR_TOO_LARGE_FOR_QR {
			EX_DATAERR
		} else {
			EX_IOERR
		};
	}
	let pdf = &pdf[..pdf_len.min(pdf.len())];
	let status = write_all(
		destination,
		pdf,
		WriteMode {
			exclusive: !o.force,
			secret: false,
		},
	);
	if status != EX_OK {
		return status;
	}
	let pages = artifacts.len();
	ui.note(&[
		ui.ok(),
		ui.mark_ok(),
		ui.off(),
		b" wrote ",
		destination,
		b": ",
		&decimal(pages),
		b" page",
		plural(pages),
		b" (",
		&decimal(pdf.len()),
		b" bytes). Print it, check the QR scans, store it.\n",
	]);
	EX_OK
}

// ── main ────────────────────────────────────────────────────────────────────

fn run(args: &[Vec<u8>]) -> i32 {
	// SAFETY: isatty on a descriptor number has no preconditions.
	let tty = unsafe { libc::isatty(2) } == 1;
	let mut ui = Ui {
		color: tty && std::env::var_os("NO_COLOR").is_none(),
		simple: false,
		quiet: false,
	};
	if args.len() < 2 {
		return usage(2);
	}
	let cmd = normalize(&args[1]);
	if is_help(&cmd) {
		usage(1);
		return EX_OK;
	}
	match cmd.as_slice() {
		b"--about" => {
			about();
			EX_OK
		}
		b"--version" => {
			out(&[version(), b"\n"]);
			EX_OK
		}
		b"verify" => cmd_verify(args, &mut ui),
		b"sign" => cmd_sign(args, &mut ui),
		b"keygen" => cmd_keygen(args, &mut ui),
		b"pubkey" => cmd_pubkey(args, &mut ui),
		b"hot-bundle" => cmd_hot_bundle(args, &mut ui),
		b"paper" => cmd_paper(args, &mut ui),
		_ => {
			err(&[b"sigil: unknown command: ", &args[1], b"\n"]);
			usage(2)
		}
	}
}

fn main() {
	// A C program dies of SIGPIPE on a closed pipe; Rust ignores the signal
	// by default. Match the C CLI.
	// SAFETY: restoring a default signal disposition before any I/O.
	unsafe { libc::signal(libc::SIGPIPE, libc::SIG_DFL) };
	let args: Vec<Vec<u8>> = std::env::args_os().map(OsStringExt::into_vec).collect();
	std::process::exit(run(&args));
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn slash_switches_normalize_but_paths_do_not() {
		assert_eq!(normalize(b"/help"), b"-help");
		assert_eq!(normalize(b"/"), b"/");
		assert_eq!(normalize(b"/tmp/x"), b"/tmp/x");
		assert_eq!(
			normalize(b"/abcdefghijklmnopqrstuvwxyz"),
			b"/abcdefghijklmnopqrstuvwxyz"
		);
		assert_eq!(normalize(b"-q"), b"-q");
	}

	#[test]
	fn json_escape_matches_cli_json_h() {
		assert_eq!(json_escape(b"a\"b\\c\n\x01", 512), b"a\\\"b\\\\c\\n\\u0001");
		assert_eq!(json_escape(b"abcdef", 4), b"abc");
		assert_eq!(json_escape(b"abc", 0), b"");
	}

	#[test]
	fn byte_arrays_break_every_eight_bytes() {
		let pk: Vec<u8> = (0..10).collect();
		let s = emit_byte_array(b"x = ", &pk, b"{", b"};");
		assert_eq!(
			String::from_utf8(s).unwrap_or_default(),
			"x = {\n    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,\n    0x08, 0x09,\n};\n"
		);
	}

	#[test]
	fn dates_and_basenames() {
		assert!(is_iso_date(b"2026-11-10"));
		assert!(!is_iso_date(b"2026-1-10"));
		assert!(!is_iso_date(b"2026/11/10"));
		assert_eq!(basename_of(b"/a/b/role.key"), b"role.key");
		assert_eq!(basename_of(b"role.key"), b"role.key");
	}
}
