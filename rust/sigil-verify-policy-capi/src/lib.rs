//! The archive a licensed application links, installed as
//! `libsigil_verify_policy.a`: `include/sigil.h` from `sigil-ffi` and
//! `mecha_policy.h` from `mecha-policy-ffi`, in one Rust static library
//! because a program can link only one (see `sigil-verify-capi`). It holds no
//! signing code.

#![forbid(unsafe_code)]

extern crate mecha_policy_ffi as _;
extern crate sigil_ffi as _;
