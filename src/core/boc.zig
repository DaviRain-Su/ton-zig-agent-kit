//! BoC (Bag of Cells) serialization/deserialization.
//! This implementation supports ordinary cells, single or shared subgraphs,
//! optional index tables, and optional CRC32C trailers.

const std = @import("std");
const cell_mod = @import("cell.zig");

pub const Cell = cell_mod.Cell;
pub const Builder = cell_mod.Builder;

const boc_magic: u32 = 0xB5EE9C72;
const has_idx_mask: u8 = 0x80;
const has_crc32c_mask: u8 = 0x40;
const has_cache_bits_mask: u8 = 0x20;

pub fn serializeBoc(allocator: std.mem.Allocator, root: *Cell) ![]u8 {
    var ordered = std.array_list.Managed(*Cell).init(allocator);
    defer ordered.deinit();

    var indices = std.AutoHashMap(*Cell, usize).init(allocator);
    defer indices.deinit();

    try collectCells(root, &ordered, &indices);

    const size_bytes = bytesForValue(ordered.items.len);

    var total_cell_size: usize = 0;
    for (ordered.items) |cell| {
        total_cell_size += serializedCellSize(cell, size_bytes);
    }

    const off_bytes = bytesForValue(total_cell_size);

    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    try writer.writer.writeInt(u32, boc_magic, .big);
    try writer.writer.writeByte(size_bytes);
    try writer.writer.writeByte(off_bytes);

    try writeSizedUint(&writer.writer, ordered.items.len, size_bytes);
    try writeSizedUint(&writer.writer, 1, size_bytes);
    try writeSizedUint(&writer.writer, 0, size_bytes);
    try writeSizedUint(&writer.writer, total_cell_size, off_bytes);
    try writeSizedUint(&writer.writer, 0, size_bytes);

    for (ordered.items) |cell| {
        try serializeCell(&writer.writer, cell, &indices, size_bytes);
    }

    return try writer.toOwnedSlice();
}

fn collectCells(
    cell: *Cell,
    ordered: *std.array_list.Managed(*Cell),
    indices: *std.AutoHashMap(*Cell, usize),
) !void {
    if (indices.contains(cell)) return;

    try indices.put(cell, ordered.items.len);
    try ordered.append(cell);

    for (cell.refs[0..cell.ref_cnt]) |ref| {
        const child = ref orelse return error.InvalidBoc;
        try collectCells(child, ordered, indices);
    }
}

fn serializeCell(
    writer: anytype,
    cell: *Cell,
    indices: *const std.AutoHashMap(*Cell, usize),
    size_bytes: u8,
) !void {
    const ref_count = cell.ref_cnt;
    const data_byte_len: usize = @intCast(@divTrunc(cell.bit_len + 7, 8));
    const d1: u8 = ref_count;
    const d2: u8 = @intCast((cell.bit_len / 8) + data_byte_len);

    try writer.writeByte(d1);
    try writer.writeByte(d2);

    if (data_byte_len > 0) {
        var payload = [_]u8{0} ** cell_mod.MAX_BYTES;
        @memcpy(payload[0..data_byte_len], cell.data[0..data_byte_len]);

        if (cell.bit_len % 8 != 0) {
            const last_index = data_byte_len - 1;
            const used_bits_last: u3 = @intCast(cell.bit_len % 8);
            const keep_shift: u3 = @intCast(8 - @as(u4, used_bits_last));
            const topup_shift: u3 = @intCast(7 - used_bits_last);
            const keep_mask: u8 = @as(u8, 0xFF) << keep_shift;
            payload[last_index] &= keep_mask;
            payload[last_index] |= @as(u8, 1) << topup_shift;
        }

        try writer.writeAll(payload[0..data_byte_len]);
    }

    for (cell.refs[0..cell.ref_cnt]) |ref| {
        const child = ref orelse return error.InvalidBoc;
        const index = indices.get(child) orelse return error.InvalidBoc;
        try writeSizedUint(writer, index, size_bytes);
    }
}

fn serializedCellSize(cell: *const Cell, ref_index_bytes: u8) usize {
    const data_byte_len: usize = @intCast(@divTrunc(cell.bit_len + 7, 8));
    return 2 + data_byte_len + (@as(usize, ref_index_bytes) * cell.ref_cnt);
}

fn bytesForValue(value: usize) u8 {
    var bytes: u8 = 1;
    var limit: usize = 0x100;
    while (value >= limit and bytes < 8) : (bytes += 1) {
        limit <<= 8;
    }
    return bytes;
}

fn writeSizedUint(writer: anytype, value: usize, size_bytes: u8) !void {
    var buf = [_]u8{0} ** 8;
    var tmp = value;
    var i: usize = size_bytes;
    while (i > 0) {
        i -= 1;
        buf[i] = @intCast(tmp & 0xFF);
        tmp >>= 8;
    }
    try writer.writeAll(buf[0..size_bytes]);
}

fn readSizedUint(reader: anytype, size_bytes: u8) !usize {
    var value: usize = 0;
    var i: u8 = 0;
    while (i < size_bytes) : (i += 1) {
        value = (value << 8) | try reader.readByte();
    }
    return value;
}

pub fn deserializeBoc(allocator: std.mem.Allocator, data: []const u8) !*Cell {
    if (data.len < 8) return error.InvalidBoc;

    if (std.mem.readInt(u32, data[0..4], .big) != boc_magic) {
        return error.InvalidBoc;
    }

    const header = data[4];
    const has_idx = (header & has_idx_mask) != 0;
    const has_crc32c = (header & has_crc32c_mask) != 0;
    if ((header & has_cache_bits_mask) != 0) return error.InvalidBoc;

    const size_bytes = header & 0x07;
    if (size_bytes == 0) return error.InvalidBoc;

    var stream = std.io.fixedBufferStream(data[5..]);
    const reader = stream.reader();

    const off_bytes = try reader.readByte();
    const cells_count = try readSizedUint(reader, size_bytes);
    const roots_count = try readSizedUint(reader, size_bytes);
    _ = try readSizedUint(reader, size_bytes); // absent
    const total_cell_size = try readSizedUint(reader, off_bytes);

    if (roots_count == 0 or cells_count == 0) return error.InvalidBoc;

    const root_indices = try allocator.alloc(usize, roots_count);
    defer allocator.free(root_indices);
    for (root_indices) |*index| {
        index.* = try readSizedUint(reader, size_bytes);
        if (index.* >= cells_count) return error.InvalidBoc;
    }

    if (has_idx) {
        var index_bytes_left: usize = cells_count * off_bytes;
        while (index_bytes_left > 0) : (index_bytes_left -= 1) {
            _ = try reader.readByte();
        }
    }

    const cell_data_offset = 5 + stream.pos;
    const crc_len: usize = if (has_crc32c) 4 else 0;
    if (cell_data_offset + total_cell_size + crc_len > data.len) return error.InvalidBoc;

    if (has_crc32c) {
        const payload = data[0 .. data.len - 4];
        const actual_crc = std.mem.readInt(u32, data[data.len - 4 ..][0..4], .little);
        var hasher = std.hash.crc.Crc32Iscsi.init();
        hasher.update(payload);
        if (hasher.final() != actual_crc) return error.InvalidBoc;
    }

    const cell_payload = data[cell_data_offset .. cell_data_offset + total_cell_size];
    var payload_stream = std.io.fixedBufferStream(cell_payload);
    const payload_reader = payload_stream.reader();

    const PendingCell = struct {
        cell: *Cell,
        ref_indices: []usize,
    };

    const pending = try allocator.alloc(PendingCell, cells_count);
    var initialized_pending: usize = 0;
    errdefer {
        for (pending[0..initialized_pending]) |entry| {
            if (entry.ref_indices.len > 0) allocator.free(entry.ref_indices);
        }
        allocator.free(pending);
    }

    for (pending) |*entry| {
        const d1 = try payload_reader.readByte();
        const d2 = try payload_reader.readByte();

        if ((d1 & 0xF8) != 0) return error.InvalidBoc;

        const ref_count: u3 = @intCast(d1 & 0x07);
        const data_byte_len = @as(usize, @intCast(@divTrunc(d2 + 1, 2)));
        const has_partial_byte = (d2 & 1) == 1;

        if (payload_stream.pos + data_byte_len + (@as(usize, size_bytes) * ref_count) > cell_payload.len) {
            return error.InvalidBoc;
        }

        const cell = try Cell.create(allocator);
        cell.ref_cnt = ref_count;

        if (data_byte_len > 0) {
            @memcpy(cell.data[0..data_byte_len], cell_payload[payload_stream.pos .. payload_stream.pos + data_byte_len]);
            payload_stream.pos += data_byte_len;

            if (has_partial_byte) {
                const last_index = data_byte_len - 1;
                const last_byte = cell.data[last_index];
                if (last_byte == 0) return error.InvalidBoc;

                const trailing_zeros = @ctz(last_byte);
                if (trailing_zeros > 7) return error.InvalidBoc;

                const used_bits_last: u3 = @intCast(7 - trailing_zeros);
                const keep_shift: u3 = @intCast(8 - @as(u4, used_bits_last));
                const keep_mask: u8 = @as(u8, 0xFF) << keep_shift;
                cell.data[last_index] &= keep_mask;
                cell.bit_len = @intCast((data_byte_len - 1) * 8 + used_bits_last);
            } else {
                cell.bit_len = @intCast(data_byte_len * 8);
            }
        } else {
            cell.bit_len = 0;
        }

        var ref_indices: []usize = &.{};
        if (ref_count > 0) {
            ref_indices = try allocator.alloc(usize, ref_count);
        }
        for (ref_indices) |*ref_index| {
            ref_index.* = try readSizedUint(payload_reader, size_bytes);
            if (ref_index.* >= cells_count) return error.InvalidBoc;
        }

        entry.* = .{
            .cell = cell,
            .ref_indices = ref_indices,
        };
        initialized_pending += 1;
    }

    for (pending) |entry| {
        for (entry.ref_indices, 0..) |ref_index, i| {
            entry.cell.refs[i] = pending[ref_index].cell;
        }
    }

    const root_cell = pending[root_indices[0]].cell;
    for (pending) |entry| {
        if (entry.ref_indices.len > 0) allocator.free(entry.ref_indices);
    }
    allocator.free(pending);

    return root_cell;
}

test "boc roundtrip ordinary cell" {
    var builder = Builder.init();
    try builder.storeUint(42, 8);
    try builder.storeUint(7, 3);

    const cell = try builder.toCell(std.testing.allocator);
    defer std.testing.allocator.destroy(cell);

    const encoded = try serializeBoc(std.testing.allocator, cell);
    defer std.testing.allocator.free(encoded);

    const decoded = try deserializeBoc(std.testing.allocator, encoded);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(cell.bit_len, decoded.bit_len);
    try std.testing.expectEqualSlices(u8, cell.data[0..2], decoded.data[0..2]);
}

test "boc deserialize crc32c single cell" {
    const bytes = try std.base64.standard.Decoder.calcSizeForSlice("te6cckEBAQEABgAACP/////btDe4");
    const decoded_b64 = try std.testing.allocator.alloc(u8, bytes);
    defer std.testing.allocator.free(decoded_b64);
    try std.base64.standard.Decoder.decode(decoded_b64, "te6cckEBAQEABgAACP/////btDe4");

    const cell = try deserializeBoc(std.testing.allocator, decoded_b64);
    defer cell.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 32), cell.bit_len);
    var slice = cell.toSlice();
    try std.testing.expectEqual(@as(u64, 0xFFFFFFFF), try slice.loadUint(32));
}
