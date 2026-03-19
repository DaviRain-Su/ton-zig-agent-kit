//! Generic contract interface

const std = @import("std");
const types = @import("../core/types.zig");
const cell = @import("../core/cell.zig");
const boc = @import("../core/boc.zig");
const external_message = @import("../core/external_message.zig");
const http_client = @import("../core/http_client.zig");
const provider_mod = @import("../core/provider.zig");

pub fn GenericContractType(comptime ClientType: type) type {
    return struct {
        client: ClientType,
        address: []const u8,

        pub fn init(client: ClientType, address: []const u8) @This() {
            return .{
                .client = client,
                .address = address,
            };
        }

        pub fn callGetMethod(self: *@This(), method: []const u8, args: []const []const u8) !types.RunGetMethodResponse {
            return self.client.runGetMethod(self.address, method, args);
        }

        pub fn callGetMethodJson(self: *@This(), method: []const u8, stack_json: []const u8) !types.RunGetMethodResponse {
            return self.client.runGetMethodJson(self.address, method, stack_json);
        }

        pub fn callGetMethodArgs(self: *@This(), method: []const u8, args: []const StackArg) !types.RunGetMethodResponse {
            const stack_json = try buildStackArgsJsonAlloc(self.client.allocator, args);
            defer self.client.allocator.free(stack_json);

            return self.callGetMethodJson(method, stack_json);
        }

        pub fn sendMessage(self: *@This(), body: []const u8) !types.SendBocResponse {
            return self.client.sendBoc(body);
        }

        pub fn sendMessageBase64(self: *@This(), body_base64: []const u8) !types.SendBocResponse {
            return self.client.sendBocBase64(body_base64);
        }

        pub fn sendMessageHex(self: *@This(), body_hex: []const u8) !types.SendBocResponse {
            return self.client.sendBocHex(body_hex);
        }

        pub fn buildExternalMessageBocAlloc(self: *@This(), body: []const u8, state_init_boc: ?[]const u8) ![]u8 {
            return external_message.buildExternalIncomingMessageBocAlloc(
                self.client.allocator,
                self.address,
                body,
                state_init_boc,
            );
        }

        pub fn sendExternalMessage(self: *@This(), body: []const u8, state_init_boc: ?[]const u8) !types.SendBocResponse {
            const ext_boc = try self.buildExternalMessageBocAlloc(body, state_init_boc);
            defer self.client.allocator.free(ext_boc);
            return self.client.sendBoc(ext_boc);
        }
    };
}

pub const GenericContract = GenericContractType(*http_client.TonHttpClient);
pub const ProviderGenericContract = GenericContractType(*provider_mod.MultiProvider);

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
        .big_number => |value| parseSignedTonInt(i64, value),
        else => error.InvalidStackEntry,
    };
}

pub fn stackEntryAsUnsigned(comptime IntType: type, entry: *const types.StackEntry) !IntType {
    return switch (entry.*) {
        .number => |value| {
            if (value < 0) return error.InvalidStackEntry;
            return @intCast(value);
        },
        .big_number => |value| parseUnsignedTonInt(IntType, value),
        else => error.InvalidStackEntry,
    };
}

pub fn stackEntryAsNumberTextAlloc(allocator: std.mem.Allocator, entry: *const types.StackEntry) ![]u8 {
    return switch (entry.*) {
        .number => |value| std.fmt.allocPrint(allocator, "{d}", .{value}),
        .big_number => |value| allocator.dupe(u8, value),
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
        .big_number => |value| {
            try writer.writeAll("[\"num\",");
            try writeJsonString(writer, value);
            try writer.writeByte(']');
        },
        .unsupported => |value| {
            try writer.writeAll("[\"unsupported\",");
            try writeJsonString(writer, value);
            try writer.writeByte(']');
        },
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

fn parseUnsignedTonInt(comptime IntType: type, value: []const u8) !IntType {
    if (value.len == 0 or value[0] == '-') return error.InvalidStackEntry;

    if (std.mem.startsWith(u8, value, "0x")) {
        return std.fmt.parseInt(IntType, value[2..], 16);
    }

    return std.fmt.parseInt(IntType, value, 10);
}

fn parseSignedTonInt(comptime IntType: type, value: []const u8) !IntType {
    if (value.len == 0) return error.InvalidStackEntry;

    if (std.mem.startsWith(u8, value, "-0x")) {
        const magnitude = try std.fmt.parseUnsigned(std.meta.Int(.unsigned, @typeInfo(IntType).int.bits), value[3..], 16);
        const min_magnitude: std.meta.Int(.unsigned, @typeInfo(IntType).int.bits) = @as(std.meta.Int(.unsigned, @typeInfo(IntType).int.bits), @intCast(std.math.maxInt(IntType))) + 1;
        if (magnitude > min_magnitude) return error.Overflow;
        if (magnitude == min_magnitude) return std.math.minInt(IntType);
        return -@as(IntType, @intCast(magnitude));
    }

    if (std.mem.startsWith(u8, value, "0x")) {
        return std.fmt.parseInt(IntType, value[2..], 16);
    }

    return std.fmt.parseInt(IntType, value, 10);
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

test "provider generic contract init" {
    const allocator = std.testing.allocator;
    var provider = try provider_mod.MultiProvider.init(allocator, &.{
        .{ .url = "https://toncenter.com/api/v2/jsonRPC" },
    });

    const contract = ProviderGenericContract.init(&provider, "EQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM9c");
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
        .{ .big_number = "0x1234567890ABCDEF1234567890ABCDEF" },
        .{ .bytes = "line1\n\"quoted\"" },
    };
    var stack = [_]types.StackEntry{
        .{ .null = {} },
        .{ .builder = payload },
        .{ .unsupported = "{\"@type\":\"tvm.stackEntryCont\"}" },
        .{ .tuple = nested[0..] },
        .{ .list = nested[0..] },
    };

    const json = try stackToJsonAlloc(allocator, stack[0..]);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "[\"null\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "[\"builder\",\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "[\"unsupported\",\"{\\\"@type\\\":\\\"tvm.stackEntryCont\\\"}\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "[\"tuple\",[[\"num\",7],[\"num\",\"0x1234567890ABCDEF1234567890ABCDEF\"],[\"bytes\",\"line1\\n\\\"quoted\\\"\"]]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "[\"list\",[[\"num\",7],[\"num\",\"0x1234567890ABCDEF1234567890ABCDEF\"],[\"bytes\",\"line1\\n\\\"quoted\\\"\"]]]") != null);
}

test "stack entry helpers support big unsigned values" {
    const allocator = std.testing.allocator;
    const entry = types.StackEntry{ .big_number = "0x1234567890ABCDEF1234567890ABCDEF" };

    try std.testing.expectEqual(
        @as(u256, 0x1234567890ABCDEF1234567890ABCDEF),
        try stackEntryAsUnsigned(u256, &entry),
    );

    const text = try stackEntryAsNumberTextAlloc(allocator, &entry);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("0x1234567890ABCDEF1234567890ABCDEF", text);
}

test "generic contract sendExternalMessage wraps body for destination" {
    const allocator = std.testing.allocator;

    const FakeClient = struct {
        allocator: std.mem.Allocator,
        last_boc: ?[]u8 = null,

        pub fn sendBoc(self: *@This(), payload: []const u8) !types.SendBocResponse {
            self.last_boc = try self.allocator.dupe(u8, payload);
            return .{
                .hash = try self.allocator.dupe(u8, "external"),
                .lt = 321,
            };
        }
    };

    var client = FakeClient{ .allocator = allocator };
    defer if (client.last_boc) |value| allocator.free(value);

    var builder = cell.Builder.init();
    try builder.storeUint(0xCAFE, 16);
    const body_cell = try builder.toCell(allocator);
    defer body_cell.deinit(allocator);
    const body_boc = try boc.serializeBoc(allocator, body_cell);
    defer allocator.free(body_boc);

    const Contract = GenericContractType(*FakeClient);
    var contract = Contract.init(&client, "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8");

    const response = try contract.sendExternalMessage(body_boc, null);
    defer allocator.free(response.hash);

    try std.testing.expectEqual(@as(i64, 321), response.lt);
    try std.testing.expect(client.last_boc != null);

    const ext_msg = try boc.deserializeBoc(allocator, client.last_boc.?);
    defer ext_msg.deinit(allocator);

    var slice = ext_msg.toSlice();
    try std.testing.expectEqual(@as(u64, 0b10), try slice.loadUint(2));
    try std.testing.expectEqual(@as(u64, 0), try slice.loadUint(2));
    const dest = try slice.loadAddress();
    try std.testing.expectEqual(@as(i8, 0), dest.workchain);
    try std.testing.expectEqual(@as(u8, 0x83), dest.raw[0]);
    _ = try slice.loadCoins();
    try std.testing.expectEqual(@as(u64, 0), try slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 1), try slice.loadUint(1));
    const body_ref = try slice.loadRef();
    var body_slice = body_ref.toSlice();
    try std.testing.expectEqual(@as(u64, 0xCAFE), try body_slice.loadUint(16));
}

test {
    _ = jetton;
    _ = nft;
    _ = abi_adapter;
}
