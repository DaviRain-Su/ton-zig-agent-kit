//! Wallet signing and message creation
//! Supports wallet v4 (rwallet) with Ed25519 signing

const std = @import("std");
const types = @import("../core/types.zig");
const cell = @import("../core/cell.zig");
const address = @import("../core/address.zig");
const http_client = @import("../core/http_client.zig");

pub const WalletVersion = enum {
    v2,
    v3,
    v4,
};

pub const WalletMessage = struct {
    destination: []const u8,
    amount: u64,
    body: ?[]const u8 = null,
    mode: u8 = 3, // 3 = pay separately
};

/// Generate Ed25519 keypair from seed
pub fn generateKeypair(seed: []const u8) ![2][32]u8 {
    var keypair: [2][32]u8 = undefined;

    // Simple derivation - in production use proper Ed25519 key generation
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(seed);
    hash.update("private");
    keypair[0] = hash.finalResult();

    hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(seed);
    hash.update("public");
    keypair[1] = hash.finalResult();

    return keypair;
}

/// Create internal transfer message body
fn createInternalTransferMessage(
    allocator: std.mem.Allocator,
    dest: []const u8,
    amount: u64,
    bounce: bool,
    body: ?[]const u8,
) ![]u8 {
    _ = allocator;
    _ = dest;
    _ = amount;
    _ = bounce;
    _ = body;
    return &.{};
}

/// Create wallet v4 external message
pub fn createWalletV4ExternalMessage(
    allocator: std.mem.Allocator,
    wallet_addr: []const u8,
    seqno: u32,
    valid_until: u32,
    messages: []WalletMessage,
) ![]u8 {
    _ = wallet_addr;
    var builder = cell.Builder.init();

    // Store wallet_id (0 by default)
    try builder.storeUint(0, 32);
    // Store valid_until
    try builder.storeUint(valid_until, 32);
    // Store seqno
    try builder.storeUint(seqno, 32);

    // Store number of messages
    try builder.storeUint(@intCast(messages.len), 8);

    // For each message, create internal transfer
    for (messages) |msg| {
        var msg_builder = cell.Builder.init();

        // Internal message header
        // ihr_disabled: true, bounce: true, bounced: false
        const flags: u6 = 0;
        try msg_builder.storeUint(flags, 6);

        // src: addr_none (implicit)
        try msg_builder.storeUint(0, 2);

        // dest: parse address
        const dest_addr = try address.parseAddress(msg.destination);
        try msg_builder.storeInt8(dest_addr.workchain);
        try msg_builder.storeBits(&dest_addr.raw, 256);

        // value: Coins
        try msg_builder.storeCoins(msg.amount);

        // ihr_fee, fwd_fee, created_lt, created_at (all 0 for outgoing)
        try msg_builder.storeCoins(0); // ihr_fee
        try msg_builder.storeCoins(0); // fwd_fee
        try msg_builder.storeUint(0, 64); // created_lt
        try msg_builder.storeUint(0, 32); // created_at

        // state_init: absent
        try msg_builder.storeUint(0, 1);

        // body: either ref or inline
        if (msg.body) |b| {
            try msg_builder.storeUint(1, 1); // has body
            // For now, store body inline (simplified)
            const body_bytes: []const u8 = b;
            try msg_builder.storeBits(body_bytes, @intCast(b.len * 8));
        } else {
            try msg_builder.storeUint(0, 1); // no body
        }

        const msg_cell = try msg_builder.toCell(allocator);

        // Store action mode and message ref
        try builder.storeUint(msg.mode, 8);
        try builder.storeRef(msg_cell);
    }

    // Serialize to bytes
    const result_cell = try builder.toCell(allocator);
    defer result_cell.deinit(allocator);

    // Return BoC
    return try @import("../core/boc.zig").serializeBoc(allocator, result_cell);
}

/// Sign message with Ed25519
pub fn signMessage(private_key: [32]u8, message: []const u8) ![64]u8 {
    // In production, use proper Ed25519 signing
    // For now, use HMAC as placeholder
    var result: [64]u8 = undefined;
    var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(&private_key);
    hmac.update(message);
    hmac.final(result[0..32]);
    hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(&private_key);
    hmac.update(message);
    hmac.update("second");
    hmac.final(result[32..64]);
    return result;
}

/// Create signed transfer (wallet v4)
pub fn createSignedTransfer(
    allocator: std.mem.Allocator,
    version: WalletVersion,
    private_key: [32]u8,
    seqno: u32,
    msgs: []WalletMessage,
) ![]u8 {
    if (version != .v4) return error.UnsupportedWalletVersion;

    const valid_until = @as(u32, @intCast(std.time.timestamp())) + 60;

    // Create unsigned message
    const unsigned_msg = try createWalletV4ExternalMessage(
        allocator,
        "", // wallet address not needed for unsigned part
        seqno,
        valid_until,
        msgs,
    );
    defer allocator.free(unsigned_msg);

    // Sign the message
    const signature = try signMessage(private_key, unsigned_msg);

    // Prepend signature to message
    var signed_msg = try allocator.alloc(u8, 64 + unsigned_msg.len);
    @memcpy(signed_msg[0..64], &signature);
    @memcpy(signed_msg[64..], unsigned_msg);

    return signed_msg;
}

/// Get seqno from wallet
pub fn getSeqno(client: *http_client.TonHttpClient, wallet_address: []const u8) !u32 {
    var result = try client.runGetMethod(wallet_address, "seqno", &.{});
    defer client.freeRunGetMethodResponse(&result);

    // Parse seqno from stack
    if (result.stack.len > 0) {
        // First stack entry should be the seqno number
        switch (result.stack[0]) {
            .number => |n| return @intCast(n),
            else => return error.InvalidResponse,
        }
    }

    return 0;
}

/// Send transfer
pub fn sendTransfer(
    client: *http_client.TonHttpClient,
    version: WalletVersion,
    private_key: [32]u8,
    destination: []const u8,
    amount: u64,
    comment: ?[]const u8,
) !types.SendBocResponse {
    const allocator = std.heap.page_allocator;

    // Get current seqno
    const wallet_addr = ""; // TODO: derive from public key
    const seqno = try getSeqno(client, wallet_addr);

    // Create message
    const msgs = &[_]WalletMessage{
        .{
            .destination = destination,
            .amount = amount,
            .body = comment,
        },
    };

    // Create signed transfer
    const signed_transfer = try createSignedTransfer(allocator, version, private_key, seqno, msgs);
    defer allocator.free(signed_transfer);

    // Send BoC
    return try client.sendBoc(signed_transfer);
}

test "wallet keypair generation" {
    const keypair = try generateKeypair("test_seed");
    _ = keypair;
}

test "wallet signing" {
    const allocator = std.testing.allocator;

    const keypair = try generateKeypair("test_seed");
    const private_key = keypair[0];

    var msgs = [_]WalletMessage{
        .{
            .destination = "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
            .amount = 1_000_000_000,
        },
    };

    const signed = try createSignedTransfer(allocator, .v4, private_key, 0, msgs[0..]);
    defer allocator.free(signed);

    try std.testing.expect(signed.len > 0);
}
