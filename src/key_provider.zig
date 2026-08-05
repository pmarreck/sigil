//! Custody-independent signing port. Tests state the boundary before its
//! implementation so provider behavior is pinned independently of adapters.

const std = @import("std");
const core = @import("verify.zig");
const testing = std.testing;

/// Algorithm vocabulary for provider capability checks. Values are internal
/// routing identifiers only; they are not the pending signed transcript tag.
pub const Algorithm = enum(u16) {
    ed25519 = 0,
    _,
};

/// Describes where signing authority resides without claiming a driver exists.
pub const Custody = enum {
    encrypted_keyfile,
    non_exportable_hardware,
    offline_ceremony,
};

/// States whether private bytes may exist in the provider process. The signer
/// port never returns them for either value.
pub const KeyExposure = enum {
    process_memory,
    non_exportable,
};

/// Readiness is separate from algorithm support so absence of a driver or an
/// intentional air gap cannot be mislabeled as a signing failure.
pub const Availability = enum {
    ready,
    driver_required,
    external_ceremony_required,
};

pub const Error = error{
    UnsupportedAlgorithm,
    ProviderDriverRequired,
    ExternalCeremonyRequired,
    ProviderFailure,
};

/// One signing capability. Providers with several algorithms expose one
/// signer per configured key, avoiding an algorithm choice inside callbacks.
pub const Capabilities = struct {
    algorithm: Algorithm,
    custody: Custody,
    key_exposure: KeyExposure,
    availability: Availability,

    pub const keyfile: Capabilities = .{
        .algorithm = .ed25519,
        .custody = .encrypted_keyfile,
        .key_exposure = .process_memory,
        .availability = .ready,
    };
};

pub const SignFn = *const fn (
    context: *anyopaque,
    message: []const u8,
) Error![core.signature_len]u8;

/// Opaque port passed to envelope construction. Its callback receives only
/// verbatim message bytes and can return only a fixed-size signature or a
/// classified provider error; private key bytes have no return path.
pub const Signer = struct {
    context: *anyopaque,
    capabilities: Capabilities,
    sign_fn: SignFn,

    pub fn init(
        context: *anyopaque,
        capabilities: Capabilities,
        sign_fn: SignFn,
    ) Signer {
        return .{
            .context = context,
            .capabilities = capabilities,
            .sign_fn = sign_fn,
        };
    }

    /// Fail capability/readiness checks before the provider callback can touch
    /// hardware, prompt for a ceremony, or collapse faults into one bucket.
    pub fn sign(
        self: Signer,
        algorithm: Algorithm,
        message: []const u8,
    ) Error![core.signature_len]u8 {
        if (algorithm != self.capabilities.algorithm) return Error.UnsupportedAlgorithm;
        switch (self.capabilities.availability) {
            .ready => {},
            .driver_required => return Error.ProviderDriverRequired,
            .external_ceremony_required => return Error.ExternalCeremonyRequired,
        }
        return self.sign_fn(self.context, message);
    }
};

const MockProvider = struct {
    calls: usize = 0,
    seen_len: usize = 0,
    should_fail: bool = false,
    private_key: [64]u8 = @splat(0xA5),

    fn sign(raw: *anyopaque, message: []const u8) Error![core.signature_len]u8 {
        const self: *MockProvider = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.seen_len = message.len;
        if (self.should_fail) return Error.ProviderFailure;
        return @splat(message[0]);
    }
};

test "capability preflight classifies every provider state before signing" {
    const unknown_algorithm: Algorithm = @enumFromInt(65535);
    const cases = [_]struct {
        name: []const u8,
        capabilities: Capabilities,
        requested: Algorithm,
        provider_fails: bool,
        expected: ?Error,
        expected_calls: usize,
    }{
        .{
            .name = "ready Ed25519 provider",
            .capabilities = .keyfile,
            .requested = .ed25519,
            .provider_fails = false,
            .expected = null,
            .expected_calls = 1,
        },
        .{
            .name = "unsupported algorithm",
            .capabilities = .keyfile,
            .requested = unknown_algorithm,
            .provider_fails = false,
            .expected = Error.UnsupportedAlgorithm,
            .expected_calls = 0,
        },
        .{
            .name = "hardware driver absent",
            .capabilities = .{
                .algorithm = .ed25519,
                .custody = .non_exportable_hardware,
                .key_exposure = .non_exportable,
                .availability = .driver_required,
            },
            .requested = .ed25519,
            .provider_fails = false,
            .expected = Error.ProviderDriverRequired,
            .expected_calls = 0,
        },
        .{
            .name = "offline ceremony required",
            .capabilities = .{
                .algorithm = .ed25519,
                .custody = .offline_ceremony,
                .key_exposure = .non_exportable,
                .availability = .external_ceremony_required,
            },
            .requested = .ed25519,
            .provider_fails = false,
            .expected = Error.ExternalCeremonyRequired,
            .expected_calls = 0,
        },
        .{
            .name = "ready provider failed",
            .capabilities = .keyfile,
            .requested = .ed25519,
            .provider_fails = true,
            .expected = Error.ProviderFailure,
            .expected_calls = 1,
        },
    };

    for (cases) |case| {
        var mock: MockProvider = .{ .should_fail = case.provider_fails };
        const signer = Signer.init(&mock, case.capabilities, MockProvider.sign);
        if (case.expected) |expected| {
            testing.expectError(expected, signer.sign(case.requested, "payload")) catch |e| {
                std.debug.print("provider case failed: {s}\n", .{case.name});
                return e;
            };
        } else {
            _ = try signer.sign(case.requested, "payload");
        }
        try testing.expectEqual(case.expected_calls, mock.calls);
    }
}

test "a non-exportable provider receives message bytes and returns only a signature" {
    var mock: MockProvider = .{};
    const capabilities: Capabilities = .{
        .algorithm = .ed25519,
        .custody = .non_exportable_hardware,
        .key_exposure = .non_exportable,
        .availability = .ready,
    };
    const signer = Signer.init(&mock, capabilities, MockProvider.sign);
    const signature = try signer.sign(.ed25519, "verbatim bytes");

    try testing.expectEqual(@as(usize, 1), mock.calls);
    try testing.expectEqual("verbatim bytes".len, mock.seen_len);
    try testing.expectEqualSlices(u8, &([_]u8{'v'} ** core.signature_len), &signature);
    try testing.expect(@sizeOf(Signer) < mock.private_key.len);
    try testing.expectEqual(KeyExposure.non_exportable, signer.capabilities.key_exposure);
}
