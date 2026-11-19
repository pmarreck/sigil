//! The archive a C program links to verify, installed as `libsigil.a`.
//!
//! Rust's rule for foreign programs is one Rust static library per program:
//! each one bundles its own copy of the standard library, so two of them in
//! one link conflict. This crate is therefore not an interface of its own. It
//! names the crates whose exported functions a verifier needs, here only
//! `sigil-ffi` (`include/sigil.h`), and the staticlib bundles them. A program
//! that also needs the policy or the signer links one of the sibling archives
//! instead of adding a second one.

#![forbid(unsafe_code)]

extern crate sigil_ffi as _;
