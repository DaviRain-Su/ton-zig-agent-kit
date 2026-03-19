//! Generic StateInit builders for contract deployment.

const std = @import("std");
const cell = @import("cell.zig");
const boc = @import("boc.zig");

pub fn buildStateInitCellAlloc(
    allocator: std.mem.Allocator,
    code_boc: ?[]const u8,
    data_boc: ?[]const u8,
) !*cell.Cell {
    var builder = cell.Builder.init();
    errdefer deinitBuilderRefs(allocator, &builder);

    // split_depth:(Maybe (## 5))
    try builder.storeUint(0, 1);
    // special:(Maybe TickTock)
    try builder.storeUint(0, 1);

    if (code_boc) |value| {
        const code_cell = try boc.deserializeBoc(allocator, value);
        try builder.storeUint(1, 1);
        try builder.storeRef(code_cell);
    } else {
        try builder.storeUint(0, 1);
    }

    if (data_boc) |value| {
        const data_cell = try boc.deserializeBoc(allocator, value);
        try builder.storeUint(1, 1);
        try builder.storeRef(data_cell);
    } else {
        try builder.storeUint(0, 1);
    }

    // library:(HashmapE 256 SimpleLib) empty
    try builder.storeUint(0, 1);

    return builder.toCell(allocator);
}

pub fn buildStateInitBocAlloc(
    allocator: std.mem.Allocator,
    code_boc: ?[]const u8,
    data_boc: ?[]const u8,
) ![]u8 {
    const state_init = try buildStateInitCellAlloc(allocator, code_boc, data_boc);
    defer state_init.deinit(allocator);

    return boc.serializeBoc(allocator, state_init);
}

fn deinitBuilderRefs(allocator: std.mem.Allocator, builder: *cell.Builder) void {
    for (builder.refs[0..builder.ref_cnt]) |ref| {
        if (ref) |value| value.deinit(allocator);
    }
}

test "state init builder stores code and data refs" {
    const allocator = std.testing.allocator;

    var code_builder = cell.Builder.init();
    try code_builder.storeUint(0xCAFE, 16);
    const code_cell = try code_builder.toCell(allocator);
    defer code_cell.deinit(allocator);
    const code_boc = try boc.serializeBoc(allocator, code_cell);
    defer allocator.free(code_boc);

    var data_builder = cell.Builder.init();
    try data_builder.storeUint(0xBEEF, 16);
    const data_cell = try data_builder.toCell(allocator);
    defer data_cell.deinit(allocator);
    const data_boc = try boc.serializeBoc(allocator, data_cell);
    defer allocator.free(data_boc);

    const built = try buildStateInitBocAlloc(allocator, code_boc, data_boc);
    defer allocator.free(built);

    const state_init = try boc.deserializeBoc(allocator, built);
    defer state_init.deinit(allocator);

    var slice = state_init.toSlice();
    try std.testing.expectEqual(@as(u64, 0), try slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 0), try slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 1), try slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 1), try slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 0), try slice.loadUint(1));

    const code_ref = try slice.loadRef();
    const data_ref = try slice.loadRef();
    try std.testing.expectEqualSlices(u8, &code_cell.hash(), &code_ref.hash());
    try std.testing.expectEqualSlices(u8, &data_cell.hash(), &data_ref.hash());
}

test "state init builder supports empty data and code" {
    const allocator = std.testing.allocator;

    const built = try buildStateInitBocAlloc(allocator, null, null);
    defer allocator.free(built);

    const state_init = try boc.deserializeBoc(allocator, built);
    defer state_init.deinit(allocator);

    var slice = state_init.toSlice();
    try std.testing.expectEqual(@as(u64, 0), try slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 0), try slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 0), try slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 0), try slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 0), try slice.loadUint(1));
    try std.testing.expect(slice.empty());
}
