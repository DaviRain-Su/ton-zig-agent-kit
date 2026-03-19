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
            .data = undefined,
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
            .data = undefined,
            .bit_len = 0,
            .refs = .{ null, null, null, null },
            .ref_cnt = 0,
        };
    }

    pub fn initStack() Builder {
        return .{};
    }

    pub fn storeUint(self: *Builder, value: u64, comptime bits: u16) !void {
        if (self.bit_len + bits > MAX_BITS) return error.CellOverflow;
        if (bits == 0) return;

        // Write value as big-endian bits
        var i: u16 = bits;
        while (i > 0) {
            i -= 1;
            const bit_val = @as(u1, @intCast((value >> @intCast(i)) & 1));
            const byte_idx = self.bit_len / 8;
            const bit_idx = 7 - @as(u3, @intCast(self.bit_len % 8));
            self.data[byte_idx] |= @as(u8, bit_val) << bit_idx;
            self.bit_len += 1;
        }
    }

    pub fn storeBits(self: *Builder, data: []const u8, len: u16) !void {
        if (self.bit_len + len > MAX_BITS) return error.CellOverflow;
        if (len == 0) return;

        const full_bytes = len / 8;
        const remaining_bits = len % 8;

        var pos = self.bit_len;
        for (data[0..full_bytes]) |byte| {
            self.data[pos / 8] = byte;
            pos += 8;
        }

        if (remaining_bits > 0) {
            const byte_idx = pos / 8;
            const mask = @as(u8, 0xFF) >> @intCast(remaining_bits);
            self.data[byte_idx] = (self.data[byte_idx] & mask) | (data[full_bytes] & ~mask);
            pos += remaining_bits;
        }

        self.bit_len = pos;
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

    pub fn storeAddress(self: *Builder, addr: anytype) !void {
        const T = @TypeOf(addr);
        if (T == []const u8) {
            const parsed = @import("address.zig").parseAddress(addr) catch return error.InvalidAddress;
            try self.storeInt8(parsed.workchain);
            try self.storeBits(&parsed.raw, 256);
        } else {
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
        const remaining_bits = s.remainingBits();
        if (remaining_bits > 0) {
            try self.storeBits(s.cell.data[s.pos_bits / 8 ..], remaining_bits);
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
        const result = self.cell.data[self.pos_bits / 8 .. self.pos_bits / 8 + @as(usize, @divTrunc(len + 7, 8))];
        self.pos_bits += len;
        return result;
    }
};

test "builder store uint" {
    var builder = Builder.init();
    try builder.storeUint(42, 8);
    try std.testing.expectEqual(@as(u16, 8), builder.bit_len);
    try std.testing.expectEqual(@as(u8, 42), builder.data[0]);
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

test "cell hash" {
    var builder = Builder.init();
    try builder.storeUint(42, 8);

    var cell = try builder.toCell(std.testing.allocator);
    defer std.testing.allocator.destroy(cell);

    const h = cell.hash();
    try std.testing.expectEqual(@as(usize, 32), h.len);
}
