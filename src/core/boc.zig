//! BoC (Bag of Cells) serialization/deserialization

const std = @import("std");
const types = @import("types.zig");
const cell = @import("cell.zig");

pub fn serializeBoc(allocator: std.mem.Allocator, root: *cell.Cell) ![]u8 {
    _ = allocator;
    _ = root;
    return &.{};
}

pub fn deserializeBoc(allocator: std.mem.Allocator, data: []const u8) !*cell.Cell {
    _ = allocator;
    _ = data;
    return error.InvalidBoc;
}

test "boc serialization" {
    _ = serializeBoc;
    _ = deserializeBoc;
}
