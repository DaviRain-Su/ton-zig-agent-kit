const std = @import("std");
const abi_adapter = @import("abi_adapter.zig");
const boc = @import("../core/boc.zig");
const body_builder = @import("../core/body_builder.zig");
const cell = @import("../core/cell.zig");
const jetton = @import("jetton.zig");

pub const StandardBodyKind = enum {
    comment,
    excesses,
    jetton_provide_wallet_address,
    jetton_take_wallet_address,
    jetton_transfer,
    jetton_internal_transfer,
    jetton_transfer_notification,
    jetton_burn,
    jetton_burn_notification,
    nft_get_static_data,
    nft_report_static_data,
    nft_transfer,
    nft_ownership_assigned,
};

pub fn parseKind(text: []const u8) !StandardBodyKind {
    if (std.ascii.eqlIgnoreCase(text, "comment")) return .comment;
    if (std.ascii.eqlIgnoreCase(text, "excesses")) return .excesses;
    if (std.ascii.eqlIgnoreCase(text, "jetton_provide_wallet_address") or std.ascii.eqlIgnoreCase(text, "jetton-provide-wallet-address") or std.ascii.eqlIgnoreCase(text, "provide_wallet_address") or std.ascii.eqlIgnoreCase(text, "provide-wallet-address")) return .jetton_provide_wallet_address;
    if (std.ascii.eqlIgnoreCase(text, "jetton_take_wallet_address") or std.ascii.eqlIgnoreCase(text, "jetton-take-wallet-address") or std.ascii.eqlIgnoreCase(text, "take_wallet_address") or std.ascii.eqlIgnoreCase(text, "take-wallet-address")) return .jetton_take_wallet_address;
    if (std.ascii.eqlIgnoreCase(text, "jetton_transfer") or std.ascii.eqlIgnoreCase(text, "jetton-transfer")) return .jetton_transfer;
    if (std.ascii.eqlIgnoreCase(text, "jetton_internal_transfer") or std.ascii.eqlIgnoreCase(text, "jetton-internal-transfer")) return .jetton_internal_transfer;
    if (std.ascii.eqlIgnoreCase(text, "jetton_transfer_notification") or std.ascii.eqlIgnoreCase(text, "jetton-transfer-notification")) return .jetton_transfer_notification;
    if (std.ascii.eqlIgnoreCase(text, "jetton_burn") or std.ascii.eqlIgnoreCase(text, "jetton-burn")) return .jetton_burn;
    if (std.ascii.eqlIgnoreCase(text, "jetton_burn_notification") or std.ascii.eqlIgnoreCase(text, "jetton-burn-notification")) return .jetton_burn_notification;
    if (std.ascii.eqlIgnoreCase(text, "nft_get_static_data") or std.ascii.eqlIgnoreCase(text, "nft-get-static-data") or std.ascii.eqlIgnoreCase(text, "get_static_data") or std.ascii.eqlIgnoreCase(text, "get-static-data")) return .nft_get_static_data;
    if (std.ascii.eqlIgnoreCase(text, "nft_report_static_data") or std.ascii.eqlIgnoreCase(text, "nft-report-static-data") or std.ascii.eqlIgnoreCase(text, "report_static_data") or std.ascii.eqlIgnoreCase(text, "report-static-data")) return .nft_report_static_data;
    if (std.ascii.eqlIgnoreCase(text, "nft_transfer") or std.ascii.eqlIgnoreCase(text, "nft-transfer")) return .nft_transfer;
    if (std.ascii.eqlIgnoreCase(text, "nft_ownership_assigned") or std.ascii.eqlIgnoreCase(text, "nft-ownership-assigned") or std.ascii.eqlIgnoreCase(text, "ownership_assigned") or std.ascii.eqlIgnoreCase(text, "ownership-assigned")) return .nft_ownership_assigned;
    return error.UnknownStandardBodyKind;
}

pub fn kindName(kind: StandardBodyKind) []const u8 {
    return switch (kind) {
        .comment => "comment",
        .excesses => "excesses",
        .jetton_provide_wallet_address => "jetton_provide_wallet_address",
        .jetton_take_wallet_address => "jetton_take_wallet_address",
        .jetton_transfer => "jetton_transfer",
        .jetton_internal_transfer => "jetton_internal_transfer",
        .jetton_transfer_notification => "jetton_transfer_notification",
        .jetton_burn => "jetton_burn",
        .jetton_burn_notification => "jetton_burn_notification",
        .nft_get_static_data => "nft_get_static_data",
        .nft_report_static_data => "nft_report_static_data",
        .nft_transfer => "nft_transfer",
        .nft_ownership_assigned => "nft_ownership_assigned",
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
        .excesses => buildExcessesBodyAlloc(allocator, object),
        .jetton_provide_wallet_address => buildJettonProvideWalletAddressBodyAlloc(allocator, object),
        .jetton_take_wallet_address => buildJettonTakeWalletAddressBodyAlloc(allocator, object),
        .jetton_transfer => buildJettonTransferBodyAlloc(allocator, object),
        .jetton_internal_transfer => buildJettonInternalTransferBodyAlloc(allocator, object),
        .jetton_transfer_notification => buildJettonTransferNotificationBodyAlloc(allocator, object),
        .jetton_burn => buildJettonBurnBodyAlloc(allocator, object),
        .jetton_burn_notification => buildJettonBurnNotificationBodyAlloc(allocator, object),
        .nft_get_static_data => buildNftGetStaticDataBodyAlloc(allocator, object),
        .nft_report_static_data => buildNftReportStaticDataBodyAlloc(allocator, object),
        .nft_transfer => buildNftTransferBodyAlloc(allocator, object),
        .nft_ownership_assigned => buildNftOwnershipAssignedBodyAlloc(allocator, object),
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

pub fn createExcessesMessage(allocator: std.mem.Allocator, query_id: u64) ![]u8 {
    var builder = cell.Builder.init();
    try builder.storeUint(0xD53276DB, 32);
    try builder.storeUint(query_id, 64);
    const root = try builder.toCell(allocator);
    defer root.deinit(allocator);
    return boc.serializeBoc(allocator, root);
}

pub fn createJettonProvideWalletAddressMessage(
    allocator: std.mem.Allocator,
    query_id: u64,
    owner_address: []const u8,
    include_address: bool,
) ![]u8 {
    var builder = cell.Builder.init();
    try builder.storeUint(0x2C76B973, 32);
    try builder.storeUint(query_id, 64);
    try builder.storeAddress(owner_address);
    try builder.storeUint(if (include_address) 1 else 0, 1);
    const root = try builder.toCell(allocator);
    defer root.deinit(allocator);
    return boc.serializeBoc(allocator, root);
}

pub fn createJettonTakeWalletAddressMessage(
    allocator: std.mem.Allocator,
    query_id: u64,
    wallet_address: []const u8,
    owner_address: ?[]const u8,
) ![]u8 {
    var builder = cell.Builder.init();
    try builder.storeUint(0xD1735400, 32);
    try builder.storeUint(query_id, 64);
    try builder.storeAddress(wallet_address);
    if (owner_address) |value| {
        var owner_builder = cell.Builder.init();
        try owner_builder.storeAddress(value);
        const owner_cell = try owner_builder.toCell(allocator);
        try builder.storeUint(1, 1);
        try builder.storeRef(owner_cell);
    } else {
        try builder.storeUint(0, 1);
    }
    const root = try builder.toCell(allocator);
    defer root.deinit(allocator);
    return boc.serializeBoc(allocator, root);
}

pub fn createJettonBurnNotificationMessage(
    allocator: std.mem.Allocator,
    query_id: u64,
    amount: u64,
    sender: []const u8,
    response_destination: []const u8,
) ![]u8 {
    var builder = cell.Builder.init();
    try builder.storeUint(0x7BDD97DE, 32);
    try builder.storeUint(query_id, 64);
    try builder.storeCoins(amount);
    try builder.storeAddress(sender);
    try builder.storeAddress(response_destination);
    const root = try builder.toCell(allocator);
    defer root.deinit(allocator);
    return boc.serializeBoc(allocator, root);
}

pub fn createNftGetStaticDataMessage(allocator: std.mem.Allocator, query_id: u64) ![]u8 {
    var builder = cell.Builder.init();
    try builder.storeUint(0x2FCB26A2, 32);
    try builder.storeUint(query_id, 64);
    const root = try builder.toCell(allocator);
    defer root.deinit(allocator);
    return boc.serializeBoc(allocator, root);
}

pub fn createNftReportStaticDataMessage(
    allocator: std.mem.Allocator,
    query_id: u64,
    index_bytes: []const u8,
    collection: []const u8,
) ![]u8 {
    var builder = cell.Builder.init();
    try builder.storeUint(0x8B771735, 32);
    try builder.storeUint(query_id, 64);
    try builder.storeUintBytes(index_bytes, 256);
    try builder.storeAddress(collection);
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

pub fn createNftOwnershipAssignedMessage(
    allocator: std.mem.Allocator,
    query_id: u64,
    prev_owner: []const u8,
    forward_payload: ?[]const u8,
) ![]u8 {
    var builder = cell.Builder.init();
    try builder.storeUint(0x05138D91, 32);
    try builder.storeUint(query_id, 64);
    try builder.storeAddress(prev_owner);
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

fn buildExcessesBodyAlloc(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]u8 {
    return createExcessesMessage(allocator, try getOptionalU64(object, "query_id", 0));
}

fn buildJettonProvideWalletAddressBodyAlloc(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]u8 {
    return createJettonProvideWalletAddressMessage(
        allocator,
        try getOptionalU64(object, "query_id", 0),
        try getRequiredString(object, "owner_address"),
        try getOptionalBool(object, "include_address", false),
    );
}

fn buildJettonTakeWalletAddressBodyAlloc(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]u8 {
    return createJettonTakeWalletAddressMessage(
        allocator,
        try getOptionalU64(object, "query_id", 0),
        try getRequiredString(object, "wallet_address"),
        try getOptionalString(object, "owner_address"),
    );
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

fn buildJettonBurnNotificationBodyAlloc(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]u8 {
    return createJettonBurnNotificationMessage(
        allocator,
        try getOptionalU64(object, "query_id", 0),
        try getRequiredU64(object, "amount"),
        try getRequiredString(object, "sender"),
        try getRequiredString(object, "response_destination"),
    );
}

fn buildNftGetStaticDataBodyAlloc(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]u8 {
    return createNftGetStaticDataMessage(allocator, try getOptionalU64(object, "query_id", 0));
}

fn buildNftReportStaticDataBodyAlloc(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]u8 {
    const index_bytes = try parseJsonUnsignedBytesAlloc(allocator, object.get("index") orelse return error.MissingStandardBodyField);
    defer allocator.free(index_bytes);

    return createNftReportStaticDataMessage(
        allocator,
        try getOptionalU64(object, "query_id", 0),
        index_bytes,
        try getRequiredString(object, "collection"),
    );
}

fn buildJettonInternalTransferBodyAlloc(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]u8 {
    const query_id = try getOptionalU64(object, "query_id", 0);
    const amount = try getRequiredU64(object, "amount");
    const sender = try getRequiredString(object, "sender");
    const response_address = try getRequiredString(object, "response_address");
    const forward_ton_amount = try getOptionalU64(object, "forward_ton_amount", 0);

    const forward_payload = try loadOptionalPayloadAlloc(
        allocator,
        object,
        "forward_payload_boc_base64",
        "forward_comment",
    );
    defer if (forward_payload) |value| allocator.free(value);

    return jetton.createInternalTransferMessage(
        allocator,
        query_id,
        amount,
        sender,
        response_address,
        forward_ton_amount,
        forward_payload,
    );
}

fn buildJettonTransferNotificationBodyAlloc(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]u8 {
    const query_id = try getOptionalU64(object, "query_id", 0);
    const amount = try getRequiredU64(object, "amount");
    const sender = try getRequiredString(object, "sender");

    const forward_payload = try loadOptionalPayloadAlloc(
        allocator,
        object,
        "forward_payload_boc_base64",
        "forward_comment",
    );
    defer if (forward_payload) |value| allocator.free(value);

    return jetton.createTransferNotificationMessage(
        allocator,
        query_id,
        amount,
        sender,
        forward_payload,
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

fn buildNftOwnershipAssignedBodyAlloc(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]u8 {
    const forward_payload = try loadOptionalPayloadAlloc(
        allocator,
        object,
        "forward_payload_boc_base64",
        "forward_comment",
    );
    defer if (forward_payload) |value| allocator.free(value);

    return createNftOwnershipAssignedMessage(
        allocator,
        try getOptionalU64(object, "query_id", 0),
        try getRequiredString(object, "prev_owner"),
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

fn getOptionalString(object: std.json.ObjectMap, field: []const u8) !?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .null => null,
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

fn getOptionalBool(object: std.json.ObjectMap, field: []const u8, default_value: bool) !bool {
    const value = object.get(field) orelse return default_value;
    return switch (value) {
        .bool => value.bool,
        .integer => value.integer != 0,
        .string => |text| {
            if (std.ascii.eqlIgnoreCase(text, "true") or std.mem.eql(u8, text, "1")) return true;
            if (std.ascii.eqlIgnoreCase(text, "false") or std.mem.eql(u8, text, "0")) return false;
            return error.InvalidStandardBodySpec;
        },
        else => error.InvalidStandardBodySpec,
    };
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

fn parseJsonUnsignedBytesAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return switch (value) {
        .integer => |int_value| {
            if (int_value < 0) return error.InvalidStandardBodySpec;
            const text = try std.fmt.allocPrint(allocator, "{d}", .{int_value});
            defer allocator.free(text);
            return parseUnsignedTextBytesAlloc(allocator, text);
        },
        .string => |text| parseUnsignedTextBytesAlloc(allocator, text),
        else => error.InvalidStandardBodySpec,
    };
}

fn parseUnsignedTextBytesAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidStandardBodySpec;

    if (std.mem.startsWith(u8, trimmed, "0x") or std.mem.startsWith(u8, trimmed, "0X")) {
        return parseUnsignedHexBytesAlloc(allocator, trimmed[2..]);
    }
    return parseUnsignedDecimalBytesAlloc(allocator, trimmed);
}

fn parseUnsignedHexBytesAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len == 0) return allocator.alloc(u8, 0);

    const out = try allocator.alloc(u8, @divTrunc(text.len + 1, 2));
    defer allocator.free(out);

    var src_idx: usize = 0;
    var dst_idx: usize = 0;
    if (text.len % 2 != 0) {
        out[0] = try hexCharValue(text[0]);
        src_idx = 1;
        dst_idx = 1;
    }

    while (src_idx < text.len) : (src_idx += 2) {
        const hi = try hexCharValue(text[src_idx]);
        const lo = try hexCharValue(text[src_idx + 1]);
        out[dst_idx] = (hi << 4) | lo;
        dst_idx += 1;
    }

    return dupeTrimmedBytes(allocator, out);
}

fn parseUnsignedDecimalBytesAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var bytes_le = std.array_list.Managed(u8).init(allocator);
    defer bytes_le.deinit();

    try bytes_le.append(0);
    for (text) |char| {
        if (char < '0' or char > '9') return error.InvalidStandardBodySpec;

        var carry: u16 = char - '0';
        for (bytes_le.items) |*byte| {
            const next: u16 = @as(u16, byte.*) * 10 + carry;
            byte.* = @intCast(next & 0xFF);
            carry = next >> 8;
        }
        while (carry != 0) {
            try bytes_le.append(@intCast(carry & 0xFF));
            carry >>= 8;
        }
    }

    const out = try allocator.alloc(u8, bytes_le.items.len);
    defer allocator.free(out);
    for (bytes_le.items, 0..) |byte, idx| {
        out[out.len - 1 - idx] = byte;
    }
    return dupeTrimmedBytes(allocator, out);
}

fn dupeTrimmedBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var start: usize = 0;
    while (start < bytes.len and bytes[start] == 0) : (start += 1) {}
    return allocator.dupe(u8, bytes[start..]);
}

fn hexCharValue(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => 10 + (c - 'a'),
        'A'...'F' => 10 + (c - 'A'),
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

test "standard body builds excesses body from json" {
    const allocator = std.testing.allocator;
    const body_boc = try buildBodyFromJsonAlloc(allocator, .excesses, "{\"query_id\":44}");
    defer allocator.free(body_boc);

    var analysis = try @import("../core/body_inspector.zig").inspectBodyBocAlloc(allocator, body_boc);
    defer analysis.deinit(allocator);
    try std.testing.expectEqualStrings("excesses", analysis.opcode_name.?);
    try std.testing.expectEqualStrings("{\"query_id\":44}", analysis.decoded_json.?);
}

test "standard body builds jetton provide wallet address" {
    const allocator = std.testing.allocator;
    const body_boc = try buildBodyFromJsonAlloc(allocator, .jetton_provide_wallet_address,
        \\{
        \\  "query_id": 2,
        \\  "owner_address": "0:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        \\  "include_address": true
        \\}
    );
    defer allocator.free(body_boc);

    var analysis = try @import("../core/body_inspector.zig").inspectBodyBocAlloc(allocator, body_boc);
    defer analysis.deinit(allocator);
    try std.testing.expectEqualStrings("jetton_provide_wallet_address", analysis.opcode_name.?);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"include_address\":true") != null);
}

test "standard body builds jetton take wallet address" {
    const allocator = std.testing.allocator;
    const body_boc = try buildBodyFromJsonAlloc(allocator, .jetton_take_wallet_address,
        \\{
        \\  "query_id": 3,
        \\  "wallet_address": "0:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
        \\  "owner_address": "0:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        \\}
    );
    defer allocator.free(body_boc);

    var analysis = try @import("../core/body_inspector.zig").inspectBodyBocAlloc(allocator, body_boc);
    defer analysis.deinit(allocator);
    try std.testing.expectEqualStrings("jetton_take_wallet_address", analysis.opcode_name.?);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"owner_address\":\"0:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"") != null);
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

test "standard body builds jetton internal transfer with forward comment" {
    const allocator = std.testing.allocator;
    const body_boc = try buildBodyFromJsonAlloc(allocator, .jetton_internal_transfer,
        \\{
        \\  "query_id": 7,
        \\  "amount": 123,
        \\  "sender": "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
        \\  "response_address": "0:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        \\  "forward_ton_amount": 9,
        \\  "forward_comment": "notify"
        \\}
    );
    defer allocator.free(body_boc);

    var analysis = try @import("../core/body_inspector.zig").inspectBodyBocAlloc(allocator, body_boc);
    defer analysis.deinit(allocator);
    try std.testing.expectEqualStrings("jetton_internal_transfer", analysis.opcode_name.?);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"sender\":\"0:83dfd552e63729b472fcbcc8c45ebcc6691702558b68ec7527e1ba403a0f31a8\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"response_address\":\"0:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"forward_comment\":\"notify\"") != null);
}

test "standard body builds jetton transfer notification with forward comment" {
    const allocator = std.testing.allocator;
    const body_boc = try buildBodyFromJsonAlloc(allocator, .jetton_transfer_notification,
        \\{
        \\  "query_id": 3,
        \\  "amount": 555,
        \\  "sender": "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
        \\  "forward_comment": "airdrop"
        \\}
    );
    defer allocator.free(body_boc);

    var analysis = try @import("../core/body_inspector.zig").inspectBodyBocAlloc(allocator, body_boc);
    defer analysis.deinit(allocator);
    try std.testing.expectEqualStrings("jetton_transfer_notification", analysis.opcode_name.?);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"sender\":\"0:83dfd552e63729b472fcbcc8c45ebcc6691702558b68ec7527e1ba403a0f31a8\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"forward_comment\":\"airdrop\"") != null);
}

test "standard body builds jetton burn notification" {
    const allocator = std.testing.allocator;
    const body_boc = try buildBodyFromJsonAlloc(allocator, .jetton_burn_notification,
        \\{
        \\  "query_id": 19,
        \\  "amount": 777,
        \\  "sender": "0:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        \\  "response_destination": "0:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
        \\}
    );
    defer allocator.free(body_boc);

    var analysis = try @import("../core/body_inspector.zig").inspectBodyBocAlloc(allocator, body_boc);
    defer analysis.deinit(allocator);
    try std.testing.expectEqualStrings("jetton_burn_notification", analysis.opcode_name.?);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"amount\":777") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"sender\":\"0:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"response_destination\":\"0:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"") != null);
}

test "standard body builds nft get static data" {
    const allocator = std.testing.allocator;
    const body_boc = try buildBodyFromJsonAlloc(allocator, .nft_get_static_data, "{\"query_id\":8}");
    defer allocator.free(body_boc);

    var analysis = try @import("../core/body_inspector.zig").inspectBodyBocAlloc(allocator, body_boc);
    defer analysis.deinit(allocator);
    try std.testing.expectEqualStrings("nft_get_static_data", analysis.opcode_name.?);
    try std.testing.expectEqualStrings("{\"query_id\":8}", analysis.decoded_json.?);
}

test "standard body builds nft report static data" {
    const allocator = std.testing.allocator;
    const body_boc = try buildBodyFromJsonAlloc(allocator, .nft_report_static_data,
        \\{
        \\  "query_id": 9,
        \\  "index": "0x1234",
        \\  "collection": "0:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
        \\}
    );
    defer allocator.free(body_boc);

    var analysis = try @import("../core/body_inspector.zig").inspectBodyBocAlloc(allocator, body_boc);
    defer analysis.deinit(allocator);
    try std.testing.expectEqualStrings("nft_report_static_data", analysis.opcode_name.?);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"index\":\"0x1234\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"collection\":\"0:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"") != null);
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

test "standard body builds nft ownership assigned with forward comment" {
    const allocator = std.testing.allocator;
    const body_boc = try buildBodyFromJsonAlloc(allocator, .nft_ownership_assigned,
        \\{
        \\  "query_id": 6,
        \\  "prev_owner": "0:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        \\  "forward_comment": "assigned"
        \\}
    );
    defer allocator.free(body_boc);

    var analysis = try @import("../core/body_inspector.zig").inspectBodyBocAlloc(allocator, body_boc);
    defer analysis.deinit(allocator);
    try std.testing.expectEqualStrings("nft_ownership_assigned", analysis.opcode_name.?);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"prev_owner\":\"0:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, analysis.decoded_json.?, "\"forward_comment\":\"assigned\"") != null);
}
