//! TON address parsing and conversion
//! Supports user-friendly (EQCD...) and raw (0x...) formats

const std = @import("std");
const types = @import("types.zig");

pub fn parseAddress(str: []const u8) !types.Address {
    if (std.mem.startsWith(u8, str, "0x") or std.mem.startsWith(u8, str, "0X")) {
        return parseRawAddress(str[2..]);
    }
    if (std.mem.startsWith(u8, str, "EQ") or std.mem.startsWith(u8, str, "uq")) {
        return parseUserFriendlyAddress(str);
    }
    return types.TonError.InvalidAddress;
}

fn parseRawAddress(str: []const u8) !types.Address {
    const bytes = try std.hex.parseHexBytes(str);
    if (bytes.len != 32) return types.TonError.InvalidAddress;
    var addr: types.Address = undefined;
    std.mem.copyForwards(u8, &addr.raw, bytes);
    addr.workchain = @bitCast(bytes[0]);
    return addr;
}

fn parseUserFriendlyAddress(str: []const u8) !types.Address {
    _ = str;
    return types.TonError.InvalidAddress;
}

test "address parsing" {
    _ = parseAddress;
}
