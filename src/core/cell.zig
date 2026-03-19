//! Cell, Builder, Slice - TON's fundamental data types
//! Each Cell can hold up to 1023 bits and up to 4 references
//! Builder creates Cells, Slice reads from Cells

const std = @import("std");

pub const MAX_BITS = 1023;
pub const MAX_REFS = 4;
pub const MAX_BYTES = 128;

pub const Cell = struct {
    data: [MAX_BYTES]u8,
    bit_len: u16,
    refs: [MAX_REFS]?*Cell,
    ref_cnt: u2,

    pub fn create(allocator: std.mem.Allocator) !*Cell {
        const cell = try allocator.create(Cell);
        cell.* = Cell{
            .data = [_]u8{0} ** MAX_BYTES,
            .bit_len = 0,
            .refs = .{ null, null, null, null },
            .ref_cnt = 0,
        };
        return cell;
    }

    pub fn deinit(self: *Cell, allocator: std.mem.Allocator) void {
        for (self.refs[0..self.ref_cnt]) |ref| {
            if (ref) |r| r.deinit(allocator);
        }
        allocator.destroy(self);
    }

    pub fn toSlice(self: *Cell) Slice {
        return Slice{
            .cell = self,
            .pos_bits = 0,
            .pos_refs = 0,
        };
    }

    pub fn hash(self: *const Cell) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(self.data[0..@as(usize, @divTrunc(self.bit_len + 7, 8))]);
        return hasher.finalResult();
    }
};

pub const Builder = struct {
    data: [MAX_BYTES]u8,
    bit_len: u16,
    refs: [MAX_REFS]?*Cell,
    ref_cnt: u2,

    pub fn init() Builder {
        return Builder{
            .data = [_]u8{0} ** MAX_BYTES,
            .bit_len = 0,
            .refs = .{ null, null, null, null },
            .ref_cnt = 0,
        };
    }

    pub fn initStack() Builder {
        return init();
    }

    fn storeBit(self: *Builder, bit_val: u1) !void {
        if (self.bit_len >= MAX_BITS) return error.CellOverflow;

        const byte_idx = self.bit_len / 8;
        const bit_idx = 7 - @as(u3, @intCast(self.bit_len % 8));
        const mask = @as(u8, 1) << bit_idx;
        self.data[byte_idx] &= ~mask;
        self.data[byte_idx] |= @as(u8, bit_val) << bit_idx;
        self.bit_len += 1;
    }

    pub fn storeUint(self: *Builder, value: u64, bits: u16) !void {
        if (self.bit_len + bits > MAX_BITS) return error.CellOverflow;
        if (bits == 0) return;

        // Write value as big-endian bits
        var i: u16 = bits;
        while (i > 0) {
            i -= 1;
            const bit_val = @as(u1, @intCast((value >> @intCast(i)) & 1));
            try self.storeBit(bit_val);
        }
    }

    pub fn storeUintBytes(self: *Builder, bytes: []const u8, bits: u16) !void {
        if (self.bit_len + bits > MAX_BITS) return error.CellOverflow;
        if (bits == 0) return;

        const significant_bits = countSignificantBits(bytes);
        if (significant_bits == 0) {
            try self.storeUint(0, bits);
            return;
        }
        if (significant_bits > bits) return error.IntegerOverflow;

        try self.storeUint(0, bits - significant_bits);

        const start_bit = firstSetBit(bytes).?;
        const total_bits: u16 = @intCast(bytes.len * 8);
        var bit_index = start_bit;
        while (bit_index < total_bits) : (bit_index += 1) {
            const src_byte = bytes[bit_index / 8];
            const src_bit_idx = 7 - @as(u3, @intCast(bit_index % 8));
            const bit_val = @as(u1, @intCast((src_byte >> src_bit_idx) & 1));
            try self.storeBit(bit_val);
        }
    }

    pub fn storeBits(self: *Builder, data: []const u8, len: u16) !void {
        if (self.bit_len + len > MAX_BITS) return error.CellOverflow;
        if (len == 0) return;

        var bit_index: u16 = 0;
        while (bit_index < len) : (bit_index += 1) {
            const src_byte = data[bit_index / 8];
            const src_bit_idx = 7 - @as(u3, @intCast(bit_index % 8));
            const bit_val = @as(u1, @intCast((src_byte >> src_bit_idx) & 1));
            try self.storeBit(bit_val);
        }
    }

    pub fn storeUint8(self: *Builder, value: u8) !void {
        try self.storeUint(@intCast(value), 8);
    }

    pub fn storeUint16(self: *Builder, value: u16) !void {
        try self.storeUint(@intCast(value), 16);
    }

    pub fn storeUint32(self: *Builder, value: u32) !void {
        try self.storeUint(@intCast(value), 32);
    }

    pub fn storeInt8(self: *Builder, value: i8) !void {
        try self.storeInt(@intCast(value), 8);
    }

    pub fn storeInt32(self: *Builder, value: i32) !void {
        try self.storeInt(@intCast(value), 32);
    }

    pub fn storeInt(self: *Builder, value: i64, bits: u16) !void {
        if (value >= 0) {
            try self.storeUint(@intCast(value), bits);
        } else {
            const mask = (@as(u64, 1) << @intCast(bits)) - 1;
            try self.storeUint(@intCast(@as(u64, @bitCast(value)) & mask), bits);
        }
    }

    pub fn storeCoins(self: *Builder, coins: u64) !void {
        if (coins == 0) {
            try self.storeUint(0, 4);
            return;
        }

        var len: u4 = 0;
        var temp = coins;
        while (temp > 0) : (temp >>= 8) {
            len += 1;
        }

        try self.storeUint(@intCast(len), 4);
        var i: i32 = len - 1;
        while (i >= 0) : (i -= 1) {
            try self.storeUint8(@intCast((coins >> @intCast(@as(u6, @intCast(i)) * 8)) & 0xFF));
        }
    }

    pub fn storeCoinsBytes(self: *Builder, bytes: []const u8) !void {
        const trimmed = trimLeadingZeroBytes(bytes);
        if (trimmed.len == 0) {
            try self.storeUint(0, 4);
            return;
        }
        if (trimmed.len > 15) return error.IntegerOverflow;

        try self.storeUint(@intCast(trimmed.len), 4);
        try self.storeBits(trimmed, @intCast(trimmed.len * 8));
    }

    pub fn storeAddress(self: *Builder, addr: anytype) !void {
        const T = @TypeOf(addr);
        if (T == []const u8) {
            const parsed = @import("address.zig").parseAddress(addr) catch return error.InvalidAddress;
            try self.storeUint(0b10, 2); // addr_std
            try self.storeUint(0, 1); // anycast absent
            try self.storeInt8(parsed.workchain);
            try self.storeBits(&parsed.raw, 256);
        } else {
            try self.storeUint(0b10, 2); // addr_std
            try self.storeUint(0, 1); // anycast absent
            try self.storeInt8(addr.workchain);
            try self.storeBits(&addr.raw, 256);
        }
    }

    pub fn storeRef(self: *Builder, child: *Cell) !void {
        if (self.ref_cnt >= MAX_REFS) return error.TooManyRefs;
        self.refs[self.ref_cnt] = child;
        self.ref_cnt += 1;
    }

    pub fn storeSlice(self: *Builder, s: *Slice) !void {
        var src = s.*;

        while (src.remainingBits() > 0) {
            const bit = try src.loadUint(1);
            try self.storeBit(@intCast(bit));
        }

        while (src.remainingRefs() > 0) {
            const child = try src.loadRef();
            try self.storeRef(child);
        }
    }

    pub fn toCell(self: *Builder, allocator: std.mem.Allocator) !*Cell {
        const cell = try Cell.create(allocator);
        cell.bit_len = self.bit_len;
        cell.ref_cnt = self.ref_cnt;
        @memcpy(&cell.data, &self.data);
        for (self.refs[0..self.ref_cnt], 0..) |ref, i| {
            cell.refs[i] = ref;
        }
        return cell;
    }

    pub fn remainingBits(self: *Builder) u16 {
        return MAX_BITS - self.bit_len;
    }
};

pub const Slice = struct {
    cell: *Cell,
    pos_bits: u16,
    pos_refs: u2,

    pub fn remainingBits(self: *const Slice) u16 {
        return self.cell.bit_len - self.pos_bits;
    }

    pub fn remainingRefs(self: *const Slice) u2 {
        return self.cell.ref_cnt - self.pos_refs;
    }

    pub fn empty(self: *const Slice) bool {
        return self.remainingBits() == 0 and self.remainingRefs() == 0;
    }

    pub fn loadUint(self: *Slice, comptime bits: u16) !u64 {
        if (self.remainingBits() < bits) return error.NotEnoughData;
        if (bits == 0) return 0;

        var result: u64 = 0;
        var i: u16 = 0;
        while (i < bits) : (i += 1) {
            const byte_idx = self.pos_bits / 8;
            const bit_idx = 7 - @as(u3, @intCast(self.pos_bits % 8));
            const bit_val = @as(u1, @intCast((self.cell.data[byte_idx] >> bit_idx) & 1));
            result = (result << 1) | bit_val;
            self.pos_bits += 1;
        }

        return result;
    }

    pub fn loadUint8(self: *Slice) !u8 {
        return @intCast(try self.loadUint(8));
    }

    pub fn loadUint16(self: *Slice) !u16 {
        return @intCast(try self.loadUint(16));
    }

    pub fn loadUint32(self: *Slice) !u32 {
        return @intCast(try self.loadUint(32));
    }

    pub fn loadInt8(self: *Slice) !i8 {
        return @bitCast(try self.loadUint8());
    }

    pub fn loadInt32(self: *Slice) !i32 {
        return @bitCast(try self.loadUint32());
    }

    pub fn loadInt(self: *Slice, comptime bits: u16) !i64 {
        const val = try self.loadUint(bits);
        const sign_bit = @as(u64, 1) << @intCast(bits - 1);
        if (val & sign_bit != 0) {
            return @bitCast(val | (@as(u64, 0xFFFFFFFFFFFFFFFF) << @intCast(bits)));
        }
        return @bitCast(val);
    }

    pub fn loadCoins(self: *Slice) !u64 {
        const len = try self.loadUint(4);
        if (len == 0) return 0;
        if (self.remainingBits() < len * 8) return error.NotEnoughData;

        var result: u64 = 0;
        var i: u64 = 0;
        while (i < len) : (i += 1) {
            result = (result << 8) | try self.loadUint8();
        }
        return result;
    }

    pub fn loadAddress(self: *Slice) !@import("types.zig").Address {
        const tag = try self.loadUint(2);
        if (tag != 0b10) return error.InvalidAddress;

        const has_anycast = try self.loadUint(1);
        if (has_anycast != 0) return error.UnsupportedAddress;

        const workchain = try self.loadInt8();
        var raw: [32]u8 = undefined;
        for (&raw) |*b| {
            b.* = try self.loadUint8();
        }
        return @import("types.zig").Address{
            .raw = raw,
            .workchain = workchain,
        };
    }

    pub fn loadRef(self: *Slice) !*Cell {
        if (self.pos_refs >= self.cell.ref_cnt) return error.NotEnoughRefs;
        const ref = self.cell.refs[self.pos_refs] orelse return error.NullRef;
        self.pos_refs += 1;
        return ref;
    }

    pub fn loadBits(self: *Slice, len: u16) ![]const u8 {
        if (self.remainingBits() < len) return error.NotEnoughData;
        if (len == 0) return &.{};
        if (self.pos_bits % 8 != 0 or len % 8 != 0) return error.UnalignedRead;

        const start = self.pos_bits / 8;
        const byte_len = len / 8;
        const result = self.cell.data[start .. start + byte_len];
        self.pos_bits += len;
        return result;
    }
};

fn trimLeadingZeroBytes(bytes: []const u8) []const u8 {
    var start: usize = 0;
    while (start < bytes.len and bytes[start] == 0) : (start += 1) {}
    return bytes[start..];
}

fn firstSetBit(bytes: []const u8) ?u16 {
    for (bytes, 0..) |byte, byte_idx| {
        if (byte == 0) continue;

        var bit_idx: u16 = 0;
        while (bit_idx < 8) : (bit_idx += 1) {
            if (((byte >> @as(u3, @intCast(7 - bit_idx))) & 1) != 0) {
                return @intCast(byte_idx * 8 + bit_idx);
            }
        }
    }
    return null;
}

fn countSignificantBits(bytes: []const u8) u16 {
    const first = firstSetBit(bytes) orelse return 0;
    return @intCast(bytes.len * 8 - first);
}

test "builder store uint" {
    var builder = Builder.init();
    try builder.storeUint(42, 8);
    try std.testing.expectEqual(@as(u16, 8), builder.bit_len);
    try std.testing.expectEqual(@as(u8, 42), builder.data[0]);
}

test "builder starts zeroed" {
    var builder = Builder.init();
    try builder.storeUint(0, 8);
    try std.testing.expectEqual(@as(u8, 0), builder.data[0]);
}

test "builder store coins zero" {
    var builder = Builder.init();
    try builder.storeCoins(0);
    try std.testing.expectEqual(@as(u16, 4), builder.bit_len);
}

test "builder store coins" {
    var builder = Builder.init();
    try builder.storeCoins(1000000000);
    try std.testing.expectEqual(@as(u16, 4 + 4 * 8), builder.bit_len);
}

test "builder store uint bytes" {
    var builder = Builder.init();
    try builder.storeUintBytes(&.{ 0x01, 0x23, 0x45, 0x67 }, 32);

    var cell = try builder.toCell(std.testing.allocator);
    defer std.testing.allocator.destroy(cell);

    var slice = cell.toSlice();
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x23, 0x45, 0x67 }, try slice.loadBits(32));
}

test "builder store coins bytes" {
    var builder = Builder.init();
    try builder.storeCoinsBytes(&.{ 0x01, 0x23, 0x45, 0x67, 0x89 });

    var cell = try builder.toCell(std.testing.allocator);
    defer std.testing.allocator.destroy(cell);

    var slice = cell.toSlice();
    try std.testing.expectEqual(@as(u64, 5), try slice.loadUint(4));
    for ([_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89 }) |byte| {
        try std.testing.expectEqual(byte, try slice.loadUint8());
    }
}

test "slice load uint" {
    var builder = Builder.init();
    try builder.storeUint(255, 8);
    try builder.storeUint(1000, 16);

    var cell = try builder.toCell(std.testing.allocator);
    defer std.testing.allocator.destroy(cell);

    var slice = cell.toSlice();
    try std.testing.expectEqual(@as(u64, 255), try slice.loadUint(8));
    try std.testing.expectEqual(@as(u64, 1000), try slice.loadUint(16));
}

test "builder store and load int" {
    var builder = Builder.init();
    try builder.storeInt(-1, 8);

    var cell = try builder.toCell(std.testing.allocator);
    defer std.testing.allocator.destroy(cell);

    var slice = cell.toSlice();
    try std.testing.expectEqual(@as(i64, -1), try slice.loadInt(8));
}

test "store bits preserves unaligned writes" {
    var builder = Builder.init();
    try builder.storeUint(0b101, 3);
    try builder.storeBits(&[_]u8{0b11000000}, 2);

    var cell = try builder.toCell(std.testing.allocator);
    defer std.testing.allocator.destroy(cell);

    var slice = cell.toSlice();
    try std.testing.expectEqual(@as(u64, 0b10111), try slice.loadUint(5));
}

test "store and load addr_std address" {
    const addr = @import("types.zig").Address{
        .workchain = 0,
        .raw = [_]u8{0xAB} ** 32,
    };

    var builder = Builder.init();
    try builder.storeAddress(addr);

    var cell = try builder.toCell(std.testing.allocator);
    defer std.testing.allocator.destroy(cell);

    var slice = cell.toSlice();
    const decoded = try slice.loadAddress();
    try std.testing.expectEqualDeep(addr, decoded);
}

test "cell hash" {
    var builder = Builder.init();
    try builder.storeUint(42, 8);

    var cell = try builder.toCell(std.testing.allocator);
    defer std.testing.allocator.destroy(cell);

    const h = cell.hash();
    try std.testing.expectEqual(@as(usize, 32), h.len);
}
