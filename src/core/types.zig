//! Common types for TON interactions

const std = @import("std");
const cell = @import("cell.zig");

pub const Address = struct {
    raw: [32]u8,
    workchain: i8,

    pub fn parseUserFriendly(str: []const u8) !Address {
        return @import("address.zig").parseAddress(str);
    }
    pub fn parseRaw(str: []const u8) !Address {
        return @import("address.zig").parseAddress(str);
    }
    pub fn toUserFriendly(self: *const Address) []const u8 {
        return @import("address.zig").addressToUserFriendly(self, false);
    }
    pub fn toUserFriendlyAlloc(self: *const Address, allocator: std.mem.Allocator, bounceable: bool, testnet: bool) ![]u8 {
        return @import("address.zig").addressToUserFriendlyAlloc(allocator, self, bounceable, testnet);
    }
    pub fn toRaw(self: *const Address) []const u8 {
        return @import("address.zig").formatRaw(std.heap.page_allocator, self) catch "";
    }
    pub fn toRawAlloc(self: *const Address, allocator: std.mem.Allocator) ![]u8 {
        return @import("address.zig").formatRaw(allocator, self);
    }
};

pub const Cell = cell.Cell;
pub const Builder = cell.Builder;
pub const Slice = cell.Slice;

pub const RunGetMethodResponse = struct {
    exit_code: i32,
    stack: []StackEntry,
    logs: []const u8,
};

pub const StackEntry = union(enum) {
    number: i64,
    cell: *cell.Cell,
    slice: *cell.Cell,
    tuple: []StackEntry,
    bytes: []const u8,
};

pub const BalanceResponse = struct {
    balance: u64,
    address: []const u8,
};

pub const SendBocResponse = struct {
    hash: []const u8,
    lt: i64,
};

pub const Transaction = struct {
    hash: []const u8,
    lt: i64,
    timestamp: i64,
    in_msg: ?*Message,
    out_msgs: []*Message,
};

pub const Message = struct {
    hash: []const u8,
    source: ?Address,
    destination: ?Address,
    value: u64,
    body: ?*cell.Cell,
    raw_body: []const u8,
};

pub const TonError = error{
    InvalidAddress,
    InvalidCell,
    InvalidBoc,
    NetworkError,
    RpcError,
    SigningError,
    SendError,
    Timeout,
    NotFound,
};

test "core types address helpers delegate to real implementation" {
    const allocator = std.testing.allocator;

    const parsed = try Address.parseUserFriendly("EQDKbjIcfM6ezt8KjKJJLshZJJSqX7XOA4ff-W72r5gqPrHF");
    try std.testing.expectEqual(@as(i8, 0), parsed.workchain);

    const raw = try parsed.toRawAlloc(allocator);
    defer allocator.free(raw);
    try std.testing.expectEqualStrings("0:ca6e321c7cce9ecedf0a8ca2492ec8592494aa5fb5ce0387dff96ef6af982a3e", raw);

    const bounceable = try parsed.toUserFriendlyAlloc(allocator, true, false);
    defer allocator.free(bounceable);
    try std.testing.expectEqualStrings("EQDKbjIcfM6ezt8KjKJJLshZJJSqX7XOA4ff-W72r5gqPrHF", bounceable);
}

test "core types cell aliases expose working builder and slice" {
    const allocator = std.testing.allocator;

    var builder = Builder.init();
    try builder.storeUint(0xCAFE, 16);
    const value = try builder.toCell(allocator);
    defer value.deinit(allocator);

    var slice = value.toSlice();
    try std.testing.expectEqual(@as(u64, 0xCAFE), try slice.loadUint(16));
    try std.testing.expect(slice.empty());
}
