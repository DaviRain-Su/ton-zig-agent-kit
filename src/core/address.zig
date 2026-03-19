//! TON address parsing and conversion
//! Supports user-friendly (EQCD...) and raw (0x...) formats

const std = @import("std");
const types = @import("types.zig");

pub const BASE64_URL_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

pub fn decodeBase64Url(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output = try allocator.alloc(u8, (input.len * 3) / 4);
    var out_idx: usize = 0;
    var i: usize = 0;

    while (i < input.len) : (i += 4) {
        var chunk: u32 = 0;
        var chunk_bits: u8 = 0;

        for (input[i..@min(i + 4, input.len)]) |c| {
            if (c == '=') continue;
            const val = try charToValue(c);
            chunk = (chunk << 6) | val;
            chunk_bits += 6;
        }

        while (chunk_bits >= 8) {
            chunk_bits -= 8;
            output[out_idx] = @truncate(chunk >> @intCast(chunk_bits));
            out_idx += 1;
        }
    }

    return output[0..out_idx];
}

fn charToValue(c: u8) !u8 {
    for (BASE64_URL_ALPHABET, 0..) |char, val| {
        if (c == char) return @as(u8, @intCast(val));
    }
    return error.InvalidBase64;
}

pub fn parseAddress(str: []const u8) !types.Address {
    if (std.mem.startsWith(u8, str, "0x") or std.mem.startsWith(u8, str, "0X")) {
        return parseRawAddress(str[2..]);
    }
    if (std.mem.startsWith(u8, str, "EQ") or std.mem.startsWith(u8, str, "eq") or
        std.mem.startsWith(u8, str, "UQ") or std.mem.startsWith(u8, str, "uq") or
        std.mem.startsWith(u8, str, "-1:"))
    {
        return try parseUserFriendlyAddress(str);
    }
    return types.TonError.InvalidAddress;
}

fn parseRawAddress(str: []const u8) !types.Address {
    if (str.len != 64) return types.TonError.InvalidAddress;
    var addr: types.Address = undefined;
    _ = try hexToBytes(str, &addr.raw);
    addr.workchain = @bitCast(addr.raw[0]);
    return addr;
}

fn parseUserFriendlyAddress(str: []const u8) !types.Address {
    const workchain: i8 = if (std.mem.startsWith(u8, str, "-1:")) -1 else 0;
    const data_start: usize = if (workchain == -1) 3 else 2;

    if (str.len < data_start + 36) return types.TonError.InvalidAddress;

    const data = try decodeBase64Url(std.heap.page_allocator, str[data_start..]);
    defer std.heap.page_allocator.free(data);

    if (data.len < 34) return types.TonError.InvalidAddress;

    var addr: types.Address = undefined;
    @memcpy(&addr.raw, data[2..34]);
    addr.workchain = workchain;

    return addr;
}

fn hexToBytes(hex: []const u8, out: []u8) !usize {
    if (hex.len % 2 != 0) return error.InvalidHex;
    const out_len = hex.len / 2;
    if (out_len > out.len) return error.BufferTooSmall;

    var i: usize = 0;
    while (i < out_len) : (i += 1) {
        const hi = try hexCharValue(hex[i * 2]);
        const lo = try hexCharValue(hex[i * 2 + 1]);
        out[i] = (hi << 4) | lo;
    }
    return out_len;
}

fn hexCharValue(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
}

pub fn addressToUserFriendly(addr: *const types.Address, testnet: bool) []u8 {
    _ = addr;
    _ = testnet;
    return "";
}

test "address parsing raw" {
    const addr = try parseAddress("0x0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF");
    try std.testing.expect(addr.workchain == 0x01);
}

test "address parsing user-friendly" {
    const addr = try parseAddress("EQCD39vd5kB8FW5w6KH7HpNmP8GCvGajvLKGPMgY4sUXJyxqH");
    _ = addr;
}

test "hex to bytes" {
    var buf: [32]u8 = undefined;
    const len = try hexToBytes("DEADBEEF", &buf);
    try std.testing.expect(len == 4);
    try std.testing.expect(buf[0] == 0xDE);
    try std.testing.expect(buf[1] == 0xAD);
    try std.testing.expect(buf[2] == 0xBE);
    try std.testing.expect(buf[3] == 0xEF);
}
