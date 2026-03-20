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
const op_excesses: u32 = 0xD53276DB;
const op_jetton_provide_wallet_address: u32 = 0x2C76B973;
const op_jetton_take_wallet_address: u32 = 0xD1735400;
const op_jetton_transfer: u32 = 0x0F8A7EA5;
const op_jetton_internal_transfer: u32 = 0x178D4519;
const op_jetton_transfer_notification: u32 = 0x7362D09C;
const op_jetton_burn: u32 = 0x595F07BC;
const op_jetton_burn_notification: u32 = 0x7BDD97DE;
const op_nft_get_static_data: u32 = 0x2FCB26A2;
const op_nft_report_static_data: u32 = 0x8B771735;
const op_nft_get_royalty_params: u32 = 0x693D3950;
const op_nft_report_royalty_params: u32 = 0xA8CB00AD;
const op_sbt_prove_ownership: u32 = 0x04DED148;
const op_sbt_request_owner: u32 = 0xD0C3BFEA;
const op_sbt_destroy: u32 = 0x1F04537A;
const op_sbt_revoke: u32 = 0x6F89F5E3;
const op_sbt_ownership_proof: u32 = 0x0524C7AE;
const op_sbt_owner_info: u32 = 0x0DD607E3;
const op_nft_transfer: u32 = 0x5FCC3D14;
const op_nft_ownership_assigned: u32 = 0x05138D91;

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
        op_excesses => "excesses",
        op_jetton_provide_wallet_address => "jetton_provide_wallet_address",
        op_jetton_take_wallet_address => "jetton_take_wallet_address",
        op_jetton_transfer => "jetton_transfer",
        op_jetton_internal_transfer => "jetton_internal_transfer",
        op_jetton_transfer_notification => "jetton_transfer_notification",
        op_jetton_burn => "jetton_burn",
        op_jetton_burn_notification => "jetton_burn_notification",
        op_nft_get_static_data => "nft_get_static_data",
        op_nft_report_static_data => "nft_report_static_data",
        op_nft_get_royalty_params => "nft_get_royalty_params",
        op_nft_report_royalty_params => "nft_report_royalty_params",
        op_sbt_prove_ownership => "sbt_prove_ownership",
        op_sbt_request_owner => "sbt_request_owner",
        op_sbt_destroy => "sbt_destroy",
        op_sbt_revoke => "sbt_revoke",
        op_sbt_ownership_proof => "sbt_ownership_proof",
        op_sbt_owner_info => "sbt_owner_info",
        op_nft_transfer => "nft_transfer",
        op_nft_ownership_assigned => "nft_ownership_assigned",
        else => null,
    };
}

fn decodeKnownBodyJsonAlloc(allocator: std.mem.Allocator, opcode: u32, slice: *cell.Slice) anyerror!?[]u8 {
    return switch (opcode) {
        op_excesses => try decodeExcessesJsonAlloc(allocator, slice),
        op_jetton_provide_wallet_address => try decodeJettonProvideWalletAddressJsonAlloc(allocator, slice),
        op_jetton_take_wallet_address => try decodeJettonTakeWalletAddressJsonAlloc(allocator, slice),
        op_jetton_transfer => try decodeJettonTransferJsonAlloc(allocator, slice),
        op_jetton_internal_transfer => try decodeJettonInternalTransferJsonAlloc(allocator, slice),
        op_jetton_transfer_notification => try decodeJettonTransferNotificationJsonAlloc(allocator, slice),
        op_jetton_burn => try decodeJettonBurnJsonAlloc(allocator, slice),
        op_jetton_burn_notification => try decodeJettonBurnNotificationJsonAlloc(allocator, slice),
        op_nft_get_static_data => try decodeNftGetStaticDataJsonAlloc(allocator, slice),
        op_nft_report_static_data => try decodeNftReportStaticDataJsonAlloc(allocator, slice),
        op_nft_get_royalty_params => try decodeNftGetRoyaltyParamsJsonAlloc(allocator, slice),
        op_nft_report_royalty_params => try decodeNftReportRoyaltyParamsJsonAlloc(allocator, slice),
        op_sbt_prove_ownership => try decodeSbtProveOwnershipJsonAlloc(allocator, slice),
        op_sbt_request_owner => try decodeSbtRequestOwnerJsonAlloc(allocator, slice),
        op_sbt_destroy => try decodeSbtDestroyJsonAlloc(allocator, slice),
        op_sbt_revoke => try decodeSbtRevokeJsonAlloc(allocator, slice),
        op_sbt_ownership_proof => try decodeSbtOwnershipProofJsonAlloc(allocator, slice),
        op_sbt_owner_info => try decodeSbtOwnerInfoJsonAlloc(allocator, slice),
        op_nft_transfer => try decodeNftTransferJsonAlloc(allocator, slice),
        op_nft_ownership_assigned => try decodeNftOwnershipAssignedJsonAlloc(allocator, slice),
        else => null,
    };
}

const PayloadAnalysis = struct {
    comment: ?[]u8 = null,
    tail_utf8: ?[]u8 = null,
    boc_base64: ?[]u8 = null,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.comment) |value| allocator.free(value);
        if (self.tail_utf8) |value| allocator.free(value);
        if (self.boc_base64) |value| allocator.free(value);
        self.* = .{};
    }
};

const MaybePayloadRef = struct {
    present: bool = false,
    boc_base64: ?[]u8 = null,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.boc_base64) |value| allocator.free(value);
        self.* = .{};
    }
};

fn inspectPayloadCellAlloc(allocator: std.mem.Allocator, value: *const cell.Cell) anyerror!PayloadAnalysis {
    var nested = try inspectBodyCellAlloc(allocator, value);
    defer nested.deinit(allocator);

    return .{
        .comment = if (nested.comment) |text| try allocator.dupe(u8, text) else null,
        .tail_utf8 = if (nested.tail_utf8) |text| try allocator.dupe(u8, text) else null,
        .boc_base64 = try serializeCellBocBase64Alloc(allocator, value),
    };
}

fn inspectPayloadSliceAlloc(allocator: std.mem.Allocator, payload: *cell.Slice) anyerror!PayloadAnalysis {
    var slice_value = payload.*;
    if (slice_value.remainingBits() == 0 and slice_value.remainingRefs() == 0) return .{};

    const boc_base64 = try serializeSliceBocBase64Alloc(allocator, &slice_value);
    errdefer allocator.free(boc_base64);

    if (slice_value.remainingBits() < 32) {
        return .{
            .tail_utf8 = try maybeFlattenUtf8TailAlloc(allocator, &slice_value),
            .boc_base64 = boc_base64,
        };
    }

    const opcode: u32 = @intCast(try loadUintDynamic(&slice_value, 32));
    if (opcode == op_comment) {
        return .{
            .comment = try maybeFlattenUtf8TailAlloc(allocator, &slice_value),
            .boc_base64 = boc_base64,
        };
    }
    return .{
        .tail_utf8 = try maybeFlattenUtf8TailAlloc(allocator, &slice_value),
        .boc_base64 = boc_base64,
    };
}

fn loadMaybeRefPayloadAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror!MaybePayloadRef {
    const has_ref = (try slice.loadUint(1)) == 1;
    if (!has_ref) return .{};

    const payload = try slice.loadRef();
    return .{
        .present = true,
        .boc_base64 = try serializeCellBocBase64Alloc(allocator, payload),
    };
}

fn loadMaybeRefAddressRawAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror!?[]u8 {
    const has_ref = (try slice.loadUint(1)) == 1;
    if (!has_ref) return null;

    const payload = try slice.loadRef();
    var payload_slice = payload.toSlice();
    const addr = try payload_slice.loadAddress();
    return try address.formatRaw(allocator, &addr);
}

fn loadEitherPayloadAnalysisAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror!PayloadAnalysis {
    const is_ref = (try slice.loadUint(1)) == 1;
    if (is_ref) {
        const payload = try slice.loadRef();
        return inspectPayloadCellAlloc(allocator, payload);
    }
    return inspectPayloadSliceAlloc(allocator, slice);
}

fn loadRequiredRefPayloadAnalysisAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror!PayloadAnalysis {
    const payload = try slice.loadRef();
    return inspectPayloadCellAlloc(allocator, payload);
}

fn decodeExcessesJsonAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror![]u8 {
    const query_id = try slice.loadUint(64);

    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("{\"query_id\":");
    try writer.writer.print("{d}", .{query_id});
    try writer.writer.writeByte('}');
    return try writer.toOwnedSlice();
}

fn decodeJettonProvideWalletAddressJsonAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror![]u8 {
    const query_id = try slice.loadUint(64);
    const owner_address = try slice.loadAddress();
    const include_address = (try slice.loadUint(1)) == 1;

    const owner_raw = try address.formatRaw(allocator, &owner_address);
    defer allocator.free(owner_raw);

    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("{\"query_id\":");
    try writer.writer.print("{d}", .{query_id});
    try writer.writer.writeAll(",\"owner_address\":");
    try writeJsonString(&writer.writer, owner_raw);
    try writer.writer.writeAll(",\"include_address\":");
    try writer.writer.writeAll(if (include_address) "true" else "false");
    try writer.writer.writeByte('}');
    return try writer.toOwnedSlice();
}

fn decodeJettonTakeWalletAddressJsonAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror![]u8 {
    const query_id = try slice.loadUint(64);
    const wallet_address = try slice.loadAddress();
    const owner_address = try loadMaybeRefAddressRawAlloc(allocator, slice);
    defer if (owner_address) |value| allocator.free(value);

    const wallet_raw = try address.formatRaw(allocator, &wallet_address);
    defer allocator.free(wallet_raw);

    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("{\"query_id\":");
    try writer.writer.print("{d}", .{query_id});
    try writer.writer.writeAll(",\"wallet_address\":");
    try writeJsonString(&writer.writer, wallet_raw);
    try writer.writer.writeAll(",\"owner_address\":");
    if (owner_address) |value| {
        try writeJsonString(&writer.writer, value);
    } else {
        try writer.writer.writeAll("null");
    }
    try writer.writer.writeByte('}');
    return try writer.toOwnedSlice();
}

fn decodeJettonTransferJsonAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror![]u8 {
    const query_id = try slice.loadUint(64);
    const amount = try slice.loadCoins();
    const destination = try slice.loadAddress();
    const response_destination = try slice.loadAddress();
    var custom_payload = try loadMaybeRefPayloadAlloc(allocator, slice);
    defer custom_payload.deinit(allocator);
    const forward_ton_amount = try slice.loadCoins();
    var forward_payload = try loadEitherPayloadAnalysisAlloc(allocator, slice);
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
        &custom_payload,
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
    var forward_payload = try loadEitherPayloadAnalysisAlloc(allocator, slice);
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
        null,
        forward_ton_amount,
        &forward_payload,
    );
}

fn decodeJettonTransferNotificationJsonAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror![]u8 {
    const query_id = try slice.loadUint(64);
    const amount = try slice.loadCoins();
    const sender = try slice.loadAddress();
    var forward_payload = try loadEitherPayloadAnalysisAlloc(allocator, slice);
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
    var custom_payload = try loadMaybeRefPayloadAlloc(allocator, slice);
    defer custom_payload.deinit(allocator);

    const response_destination_raw = try address.formatRaw(allocator, &response_destination);
    defer allocator.free(response_destination_raw);

    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("{\"query_id\":");
    try writer.writer.print("{d}", .{query_id});
    try writer.writer.writeAll(",\"amount\":");
    try writer.writer.print("{d}", .{amount});
    try writer.writer.writeAll(",\"response_destination\":");
    try writeJsonString(&writer.writer, response_destination_raw);
    try appendCustomPayloadJson(&writer.writer, &custom_payload);
    try writer.writer.writeByte('}');
    return try writer.toOwnedSlice();
}

fn decodeJettonBurnNotificationJsonAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror![]u8 {
    const query_id = try slice.loadUint(64);
    const amount = try slice.loadCoins();
    const sender = try slice.loadAddress();
    const response_destination = try slice.loadAddress();

    const sender_raw = try address.formatRaw(allocator, &sender);
    defer allocator.free(sender_raw);
    const response_destination_raw = try address.formatRaw(allocator, &response_destination);
    defer allocator.free(response_destination_raw);

    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("{\"query_id\":");
    try writer.writer.print("{d}", .{query_id});
    try writer.writer.writeAll(",\"amount\":");
    try writer.writer.print("{d}", .{amount});
    try writer.writer.writeAll(",\"sender\":");
    try writeJsonString(&writer.writer, sender_raw);
    try writer.writer.writeAll(",\"response_destination\":");
    try writeJsonString(&writer.writer, response_destination_raw);
    try writer.writer.writeByte('}');
    return try writer.toOwnedSlice();
}

fn decodeNftGetStaticDataJsonAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror![]u8 {
    const query_id = try slice.loadUint(64);

    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("{\"query_id\":");
    try writer.writer.print("{d}", .{query_id});
    try writer.writer.writeByte('}');
    return try writer.toOwnedSlice();
}

fn decodeNftReportStaticDataJsonAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror![]u8 {
    const query_id = try slice.loadUint(64);
    const index = try loadBitsHexTextAlloc(allocator, slice, 256);
    defer allocator.free(index);
    const collection = try slice.loadAddress();
    const collection_raw = try address.formatRaw(allocator, &collection);
    defer allocator.free(collection_raw);

    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("{\"query_id\":");
    try writer.writer.print("{d}", .{query_id});
    try writer.writer.writeAll(",\"index\":");
    try writeJsonString(&writer.writer, index);
    try writer.writer.writeAll(",\"collection\":");
    try writeJsonString(&writer.writer, collection_raw);
    try writer.writer.writeByte('}');
    return try writer.toOwnedSlice();
}

fn decodeNftGetRoyaltyParamsJsonAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror![]u8 {
    const query_id = try slice.loadUint(64);

    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("{\"query_id\":");
    try writer.writer.print("{d}", .{query_id});
    try writer.writer.writeByte('}');
    return try writer.toOwnedSlice();
}

fn decodeNftReportRoyaltyParamsJsonAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror![]u8 {
    const query_id = try slice.loadUint(64);
    const numerator = try slice.loadUint16();
    const denominator = try slice.loadUint16();
    const destination = try slice.loadAddress();
    const destination_raw = try address.formatRaw(allocator, &destination);
    defer allocator.free(destination_raw);

    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("{\"query_id\":");
    try writer.writer.print("{d}", .{query_id});
    try writer.writer.writeAll(",\"numerator\":");
    try writer.writer.print("{d}", .{numerator});
    try writer.writer.writeAll(",\"denominator\":");
    try writer.writer.print("{d}", .{denominator});
    try writer.writer.writeAll(",\"destination\":");
    try writeJsonString(&writer.writer, destination_raw);
    try writer.writer.writeByte('}');
    return try writer.toOwnedSlice();
}

fn decodeSbtProveOwnershipJsonAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror![]u8 {
    const query_id = try slice.loadUint(64);
    const destination = try slice.loadAddress();
    var forward_payload = try loadRequiredRefPayloadAnalysisAlloc(allocator, slice);
    defer forward_payload.deinit(allocator);
    const with_content = (try slice.loadUint(1)) == 1;

    const destination_raw = try address.formatRaw(allocator, &destination);
    defer allocator.free(destination_raw);

    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("{\"query_id\":");
    try writer.writer.print("{d}", .{query_id});
    try writer.writer.writeAll(",\"destination\":");
    try writeJsonString(&writer.writer, destination_raw);
    try appendForwardPayloadJson(&writer.writer, &forward_payload);
    try writer.writer.writeAll(",\"with_content\":");
    try writer.writer.writeAll(if (with_content) "true" else "false");
    try writer.writer.writeByte('}');
    return try writer.toOwnedSlice();
}

fn decodeSbtRequestOwnerJsonAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror![]u8 {
    const query_id = try slice.loadUint(64);
    const destination = try slice.loadAddress();
    var forward_payload = try loadRequiredRefPayloadAnalysisAlloc(allocator, slice);
    defer forward_payload.deinit(allocator);
    const with_content = (try slice.loadUint(1)) == 1;

    const destination_raw = try address.formatRaw(allocator, &destination);
    defer allocator.free(destination_raw);

    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("{\"query_id\":");
    try writer.writer.print("{d}", .{query_id});
    try writer.writer.writeAll(",\"destination\":");
    try writeJsonString(&writer.writer, destination_raw);
    try appendForwardPayloadJson(&writer.writer, &forward_payload);
    try writer.writer.writeAll(",\"with_content\":");
    try writer.writer.writeAll(if (with_content) "true" else "false");
    try writer.writer.writeByte('}');
    return try writer.toOwnedSlice();
}

fn decodeSbtDestroyJsonAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror![]u8 {
    const query_id = try slice.loadUint(64);

    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("{\"query_id\":");
    try writer.writer.print("{d}", .{query_id});
    try writer.writer.writeByte('}');
    return try writer.toOwnedSlice();
}

fn decodeSbtRevokeJsonAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror![]u8 {
    return decodeSbtDestroyJsonAlloc(allocator, slice);
}

fn decodeSbtOwnershipProofJsonAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror![]u8 {
    const query_id = try slice.loadUint(64);
    const item_id = try loadBitsHexTextAlloc(allocator, slice, 256);
    defer allocator.free(item_id);
    const owner = try slice.loadAddress();
    var data_payload = try loadRequiredRefPayloadAnalysisAlloc(allocator, slice);
    defer data_payload.deinit(allocator);
    const revoked_at = try slice.loadUint(64);
    var content_payload = try loadMaybeRefPayloadAlloc(allocator, slice);
    defer content_payload.deinit(allocator);

    const owner_raw = try address.formatRaw(allocator, &owner);
    defer allocator.free(owner_raw);

    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("{\"query_id\":");
    try writer.writer.print("{d}", .{query_id});
    try writer.writer.writeAll(",\"item_id\":");
    try writeJsonString(&writer.writer, item_id);
    try writer.writer.writeAll(",\"owner\":");
    try writeJsonString(&writer.writer, owner_raw);
    try writer.writer.writeAll(",\"data_boc_base64\":");
    if (data_payload.boc_base64) |value| {
        try writeJsonString(&writer.writer, value);
    } else {
        try writer.writer.writeAll("null");
    }
    try writer.writer.writeAll(",\"data_comment\":");
    if (data_payload.comment) |value| {
        try writeJsonString(&writer.writer, value);
    } else {
        try writer.writer.writeAll("null");
    }
    try writer.writer.writeAll(",\"data_utf8_tail\":");
    if (data_payload.tail_utf8) |value| {
        try writeJsonString(&writer.writer, value);
    } else {
        try writer.writer.writeAll("null");
    }
    try writer.writer.writeAll(",\"revoked_at\":");
    try writer.writer.print("{d}", .{revoked_at});
    try writer.writer.writeAll(",\"content_boc_base64\":");
    if (content_payload.boc_base64) |value| {
        try writeJsonString(&writer.writer, value);
    } else {
        try writer.writer.writeAll("null");
    }
    try writer.writer.writeByte('}');
    return try writer.toOwnedSlice();
}

fn decodeSbtOwnerInfoJsonAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror![]u8 {
    const query_id = try slice.loadUint(64);
    const item_id = try loadBitsHexTextAlloc(allocator, slice, 256);
    defer allocator.free(item_id);
    const initiator = try slice.loadAddress();
    const owner = try slice.loadAddress();
    var data_payload = try loadRequiredRefPayloadAnalysisAlloc(allocator, slice);
    defer data_payload.deinit(allocator);
    const revoked_at = try slice.loadUint(64);
    var content_payload = try loadMaybeRefPayloadAlloc(allocator, slice);
    defer content_payload.deinit(allocator);

    const initiator_raw = try address.formatRaw(allocator, &initiator);
    defer allocator.free(initiator_raw);
    const owner_raw = try address.formatRaw(allocator, &owner);
    defer allocator.free(owner_raw);

    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("{\"query_id\":");
    try writer.writer.print("{d}", .{query_id});
    try writer.writer.writeAll(",\"item_id\":");
    try writeJsonString(&writer.writer, item_id);
    try writer.writer.writeAll(",\"initiator\":");
    try writeJsonString(&writer.writer, initiator_raw);
    try writer.writer.writeAll(",\"owner\":");
    try writeJsonString(&writer.writer, owner_raw);
    try writer.writer.writeAll(",\"data_boc_base64\":");
    if (data_payload.boc_base64) |value| {
        try writeJsonString(&writer.writer, value);
    } else {
        try writer.writer.writeAll("null");
    }
    try writer.writer.writeAll(",\"data_comment\":");
    if (data_payload.comment) |value| {
        try writeJsonString(&writer.writer, value);
    } else {
        try writer.writer.writeAll("null");
    }
    try writer.writer.writeAll(",\"data_utf8_tail\":");
    if (data_payload.tail_utf8) |value| {
        try writeJsonString(&writer.writer, value);
    } else {
        try writer.writer.writeAll("null");
    }
    try writer.writer.writeAll(",\"revoked_at\":");
    try writer.writer.print("{d}", .{revoked_at});
    try writer.writer.writeAll(",\"content_boc_base64\":");
    if (content_payload.boc_base64) |value| {
        try writeJsonString(&writer.writer, value);
    } else {
        try writer.writer.writeAll("null");
    }
    try writer.writer.writeByte('}');
    return try writer.toOwnedSlice();
}

fn decodeNftTransferJsonAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror![]u8 {
    const query_id = try slice.loadUint(64);
    const new_owner = try slice.loadAddress();
    const response_destination = try slice.loadAddress();
    var custom_payload = try loadMaybeRefPayloadAlloc(allocator, slice);
    defer custom_payload.deinit(allocator);
    const forward_amount = try slice.loadCoins();
    var forward_payload = try loadEitherPayloadAnalysisAlloc(allocator, slice);
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
    try appendCustomPayloadJson(&writer.writer, &custom_payload);
    try writer.writer.writeAll(",\"forward_amount\":");
    try writer.writer.print("{d}", .{forward_amount});
    try appendForwardPayloadJson(&writer.writer, &forward_payload);
    try writer.writer.writeByte('}');
    return try writer.toOwnedSlice();
}

fn decodeNftOwnershipAssignedJsonAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) anyerror![]u8 {
    const query_id = try slice.loadUint(64);
    const prev_owner = try slice.loadAddress();
    var forward_payload = try loadEitherPayloadAnalysisAlloc(allocator, slice);
    defer forward_payload.deinit(allocator);

    const prev_owner_raw = try address.formatRaw(allocator, &prev_owner);
    defer allocator.free(prev_owner_raw);

    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("{\"query_id\":");
    try writer.writer.print("{d}", .{query_id});
    try writer.writer.writeAll(",\"prev_owner\":");
    try writeJsonString(&writer.writer, prev_owner_raw);
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
    custom_payload: ?*const MaybePayloadRef,
    forward_ton_amount: u64,
    forward_payload: *const PayloadAnalysis,
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
    if (custom_payload) |payload| {
        try appendCustomPayloadJson(&writer.writer, payload);
    }
    try writer.writer.writeAll(",\"forward_ton_amount\":");
    try writer.writer.print("{d}", .{forward_ton_amount});
    try appendForwardPayloadJson(&writer.writer, forward_payload);
    try writer.writer.writeByte('}');
    return try writer.toOwnedSlice();
}

fn appendCustomPayloadJson(writer: anytype, payload: *const MaybePayloadRef) anyerror!void {
    try writer.writeAll(",\"custom_payload_ref\":");
    try writer.writeAll(if (payload.present) "true" else "false");
    try writer.writeAll(",\"custom_payload_boc_base64\":");
    if (payload.boc_base64) |value| {
        try writeJsonString(writer, value);
    } else {
        try writer.writeAll("null");
    }
}

fn appendForwardPayloadJson(writer: anytype, payload: *const PayloadAnalysis) anyerror!void {
    try writer.writeAll(",\"forward_payload_boc_base64\":");
    if (payload.boc_base64) |value| {
        try writeJsonString(writer, value);
    } else {
        try writer.writeAll("null");
    }
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

fn serializeCellBocBase64Alloc(allocator: std.mem.Allocator, value: *const cell.Cell) ![]u8 {
    const payload_boc = try boc.serializeBoc(allocator, @constCast(value));
    defer allocator.free(payload_boc);

    const encoded_len = std.base64.standard.Encoder.calcSize(payload_boc.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    errdefer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, payload_boc);
    return encoded;
}

fn serializeSliceBocBase64Alloc(allocator: std.mem.Allocator, slice: *cell.Slice) ![]u8 {
    var builder = cell.Builder.init();
    var copy = slice.*;
    try builder.storeSlice(&copy);

    const payload_cell = try builder.toCell(allocator);
    defer payload_cell.deinit(allocator);
    return serializeCellBocBase64Alloc(allocator, payload_cell);
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

fn loadBitsHexTextAlloc(allocator: std.mem.Allocator, slice: *cell.Slice, bits: u16) ![]u8 {
    if (bits % 8 != 0) return error.UnsupportedAbiType;
    const bytes = try slice.loadBits(bits);
    return formatHexTextAlloc(allocator, trimLeadingZeroBytesView(bytes));
}

fn trimLeadingZeroBytesView(bytes: []const u8) []const u8 {
    var start: usize = 0;
    while (start < bytes.len and bytes[start] == 0) : (start += 1) {}
    return bytes[start..];
}

fn formatHexTextAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (bytes.len == 0) return allocator.dupe(u8, "0x0");

    const hi_nibble = bytes[0] >> 4;
    const prefix_digits: usize = if (hi_nibble == 0) 1 else 2;
    const total_len: usize = 2 + prefix_digits + (bytes.len - 1) * 2;
    const out = try allocator.alloc(u8, total_len);
    errdefer allocator.free(out);

    out[0] = '0';
    out[1] = 'x';

    var idx: usize = 2;
    if (hi_nibble != 0) {
        out[idx] = lowerHexChar(hi_nibble);
        idx += 1;
    }
    out[idx] = lowerHexChar(bytes[0] & 0x0F);
    idx += 1;

    for (bytes[1..]) |byte| {
        out[idx] = lowerHexChar(byte >> 4);
        out[idx + 1] = lowerHexChar(byte & 0x0F);
        idx += 2;
    }
    return out;
}

fn lowerHexChar(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + (value - 10);
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
    const payload_b64 = try serializeCellBocBase64Alloc(allocator, payload);
    defer allocator.free(payload_b64);

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
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"forward_payload_boc_base64\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, payload_b64) != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"forward_comment\":\"memo\"") != null);
}

test "body inspector preserves custom payload boc in jetton burn" {
    const allocator = std.testing.allocator;

    var payload_builder = cell.Builder.init();
    try payload_builder.storeUint(0xCAFE, 16);
    const payload = try payload_builder.toCell(allocator);
    defer payload.deinit(allocator);
    const payload_boc = try boc.serializeBoc(allocator, payload);
    defer allocator.free(payload_boc);
    const payload_b64 = try serializeCellBocBase64Alloc(allocator, payload);
    defer allocator.free(payload_b64);

    const body_boc = try @import("../contract/jetton.zig").createBurnMessage(
        allocator,
        8,
        777,
        "0:2222222222222222222222222222222222222222222222222222222222222222",
        payload_boc,
    );
    defer allocator.free(body_boc);

    var analysis = try inspectBodyBocAlloc(allocator, body_boc);
    defer analysis.deinit(allocator);

    try std.testing.expectEqual(@as(?u32, op_jetton_burn), analysis.opcode);
    try std.testing.expectEqualStrings("jetton_burn", analysis.opcode_name.?);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"custom_payload_ref\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"custom_payload_boc_base64\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, payload_b64) != null);
}

test "body inspector best-effort decodes nft transfer" {
    const allocator = std.testing.allocator;

    var payload_builder = cell.Builder.init();
    try payload_builder.storeUint(0, 32);
    try payload_builder.storeBits("gift", 32);
    const payload = try payload_builder.toCell(allocator);
    const payload_b64 = try serializeCellBocBase64Alloc(allocator, payload);
    defer allocator.free(payload_b64);

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
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"forward_payload_boc_base64\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, payload_b64) != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"forward_comment\":\"gift\"") != null);
}

test "body inspector best-effort decodes excesses" {
    const allocator = std.testing.allocator;

    const body_boc = try @import("../contract/standard_body.zig").createExcessesMessage(allocator, 44);
    defer allocator.free(body_boc);

    var analysis = try inspectBodyBocAlloc(allocator, body_boc);
    defer analysis.deinit(allocator);

    try std.testing.expectEqual(@as(?u32, op_excesses), analysis.opcode);
    try std.testing.expectEqualStrings("excesses", analysis.opcode_name.?);
    try std.testing.expectEqualStrings("{\"query_id\":44}", analysis.decoded_json.?);
}

test "body inspector best-effort decodes jetton provide wallet address" {
    const allocator = std.testing.allocator;

    const body_boc = try @import("../contract/standard_body.zig").createJettonProvideWalletAddressMessage(
        allocator,
        12,
        "0:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        true,
    );
    defer allocator.free(body_boc);

    var analysis = try inspectBodyBocAlloc(allocator, body_boc);
    defer analysis.deinit(allocator);

    try std.testing.expectEqual(@as(?u32, op_jetton_provide_wallet_address), analysis.opcode);
    try std.testing.expectEqualStrings("jetton_provide_wallet_address", analysis.opcode_name.?);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"query_id\":12") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"include_address\":true") != null);
}

test "body inspector best-effort decodes jetton take wallet address" {
    const allocator = std.testing.allocator;

    const body_boc = try @import("../contract/standard_body.zig").createJettonTakeWalletAddressMessage(
        allocator,
        13,
        "0:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
        "0:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    );
    defer allocator.free(body_boc);

    var analysis = try inspectBodyBocAlloc(allocator, body_boc);
    defer analysis.deinit(allocator);

    try std.testing.expectEqual(@as(?u32, op_jetton_take_wallet_address), analysis.opcode);
    try std.testing.expectEqualStrings("jetton_take_wallet_address", analysis.opcode_name.?);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"wallet_address\":\"0:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"owner_address\":\"0:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"") != null);
}

test "body inspector best-effort decodes jetton burn notification" {
    const allocator = std.testing.allocator;

    const body_boc = try @import("../contract/standard_body.zig").createJettonBurnNotificationMessage(
        allocator,
        17,
        333,
        "0:1111111111111111111111111111111111111111111111111111111111111111",
        "0:2222222222222222222222222222222222222222222222222222222222222222",
    );
    defer allocator.free(body_boc);

    var analysis = try inspectBodyBocAlloc(allocator, body_boc);
    defer analysis.deinit(allocator);

    try std.testing.expectEqual(@as(?u32, op_jetton_burn_notification), analysis.opcode);
    try std.testing.expectEqualStrings("jetton_burn_notification", analysis.opcode_name.?);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"query_id\":17") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"amount\":333") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"sender\":\"0:1111111111111111111111111111111111111111111111111111111111111111\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"response_destination\":\"0:2222222222222222222222222222222222222222222222222222222222222222\"") != null);
}

test "body inspector best-effort decodes nft get static data" {
    const allocator = std.testing.allocator;

    const body_boc = try @import("../contract/standard_body.zig").createNftGetStaticDataMessage(allocator, 18);
    defer allocator.free(body_boc);

    var analysis = try inspectBodyBocAlloc(allocator, body_boc);
    defer analysis.deinit(allocator);

    try std.testing.expectEqual(@as(?u32, op_nft_get_static_data), analysis.opcode);
    try std.testing.expectEqualStrings("nft_get_static_data", analysis.opcode_name.?);
    try std.testing.expectEqualStrings("{\"query_id\":18}", analysis.decoded_json.?);
}

test "body inspector best-effort decodes nft report static data" {
    const allocator = std.testing.allocator;

    const body_boc = try @import("../contract/standard_body.zig").createNftReportStaticDataMessage(
        allocator,
        19,
        &.{ 0x12, 0x34 },
        "0:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
    );
    defer allocator.free(body_boc);

    var analysis = try inspectBodyBocAlloc(allocator, body_boc);
    defer analysis.deinit(allocator);

    try std.testing.expectEqual(@as(?u32, op_nft_report_static_data), analysis.opcode);
    try std.testing.expectEqualStrings("nft_report_static_data", analysis.opcode_name.?);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"index\":\"0x1234\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"collection\":\"0:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"") != null);
}

test "body inspector best-effort decodes nft get royalty params" {
    const allocator = std.testing.allocator;

    const body_boc = try @import("../contract/standard_body.zig").createNftGetRoyaltyParamsMessage(allocator, 20);
    defer allocator.free(body_boc);

    var analysis = try inspectBodyBocAlloc(allocator, body_boc);
    defer analysis.deinit(allocator);

    try std.testing.expectEqual(@as(?u32, op_nft_get_royalty_params), analysis.opcode);
    try std.testing.expectEqualStrings("nft_get_royalty_params", analysis.opcode_name.?);
    try std.testing.expectEqualStrings("{\"query_id\":20}", analysis.decoded_json.?);
}

test "body inspector best-effort decodes nft report royalty params" {
    const allocator = std.testing.allocator;

    const body_boc = try @import("../contract/standard_body.zig").createNftReportRoyaltyParamsMessage(
        allocator,
        21,
        25,
        1000,
        "0:DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD",
    );
    defer allocator.free(body_boc);

    var analysis = try inspectBodyBocAlloc(allocator, body_boc);
    defer analysis.deinit(allocator);

    try std.testing.expectEqual(@as(?u32, op_nft_report_royalty_params), analysis.opcode);
    try std.testing.expectEqualStrings("nft_report_royalty_params", analysis.opcode_name.?);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"numerator\":25") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"denominator\":1000") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"destination\":\"0:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"") != null);
}

test "body inspector best-effort decodes sbt prove ownership" {
    const allocator = std.testing.allocator;

    const forward_payload = try @import("../contract/standard_body.zig").buildCommentBodyBocAlloc(allocator, "prove");
    defer allocator.free(forward_payload);

    const body_boc = try @import("../contract/standard_body.zig").createSbtProveOwnershipMessage(
        allocator,
        22,
        "0:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        forward_payload,
        true,
    );
    defer allocator.free(body_boc);

    var analysis = try inspectBodyBocAlloc(allocator, body_boc);
    defer analysis.deinit(allocator);

    try std.testing.expectEqual(@as(?u32, op_sbt_prove_ownership), analysis.opcode);
    try std.testing.expectEqualStrings("sbt_prove_ownership", analysis.opcode_name.?);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"forward_comment\":\"prove\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"with_content\":true") != null);
}

test "body inspector best-effort decodes sbt destroy and revoke" {
    const allocator = std.testing.allocator;

    const destroy_boc = try @import("../contract/standard_body.zig").createSbtDestroyMessage(allocator, 23);
    defer allocator.free(destroy_boc);
    var destroy_analysis = try inspectBodyBocAlloc(allocator, destroy_boc);
    defer destroy_analysis.deinit(allocator);
    try std.testing.expectEqualStrings("sbt_destroy", destroy_analysis.opcode_name.?);

    const revoke_boc = try @import("../contract/standard_body.zig").createSbtRevokeMessage(allocator, 24);
    defer allocator.free(revoke_boc);
    var revoke_analysis = try inspectBodyBocAlloc(allocator, revoke_boc);
    defer revoke_analysis.deinit(allocator);
    try std.testing.expectEqualStrings("sbt_revoke", revoke_analysis.opcode_name.?);
}

test "body inspector best-effort decodes sbt ownership proof and owner info" {
    const allocator = std.testing.allocator;

    const data_boc = try @import("../contract/standard_body.zig").buildCommentBodyBocAlloc(allocator, "proof");
    defer allocator.free(data_boc);

    const ownership_boc = try @import("../contract/standard_body.zig").createSbtOwnershipProofMessage(
        allocator,
        25,
        &.{ 0x12, 0x34 },
        "0:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        data_boc,
        55,
        null,
    );
    defer allocator.free(ownership_boc);

    var ownership_analysis = try inspectBodyBocAlloc(allocator, ownership_boc);
    defer ownership_analysis.deinit(allocator);
    try std.testing.expectEqualStrings("sbt_ownership_proof", ownership_analysis.opcode_name.?);
    try std.testing.expect(std.mem.indexOf(u8, ownership_analysis.decoded_json.?, "\"item_id\":\"0x1234\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ownership_analysis.decoded_json.?, "\"data_comment\":\"proof\"") != null);

    const owner_info_boc = try @import("../contract/standard_body.zig").createSbtOwnerInfoMessage(
        allocator,
        26,
        &.{ 0x12, 0x34 },
        "0:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "0:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
        data_boc,
        56,
        null,
    );
    defer allocator.free(owner_info_boc);

    var owner_info_analysis = try inspectBodyBocAlloc(allocator, owner_info_boc);
    defer owner_info_analysis.deinit(allocator);
    try std.testing.expectEqualStrings("sbt_owner_info", owner_info_analysis.opcode_name.?);
    try std.testing.expect(std.mem.indexOf(u8, owner_info_analysis.decoded_json.?, "\"owner\":\"0:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, owner_info_analysis.decoded_json.?, "\"data_comment\":\"proof\"") != null);
}

test "body inspector best-effort decodes nft ownership assigned" {
    const allocator = std.testing.allocator;

    const forward_payload = try @import("../contract/standard_body.zig").buildCommentBodyBocAlloc(allocator, "assigned");
    defer allocator.free(forward_payload);

    const body_boc = try @import("../contract/standard_body.zig").createNftOwnershipAssignedMessage(
        allocator,
        5,
        "0:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        forward_payload,
    );
    defer allocator.free(body_boc);

    var analysis = try inspectBodyBocAlloc(allocator, body_boc);
    defer analysis.deinit(allocator);

    try std.testing.expectEqual(@as(?u32, op_nft_ownership_assigned), analysis.opcode);
    try std.testing.expectEqualStrings("nft_ownership_assigned", analysis.opcode_name.?);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"query_id\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"prev_owner\":\"0:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"forward_comment\":\"assigned\"") != null);
}
