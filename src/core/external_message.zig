//! Builders for generic external incoming messages.

const std = @import("std");
const cell = @import("cell.zig");
const boc = @import("boc.zig");

pub fn buildExternalIncomingMessageCellAlloc(
    allocator: std.mem.Allocator,
    destination: []const u8,
    body_cell: *cell.Cell,
    state_init_boc: ?[]const u8,
) !*cell.Cell {
    var builder = cell.Builder.init();
    errdefer deinitBuilderRefs(allocator, &builder);

    try builder.storeUint(0b10, 2); // ext_in_msg_info$10
    try builder.storeUint(0, 2); // src: addr_none (MsgAddressExt)
    try builder.storeAddress(destination);
    try builder.storeCoins(0); // import_fee

    if (state_init_boc) |value| {
        const state_init_cell = try boc.deserializeBoc(allocator, value);
        try builder.storeUint(1, 1); // state_init present
        try builder.storeUint(1, 1); // state_init in ref
        try builder.storeRef(state_init_cell);
    } else {
        try builder.storeUint(0, 1); // state_init absent
    }

    try builder.storeUint(1, 1); // body in ref
    try builder.storeRef(body_cell);

    return builder.toCell(allocator);
}

pub fn buildExternalIncomingMessageBocAlloc(
    allocator: std.mem.Allocator,
    destination: []const u8,
    body_boc: []const u8,
    state_init_boc: ?[]const u8,
) ![]u8 {
    const body_cell = try boc.deserializeBoc(allocator, body_boc);
    errdefer body_cell.deinit(allocator);

    const ext_msg = try buildExternalIncomingMessageCellAlloc(
        allocator,
        destination,
        body_cell,
        state_init_boc,
    );
    defer ext_msg.deinit(allocator);

    return boc.serializeBoc(allocator, ext_msg);
}

fn deinitBuilderRefs(allocator: std.mem.Allocator, builder: *cell.Builder) void {
    for (builder.refs[0..builder.ref_cnt]) |ref| {
        if (ref) |value| value.deinit(allocator);
    }
}

test "external incoming message builder stores destination, body, and state init" {
    const allocator = std.testing.allocator;

    var body_builder = cell.Builder.init();
    try body_builder.storeUint(0xCAFE, 16);
    const body_cell = try body_builder.toCell(allocator);
    defer body_cell.deinit(allocator);
    const body_boc = try boc.serializeBoc(allocator, body_cell);
    defer allocator.free(body_boc);

    var code_builder = cell.Builder.init();
    try code_builder.storeUint(0xAA, 8);
    const code_cell = try code_builder.toCell(allocator);
    defer code_cell.deinit(allocator);
    const code_boc = try boc.serializeBoc(allocator, code_cell);
    defer allocator.free(code_boc);

    const state_init_boc = try @import("state_init.zig").buildStateInitBocAlloc(allocator, code_boc, null);
    defer allocator.free(state_init_boc);

    const built = try buildExternalIncomingMessageBocAlloc(
        allocator,
        "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
        body_boc,
        state_init_boc,
    );
    defer allocator.free(built);

    const ext_msg = try boc.deserializeBoc(allocator, built);
    defer ext_msg.deinit(allocator);

    var slice = ext_msg.toSlice();
    try std.testing.expectEqual(@as(u64, 0b10), try slice.loadUint(2));
    try std.testing.expectEqual(@as(u64, 0), try slice.loadUint(2));

    const dest = try slice.loadAddress();
    try std.testing.expectEqual(@as(i8, 0), dest.workchain);
    try std.testing.expectEqual(@as(u8, 0x83), dest.raw[0]);

    try std.testing.expectEqual(@as(u64, 0), try slice.loadCoins());
    try std.testing.expectEqual(@as(u64, 1), try slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 1), try slice.loadUint(1));

    const init_ref = try slice.loadRef();
    var init_slice = init_ref.toSlice();
    _ = try init_slice.loadUint(1);
    _ = try init_slice.loadUint(1);
    try std.testing.expectEqual(@as(u64, 1), try init_slice.loadUint(1));
    _ = try init_slice.loadUint(1);
    _ = try init_slice.loadUint(1);
    const stored_code_ref = try init_slice.loadRef();
    try std.testing.expectEqualSlices(u8, &code_cell.hash(), &stored_code_ref.hash());

    try std.testing.expectEqual(@as(u64, 1), try slice.loadUint(1));
    const body_ref = try slice.loadRef();
    var body_slice = body_ref.toSlice();
    try std.testing.expectEqual(@as(u64, 0xCAFE), try body_slice.loadUint(16));
}

test "external incoming message builder supports absent state init" {
    const allocator = std.testing.allocator;

    var body_builder = cell.Builder.init();
    try body_builder.storeUint(0x42, 8);
    const body_cell = try body_builder.toCell(allocator);
    defer body_cell.deinit(allocator);
    const body_boc = try boc.serializeBoc(allocator, body_cell);
    defer allocator.free(body_boc);

    const built = try buildExternalIncomingMessageBocAlloc(
        allocator,
        "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
        body_boc,
        null,
    );
    defer allocator.free(built);

    const ext_msg = try boc.deserializeBoc(allocator, built);
    defer ext_msg.deinit(allocator);

    var slice = ext_msg.toSlice();
    _ = try slice.loadUint(2);
    _ = try slice.loadUint(2);
    _ = try slice.loadAddress();
    _ = try slice.loadCoins();
    try std.testing.expectEqual(@as(u64, 0), try slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 1), try slice.loadUint(1));
    const body_ref = try slice.loadRef();
    var body_slice = body_ref.toSlice();
    try std.testing.expectEqual(@as(u64, 0x42), try body_slice.loadUint(8));
}
