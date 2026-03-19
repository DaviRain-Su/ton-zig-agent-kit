//! Generic StateInit builders for contract deployment.

const std = @import("std");
const address = @import("address.zig");
const cell = @import("cell.zig");
const boc = @import("boc.zig");
const types = @import("types.zig");

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

pub fn computeStateInitAddress(workchain: i8, state_init: *const cell.Cell) types.Address {
    return .{
        .raw = state_init.hash(),
        .workchain = workchain,
    };
}

pub fn computeStateInitAddressFromBoc(
    allocator: std.mem.Allocator,
    workchain: i8,
    state_init_boc: []const u8,
) !types.Address {
    const state_init = try boc.deserializeBoc(allocator, state_init_boc);
    defer state_init.deinit(allocator);
    return computeStateInitAddress(workchain, state_init);
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

test "state init address uses representation hash" {
    const allocator = std.testing.allocator;

    const built = try buildStateInitBocAlloc(allocator, null, null);
    defer allocator.free(built);

    const addr = try computeStateInitAddressFromBoc(allocator, 0, built);
    const raw = try address.formatRaw(allocator, &addr);
    defer allocator.free(raw);

    try std.testing.expectEqualStrings("0:3f078d3b7e22c8944e5561909a236ae48b48a7ea42f28dd861c22b6f64d7e97b", raw);
}

test "state init address changes with referenced code" {
    const allocator = std.testing.allocator;

    var code_a_builder = cell.Builder.init();
    try code_a_builder.storeUint(0xAA, 8);
    const code_a_cell = try code_a_builder.toCell(allocator);
    defer code_a_cell.deinit(allocator);
    const code_a_boc = try boc.serializeBoc(allocator, code_a_cell);
    defer allocator.free(code_a_boc);

    var code_b_builder = cell.Builder.init();
    try code_b_builder.storeUint(0xBB, 8);
    const code_b_cell = try code_b_builder.toCell(allocator);
    defer code_b_cell.deinit(allocator);
    const code_b_boc = try boc.serializeBoc(allocator, code_b_cell);
    defer allocator.free(code_b_boc);

    const state_init_a = try buildStateInitBocAlloc(allocator, code_a_boc, null);
    defer allocator.free(state_init_a);
    const state_init_b = try buildStateInitBocAlloc(allocator, code_b_boc, null);
    defer allocator.free(state_init_b);

    const addr_a = try computeStateInitAddressFromBoc(allocator, 0, state_init_a);
    const addr_b = try computeStateInitAddressFromBoc(allocator, 0, state_init_b);
    try std.testing.expect(!std.mem.eql(u8, &addr_a.raw, &addr_b.raw));
}
