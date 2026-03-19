//! Cell, Builder, Slice - TON's fundamental data types
//! Each Cell can hold up to 1023 bits and up to 4 references

const std = @import("std");
const types = @import("types.zig");

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

    pub fn toSlice(self: *Cell) types.Slice {
        return types.Slice{
            .cell = self,
            .pos_bits = 0,
            .pos_refs = 0,
        };
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

    pub fn storeUint(self: *Builder, value: u64, bits: u16) !void {
        if (self.bit_len + bits > MAX_BITS) return error.CellOverflow;
        std.mem.writeIntLittle(u64, self.data[self.bit_len / 8 ..], value, @intCast(bits / 8 + 1));
        self.bit_len += bits;
    }

    pub fn storeCoins(self: *Builder, coins: u64) !void {
        try self.storeUint(coins, 64);
    }

    pub fn storeBits(self: *Builder, bits: []const u8, len: u16) !void {
        if (self.bit_len + len > MAX_BITS) return error.CellOverflow;
        for (bits[0..@divTrunc(len, 8)], 0..) |byte, i| {
            self.data[@divTrunc(self.bit_len, 8) + i] = byte;
        }
        self.bit_len += len;
    }

    pub fn storeRef(self: *Builder, child: *Cell) !void {
        if (self.ref_cnt >= MAX_REFS) return error.TooManyRefs;
        self.refs[self.ref_cnt] = child;
        self.ref_cnt += 1;
    }

    pub fn toCell(self: *Builder, allocator: std.mem.Allocator) !*Cell {
        const cell = try Cell.create(allocator);
        cell.bit_len = self.bit_len;
        cell.ref_cnt = self.ref_cnt;
        @memcpy(cell.data[0..self.bit_len], self.data[0..self.bit_len]);
        for (self.refs[0..self.ref_cnt], 0..) |ref, i| {
            cell.refs[i] = ref;
        }
        return cell;
    }
};

pub fn loadUint(slice: *types.Slice, comptime bits: u16) u64 {
    const byte_pos = slice.pos_bits / 8;
    slice.pos_bits += bits;
    return std.mem.readIntLittle(u64, slice.cell.data[byte_pos .. byte_pos + 8]);
}

pub fn loadCoins(slice: *types.Slice) u64 {
    return loadUint(slice, 64);
}

test "cell builder basic" {
    var builder = Builder.init();
    try builder.storeUint(42, 8);
    try std.testing.expect(builder.bit_len == 8);
}
