const std = @import("std");
const boc = @import("boc.zig");
const cell = @import("cell.zig");

pub const BodyAnalysis = struct {
    opcode: ?u32 = null,
    comment: ?[]u8 = null,
    tail_utf8: ?[]u8 = null,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.comment) |value| allocator.free(value);
        if (self.tail_utf8) |value| allocator.free(value);
        self.* = .{};
    }

    pub fn empty(self: @This()) bool {
        return self.opcode == null and self.comment == null and self.tail_utf8 == null;
    }
};

pub fn inspectBodyBocAlloc(allocator: std.mem.Allocator, body_boc: []const u8) !BodyAnalysis {
    const root = try boc.deserializeBoc(allocator, body_boc);
    defer root.deinit(allocator);
    return inspectBodyCellAlloc(allocator, root);
}

pub fn inspectBodyCellAlloc(allocator: std.mem.Allocator, root: *const cell.Cell) !BodyAnalysis {
    var analysis = BodyAnalysis{};
    errdefer analysis.deinit(allocator);

    if (root.bit_len == 0 and root.ref_cnt == 0) return analysis;

    if (root.bit_len < 32) {
        analysis.tail_utf8 = try maybeFlattenUtf8CellAlloc(allocator, root);
        return analysis;
    }

    var slice = @constCast(root).toSlice();
    analysis.opcode = @intCast(try loadUintDynamic(&slice, 32));

    if (analysis.opcode.? == 0) {
        analysis.comment = try maybeFlattenUtf8TailAlloc(allocator, &slice);
        return analysis;
    }

    analysis.tail_utf8 = try maybeFlattenUtf8TailAlloc(allocator, &slice);
    return analysis;
}

fn maybeFlattenUtf8CellAlloc(allocator: std.mem.Allocator, root: *const cell.Cell) !?[]u8 {
    var slice = @constCast(root).toSlice();
    return maybeFlattenUtf8TailAlloc(allocator, &slice);
}

fn maybeFlattenUtf8TailAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) !?[]u8 {
    var tail = slice.*;
    const bytes = flattenSnakeTailBytesAlloc(allocator, &tail) catch return null;
    errdefer allocator.free(bytes);

    if (bytes.len == 0 or !std.unicode.utf8ValidateSlice(bytes)) {
        allocator.free(bytes);
        return null;
    }
    return bytes;
}

fn flattenSnakeTailBytesAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) ![]u8 {
    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    try appendSnakeSliceBytes(&writer.writer, slice);
    return try writer.toOwnedSlice();
}

fn appendSnakeSliceBytes(writer: anytype, slice: *cell.Slice) !void {
    if (slice.remainingBits() % 8 != 0) return error.InvalidSnakeData;
    if (slice.remainingRefs() > 1) return error.InvalidSnakeData;

    while (slice.remainingBits() > 0) {
        try writer.writeByte(try slice.loadUint8());
    }

    if (slice.remainingRefs() == 1) {
        const next = try slice.loadRef();
        if (next.bit_len % 8 != 0 or next.ref_cnt > 1) return error.InvalidSnakeData;
        var next_slice = next.toSlice();
        try appendSnakeSliceBytes(writer, &next_slice);
    }
}

fn loadUintDynamic(slice: *cell.Slice, bits: u16) !u64 {
    if (bits > 64) return error.UnsupportedAbiType;
    if (slice.remainingBits() < bits) return error.NotEnoughData;
    if (bits == 0) return 0;

    var result: u64 = 0;
    var idx: u16 = 0;
    while (idx < bits) : (idx += 1) {
        result = (result << 1) | try slice.loadUint(1);
    }
    return result;
}

test "body inspector extracts opcode and utf8 tail" {
    const allocator = std.testing.allocator;

    var builder = cell.Builder.init();
    try builder.storeUint(0x11223344, 32);
    try builder.storeBits("ping", 32);
    const body = try builder.toCell(allocator);
    defer body.deinit(allocator);

    var analysis = try inspectBodyCellAlloc(allocator, body);
    defer analysis.deinit(allocator);

    try std.testing.expectEqual(@as(?u32, 0x11223344), analysis.opcode);
    try std.testing.expectEqualStrings("ping", analysis.tail_utf8.?);
    try std.testing.expect(analysis.comment == null);
}

test "body inspector extracts snake comment after zero opcode" {
    const allocator = std.testing.allocator;

    var tail_builder = cell.Builder.init();
    try tail_builder.storeBits("lo", 16);
    const tail = try tail_builder.toCell(allocator);

    var root_builder = cell.Builder.init();
    try root_builder.storeUint(0, 32);
    try root_builder.storeBits("hel", 24);
    try root_builder.storeRef(tail);
    const body = try root_builder.toCell(allocator);
    defer body.deinit(allocator);

    var analysis = try inspectBodyCellAlloc(allocator, body);
    defer analysis.deinit(allocator);

    try std.testing.expectEqual(@as(?u32, 0), analysis.opcode);
    try std.testing.expectEqualStrings("hello", analysis.comment.?);
    try std.testing.expect(analysis.tail_utf8 == null);
}
