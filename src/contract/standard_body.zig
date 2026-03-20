const std = @import("std");
const abi_adapter = @import("abi_adapter.zig");
const boc = @import("../core/boc.zig");
const body_builder = @import("../core/body_builder.zig");
const cell = @import("../core/cell.zig");
const jetton = @import("jetton.zig");

pub const StandardBodyKind = enum {
    comment,
    jetton_transfer,
    jetton_burn,
    nft_transfer,
};

pub fn parseKind(text: []const u8) !StandardBodyKind {
    if (std.ascii.eqlIgnoreCase(text, "comment")) return .comment;
    if (std.ascii.eqlIgnoreCase(text, "jetton_transfer") or std.ascii.eqlIgnoreCase(text, "jetton-transfer")) return .jetton_transfer;
    if (std.ascii.eqlIgnoreCase(text, "jetton_burn") or std.ascii.eqlIgnoreCase(text, "jetton-burn")) return .jetton_burn;
    if (std.ascii.eqlIgnoreCase(text, "nft_transfer") or std.ascii.eqlIgnoreCase(text, "nft-transfer")) return .nft_transfer;
    return error.UnknownStandardBodyKind;
}

pub fn kindName(kind: StandardBodyKind) []const u8 {
    return switch (kind) {
        .comment => "comment",
        .jetton_transfer => "jetton_transfer",
        .jetton_burn => "jetton_burn",
        .nft_transfer => "nft_transfer",
    };
}

pub fn buildBodyFromSourceAlloc(
    allocator: std.mem.Allocator,
    kind_name: []const u8,
    source: []const u8,
) ![]u8 {
    const kind = try parseKind(kind_name);
    const json_text = try abi_adapter.loadAbiTextSourceAlloc(allocator, source);
    defer allocator.free(json_text);
    return buildBodyFromJsonAlloc(allocator, kind, json_text);
}

pub fn buildBodyFromJsonAlloc(
    allocator: std.mem.Allocator,
    kind: StandardBodyKind,
    json_text: []const u8,
) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidStandardBodySpec,
    };

    return switch (kind) {
        .comment => buildCommentBodyBocAlloc(allocator, try getRequiredString(object, "comment")),
        .jetton_transfer => buildJettonTransferBodyAlloc(allocator, object),
        .jetton_burn => buildJettonBurnBodyAlloc(allocator, object),
        .nft_transfer => buildNftTransferBodyAlloc(allocator, object),
    };
}

pub fn buildCommentBodyBocAlloc(allocator: std.mem.Allocator, comment: []const u8) ![]u8 {
    var builder = cell.Builder.init();
    try builder.storeUint(0, 32);
    try builder.storeBits(comment, @intCast(comment.len * 8));
    const root = try builder.toCell(allocator);
    defer root.deinit(allocator);
    return boc.serializeBoc(allocator, root);
}

pub fn createNftTransferMessage(
    allocator: std.mem.Allocator,
    query_id: u64,
    new_owner: []const u8,
    response_destination: []const u8,
    custom_payload: ?[]const u8,
    forward_amount: u64,
    forward_payload: ?[]const u8,
) ![]u8 {
    var builder = cell.Builder.init();
    try builder.storeUint(0x5FCC3D14, 32);
    try builder.storeUint(query_id, 64);
    try builder.storeAddress(new_owner);
    try builder.storeAddress(response_destination);
    if (custom_payload) |payload| {
        try builder.storeUint(1, 1);
        try body_builder.storeRefBoc(&builder, allocator, payload);
    } else {
        try builder.storeUint(0, 1);
    }
    try builder.storeCoins(forward_amount);
    if (forward_payload) |payload| {
        try builder.storeUint(1, 1);
        try body_builder.storeRefBoc(&builder, allocator, payload);
    } else {
        try builder.storeUint(0, 1);
    }

    const root = try builder.toCell(allocator);
    defer root.deinit(allocator);
    return boc.serializeBoc(allocator, root);
}

fn buildJettonTransferBodyAlloc(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]u8 {
    const query_id = try getOptionalU64(object, "query_id", 0);
    const amount = try getRequiredU64(object, "amount");
    const destination = try getRequiredString(object, "destination");
    const response_destination = try getRequiredString(object, "response_destination");
    const forward_ton_amount = try getOptionalU64(object, "forward_ton_amount", 0);

    const custom_payload = try loadOptionalBocAlloc(allocator, object, "custom_payload_boc_base64");
    defer if (custom_payload) |value| allocator.free(value);

    const forward_payload = try loadOptionalPayloadAlloc(
        allocator,
        object,
        "forward_payload_boc_base64",
        "forward_comment",
    );
    defer if (forward_payload) |value| allocator.free(value);

    return jetton.createTransferMessage(
        allocator,
        query_id,
        amount,
        destination,
        response_destination,
        custom_payload,
        forward_ton_amount,
        forward_payload,
    );
}

fn buildJettonBurnBodyAlloc(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]u8 {
    const query_id = try getOptionalU64(object, "query_id", 0);
    const amount = try getRequiredU64(object, "amount");
    const response_destination = try getRequiredString(object, "response_destination");
    const custom_payload = try loadOptionalBocAlloc(allocator, object, "custom_payload_boc_base64");
    defer if (custom_payload) |value| allocator.free(value);

    return jetton.createBurnMessage(
        allocator,
        query_id,
        amount,
        response_destination,
        custom_payload,
    );
}

fn buildNftTransferBodyAlloc(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]u8 {
    const query_id = try getOptionalU64(object, "query_id", 0);
    const new_owner = try getRequiredString(object, "new_owner");
    const response_destination = try getRequiredString(object, "response_destination");
    const forward_amount = try getOptionalU64(object, "forward_amount", 0);

    const custom_payload = try loadOptionalBocAlloc(allocator, object, "custom_payload_boc_base64");
    defer if (custom_payload) |value| allocator.free(value);

    const forward_payload = try loadOptionalPayloadAlloc(
        allocator,
        object,
        "forward_payload_boc_base64",
        "forward_comment",
    );
    defer if (forward_payload) |value| allocator.free(value);

    return createNftTransferMessage(
        allocator,
        query_id,
        new_owner,
        response_destination,
        custom_payload,
        forward_amount,
        forward_payload,
    );
}

fn getRequiredString(object: std.json.ObjectMap, field: []const u8) ![]const u8 {
    const value = object.get(field) orelse return error.MissingStandardBodyField;
    return switch (value) {
        .string => value.string,
        else => error.InvalidStandardBodySpec,
    };
}

fn getRequiredU64(object: std.json.ObjectMap, field: []const u8) !u64 {
    const value = object.get(field) orelse return error.MissingStandardBodyField;
    return parseJsonU64(value);
}

fn getOptionalU64(object: std.json.ObjectMap, field: []const u8, default_value: u64) !u64 {
    const value = object.get(field) orelse return default_value;
    return parseJsonU64(value);
}

fn parseJsonU64(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => @intCast(value.integer),
        .string => |text| {
            if (std.mem.startsWith(u8, text, "0x")) return std.fmt.parseInt(u64, text[2..], 16);
            return std.fmt.parseInt(u64, text, 10);
        },
        else => error.InvalidStandardBodySpec,
    };
}

fn loadOptionalPayloadAlloc(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    boc_field: []const u8,
    comment_field: []const u8,
) !?[]u8 {
    if (try loadOptionalBocAlloc(allocator, object, boc_field)) |value| {
        return value;
    }
    if (object.get(comment_field)) |value| {
        return switch (value) {
            .null => null,
            .string => |text| try buildCommentBodyBocAlloc(allocator, text),
            else => error.InvalidStandardBodySpec,
        };
    }
    return null;
}

fn loadOptionalBocAlloc(allocator: std.mem.Allocator, object: std.json.ObjectMap, field: []const u8) !?[]u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .null => null,
        .string => |text| try decodeBase64FlexibleAlloc(allocator, text),
        else => error.InvalidStandardBodySpec,
    };
}

fn decodeBase64FlexibleAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return decodeBase64WithDecoder(allocator, input, std.base64.standard.Decoder) catch
        decodeBase64WithDecoder(allocator, input, std.base64.url_safe.Decoder);
}

fn decodeBase64WithDecoder(allocator: std.mem.Allocator, input: []const u8, comptime decoder: anytype) ![]u8 {
    const decoded_len = try decoder.calcSizeForSlice(input);
    const output = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(output);
    try decoder.decode(output, input);
    return output;
}

test "standard body builds comment body from json" {
    const allocator = std.testing.allocator;
    const body_boc = try buildBodyFromJsonAlloc(allocator, .comment, "{\"comment\":\"hello\"}");
    defer allocator.free(body_boc);

    var analysis = try @import("../core/body_inspector.zig").inspectBodyBocAlloc(allocator, body_boc);
    defer analysis.deinit(allocator);
    try std.testing.expectEqualStrings("comment", analysis.opcode_name.?);
    try std.testing.expectEqualStrings("hello", analysis.comment.?);
}

test "standard body builds jetton transfer with forward comment" {
    const allocator = std.testing.allocator;
    const body_boc = try buildBodyFromJsonAlloc(allocator, .jetton_transfer,
        \\{
        \\  "query_id": 7,
        \\  "amount": 1234,
        \\  "destination": "0:1111111111111111111111111111111111111111111111111111111111111111",
        \\  "response_destination": "0:2222222222222222222222222222222222222222222222222222222222222222",
        \\  "forward_ton_amount": 9,
        \\  "forward_comment": "memo"
        \\}
    );
    defer allocator.free(body_boc);

    var analysis = try @import("../core/body_inspector.zig").inspectBodyBocAlloc(allocator, body_boc);
    defer analysis.deinit(allocator);
    try std.testing.expectEqualStrings("jetton_transfer", analysis.opcode_name.?);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"forward_comment\":\"memo\"") != null);
}

test "standard body builds nft transfer with forward comment" {
    const allocator = std.testing.allocator;
    const body_boc = try buildBodyFromJsonAlloc(allocator, .nft_transfer,
        \\{
        \\  "query_id": 9,
        \\  "new_owner": "0:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        \\  "response_destination": "0:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
        \\  "forward_amount": 11,
        \\  "forward_comment": "gift"
        \\}
    );
    defer allocator.free(body_boc);

    var analysis = try @import("../core/body_inspector.zig").inspectBodyBocAlloc(allocator, body_boc);
    defer analysis.deinit(allocator);
    try std.testing.expectEqualStrings("nft_transfer", analysis.opcode_name.?);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"forward_comment\":\"gift\"") != null);
}
