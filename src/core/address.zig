//! TON address parsing and conversion.
//! Supports:
//! - raw format: `workchain:64hex`
//! - legacy raw format: `0x64hex` (assumes workchain 0)
//! - user-friendly format: 48-char base64/base64url form from TEP-2

const std = @import("std");
const types = @import("types.zig");

const user_friendly_len = 48;
const user_friendly_data_len = 36;
const checksum_offset = 34;
const bounceable_flag: u8 = 0x11;
const non_bounceable_flag: u8 = 0x51;
const testnet_flag: u8 = 0x80;

pub fn decodeBase64Url(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var decoded = [_]u8{0} ** user_friendly_data_len;
    const out = try decodeUserFriendlyBytes(input, &decoded);
    return allocator.dupe(u8, out);
}

pub fn parseAddress(str: []const u8) !types.Address {
    if (std.mem.indexOfScalar(u8, str, ':') != null) {
        return parseRawAddress(str);
    }
    if (std.mem.startsWith(u8, str, "0x") or std.mem.startsWith(u8, str, "0X")) {
        return parseLegacyRawAddress(str[2..]);
    }
    if (str.len == user_friendly_len) {
        return parseUserFriendlyAddress(str);
    }
    return types.TonError.InvalidAddress;
}

fn parseLegacyRawAddress(str: []const u8) !types.Address {
    if (str.len != 64) return types.TonError.InvalidAddress;

    var addr = types.Address{
        .raw = [_]u8{0} ** 32,
        .workchain = 0,
    };
    try decodeHexInto(str, &addr.raw);
    return addr;
}

fn parseRawAddress(str: []const u8) !types.Address {
    var iter = std.mem.splitScalar(u8, str, ':');
    const workchain_str = iter.next() orelse return types.TonError.InvalidAddress;
    const account_str = iter.next() orelse return types.TonError.InvalidAddress;
    if (iter.next() != null) return types.TonError.InvalidAddress;
    if (account_str.len != 64) return types.TonError.InvalidAddress;

    const workchain = std.fmt.parseInt(i8, workchain_str, 10) catch return types.TonError.InvalidAddress;
    var addr = types.Address{
        .raw = [_]u8{0} ** 32,
        .workchain = workchain,
    };
    try decodeHexInto(account_str, &addr.raw);
    return addr;
}

fn parseUserFriendlyAddress(str: []const u8) !types.Address {
    var bytes = [_]u8{0} ** user_friendly_data_len;
    const decoded = try decodeUserFriendlyBytes(str, &bytes);
    if (decoded.len != user_friendly_data_len) return types.TonError.InvalidAddress;

    if (!isValidUserFriendlyFlag(decoded[0])) {
        return types.TonError.InvalidAddress;
    }

    const expected_checksum = crc16(decoded[0..checksum_offset]);
    const actual_checksum = std.mem.readInt(u16, decoded[checksum_offset..][0..2], .big);
    if (expected_checksum != actual_checksum) {
        return types.TonError.InvalidAddress;
    }

    var addr = types.Address{
        .raw = [_]u8{0} ** 32,
        .workchain = @bitCast(decoded[1]),
    };
    @memcpy(&addr.raw, decoded[2..34]);
    return addr;
}

fn decodeUserFriendlyBytes(input: []const u8, out: *[user_friendly_data_len]u8) ![]u8 {
    const decoder = if (std.mem.indexOfAny(u8, input, "-_") != null)
        std.base64.url_safe_no_pad.Decoder
    else
        std.base64.standard_no_pad.Decoder;

    const decoded_len = decoder.calcSizeForSlice(input) catch return types.TonError.InvalidAddress;
    if (decoded_len != user_friendly_data_len) return types.TonError.InvalidAddress;
    decoder.decode(out, input) catch return types.TonError.InvalidAddress;
    return out[0..decoded_len];
}

fn isValidUserFriendlyFlag(flag: u8) bool {
    return (flag & 0x3f) == bounceable_flag;
}

fn decodeHexInto(hex: []const u8, out: []u8) !void {
    if (hex.len != out.len * 2) return types.TonError.InvalidAddress;
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const hi = hexCharValue(hex[i * 2]) catch return types.TonError.InvalidAddress;
        const lo = hexCharValue(hex[i * 2 + 1]) catch return types.TonError.InvalidAddress;
        out[i] = (hi << 4) | lo;
    }
}

fn hexCharValue(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
}

fn crc16(data: []const u8) u16 {
    var hasher = std.hash.crc.Crc16Xmodem.init();
    hasher.update(data);
    return hasher.final();
}

pub fn formatRaw(allocator: std.mem.Allocator, addr: *const types.Address) ![]u8 {
    const raw_hex = std.fmt.bytesToHex(addr.raw, .lower);
    return std.fmt.allocPrint(allocator, "{d}:{s}", .{ addr.workchain, raw_hex[0..] });
}

pub fn addressToUserFriendlyAlloc(
    allocator: std.mem.Allocator,
    addr: *const types.Address,
    bounceable: bool,
    testnet: bool,
) ![]u8 {
    var payload = [_]u8{0} ** user_friendly_data_len;
    payload[0] = if (bounceable) bounceable_flag else non_bounceable_flag;
    if (testnet) payload[0] |= testnet_flag;
    payload[1] = @bitCast(addr.workchain);
    @memcpy(payload[2..34], &addr.raw);
    std.mem.writeInt(u16, payload[checksum_offset..][0..2], crc16(payload[0..checksum_offset]), .big);

    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(payload.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, &payload);
    return encoded;
}

pub fn addressToUserFriendly(addr: *const types.Address, testnet: bool) []u8 {
    return addressToUserFriendlyAlloc(std.heap.page_allocator, addr, true, testnet) catch "";
}

test "address parsing raw canonical" {
    const addr = try parseAddress("0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8");
    try std.testing.expectEqual(@as(i8, 0), addr.workchain);
    try std.testing.expectEqual(@as(u8, 0x83), addr.raw[0]);
    try std.testing.expectEqual(@as(u8, 0xA8), addr.raw[31]);
}

test "address parsing legacy raw defaults to basechain" {
    const addr = try parseAddress("0x0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF");
    try std.testing.expectEqual(@as(i8, 0), addr.workchain);
    try std.testing.expectEqual(@as(u8, 0x01), addr.raw[0]);
}

test "address parsing user-friendly" {
    const addr = try parseAddress("EQDKbjIcfM6ezt8KjKJJLshZJJSqX7XOA4ff-W72r5gqPrHF");
    try std.testing.expectEqual(@as(i8, 0), addr.workchain);

    const raw = try formatRaw(std.testing.allocator, &addr);
    defer std.testing.allocator.free(raw);
    try std.testing.expectEqualStrings("0:ca6e321c7cce9ecedf0a8ca2492ec8592494aa5fb5ce0387dff96ef6af982a3e", raw);
}

test "address roundtrip user-friendly" {
    const addr = try parseAddress("0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8");
    const user_friendly = try addressToUserFriendlyAlloc(std.testing.allocator, &addr, true, false);
    defer std.testing.allocator.free(user_friendly);

    try std.testing.expectEqualStrings("EQCD39VS5jcptHL8vMjEXrzGaRcCVYto7HUn4bpAOg8xqB2N", user_friendly);
    const parsed = try parseAddress(user_friendly);
    try std.testing.expectEqualDeep(addr, parsed);
}

test "invalid checksum is rejected" {
    try std.testing.expectError(types.TonError.InvalidAddress, parseAddress("EQDKbjIcfM6ezt8KjKJJLshZJJSqX7XOA4ff-W72r5gqPrHA"));
}
