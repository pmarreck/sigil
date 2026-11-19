//! The library the sigil CLI links, installed as `libsigil_verify_sign.a` and
//! as a shared library: `include/sigil.h` from `sigil-ffi` and
//! `include/sigil_sign.h` from `sigil-sign-ffi`, in one Rust library because
//! a program can link only one Rust static library (see `sigil-verify-capi`).
//!
//! The shared library is for the Rust CLI. It reaches the core only through
//! the C ABI, and a Rust program linking a Rust static library would carry two
//! copies of the standard library; a shared library keeps its own copy inside.

#![forbid(unsafe_code)]

extern crate sigil_ffi as _;
extern crate sigil_sign_ffi as _;
