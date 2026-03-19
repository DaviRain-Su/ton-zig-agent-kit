const std = @import("std");
const address = @import("address.zig");
const boc = @import("boc.zig");
const cell = @import("cell.zig");

pub const BodyAnalysis = struct {
    opcode: ?u32 = null,
    opcode_name: ?[]u8 = null,
    comment: ?[]u8 = null,
    tail_utf8: ?[]u8 = null,
    decoded_json: ?[]u8 = null,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.opcode_name) |value| allocator.free(value);
        if (self.comment) |value| allocator.free(value);
        if (self.tail_utf8) |value| allocator.free(value);
        if (self.decoded_json) |value| allocator.free(value);
        self.* = .{};
    }

    pub fn empty(self: @This()) bool {
        return self.opcode == null and self.opcode_name == null and self.comment == null and self.tail_utf8 == null and self.decoded_json == null;
    }
};

const op_comment: u32 = 0x00000000;
const op_encrypted_comment: u32 = 0x2167DA4B;
const op_jetton_transfer: u32 = 0x0F8A7EA5;
const op_jetton_internal_transfer: u32 = 0x178D4519;
const op_jetton_transfer_notification: u32 = 0x7362D09C;
const op_jetton_burn: u32 = 0x595F07BC;
const op_nft_transfer: u32 = 0x5FCC3D14;

pub fn inspectBodyBocAlloc(allocator: std.mem.Allocator, body_boc: []const u8) anyerror!BodyAnalysis {
    const root = try boc.deserializeBoc(allocator, body_boc);
    defer root.deinit(allocator);
    return inspectBodyCellAlloc(allocator, root);
}

pub fn inspectBodyCellAlloc(allocator: std.mem.Allocator, root: *const cell.Cell) anyerror!BodyAnalysis {
    var analysis = BodyAnalysis{};
    errdefer analysis.deinit(allocator);

    if (root.bit_len == 0 and root.ref_cnt == 0) return analysis;

    if (root.bit_len < 32) {
        analysis.tail_utf8 = try maybeFlattenUtf8CellAlloc(allocator, root);
        return analysis;
    }

    var slice = @constCast(root).toSlice();
    analysis.opcode = @intCast(try loadUintDynamic(&slice, 32));
    if (knownOpcodeName(analysis.opcode.?)) |name| {
        analysis.opcode_name = try allocator.dupe(u8, name);
    }

    if (analysis.opcode.? == op_comment) {
        analysis.comment = try maybeFlattenUtf8TailAlloc(allocator, &slice);
        if (analysis.comment) |value| {
            analysis.decoded_json = try buildSimpleStringJsonAlloc(allocator, "comment", value);
        }
        return analysis;
    }

    var decode_slice = slice;
    analysis.decoded_json = decodeKnownBodyJsonAlloc(allocator, analysis.opcode.?, &decode_slice) catch null;
    analysis.tail_utf8 = try maybeFlattenUtf8TailAlloc(allocator, &slice);
    return analysis;
}

fn knownOpcodeName(opcode: u32) ?[]const u8 {
    return switch (opcode) {
        op_comment => "comment",
        op_encrypted_comment => "encrypted_comment",
        op_jetton_transfer => "jetton_transfer",
        op_jetton_internal_transfer => "jetton_internal_transfer",
        op_jetton_transfer_notification => "jetton_transfer_notification",
        op_jetton_burn => "jetton_burn",
        op_nft_transfer => "nft_transfer",
        else => null,
    };
}

fn decodeKnownBodyJsonAlloc(allocator: std.mem.Allocator, opcode: u32, slice: *cell.Slice) anyerror!?[]u8 {
    return switch (opcode) {
        op_jetton_transfer => try decodeJettonTransferJsonAlloc(allocator, slice),
        op_jetton_internal_transfer => try decodeJettonInternalTransferJsonAlloc(allocator, slice),
        op_jetton_transfer_notification => try decodeJettonTransferNotificationJsonAlloc(allocator, slice),
        op_jetton_burn => try decodeJettonBurnJsonAlloc(allocator, slice),
        op_nft_transfer => try decodeNftTransferJsonAlloc(allocator, slice),
        else => null,
    };
}

const PayloadText = struct {
    comment: ?[]u8 = null,
    tail_utf8: ?[]u8 = null,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.comment) |value| allocator.free(value);
        if (self.tail_utf8) |value| allocator.free(value);
        self.* = .{};
    }
};

fn inspectPayloadCellTextAlloc(allocator: std.mem.Allocator, value: *const cell.Cell) anyerror!PayloadText {
    var nested = try inspectBodyCellAlloc(allocator, value);
    defer nested.deinit(allocator);

    return .{
        .comment = if (nested.comment) |text| try allocator.dupe(u8, text) else null,
        .tail_utf8 = if (nested.tail_utf8) |text| try allocator.dupe(u8, text) else null,
    };
}

fn inspectPayloadSliceTextAlloc(allocator: std.mem.Allocator, payload: *cell.Slice) anyerror!PayloadText {
    var slice_value = payload.*;
    if (slice_value.remainingBits() == 0 and slice_value.remainingRefs() == 0) return .{};

    if (slice_value.remainingBits() < 32) {
        return .{ .tail_utf8 = try maybeFlattenUtf8TailAlloc(allocator, &slice_value) };
    }

    const opcode: u32 = @intCast(try loadUintDynamic(&slice_value, 32));
    if (opcode == op_comment) {
        return .{ .comment = try maybeFlattenUtf8TailAlloc(allocator, &slice_value) };
    }
    return .{ .tail_utf8 = try maybeFlattenUtf8TailAlloc(allocator, &slice_value) };
}

fn loadMaybeRefCell(slice: *cell.Slice) anyerror!bool {
    const has_ref = (try slice.loadUint(1)) == 1;
    if (has_ref) _ = try slice.loadRef();
    return has_ref;
}

fn loadEitherPayloadTextAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror!PayloadText {
    const is_ref = (try slice.loadUint(1)) == 1;
    if (is_ref) {
        const payload = try slice.loadRef();
        return inspectPayloadCellTextAlloc(allocator, payload);
    }
    return inspectPayloadSliceTextAlloc(allocator, slice);
}

fn decodeJettonTransferJsonAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror![]u8 {
    const query_id = try slice.loadUint(64);
    const amount = try slice.loadCoins();
    const destination = try slice.loadAddress();
    const response_destination = try slice.loadAddress();
    const has_custom_payload = try loadMaybeRefCell(slice);
    const forward_ton_amount = try slice.loadCoins();
    var forward_payload = try loadEitherPayloadTextAlloc(allocator, slice);
    defer forward_payload.deinit(allocator);

    const destination_raw = try address.formatRaw(allocator, &destination);
    defer allocator.free(destination_raw);
    const response_destination_raw = try address.formatRaw(allocator, &response_destination);
    defer allocator.free(response_destination_raw);

    return buildTransferLikeJsonAlloc(
        allocator,
        query_id,
        amount,
        "destination",
        destination_raw,
        "response_destination",
        response_destination_raw,
        has_custom_payload,
        forward_ton_amount,
        &forward_payload,
    );
}

fn decodeJettonInternalTransferJsonAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror![]u8 {
    const query_id = try slice.loadUint(64);
    const amount = try slice.loadCoins();
    const sender = try slice.loadAddress();
    const response_address = try slice.loadAddress();
    const forward_ton_amount = try slice.loadCoins();
    var forward_payload = try loadEitherPayloadTextAlloc(allocator, slice);
    defer forward_payload.deinit(allocator);

    const sender_raw = try address.formatRaw(allocator, &sender);
    defer allocator.free(sender_raw);
    const response_address_raw = try address.formatRaw(allocator, &response_address);
    defer allocator.free(response_address_raw);

    return buildTransferLikeJsonAlloc(
        allocator,
        query_id,
        amount,
        "sender",
        sender_raw,
        "response_address",
        response_address_raw,
        false,
        forward_ton_amount,
        &forward_payload,
    );
}

fn decodeJettonTransferNotificationJsonAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror![]u8 {
    const query_id = try slice.loadUint(64);
    const amount = try slice.loadCoins();
    const sender = try slice.loadAddress();
    var forward_payload = try loadEitherPayloadTextAlloc(allocator, slice);
    defer forward_payload.deinit(allocator);

    const sender_raw = try address.formatRaw(allocator, &sender);
    defer allocator.free(sender_raw);

    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("{\"query_id\":");
    try writer.writer.print("{d}", .{query_id});
    try writer.writer.writeAll(",\"amount\":");
    try writer.writer.print("{d}", .{amount});
    try writer.writer.writeAll(",\"sender\":");
    try writeJsonString(&writer.writer, sender_raw);
    try appendForwardPayloadJson(&writer.writer, &forward_payload);
    try writer.writer.writeByte('}');
    return try writer.toOwnedSlice();
}

fn decodeJettonBurnJsonAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror![]u8 {
    const query_id = try slice.loadUint(64);
    const amount = try slice.loadCoins();
    const response_destination = try slice.loadAddress();
    const has_custom_payload = try loadMaybeRefCell(slice);

    const response_destination_raw = try address.formatRaw(allocator, &response_destination);
    defer allocator.free(response_destination_raw);

    return std.fmt.allocPrint(
        allocator,
        "{{\"query_id\":{d},\"amount\":{d},\"response_destination\":\"{s}\",\"custom_payload_ref\":{s}}}",
        .{
            query_id,
            amount,
            response_destination_raw,
            if (has_custom_payload) "true" else "false",
        },
    );
}

fn decodeNftTransferJsonAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror![]u8 {
    const query_id = try slice.loadUint(64);
    const new_owner = try slice.loadAddress();
    const response_destination = try slice.loadAddress();
    const has_custom_payload = try loadMaybeRefCell(slice);
    const forward_amount = try slice.loadCoins();
    var forward_payload = try loadEitherPayloadTextAlloc(allocator, slice);
    defer forward_payload.deinit(allocator);

    const new_owner_raw = try address.formatRaw(allocator, &new_owner);
    defer allocator.free(new_owner_raw);
    const response_destination_raw = try address.formatRaw(allocator, &response_destination);
    defer allocator.free(response_destination_raw);

    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("{\"query_id\":");
    try writer.writer.print("{d}", .{query_id});
    try writer.writer.writeAll(",\"new_owner\":");
    try writeJsonString(&writer.writer, new_owner_raw);
    try writer.writer.writeAll(",\"response_destination\":");
    try writeJsonString(&writer.writer, response_destination_raw);
    try writer.writer.writeAll(",\"custom_payload_ref\":");
    try writer.writer.writeAll(if (has_custom_payload) "true" else "false");
    try writer.writer.writeAll(",\"forward_amount\":");
    try writer.writer.print("{d}", .{forward_amount});
    try appendForwardPayloadJson(&writer.writer, &forward_payload);
    try writer.writer.writeByte('}');
    return try writer.toOwnedSlice();
}

fn buildTransferLikeJsonAlloc(
    allocator: std.mem.Allocator,
    query_id: u64,
    amount: u64,
    first_addr_name: []const u8,
    first_addr_value: []const u8,
    second_addr_name: []const u8,
    second_addr_value: []const u8,
    has_custom_payload: bool,
    forward_ton_amount: u64,
    forward_payload: *const PayloadText,
) anyerror![]u8 {
    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("{\"query_id\":");
    try writer.writer.print("{d}", .{query_id});
    try writer.writer.writeAll(",\"amount\":");
    try writer.writer.print("{d}", .{amount});
    try writer.writer.writeByte(',');
    try writeJsonString(&writer.writer, first_addr_name);
    try writer.writer.writeByte(':');
    try writeJsonString(&writer.writer, first_addr_value);
    try writer.writer.writeByte(',');
    try writeJsonString(&writer.writer, second_addr_name);
    try writer.writer.writeByte(':');
    try writeJsonString(&writer.writer, second_addr_value);
    try writer.writer.writeAll(",\"custom_payload_ref\":");
    try writer.writer.writeAll(if (has_custom_payload) "true" else "false");
    try writer.writer.writeAll(",\"forward_ton_amount\":");
    try writer.writer.print("{d}", .{forward_ton_amount});
    try appendForwardPayloadJson(&writer.writer, forward_payload);
    try writer.writer.writeByte('}');
    return try writer.toOwnedSlice();
}

fn appendForwardPayloadJson(writer: anytype, payload: *const PayloadText) anyerror!void {
    try writer.writeAll(",\"forward_comment\":");
    if (payload.comment) |value| {
        try writeJsonString(writer, value);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"forward_utf8_tail\":");
    if (payload.tail_utf8) |value| {
        try writeJsonString(writer, value);
    } else {
        try writer.writeAll("null");
    }
}

fn buildSimpleStringJsonAlloc(allocator: std.mem.Allocator, field_name: []const u8, value: []const u8) anyerror![]u8 {
    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeByte('{');
    try writeJsonString(&writer.writer, field_name);
    try writer.writer.writeByte(':');
    try writeJsonString(&writer.writer, value);
    try writer.writer.writeByte('}');
    return try writer.toOwnedSlice();
}

fn writeJsonString(writer: anytype, value: []const u8) anyerror!void {
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

fn maybeFlattenUtf8CellAlloc(allocator: std.mem.Allocator, root: *const cell.Cell) !?[]u8 {
    var slice = @constCast(root).toSlice();
    return maybeFlattenUtf8TailAlloc(allocator, &slice);
}

fn maybeFlattenUtf8TailAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) !?[]u8 {
    var tail = slice.*;
    const bytes = flattenSnakeTailBytesAlloc(allocator, &tail) catch return null;
    errdefer allocator.free(bytes);

    if (bytes.len == 0 or !std.unicode.utf8ValidateSlice(bytes)) {
        allocator.free(bytes);
        return null;
    }
    return bytes;
}

fn flattenSnakeTailBytesAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) ![]u8 {
    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    try appendSnakeSliceBytes(&writer.writer, slice);
    return try writer.toOwnedSlice();
}

fn appendSnakeSliceBytes(writer: anytype, slice: *cell.Slice) !void {
    if (slice.remainingBits() % 8 != 0) return error.InvalidSnakeData;
    if (slice.remainingRefs() > 1) return error.InvalidSnakeData;

    while (slice.remainingBits() > 0) {
        try writer.writeByte(try slice.loadUint8());
    }

    if (slice.remainingRefs() == 1) {
        const next = try slice.loadRef();
        if (next.bit_len % 8 != 0 or next.ref_cnt > 1) return error.InvalidSnakeData;
        var next_slice = next.toSlice();
        try appendSnakeSliceBytes(writer, &next_slice);
    }
}

fn loadUintDynamic(slice: *cell.Slice, bits: u16) !u64 {
    if (bits > 64) return error.UnsupportedAbiType;
    if (slice.remainingBits() < bits) return error.NotEnoughData;
    if (bits == 0) return 0;

    var result: u64 = 0;
    var idx: u16 = 0;
    while (idx < bits) : (idx += 1) {
        result = (result << 1) | try slice.loadUint(1);
    }
    return result;
}

test "body inspector extracts opcode and utf8 tail" {
    const allocator = std.testing.allocator;

    var builder = cell.Builder.init();
    try builder.storeUint(0x11223344, 32);
    try builder.storeBits("ping", 32);
    const body = try builder.toCell(allocator);
    defer body.deinit(allocator);

    var analysis = try inspectBodyCellAlloc(allocator, body);
    defer analysis.deinit(allocator);

    try std.testing.expectEqual(@as(?u32, 0x11223344), analysis.opcode);
    try std.testing.expectEqualStrings("ping", analysis.tail_utf8.?);
    try std.testing.expect(analysis.comment == null);
}

test "body inspector extracts snake comment after zero opcode" {
    const allocator = std.testing.allocator;

    var tail_builder = cell.Builder.init();
    try tail_builder.storeBits("lo", 16);
    const tail = try tail_builder.toCell(allocator);

    var root_builder = cell.Builder.init();
    try root_builder.storeUint(0, 32);
    try root_builder.storeBits("hel", 24);
    try root_builder.storeRef(tail);
    const body = try root_builder.toCell(allocator);
    defer body.deinit(allocator);

    var analysis = try inspectBodyCellAlloc(allocator, body);
    defer analysis.deinit(allocator);

    try std.testing.expectEqual(@as(?u32, 0), analysis.opcode);
    try std.testing.expectEqualStrings("comment", analysis.opcode_name.?);
    try std.testing.expectEqualStrings("hello", analysis.comment.?);
    try std.testing.expectEqualStrings("{\"comment\":\"hello\"}", analysis.decoded_json.?);
    try std.testing.expect(analysis.tail_utf8 == null);
}

test "body inspector best-effort decodes jetton transfer" {
    const allocator = std.testing.allocator;

    var payload_builder = cell.Builder.init();
    try payload_builder.storeUint(0, 32);
    try payload_builder.storeBits("memo", 32);
    const payload = try payload_builder.toCell(allocator);
    defer payload.deinit(allocator);
    const payload_boc = try boc.serializeBoc(allocator, payload);
    defer allocator.free(payload_boc);

    const body_boc = try @import("../contract/jetton.zig").createTransferMessage(
        allocator,
        7,
        1234,
        "0:1111111111111111111111111111111111111111111111111111111111111111",
        "0:2222222222222222222222222222222222222222222222222222222222222222",
        null,
        99,
        payload_boc,
    );
    defer allocator.free(body_boc);

    var analysis = try inspectBodyBocAlloc(allocator, body_boc);
    defer analysis.deinit(allocator);

    try std.testing.expectEqual(@as(?u32, op_jetton_transfer), analysis.opcode);
    try std.testing.expectEqualStrings("jetton_transfer", analysis.opcode_name.?);
    try std.testing.expect(analysis.decoded_json != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"query_id\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"amount\":1234") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"forward_ton_amount\":99") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"forward_comment\":\"memo\"") != null);
}

test "body inspector best-effort decodes nft transfer" {
    const allocator = std.testing.allocator;

    var payload_builder = cell.Builder.init();
    try payload_builder.storeUint(0, 32);
    try payload_builder.storeBits("gift", 32);
    const payload = try payload_builder.toCell(allocator);

    var builder = cell.Builder.init();
    try builder.storeUint(op_nft_transfer, 32);
    try builder.storeUint(9, 64);
    try builder.storeAddress(@as([]const u8, "0:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"));
    try builder.storeAddress(@as([]const u8, "0:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"));
    try builder.storeUint(0, 1);
    try builder.storeCoins(11);
    try builder.storeUint(1, 1);
    try builder.storeRef(payload);
    const body = try builder.toCell(allocator);
    defer body.deinit(allocator);
    const body_boc = try boc.serializeBoc(allocator, body);
    defer allocator.free(body_boc);

    var analysis = try inspectBodyBocAlloc(allocator, body_boc);
    defer analysis.deinit(allocator);

    try std.testing.expectEqual(@as(?u32, op_nft_transfer), analysis.opcode);
    try std.testing.expectEqualStrings("nft_transfer", analysis.opcode_name.?);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"query_id\":9") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"forward_amount\":11") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"forward_comment\":\"gift\"") != null);
}
