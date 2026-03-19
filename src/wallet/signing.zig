//! Wallet signing and message creation

const std = @import("std");
const types = @import("../core/types.zig");
const cell = @import("../core/cell.zig");
const address = @import("../core/address.zig");

pub const WalletVersion = enum {
    v2,
    v3,
    v4,
};

pub const WalletMessage = struct {
    destination: []const u8,
    amount: u64,
    body: ?[]const u8 = null,
};

pub fn createSignedTransfer(
    allocator: std.mem.Allocator,
    version: WalletVersion,
    private_key: [32]u8,
    seqno: u32,
    msgs: []WalletMessage,
) ![]u8 {
    _ = allocator;
    _ = version;
    _ = private_key;
    _ = seqno;
    _ = msgs;
    return &.{};
}

pub fn getSeqno(client: anytype, wallet_address: []const u8) !u32 {
    _ = client;
    _ = wallet_address;
    return 0;
}

pub fn sendTransfer(
    client: anytype,
    version: WalletVersion,
    private_key: [32]u8,
    destination: []const u8,
    amount: u64,
    comment: ?[]const u8,
) !types.SendBocResponse {
    _ = client;
    _ = version;
    _ = private_key;
    _ = destination;
    _ = amount;
    _ = comment;
    return types.SendBocResponse{ .hash = "", .lt = 0 };
}

test "wallet signing" {
    _ = createSignedTransfer;
    _ = getSeqno;
    _ = sendTransfer;
}
