//! BoC (Bag of Cells) serialization/deserialization
//! Format spec: https://docs.ton.org/develop/data-formats/boc

const std = @import("std");
const cell_mod = @import("cell.zig");

pub const Cell = cell_mod.Cell;
pub const Builder = cell_mod.Builder;

pub fn serializeBoc(allocator: std.mem.Allocator, root: *Cell) ![]u8 {
    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    const magic: u32 = 0xB5EE9C72;
    try writer.writer.writeInt(u32, magic, .big);

    const size_bytes: u8 = 4;
    const off_bytes: u8 = 4;

    const flags_byte: u8 = 1 << 7;
    try writer.writer.writeByte(flags_byte);
    try writer.writer.writeByte(size_bytes);

    var count: u32 = 0;
    countCells(root, &count);
    try writer.writer.writeInt(u32, count, .big);
    try writer.writer.writeInt(u32, 0, .big);
    try writer.writer.writeInt(u32, 0, .big);

    const total_size = calcCellSize(root, size_bytes);
    try writer.writer.writeInt(u32, total_size, .big);
    try writer.writer.writeByte(off_bytes);
    try writer.writer.writeInt(u32, 0, .big);

    try serializeCellData(&writer.writer, root);

    try writer.writer.writeInt(u32, 0, .big);

    return try writer.toOwnedSlice();
}

fn countCells(cell: *Cell, count: *u32) void {
    count.* += 1;
    for (cell.refs[0..cell.ref_cnt]) |ref| {
        if (ref) |r| countCells(r, count);
    }
}

fn calcCellSize(cell: *Cell, size_bytes: u8) u32 {
    var total: u32 = 0;
    total += 2 + @as(u32, @divTrunc(cell.bit_len + 7, 8));
    total += size_bytes * cell.ref_cnt;
    for (cell.refs[0..cell.ref_cnt]) |ref| {
        if (ref) |r| total += calcCellSize(r, size_bytes);
    }
    return total;
}

fn serializeCellData(writer: anytype, cell: *Cell) !void {
    const data_len = @divTrunc(cell.bit_len + 7, 8);
    try writer.writeByte(cell.ref_cnt);
    try writer.writeByte(@as(u8, @intCast(data_len)));
    try writer.writeAll(cell.data[0..data_len]);
}

pub fn deserializeBoc(allocator: std.mem.Allocator, data: []const u8) !*Cell {
    _ = allocator;
    if (data.len < 4) return error.InvalidBoc;

    var reader = std.io.fixedBufferStream(data);
    const r = reader.reader();

    const magic = try r.readInt(u32, .big);
    if (magic != 0xB5EE9C72) return error.InvalidBoc;

    _ = try r.readByte();

    _ = try r.readByte();

    const cells_count = try r.readInt(u32, .big);
    _ = cells_count;
    const roots_count = try r.readInt(u32, .big);
    _ = roots_count;
    const absent_count = try r.readInt(u32, .big);
    _ = absent_count;
    const tot_cells_size = try r.readInt(u32, .big);

    _ = try r.readByte();
    _ = try r.readInt(u32, .big);

    const cell_data = try reader.readAlloc(std.heap.page_allocator, tot_cells_size);
    defer std.heap.page_allocator.free(cell_data);

    if (cell_data.len < 2) return error.InvalidBoc;

    const cell_ref_cnt = cell_data[0];
    const cell_data_len = cell_data[1];

    const cell = try Cell.create(std.heap.page_allocator);
    cell.ref_cnt = @intCast(cell_ref_cnt);
    cell.bit_len = @intCast(cell_data_len * 8);

    if (cell_data_len > 0 and cell_data_len <= cell_mod.MAX_BYTES) {
        @memcpy(cell.data[0..cell_data_len], cell_data[2 .. 2 + cell_data_len]);
    }

    return cell;
}

test "boc serialization" {
    var builder = Builder.init();
    try builder.storeUint(42, 8);

    const cell = try builder.toCell(std.testing.allocator);
    defer std.testing.allocator.destroy(cell);

    const boc = try serializeBoc(std.testing.allocator, cell);
    defer std.testing.allocator.free(boc);

    try std.testing.expect(boc.len > 0);
    try std.testing.expectEqual(@as(u32, 0xB5EE9C72), std.mem.readInt(u32, boc[0..4], .big));
}
