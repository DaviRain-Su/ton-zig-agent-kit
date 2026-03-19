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

    pub fn callGetMethodArgs(self: *GenericContract, method: []const u8, args: []const StackArg) !types.RunGetMethodResponse {
        const stack_json = try buildStackArgsJsonAlloc(self.client.allocator, args);
        defer self.client.allocator.free(stack_json);

        return self.callGetMethodJson(method, stack_json);
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

pub const StackArg = union(enum) {
    null: void,
    int: i64,
    cell: []const u8,
    slice: []const u8,
    builder: []const u8,
    address: []const u8,
    raw_json: []const u8,
};

const offchain_content_prefix: u8 = 0x01;

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
        .builder => |value| value,
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
        .builder => |value| boc.serializeBoc(allocator, value),
        .bytes => |value| allocator.dupe(u8, value),
        else => error.InvalidStackEntry,
    };
}

pub fn flattenSnakeBytesAlloc(allocator: std.mem.Allocator, root: *const cell.Cell) ![]u8 {
    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    var current: ?*const cell.Cell = root;
    while (current) |value| {
        if (value.bit_len % 8 != 0) return error.InvalidSnakeData;
        if (value.ref_cnt > 1) return error.InvalidSnakeData;

        const byte_len: usize = @intCast(value.bit_len / 8);
        try writer.writer.writeAll(value.data[0..byte_len]);
        current = if (value.ref_cnt == 1)
            value.refs[0] orelse return error.InvalidSnakeData
        else
            null;
    }

    return try writer.toOwnedSlice();
}

pub fn decodeOffchainContentUriCellAlloc(allocator: std.mem.Allocator, root: *const cell.Cell) !?[]u8 {
    const flattened = try flattenSnakeBytesAlloc(allocator, root);
    defer allocator.free(flattened);

    if (flattened.len == 0 or flattened[0] != offchain_content_prefix) return null;
    return try allocator.dupe(u8, flattened[1..]);
}

pub fn stackEntryAsOffchainContentUriAlloc(allocator: std.mem.Allocator, entry: *const types.StackEntry) !?[]u8 {
    const value = try stackEntryAsCell(entry);
    return decodeOffchainContentUriCellAlloc(allocator, value);
}

pub fn buildStackArgsJsonAlloc(allocator: std.mem.Allocator, args: []const StackArg) ![]u8 {
    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    try writer.writer.writeByte('[');
    for (args, 0..) |arg, i| {
        if (i != 0) try writer.writer.writeByte(',');
        try writeStackArgJson(&writer.writer, allocator, arg);
    }
    try writer.writer.writeByte(']');

    return try writer.toOwnedSlice();
}

fn writeStackArgJson(writer: anytype, allocator: std.mem.Allocator, arg: StackArg) !void {
    switch (arg) {
        .null => try writer.writeAll("[\"null\"]"),
        .int => |value| try writer.print("[\"num\",{d}]", .{value}),
        .cell => |boc_bytes| try writeBocStackArgJson(writer, allocator, "cell", boc_bytes),
        .slice => |boc_bytes| try writeBocStackArgJson(writer, allocator, "slice", boc_bytes),
        .builder => |boc_bytes| try writeBocStackArgJson(writer, allocator, "builder", boc_bytes),
        .address => |address_text| {
            const address_boc = try buildAddressSliceBocAlloc(allocator, address_text);
            defer allocator.free(address_boc);

            try writeBocStackArgJson(writer, allocator, "slice", address_boc);
        },
        .raw_json => |value| try writer.writeAll(value),
    }
}

fn writeBocStackArgJson(writer: anytype, allocator: std.mem.Allocator, tag: []const u8, boc_bytes: []const u8) !void {
    const encoded_len = std.base64.standard.Encoder.calcSize(boc_bytes.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, boc_bytes);

    try writer.print("[\"{s}\",\"{s}\"]", .{ tag, encoded });
}

fn buildAddressSliceBocAlloc(allocator: std.mem.Allocator, address_text: []const u8) ![]u8 {
    var builder = cell.Builder.init();
    try builder.storeAddress(address_text);

    const address_cell = try builder.toCell(allocator);
    defer address_cell.deinit(allocator);

    return boc.serializeBoc(allocator, address_cell);
}

pub fn buildSliceStackArgJson(allocator: std.mem.Allocator, body_boc: []const u8) ![]u8 {
    return buildStackArgsJsonAlloc(allocator, &.{.{ .slice = body_boc }});
}

pub fn buildAddressSliceStackArgJson(allocator: std.mem.Allocator, address_text: []const u8) ![]u8 {
    return buildStackArgsJsonAlloc(allocator, &.{.{ .address = address_text }});
}

pub fn stackToJsonAlloc(allocator: std.mem.Allocator, stack: []const types.StackEntry) ![]u8 {
    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    try writeStackEntriesJson(&writer.writer, allocator, stack);
    return try writer.toOwnedSlice();
}

fn writeStackEntriesJson(writer: anytype, allocator: std.mem.Allocator, stack: []const types.StackEntry) anyerror!void {
    try writer.writeByte('[');
    for (stack, 0..) |*entry, i| {
        if (i != 0) try writer.writeByte(',');
        try writeStackEntryJson(writer, allocator, entry);
    }
    try writer.writeByte(']');
}

fn writeStackEntryJson(writer: anytype, allocator: std.mem.Allocator, entry: *const types.StackEntry) anyerror!void {
    switch (entry.*) {
        .null => try writer.writeAll("[\"null\"]"),
        .number => |value| try writer.print("[\"num\",{d}]", .{value}),
        .bytes => |value| {
            try writer.writeAll("[\"bytes\",");
            try writeJsonString(writer, value);
            try writer.writeByte(']');
        },
        .cell => |value| {
            const body = try boc.serializeBoc(allocator, value);
            defer allocator.free(body);
            try writeBocStackArgJson(writer, allocator, "cell", body);
        },
        .slice => |value| {
            const body = try boc.serializeBoc(allocator, value);
            defer allocator.free(body);
            try writeBocStackArgJson(writer, allocator, "slice", body);
        },
        .builder => |value| {
            const body = try boc.serializeBoc(allocator, value);
            defer allocator.free(body);
            try writeBocStackArgJson(writer, allocator, "builder", body);
        },
        .tuple => |items| {
            try writer.writeAll("[\"tuple\",");
            try writeStackEntriesJson(writer, allocator, items);
            try writer.writeByte(']');
        },
        .list => |items| {
            try writer.writeAll("[\"list\",");
            try writeStackEntriesJson(writer, allocator, items);
            try writer.writeByte(']');
        },
    }
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |char| {
        switch (char) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f => try writer.print("\\u00{X:0>2}", .{char}),
            else => try writer.writeByte(char),
        }
    }
    try writer.writeByte('"');
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

test "build stack args json" {
    const allocator = std.testing.allocator;

    var builder = cell.Builder.init();
    try builder.storeUint(0xCAFE, 16);
    const content_cell = try builder.toCell(allocator);
    defer content_cell.deinit(allocator);

    const content_boc = try boc.serializeBoc(allocator, content_cell);
    defer allocator.free(content_boc);

    const stack_json = try buildStackArgsJsonAlloc(allocator, &.{
        .{ .null = {} },
        .{ .int = 42 },
        .{ .address = "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8" },
        .{ .cell = content_boc },
        .{ .builder = content_boc },
        .{ .raw_json = "[\"tuple\",[[\"num\",7],[\"null\"]]]" },
    });
    defer allocator.free(stack_json);

    try std.testing.expect(std.mem.indexOf(u8, stack_json, "[\"null\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, stack_json, "[\"num\",42]") != null);
    try std.testing.expect(std.mem.indexOf(u8, stack_json, "[\"slice\",\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stack_json, "[\"cell\",\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stack_json, "[\"builder\",\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, stack_json, "[\"tuple\",[[\"num\",7],[\"null\"]]]") != null);
    try std.testing.expect(std.mem.startsWith(u8, stack_json, "["));
    try std.testing.expect(std.mem.endsWith(u8, stack_json, "]"));
}

test "decode offchain content uri from snake cell" {
    const allocator = std.testing.allocator;

    var tail_builder = cell.Builder.init();
    try tail_builder.storeBits("meta.json", "meta.json".len * 8);
    const tail = try tail_builder.toCell(allocator);

    var head_builder = cell.Builder.init();
    try head_builder.storeUint(offchain_content_prefix, 8);
    try head_builder.storeBits("https://example.com/", "https://example.com/".len * 8);
    try head_builder.storeRef(tail);
    const root = try head_builder.toCell(allocator);
    defer root.deinit(allocator);

    const uri = (try decodeOffchainContentUriCellAlloc(allocator, root)).?;
    defer allocator.free(uri);

    try std.testing.expectEqualStrings("https://example.com/meta.json", uri);
}

test "serialize stack entries to json" {
    const allocator = std.testing.allocator;

    var builder = cell.Builder.init();
    try builder.storeUint(0xCAFE, 16);
    const payload = try builder.toCell(allocator);
    defer payload.deinit(allocator);

    var nested = [_]types.StackEntry{
        .{ .number = 7 },
        .{ .bytes = "line1\n\"quoted\"" },
    };
    var stack = [_]types.StackEntry{
        .{ .null = {} },
        .{ .builder = payload },
        .{ .tuple = nested[0..] },
        .{ .list = nested[0..] },
    };

    const json = try stackToJsonAlloc(allocator, stack[0..]);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "[\"null\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "[\"builder\",\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "[\"tuple\",[[\"num\",7],[\"bytes\",\"line1\\n\\\"quoted\\\"\"]]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "[\"list\",[[\"num\",7],[\"bytes\",\"line1\\n\\\"quoted\\\"\"]]]") != null);
}

test {
    _ = jetton;
    _ = nft;
    _ = abi_adapter;
}
