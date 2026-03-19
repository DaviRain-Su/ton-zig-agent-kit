//! Generic TON message body builder from typed operations.

const std = @import("std");
const cell = @import("cell.zig");
const boc = @import("boc.zig");

pub const BodyOp = union(enum) {
    uint: struct {
        bits: u16,
        value: u64,
    },
    int: struct {
        bits: u16,
        value: i64,
    },
    coins: u64,
    address: []const u8,
    bytes: []const u8,
    ref_boc: []const u8,
};

pub fn buildBodyCellAlloc(allocator: std.mem.Allocator, ops: []const BodyOp) !*cell.Cell {
    var builder = cell.Builder.init();
    errdefer deinitBuilderRefs(allocator, &builder);

    for (ops) |op| {
        try applyBodyOp(&builder, allocator, op);
    }

    return builder.toCell(allocator);
}

pub fn buildBodyBocAlloc(allocator: std.mem.Allocator, ops: []const BodyOp) ![]u8 {
    const root = try buildBodyCellAlloc(allocator, ops);
    defer root.deinit(allocator);

    return boc.serializeBoc(allocator, root);
}

pub fn storeRefBoc(builder: *cell.Builder, allocator: std.mem.Allocator, body_boc: []const u8) !void {
    const ref = try boc.deserializeBoc(allocator, body_boc);
    errdefer ref.deinit(allocator);
    try builder.storeRef(ref);
}

fn applyBodyOp(builder: *cell.Builder, allocator: std.mem.Allocator, op: BodyOp) !void {
    switch (op) {
        .uint => |value| try builder.storeUint(value.value, value.bits),
        .int => |value| try builder.storeInt(value.value, value.bits),
        .coins => |value| try builder.storeCoins(value),
        .address => |value| try builder.storeAddress(value),
        .bytes => |value| try builder.storeBits(value, @intCast(value.len * 8)),
        .ref_boc => |value| try storeRefBoc(builder, allocator, value),
    }
}

fn deinitBuilderRefs(allocator: std.mem.Allocator, builder: *cell.Builder) void {
    for (builder.refs[0..builder.ref_cnt]) |ref| {
        if (ref) |value| value.deinit(allocator);
    }
}

test "body builder constructs boc from typed ops" {
    const allocator = std.testing.allocator;

    var child_builder = cell.Builder.init();
    try child_builder.storeUint(0xAB, 8);
    const child = try child_builder.toCell(allocator);
    defer child.deinit(allocator);

    const child_boc = try boc.serializeBoc(allocator, child);
    defer allocator.free(child_boc);

    const built = try buildBodyBocAlloc(allocator, &.{
        .{ .uint = .{ .bits = 32, .value = 0x12345678 } },
        .{ .int = .{ .bits = 8, .value = -1 } },
        .{ .coins = 1_000_000_000 },
        .{ .address = "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8" },
        .{ .bytes = "OK" },
        .{ .ref_boc = child_boc },
    });
    defer allocator.free(built);

    const root = try boc.deserializeBoc(allocator, built);
    defer root.deinit(allocator);

    var slice = root.toSlice();
    try std.testing.expectEqual(@as(u64, 0x12345678), try slice.loadUint(32));
    try std.testing.expectEqual(@as(i64, -1), try slice.loadInt(8));
    try std.testing.expectEqual(@as(u64, 1_000_000_000), try slice.loadCoins());
    const addr = try slice.loadAddress();
    try std.testing.expectEqual(@as(i8, 0), addr.workchain);
    try std.testing.expectEqual(@as(u8, 'O'), try slice.loadUint8());
    try std.testing.expectEqual(@as(u8, 'K'), try slice.loadUint8());

    const child_ref = try slice.loadRef();
    var child_slice = child_ref.toSlice();
    try std.testing.expectEqual(@as(u64, 0xAB), try child_slice.loadUint(8));
}

test "body builder storeRefBoc preserves referenced cell" {
    const allocator = std.testing.allocator;

    var child_builder = cell.Builder.init();
    try child_builder.storeUint(0xCAFE, 16);
    const child = try child_builder.toCell(allocator);
    defer child.deinit(allocator);

    const child_boc = try boc.serializeBoc(allocator, child);
    defer allocator.free(child_boc);

    var builder = cell.Builder.init();
    try builder.storeUint(1, 1);
    try storeRefBoc(&builder, allocator, child_boc);

    const root = try builder.toCell(allocator);
    defer root.deinit(allocator);

    var slice = root.toSlice();
    try std.testing.expectEqual(@as(u64, 1), try slice.loadUint(1));

    const child_ref = try slice.loadRef();
    var child_slice = child_ref.toSlice();
    try std.testing.expectEqual(@as(u64, 0xCAFE), try child_slice.loadUint(16));
}
