//! Generic contract interface

const std = @import("std");
const types = @import("../core/types.zig");
const cell = @import("../core/cell.zig");
const boc = @import("../core/boc.zig");
const http_client = @import("../core/http_client.zig");

pub const GenericContract = struct {
    client: *http_client.TonHttpClient,
    address: []const u8,

    pub fn init(client: *http_client.TonHttpClient, address: []const u8) GenericContract {
        return .{
            .client = client,
            .address = address,
        };
    }

    pub fn callGetMethod(self: *GenericContract, method: []const u8, args: []const []const u8) !types.RunGetMethodResponse {
        return self.client.runGetMethod(self.address, method, args);
    }

    pub fn callGetMethodJson(self: *GenericContract, method: []const u8, stack_json: []const u8) !types.RunGetMethodResponse {
        return self.client.runGetMethodJson(self.address, method, stack_json);
    }

    pub fn sendMessage(self: *GenericContract, body: []const u8) !types.SendBocResponse {
        return self.client.sendBoc(body);
    }

    pub fn sendMessageBase64(self: *GenericContract, body_base64: []const u8) !types.SendBocResponse {
        return self.client.sendBocBase64(body_base64);
    }

    pub fn sendMessageHex(self: *GenericContract, body_hex: []const u8) !types.SendBocResponse {
        return self.client.sendBocHex(body_hex);
    }
};

pub fn stackEntryAsInt(entry: *const types.StackEntry) !i64 {
    return switch (entry.*) {
        .number => |value| value,
        else => error.InvalidStackEntry,
    };
}

pub fn stackEntryAsCell(entry: *const types.StackEntry) !*cell.Cell {
    return switch (entry.*) {
        .cell => |value| value,
        .slice => |value| value,
        else => error.InvalidStackEntry,
    };
}

pub fn stackEntryAsOptionalAddress(entry: *const types.StackEntry) !?types.Address {
    const value = try stackEntryAsCell(entry);
    var slice_value = value.toSlice();

    const tag = try slice_value.loadUint(2);
    if (tag == 0) return null;
    if (tag != 0b10) return error.InvalidAddress;

    const has_anycast = try slice_value.loadUint(1);
    if (has_anycast != 0) return error.UnsupportedAddress;

    var raw: [32]u8 = undefined;
    const workchain = try slice_value.loadInt8();
    for (&raw) |*byte| {
        byte.* = try slice_value.loadUint8();
    }

    return .{
        .raw = raw,
        .workchain = workchain,
    };
}

pub fn stackEntryToBocAlloc(allocator: std.mem.Allocator, entry: *const types.StackEntry) ![]u8 {
    return switch (entry.*) {
        .cell => |value| boc.serializeBoc(allocator, value),
        .slice => |value| boc.serializeBoc(allocator, value),
        .bytes => |value| allocator.dupe(u8, value),
        else => error.InvalidStackEntry,
    };
}

pub fn buildSliceStackArgJson(allocator: std.mem.Allocator, body_boc: []const u8) ![]u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(body_boc.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, body_boc);

    return std.fmt.allocPrint(allocator, "[[\"slice\",\"{s}\"]]", .{encoded});
}

pub fn buildAddressSliceStackArgJson(allocator: std.mem.Allocator, address_text: []const u8) ![]u8 {
    var builder = cell.Builder.init();
    try builder.storeAddress(address_text);

    const address_cell = try builder.toCell(allocator);
    defer address_cell.deinit(allocator);

    const body_boc = try boc.serializeBoc(allocator, address_cell);
    defer allocator.free(body_boc);

    return buildSliceStackArgJson(allocator, body_boc);
}

pub const jetton = @import("jetton.zig");
pub const nft = @import("nft.zig");
pub const abi_adapter = @import("abi_adapter.zig");

test "generic contract init" {
    const allocator = std.testing.allocator;
    var client = try http_client.TonHttpClient.init(allocator, "https://toncenter.com/api/v2/jsonRPC", null);
    defer client.deinit();

    const contract = GenericContract.init(&client, "EQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM9c");
    try std.testing.expectEqualStrings("EQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM9c", contract.address);
}

test "stack entry address helper" {
    const allocator = std.testing.allocator;

    var builder = cell.Builder.init();
    try builder.storeAddress(@as([]const u8, "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8"));
    const address_cell = try builder.toCell(allocator);
    defer address_cell.deinit(allocator);

    const entry = types.StackEntry{ .slice = address_cell };
    const parsed = (try stackEntryAsOptionalAddress(&entry)).?;

    try std.testing.expectEqual(@as(i8, 0), parsed.workchain);
    try std.testing.expectEqual(@as(u8, 0x83), parsed.raw[0]);
}

test {
    _ = jetton;
    _ = nft;
    _ = abi_adapter;
}
