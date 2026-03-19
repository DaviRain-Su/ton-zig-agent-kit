//! Agent tools - High-level interface for AI agents
//! Unified API for balance queries, transfers, invoices, and verification

const std = @import("std");
const address_mod = @import("../core/address.zig");
const boc = @import("../core/boc.zig");
const body_builder = @import("../core/body_builder.zig");
const external_message = @import("../core/external_message.zig");
const core_types = @import("../core/types.zig");
const http_client = @import("../core/http_client.zig");
const provider_mod = @import("../core/provider.zig");
const state_init = @import("../core/state_init.zig");
const paywatch = @import("../paywatch/paywatch.zig");
const wallet = @import("../wallet/wallet.zig");
const signing = @import("../wallet/signing.zig");
const contract = @import("../contract/contract.zig");
const abi_adapter = @import("../contract/abi_adapter.zig");
const jetton = @import("../contract/jetton.zig");
const nft = @import("../contract/nft.zig");
const tools_types = @import("types.zig");

const BuiltAbiInspect = struct {
    uri: ?[]u8 = null,
    version: ?[]u8 = null,
    json: ?[]u8 = null,
    functions: []tools_types.AbiFunctionTemplateResult = &.{},
    events: []tools_types.AbiEventTemplateResult = &.{},

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.uri) |value| allocator.free(value);
        if (self.version) |value| allocator.free(value);
        if (self.json) |value| allocator.free(value);
        for (self.functions) |*item| item.deinit(allocator);
        if (self.functions.len > 0) allocator.free(self.functions);
        for (self.events) |*item| item.deinit(allocator);
        if (self.events.len > 0) allocator.free(self.events);
        self.* = .{};
    }
};

fn buildAbiCliArgsTemplateAlloc(
    allocator: std.mem.Allocator,
    params: []const abi_adapter.ParamDef,
) anyerror![]u8 {
    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    for (params, 0..) |param, idx| {
        if (idx != 0) try writer.writer.writeByte(' ');
        const value = try buildAbiCliValueTemplateAlloc(allocator, param);
        defer allocator.free(value);
        try writer.writer.writeAll(value);
    }

    return try writer.toOwnedSlice();
}

fn buildAbiNamedCliArgsTemplateAlloc(
    allocator: std.mem.Allocator,
    params: []const abi_adapter.ParamDef,
) anyerror![]u8 {
    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    for (params, 0..) |param, idx| {
        if (idx != 0) try writer.writer.writeByte(' ');

        var fallback_name_buf: [32]u8 = undefined;
        const name = if (param.name.len > 0)
            param.name
        else
            try std.fmt.bufPrint(&fallback_name_buf, "arg{d}", .{idx});

        try writer.writer.print("{s}=", .{name});

        const value = try buildAbiCliValueTemplateAlloc(allocator, param);
        defer allocator.free(value);
        try writer.writer.writeAll(value);
    }

    return try writer.toOwnedSlice();
}

fn buildAbiDecodedOutputsTemplateAlloc(
    allocator: std.mem.Allocator,
    params: []const abi_adapter.ParamDef,
) anyerror![]u8 {
    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    try writer.writer.writeByte('{');
    for (params, 0..) |param, idx| {
        if (idx != 0) try writer.writer.writeByte(',');

        var fallback_name_buf: [32]u8 = undefined;
        const name = if (param.name.len > 0)
            param.name
        else
            try std.fmt.bufPrint(&fallback_name_buf, "value{d}", .{idx});

        try writeAbiTemplateJsonString(&writer.writer, name);
        try writer.writer.writeByte(':');

        const value = try buildAbiOutputValueTemplateAlloc(allocator, param);
        defer allocator.free(value);
        try writer.writer.writeAll(value);
    }
    try writer.writer.writeByte('}');

    return try writer.toOwnedSlice();
}

fn buildAbiCliValueTemplateAlloc(
    allocator: std.mem.Allocator,
    param: abi_adapter.ParamDef,
) anyerror![]u8 {
    if (abiTemplateOptionalInnerType(param.type_name) != null) {
        return allocator.dupe(u8, "null");
    }

    if (abiTemplateArrayInnerType(param.type_name)) |inner_type| {
        const value = try buildAbiJsonValueTemplateAlloc(allocator, abiTemplateParamWithType(param, inner_type));
        defer allocator.free(value);
        return std.fmt.allocPrint(allocator, "json:[{s}]", .{value});
    }

    if (abiTemplateIsCompositeParam(param)) {
        const value = try buildAbiJsonValueTemplateAlloc(allocator, param);
        defer allocator.free(value);
        return std.fmt.allocPrint(allocator, "json:{s}", .{value});
    }

    if (std.mem.eql(u8, param.type_name, "bool")) {
        return allocator.dupe(u8, "num:1");
    }

    if (std.mem.eql(u8, param.type_name, "address")) {
        return allocator.dupe(u8, "addr:EQ...");
    }

    if (std.mem.eql(u8, param.type_name, "string")) {
        return allocator.dupe(u8, "str:text");
    }

    if (std.mem.eql(u8, param.type_name, "bytes") or abiTemplateFixedBytesLength(param.type_name) != null) {
        return allocator.dupe(u8, "hex:CAFE");
    }

    if (abiTemplateIsCellLikeType(param.type_name)) {
        return allocator.dupe(u8, "boc:<base64_boc>");
    }

    if (abiTemplateIsNumericType(param.type_name)) {
        return allocator.dupe(u8, "num:0");
    }

    return allocator.dupe(u8, "json:null");
}

fn buildAbiJsonValueTemplateAlloc(
    allocator: std.mem.Allocator,
    param: abi_adapter.ParamDef,
) anyerror![]u8 {
    if (abiTemplateOptionalInnerType(param.type_name) != null) {
        return allocator.dupe(u8, "null");
    }

    if (abiTemplateArrayInnerType(param.type_name)) |inner_type| {
        const value = try buildAbiJsonValueTemplateAlloc(allocator, abiTemplateParamWithType(param, inner_type));
        defer allocator.free(value);
        return std.fmt.allocPrint(allocator, "[{s}]", .{value});
    }

    if (abiTemplateIsCompositeParam(param)) {
        return buildAbiCompositeJsonTemplateAlloc(allocator, param.components);
    }

    if (abiTemplateIsNumericType(param.type_name)) {
        return allocator.dupe(u8, if (std.mem.eql(u8, param.type_name, "bool")) "true" else "0");
    }

    if (std.mem.eql(u8, param.type_name, "address")) {
        return allocator.dupe(u8, "\"EQ...\"");
    }

    if (std.mem.eql(u8, param.type_name, "string")) {
        return allocator.dupe(u8, "\"text\"");
    }

    if (std.mem.eql(u8, param.type_name, "bytes") or abiTemplateFixedBytesLength(param.type_name) != null) {
        return allocator.dupe(u8, "{\"hex\":\"CAFE\"}");
    }

    if (abiTemplateIsCellLikeType(param.type_name)) {
        return allocator.dupe(u8, "{\"boc\":\"<base64_boc>\"}");
    }

    return allocator.dupe(u8, "null");
}

fn buildAbiOutputValueTemplateAlloc(
    allocator: std.mem.Allocator,
    param: abi_adapter.ParamDef,
) anyerror![]u8 {
    if (abiTemplateOptionalInnerType(param.type_name) != null) {
        return allocator.dupe(u8, "null");
    }

    if (abiTemplateArrayInnerType(param.type_name)) |inner_type| {
        const value = try buildAbiOutputValueTemplateAlloc(allocator, abiTemplateParamWithType(param, inner_type));
        defer allocator.free(value);
        return std.fmt.allocPrint(allocator, "[{s}]", .{value});
    }

    if (abiTemplateIsCompositeParam(param)) {
        return buildAbiCompositeOutputTemplateAlloc(allocator, param.components);
    }

    if (abiTemplateIsNumericType(param.type_name)) {
        return allocator.dupe(u8, if (std.mem.eql(u8, param.type_name, "bool")) "true" else "0");
    }

    if (std.mem.eql(u8, param.type_name, "address")) {
        return allocator.dupe(u8, "\"0:...\"");
    }

    if (std.mem.eql(u8, param.type_name, "string")) {
        return allocator.dupe(u8, "\"text\"");
    }

    if (std.mem.eql(u8, param.type_name, "bytes") or abiTemplateFixedBytesLength(param.type_name) != null) {
        return allocator.dupe(u8, "\"<base64_bytes>\"");
    }

    if (abiTemplateIsCellLikeType(param.type_name)) {
        return allocator.dupe(u8, "\"<base64_boc>\"");
    }

    return allocator.dupe(u8, "null");
}

fn buildAbiCompositeJsonTemplateAlloc(
    allocator: std.mem.Allocator,
    components: []const abi_adapter.ParamDef,
) anyerror![]u8 {
    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    var has_named_components = true;
    for (components) |component| {
        if (component.name.len == 0) {
            has_named_components = false;
            break;
        }
    }

    if (has_named_components) {
        try writer.writer.writeByte('{');
        for (components, 0..) |component, idx| {
            if (idx != 0) try writer.writer.writeByte(',');
            try writeAbiTemplateJsonString(&writer.writer, component.name);
            try writer.writer.writeByte(':');
            const value = try buildAbiJsonValueTemplateAlloc(allocator, component);
            defer allocator.free(value);
            try writer.writer.writeAll(value);
        }
        try writer.writer.writeByte('}');
    } else {
        try writer.writer.writeByte('[');
        for (components, 0..) |component, idx| {
            if (idx != 0) try writer.writer.writeByte(',');
            const value = try buildAbiJsonValueTemplateAlloc(allocator, component);
            defer allocator.free(value);
            try writer.writer.writeAll(value);
        }
        try writer.writer.writeByte(']');
    }

    return try writer.toOwnedSlice();
}

fn buildAbiCompositeOutputTemplateAlloc(
    allocator: std.mem.Allocator,
    components: []const abi_adapter.ParamDef,
) anyerror![]u8 {
    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    var has_named_components = true;
    for (components) |component| {
        if (component.name.len == 0) {
            has_named_components = false;
            break;
        }
    }

    if (has_named_components) {
        try writer.writer.writeByte('{');
        for (components, 0..) |component, idx| {
            if (idx != 0) try writer.writer.writeByte(',');
            try writeAbiTemplateJsonString(&writer.writer, component.name);
            try writer.writer.writeByte(':');
            const value = try buildAbiOutputValueTemplateAlloc(allocator, component);
            defer allocator.free(value);
            try writer.writer.writeAll(value);
        }
        try writer.writer.writeByte('}');
    } else {
        try writer.writer.writeByte('[');
        for (components, 0..) |component, idx| {
            if (idx != 0) try writer.writer.writeByte(',');
            const value = try buildAbiOutputValueTemplateAlloc(allocator, component);
            defer allocator.free(value);
            try writer.writer.writeAll(value);
        }
        try writer.writer.writeByte(']');
    }

    return try writer.toOwnedSlice();
}

fn abiTemplateParamWithType(
    param: abi_adapter.ParamDef,
    type_name: []const u8,
) abi_adapter.ParamDef {
    return .{
        .name = param.name,
        .type_name = type_name,
        .components = param.components,
    };
}

fn abiTemplateIsCompositeParam(param: abi_adapter.ParamDef) bool {
    return param.components.len > 0 or
        std.mem.eql(u8, param.type_name, "tuple") or
        std.mem.eql(u8, param.type_name, "struct");
}

fn abiTemplateIsNumericType(type_name: []const u8) bool {
    return std.mem.eql(u8, type_name, "bool") or
        std.mem.eql(u8, type_name, "coins") or
        std.mem.startsWith(u8, type_name, "uint") or
        std.mem.startsWith(u8, type_name, "int");
}

fn abiTemplateIsCellLikeType(type_name: []const u8) bool {
    return abiTemplateMatchesAbiTypeBase(type_name, "cell") or
        abiTemplateMatchesAbiTypeBase(type_name, "slice") or
        abiTemplateMatchesAbiTypeBase(type_name, "builder") or
        abiTemplateMatchesAbiTypeBase(type_name, "ref") or
        abiTemplateMatchesAbiTypeBase(type_name, "boc") or
        abiTemplateMatchesAbiTypeBase(type_name, "ref_boc") or
        abiTemplateMatchesAbiTypeBase(type_name, "cell_ref") or
        abiTemplateMatchesAbiTypeBase(type_name, "dict") or
        abiTemplateMatchesAbiTypeBase(type_name, "map") or
        abiTemplateMatchesAbiTypeBase(type_name, "hashmap") or
        abiTemplateMatchesAbiTypeBase(type_name, "hashmape") or
        abiTemplateMatchesAbiTypeBase(type_name, "dict_ref") or
        abiTemplateMatchesAbiTypeBase(type_name, "map_ref") or
        abiTemplateMatchesAbiTypeBase(type_name, "hashmap_ref") or
        abiTemplateMatchesAbiTypeBase(type_name, "hashmape_ref");
}

fn abiTemplateFixedBytesLength(type_name: []const u8) ?usize {
    const trimmed = std.mem.trim(u8, type_name, " \t\r\n");

    if (abiTemplateParseFixedBytesSuffix(trimmed, "bytes")) |value| return value;
    if (abiTemplateParseFixedBytesSuffix(trimmed, "fixedbytes")) |value| return value;
    if (abiTemplateParseFixedBytesSuffix(trimmed, "fixed_bytes")) |value| return value;

    if (abiTemplateParseFixedBytesGeneric(trimmed, "fixedbytes<")) |value| return value;
    if (abiTemplateParseFixedBytesGeneric(trimmed, "fixed_bytes<")) |value| return value;

    return null;
}

fn abiTemplateParseFixedBytesSuffix(trimmed: []const u8, comptime prefix: []const u8) ?usize {
    if (trimmed.len <= prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(trimmed[0..prefix.len], prefix)) return null;

    const digits = trimmed[prefix.len..];
    if (digits.len == 0) return null;
    for (digits) |char| {
        if (!std.ascii.isDigit(char)) return null;
    }

    return std.fmt.parseInt(usize, digits, 10) catch null;
}

fn abiTemplateParseFixedBytesGeneric(trimmed: []const u8, comptime prefix: []const u8) ?usize {
    if (!std.ascii.startsWithIgnoreCase(trimmed, prefix)) return null;
    if (trimmed.len <= prefix.len or trimmed[trimmed.len - 1] != '>') return null;
    return std.fmt.parseInt(usize, trimmed[prefix.len .. trimmed.len - 1], 10) catch null;
}

fn abiTemplateMatchesAbiTypeBase(type_name: []const u8, base: []const u8) bool {
    const trimmed = std.mem.trim(u8, type_name, " \t\r\n");
    if (trimmed.len < base.len) return false;
    if (!std.ascii.eqlIgnoreCase(trimmed[0..base.len], base)) return false;
    return trimmed.len == base.len or trimmed[base.len] == '<' or trimmed[base.len] == ' ';
}

fn abiTemplateOptionalInnerType(type_name: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, type_name, " \t\r\n");

    if (std.mem.startsWith(u8, trimmed, "maybe<") and trimmed.len > "maybe<>".len and trimmed[trimmed.len - 1] == '>') {
        return std.mem.trim(u8, trimmed["maybe<".len .. trimmed.len - 1], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "optional<") and trimmed.len > "optional<>".len and trimmed[trimmed.len - 1] == '>') {
        return std.mem.trim(u8, trimmed["optional<".len .. trimmed.len - 1], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "maybe ")) {
        return std.mem.trim(u8, trimmed["maybe ".len..], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "optional ")) {
        return std.mem.trim(u8, trimmed["optional ".len..], " \t\r\n");
    }

    return null;
}

fn abiTemplateArrayInnerType(type_name: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, type_name, " \t\r\n");

    if (trimmed.len > 2 and std.mem.endsWith(u8, trimmed, "[]")) {
        return std.mem.trim(u8, trimmed[0 .. trimmed.len - 2], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "array<") and trimmed.len > "array<>".len and trimmed[trimmed.len - 1] == '>') {
        return std.mem.trim(u8, trimmed["array<".len .. trimmed.len - 1], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "list<") and trimmed.len > "list<>".len and trimmed[trimmed.len - 1] == '>') {
        return std.mem.trim(u8, trimmed["list<".len .. trimmed.len - 1], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "array ")) {
        return std.mem.trim(u8, trimmed["array ".len..], " \t\r\n");
    }

    return null;
}

fn writeAbiTemplateJsonString(writer: anytype, value: []const u8) !void {
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

fn AgentToolsImpl(comptime ClientType: type) type {
    const supports_standard_wrappers = ClientType == *http_client.TonHttpClient or ClientType == *provider_mod.MultiProvider;
    const JettonMasterClient = if (ClientType == *http_client.TonHttpClient)
        jetton.JettonMaster
    else if (ClientType == *provider_mod.MultiProvider)
        jetton.ProviderJettonMaster
    else
        void;
    const JettonWalletClient = if (ClientType == *http_client.TonHttpClient)
        jetton.JettonWallet
    else if (ClientType == *provider_mod.MultiProvider)
        jetton.ProviderJettonWallet
    else
        void;
    const NFTItemClient = if (ClientType == *http_client.TonHttpClient)
        nft.NFTItem
    else if (ClientType == *provider_mod.MultiProvider)
        nft.ProviderNFTItem
    else
        void;
    const NFTCollectionClient = if (ClientType == *http_client.TonHttpClient)
        nft.NFTCollection
    else if (ClientType == *provider_mod.MultiProvider)
        nft.ProviderNFTCollection
    else
        void;

    return struct {
        allocator: std.mem.Allocator,
        client: ClientType,
        config: tools_types.AgentToolsConfig,

        pub fn init(allocator: std.mem.Allocator, client: ClientType, config: tools_types.AgentToolsConfig) @This() {
            return .{
                .allocator = allocator,
                .client = client,
                .config = config,
            };
        }

        /// Get TON balance for address
        pub fn getBalance(self: *@This(), target_address: []const u8) !tools_types.BalanceResult {
            const resp = self.client.getBalance(target_address) catch |err| {
                return tools_types.BalanceResult{
                    .address = target_address,
                    .balance = 0,
                    .formatted = "0 TON",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };

            const formatted = try std.fmt.allocPrint(self.allocator, "{d}.{d:09} TON", .{
                resp.balance / 1_000_000_000,
                resp.balance % 1_000_000_000,
            });

            return tools_types.BalanceResult{
                .address = target_address,
                .balance = resp.balance,
                .formatted = formatted,
                .success = true,
                .error_message = null,
            };
        }

        fn deriveConfiguredWalletRawAddressAlloc(self: *@This()) ![]u8 {
            const private_key = self.config.wallet_private_key orelse return error.MissingWalletPrivateKey;
            var wallet_init = try signing.deriveWalletV4InitFromPrivateKeyAlloc(
                self.allocator,
                self.config.wallet_workchain,
                self.config.wallet_id,
                private_key,
            );
            defer wallet_init.deinit(self.allocator);
            return address_mod.formatRaw(self.allocator, &wallet_init.address);
        }

        fn buildWalletInitResultAlloc(self: *@This(), private_key: [32]u8) !tools_types.WalletInitResult {
            var wallet_init = try signing.deriveWalletV4InitFromPrivateKeyAlloc(
                self.allocator,
                self.config.wallet_workchain,
                self.config.wallet_id,
                private_key,
            );
            defer wallet_init.deinit(self.allocator);

            const raw_address = try address_mod.formatRaw(self.allocator, &wallet_init.address);
            errdefer self.allocator.free(raw_address);

            const user_friendly_address = try address_mod.addressToUserFriendlyAlloc(self.allocator, &wallet_init.address, true, false);
            errdefer self.allocator.free(user_friendly_address);

            const public_key_hex = try allocHexLower(self.allocator, &wallet_init.public_key);
            errdefer self.allocator.free(public_key_hex);

            const encoded_len = std.base64.standard.Encoder.calcSize(wallet_init.state_init_boc.len);
            const state_init_boc = try self.allocator.alloc(u8, encoded_len);
            errdefer self.allocator.free(state_init_boc);
            _ = std.base64.standard.Encoder.encode(state_init_boc, wallet_init.state_init_boc);

            return tools_types.WalletInitResult{
                .raw_address = raw_address,
                .user_friendly_address = user_friendly_address,
                .workchain = self.config.wallet_workchain,
                .wallet_id = self.config.wallet_id,
                .public_key_hex = public_key_hex,
                .state_init_boc = state_init_boc,
                .success = true,
                .error_message = null,
            };
        }

        fn allocHexLower(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
            const hex_chars = "0123456789abcdef";
            const out = try allocator.alloc(u8, bytes.len * 2);
            errdefer allocator.free(out);

            for (bytes, 0..) |byte, idx| {
                out[idx * 2] = hex_chars[byte >> 4];
                out[idx * 2 + 1] = hex_chars[byte & 0x0f];
            }

            return out;
        }

        fn encodeBase64Alloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
            const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
            const out = try allocator.alloc(u8, encoded_len);
            errdefer allocator.free(out);
            _ = std.base64.standard.Encoder.encode(out, bytes);
            return out;
        }

        fn builtBodyError(error_message: []const u8) tools_types.BuiltBodyResult {
            return .{
                .address = null,
                .selector = "",
                .body_boc = "",
                .body_hex = "",
                .success = false,
                .error_message = error_message,
            };
        }

        fn builtExternalError(error_message: []const u8) tools_types.BuiltExternalMessageResult {
            return .{
                .destination = "",
                .body_boc = "",
                .external_boc = "",
                .external_hex = "",
                .state_init_attached = false,
                .success = false,
                .error_message = error_message,
            };
        }

        fn buildBodyResultAlloc(
            self: *@This(),
            contract_address: ?[]const u8,
            selector: []const u8,
            body_boc: []const u8,
        ) !tools_types.BuiltBodyResult {
            const address = if (contract_address) |value| try self.allocator.dupe(u8, value) else null;
            errdefer if (address) |value| self.allocator.free(value);

            const owned_selector = try self.allocator.dupe(u8, selector);
            errdefer self.allocator.free(owned_selector);

            const body_b64 = try encodeBase64Alloc(self.allocator, body_boc);
            errdefer self.allocator.free(body_b64);

            const body_hex = try allocHexLower(self.allocator, body_boc);
            errdefer self.allocator.free(body_hex);

            return .{
                .address = address,
                .selector = owned_selector,
                .body_boc = body_b64,
                .body_hex = body_hex,
                .success = true,
                .error_message = null,
            };
        }

        fn buildExternalMessageResultAlloc(
            self: *@This(),
            destination: []const u8,
            body_boc: []const u8,
            external_boc_bytes: []const u8,
            state_init_attached: bool,
        ) !tools_types.BuiltExternalMessageResult {
            const owned_destination = try self.allocator.dupe(u8, destination);
            errdefer self.allocator.free(owned_destination);

            const body_b64 = try encodeBase64Alloc(self.allocator, body_boc);
            errdefer self.allocator.free(body_b64);

            const external_b64 = try encodeBase64Alloc(self.allocator, external_boc_bytes);
            errdefer self.allocator.free(external_b64);

            const external_hex = try allocHexLower(self.allocator, external_boc_bytes);
            errdefer self.allocator.free(external_hex);

            return .{
                .destination = owned_destination,
                .body_boc = body_b64,
                .external_boc = external_b64,
                .external_hex = external_hex,
                .state_init_attached = state_init_attached,
                .success = true,
                .error_message = null,
            };
        }

        fn builtWalletError(_: []const u8, amount: u64, error_message: []const u8) tools_types.BuiltWalletMessageResult {
            return .{
                .wallet_address = "",
                .destination = "",
                .amount = amount,
                .wallet_id = 0,
                .seqno = 0,
                .external_boc = "",
                .external_hex = "",
                .state_init_attached = false,
                .success = false,
                .error_message = error_message,
            };
        }

        fn buildWalletMessageResultAlloc(
            self: *@This(),
            built: *signing.BuiltWalletExternalMessage,
            destination: []const u8,
            amount: u64,
        ) !tools_types.BuiltWalletMessageResult {
            const owned_destination = try self.allocator.dupe(u8, destination);
            errdefer self.allocator.free(owned_destination);

            const external_boc = try encodeBase64Alloc(self.allocator, built.boc);
            errdefer self.allocator.free(external_boc);

            const external_hex = try allocHexLower(self.allocator, built.boc);
            errdefer self.allocator.free(external_hex);

            const wallet_address = built.wallet_address;
            const raw_boc = built.boc;
            built.wallet_address = built.wallet_address[0..0];
            built.boc = built.boc[0..0];
            self.allocator.free(raw_boc);

            return .{
                .wallet_address = wallet_address,
                .destination = owned_destination,
                .amount = amount,
                .wallet_id = built.wallet_id,
                .seqno = built.seqno,
                .external_boc = external_boc,
                .external_hex = external_hex,
                .state_init_attached = built.state_init_attached,
                .success = true,
                .error_message = null,
            };
        }

        fn freeDecodedBodyAlloc(allocator: std.mem.Allocator, decoded: *tools_types.DecodedBodyResult) void {
            if (decoded.address.len > 0) allocator.free(decoded.address);
            if (decoded.selector.len > 0) allocator.free(decoded.selector);
            if (decoded.decoded_json.len > 0) allocator.free(decoded.decoded_json);
            decoded.* = undefined;
        }

        fn formatOptionalAddressAlloc(self: *@This(), maybe_addr: ?core_types.Address) !?[]u8 {
            if (maybe_addr) |addr| {
                return try address_mod.formatRaw(self.allocator, &addr);
            }
            return null;
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

        fn writeJsonFieldPrefix(writer: anytype, wrote_any: *bool, field_name: []const u8) !void {
            if (wrote_any.*) try writer.writeByte(',');
            wrote_any.* = true;
            try writeJsonString(writer, field_name);
            try writer.writeByte(':');
        }

        fn writeErrorObjectJson(writer: anytype, error_message: []const u8) !void {
            try writer.writeByte('{');
            var wrote_any = false;
            try writeJsonFieldPrefix(writer, &wrote_any, "error");
            try writeJsonString(writer, error_message);
            try writer.writeByte('}');
        }

        fn formatU256Alloc(self: *@This(), value: anytype) ![]u8 {
            return std.fmt.allocPrint(self.allocator, "{d}", .{value});
        }

        fn buildAbiSummaryJsonAlloc(self: *@This(), contract_address: []const u8) !BuiltAbiInspect {
            var abi_ref = try abi_adapter.queryAbiIpfs(self.client, contract_address);
            defer if (abi_ref) |*info| info.deinit(self.allocator);

            var abi_doc_error: ?[]const u8 = null;
            var abi_doc = abi_adapter.queryAbiDocumentAlloc(self.client, contract_address) catch |err| blk: {
                abi_doc_error = @errorName(err);
                break :blk null;
            };
            defer if (abi_doc) |*info| info.deinit(self.allocator);

            if (abi_ref == null and abi_doc == null and abi_doc_error == null) return .{};

            const owned_uri = if (abi_ref) |info|
                if (info.uri) |value| try self.allocator.dupe(u8, value) else null
            else
                null;
            errdefer if (owned_uri) |value| self.allocator.free(value);

            const owned_version = if (abi_doc) |*info|
                try self.allocator.dupe(u8, info.abi.version)
            else
                null;
            errdefer if (owned_version) |value| self.allocator.free(value);

            const functions: []tools_types.AbiFunctionTemplateResult = if (abi_doc) |*info|
                try self.buildAbiFunctionTemplateResultsAlloc(info.abi.functions)
            else
                &.{};
            errdefer {
                for (0..functions.len) |idx| @constCast(&functions[idx]).deinit(self.allocator);
                if (functions.len > 0) self.allocator.free(functions);
            }

            const events: []tools_types.AbiEventTemplateResult = if (abi_doc) |*info|
                try self.buildAbiEventTemplateResultsAlloc(info.abi.events)
            else
                &.{};
            errdefer {
                for (0..events.len) |idx| @constCast(&events[idx]).deinit(self.allocator);
                if (events.len > 0) self.allocator.free(events);
            }

            var writer = std.io.Writer.Allocating.init(self.allocator);
            errdefer writer.deinit();

            try writer.writer.writeByte('{');
            var wrote_any = false;

            if (abi_ref) |info| {
                try writeJsonFieldPrefix(&writer.writer, &wrote_any, "reference_kind");
                try writeJsonString(&writer.writer, info.version);
                if (info.uri) |value| {
                    try writeJsonFieldPrefix(&writer.writer, &wrote_any, "uri");
                    try writeJsonString(&writer.writer, value);
                }
            }

            if (abi_doc) |*info| {
                try writeJsonFieldPrefix(&writer.writer, &wrote_any, "document_version");
                try writeJsonString(&writer.writer, info.abi.version);

                try writeJsonFieldPrefix(&writer.writer, &wrote_any, "function_count");
                try writer.writer.print("{d}", .{info.abi.functions.len});

                try writeJsonFieldPrefix(&writer.writer, &wrote_any, "event_count");
                try writer.writer.print("{d}", .{info.abi.events.len});

                try writeJsonFieldPrefix(&writer.writer, &wrote_any, "functions");
                try writer.writer.writeByte('[');
                for (info.abi.functions, 0..) |function, idx| {
                    if (idx != 0) try writer.writer.writeByte(',');
                    const selector = try abi_adapter.buildFunctionSelectorAlloc(self.allocator, function);
                    defer self.allocator.free(selector);
                    const input_template = try buildAbiCliArgsTemplateAlloc(self.allocator, function.inputs);
                    defer self.allocator.free(input_template);
                    const named_input_template = try buildAbiNamedCliArgsTemplateAlloc(self.allocator, function.inputs);
                    defer self.allocator.free(named_input_template);
                    const output_template = try buildAbiDecodedOutputsTemplateAlloc(self.allocator, function.outputs);
                    defer self.allocator.free(output_template);

                    try writer.writer.writeByte('{');
                    var wrote_function = false;
                    try writeJsonFieldPrefix(&writer.writer, &wrote_function, "name");
                    try writeJsonString(&writer.writer, function.name);
                    try writeJsonFieldPrefix(&writer.writer, &wrote_function, "selector");
                    try writeJsonString(&writer.writer, selector);
                    if (function.opcode) |opcode| {
                        try writeJsonFieldPrefix(&writer.writer, &wrote_function, "opcode");
                        try writer.writer.print("\"0x{X}\"", .{opcode});
                    }
                    try writeJsonFieldPrefix(&writer.writer, &wrote_function, "input_template");
                    try writeJsonString(&writer.writer, input_template);
                    try writeJsonFieldPrefix(&writer.writer, &wrote_function, "named_input_template");
                    try writeJsonString(&writer.writer, named_input_template);
                    try writeJsonFieldPrefix(&writer.writer, &wrote_function, "decoded_output_template");
                    try writeJsonString(&writer.writer, output_template);
                    try writer.writer.writeByte('}');
                }
                try writer.writer.writeByte(']');

                try writeJsonFieldPrefix(&writer.writer, &wrote_any, "events");
                try writer.writer.writeByte('[');
                for (info.abi.events, 0..) |event, idx| {
                    if (idx != 0) try writer.writer.writeByte(',');
                    const selector = try abi_adapter.buildEventSelectorAlloc(self.allocator, event);
                    defer self.allocator.free(selector);
                    const decoded_template = try buildAbiDecodedOutputsTemplateAlloc(self.allocator, event.inputs);
                    defer self.allocator.free(decoded_template);

                    try writer.writer.writeByte('{');
                    var wrote_event = false;
                    try writeJsonFieldPrefix(&writer.writer, &wrote_event, "name");
                    try writeJsonString(&writer.writer, event.name);
                    try writeJsonFieldPrefix(&writer.writer, &wrote_event, "selector");
                    try writeJsonString(&writer.writer, selector);
                    if (event.opcode) |opcode| {
                        try writeJsonFieldPrefix(&writer.writer, &wrote_event, "opcode");
                        try writer.writer.print("\"0x{X}\"", .{opcode});
                    }
                    try writeJsonFieldPrefix(&writer.writer, &wrote_event, "decoded_fields_template");
                    try writeJsonString(&writer.writer, decoded_template);
                    try writer.writer.writeByte('}');
                }
                try writer.writer.writeByte(']');
            } else if (abi_doc_error) |value| {
                try writeJsonFieldPrefix(&writer.writer, &wrote_any, "document_error");
                try writeJsonString(&writer.writer, value);
            }

            try writer.writer.writeByte('}');

            return .{
                .uri = owned_uri,
                .version = owned_version,
                .json = try writer.toOwnedSlice(),
                .functions = functions,
                .events = events,
            };
        }

        fn buildAbiFunctionTemplateResultsAlloc(
            self: *@This(),
            functions: []const abi_adapter.FunctionDef,
        ) ![]tools_types.AbiFunctionTemplateResult {
            const items = try self.allocator.alloc(tools_types.AbiFunctionTemplateResult, functions.len);
            var built: usize = 0;
            errdefer {
                for (items[0..built]) |*item| item.deinit(self.allocator);
                if (items.len > 0) self.allocator.free(items);
            }

            for (functions, 0..) |function, idx| {
                items[idx] = .{
                    .name = try self.allocator.dupe(u8, function.name),
                    .selector = try abi_adapter.buildFunctionSelectorAlloc(self.allocator, function),
                    .opcode = function.opcode,
                    .input_template = try buildAbiCliArgsTemplateAlloc(self.allocator, function.inputs),
                    .named_input_template = try buildAbiNamedCliArgsTemplateAlloc(self.allocator, function.inputs),
                    .decoded_output_template = try buildAbiDecodedOutputsTemplateAlloc(self.allocator, function.outputs),
                    .inputs = try self.buildAbiParamTemplateResultsAlloc(function.inputs),
                    .outputs = try self.buildAbiParamTemplateResultsAlloc(function.outputs),
                };
                built += 1;
            }

            return items;
        }

        fn buildAbiParamTemplateResultsAlloc(
            self: *@This(),
            params: []const abi_adapter.ParamDef,
        ) ![]tools_types.AbiParamTemplateResult {
            const items = try self.allocator.alloc(tools_types.AbiParamTemplateResult, params.len);
            var built: usize = 0;
            errdefer {
                for (items[0..built]) |*item| item.deinit(self.allocator);
                if (items.len > 0) self.allocator.free(items);
            }

            for (params, 0..) |param, idx| {
                items[idx] = .{
                    .name = try self.allocator.dupe(u8, param.name),
                    .type_name = try self.allocator.dupe(u8, param.type_name),
                    .cli_template = try buildAbiCliValueTemplateAlloc(self.allocator, param),
                    .json_template = try buildAbiJsonValueTemplateAlloc(self.allocator, param),
                    .decoded_template = try buildAbiOutputValueTemplateAlloc(self.allocator, param),
                    .components = try self.buildAbiParamTemplateResultsAlloc(param.components),
                };
                built += 1;
            }

            return items;
        }

        fn buildAbiEventTemplateResultsAlloc(
            self: *@This(),
            events: []const abi_adapter.EventDef,
        ) ![]tools_types.AbiEventTemplateResult {
            const items = try self.allocator.alloc(tools_types.AbiEventTemplateResult, events.len);
            var built: usize = 0;
            errdefer {
                for (items[0..built]) |*item| item.deinit(self.allocator);
                if (items.len > 0) self.allocator.free(items);
            }

            for (events, 0..) |event, idx| {
                items[idx] = .{
                    .name = try self.allocator.dupe(u8, event.name),
                    .selector = try abi_adapter.buildEventSelectorAlloc(self.allocator, event),
                    .opcode = event.opcode,
                    .decoded_fields_template = try buildAbiDecodedOutputsTemplateAlloc(self.allocator, event.inputs),
                    .fields = try self.buildAbiParamTemplateResultsAlloc(event.inputs),
                };
                built += 1;
            }

            return items;
        }

        fn abiDescribeErrorAlloc(
            self: *@This(),
            source: []const u8,
            error_message: []const u8,
        ) !tools_types.AbiDescribeResult {
            return .{
                .source = try self.allocator.dupe(u8, source),
                .address = null,
                .version = "",
                .uri = null,
                .functions = &.{},
                .events = &.{},
                .success = false,
                .error_message = error_message,
            };
        }

        fn buildAbiDescribeResultAlloc(
            self: *@This(),
            source: []const u8,
            address: ?[]const u8,
            abi: *const abi_adapter.AbiInfo,
        ) !tools_types.AbiDescribeResult {
            const owned_source = try self.allocator.dupe(u8, source);
            errdefer self.allocator.free(owned_source);

            const owned_address = if (address) |value| try self.allocator.dupe(u8, value) else null;
            errdefer if (owned_address) |value| self.allocator.free(value);

            const version = try self.allocator.dupe(u8, abi.version);
            errdefer self.allocator.free(version);

            const uri = if (abi.uri) |value| try self.allocator.dupe(u8, value) else null;
            errdefer if (uri) |value| self.allocator.free(value);

            const functions = try self.buildAbiFunctionTemplateResultsAlloc(abi.functions);
            errdefer {
                for (functions) |*item| item.deinit(self.allocator);
                if (functions.len > 0) self.allocator.free(functions);
            }

            const events = try self.buildAbiEventTemplateResultsAlloc(abi.events);
            errdefer {
                for (events) |*item| item.deinit(self.allocator);
                if (events.len > 0) self.allocator.free(events);
            }

            return .{
                .source = owned_source,
                .address = owned_address,
                .version = version,
                .uri = uri,
                .functions = functions,
                .events = events,
                .success = true,
                .error_message = null,
            };
        }

        fn writeWalletInspectJson(self: *@This(), writer: anytype, contract_address: []const u8) !void {
            const info = signing.getWalletInfo(self.client, contract_address) catch |err| {
                return writeErrorObjectJson(writer, @errorName(err));
            };

            const public_key_hex = try allocHexLower(self.allocator, &info.public_key);
            defer self.allocator.free(public_key_hex);

            try writer.writeByte('{');
            var wrote_any = false;
            try writeJsonFieldPrefix(writer, &wrote_any, "seqno");
            try writer.print("{d}", .{info.seqno});
            try writeJsonFieldPrefix(writer, &wrote_any, "wallet_id");
            try writer.print("{d}", .{info.wallet_id});
            try writeJsonFieldPrefix(writer, &wrote_any, "public_key");
            try writeJsonString(writer, public_key_hex);
            try writer.writeByte('}');
        }

        fn writeJettonMasterInspectJson(self: *@This(), writer: anytype, contract_address: []const u8) !void {
            if (!supports_standard_wrappers) {
                return writeErrorObjectJson(writer, "UnsupportedClientType");
            }

            var master = JettonMasterClient.init(contract_address, self.client);
            var data = master.getJettonData() catch |err| {
                return writeErrorObjectJson(writer, @errorName(err));
            };
            defer data.deinit(self.allocator);

            const total_supply = try self.formatU256Alloc(data.total_supply);
            defer self.allocator.free(total_supply);
            const admin = if (data.admin) |value| try address_mod.formatRaw(self.allocator, &value) else null;
            defer if (admin) |value| self.allocator.free(value);

            try writer.writeByte('{');
            var wrote_any = false;
            try writeJsonFieldPrefix(writer, &wrote_any, "total_supply");
            try writeJsonString(writer, total_supply);
            try writeJsonFieldPrefix(writer, &wrote_any, "mintable");
            try writer.writeAll(if (data.mintable) "true" else "false");
            try writeJsonFieldPrefix(writer, &wrote_any, "admin");
            if (admin) |value| {
                try writeJsonString(writer, value);
            } else {
                try writer.writeAll("null");
            }
            try writeJsonFieldPrefix(writer, &wrote_any, "content_uri");
            if (data.content_uri) |value| {
                try writeJsonString(writer, value);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeByte('}');
        }

        fn writeJettonWalletInspectJson(self: *@This(), writer: anytype, contract_address: []const u8) !void {
            if (!supports_standard_wrappers) {
                return writeErrorObjectJson(writer, "UnsupportedClientType");
            }

            var wallet_contract = JettonWalletClient.init(contract_address, self.client);
            var data = wallet_contract.getWalletData() catch |err| {
                return writeErrorObjectJson(writer, @errorName(err));
            };
            defer data.deinit(self.allocator);

            const balance = try self.formatU256Alloc(data.balance);
            defer self.allocator.free(balance);

            try writer.writeByte('{');
            var wrote_any = false;
            try writeJsonFieldPrefix(writer, &wrote_any, "balance");
            try writeJsonString(writer, balance);
            try writeJsonFieldPrefix(writer, &wrote_any, "owner");
            try writeJsonString(writer, data.owner);
            try writeJsonFieldPrefix(writer, &wrote_any, "master");
            try writeJsonString(writer, data.master);
            try writer.writeByte('}');
        }

        fn writeNFTItemInspectJson(self: *@This(), writer: anytype, contract_address: []const u8) !void {
            if (!supports_standard_wrappers) {
                return writeErrorObjectJson(writer, "UnsupportedClientType");
            }

            var item = NFTItemClient.init(contract_address, self.client);
            var data = item.getNFTData() catch |err| {
                return writeErrorObjectJson(writer, @errorName(err));
            };
            defer data.deinit(self.allocator);

            const index = try self.formatU256Alloc(data.index);
            defer self.allocator.free(index);
            const owner = if (data.owner) |value| try address_mod.formatRaw(self.allocator, &value) else null;
            defer if (owner) |value| self.allocator.free(value);
            const collection = if (data.collection) |value| try address_mod.formatRaw(self.allocator, &value) else null;
            defer if (collection) |value| self.allocator.free(value);

            try writer.writeByte('{');
            var wrote_any = false;
            try writeJsonFieldPrefix(writer, &wrote_any, "index");
            try writeJsonString(writer, index);
            try writeJsonFieldPrefix(writer, &wrote_any, "owner");
            if (owner) |value| {
                try writeJsonString(writer, value);
            } else {
                try writer.writeAll("null");
            }
            try writeJsonFieldPrefix(writer, &wrote_any, "collection");
            if (collection) |value| {
                try writeJsonString(writer, value);
            } else {
                try writer.writeAll("null");
            }
            try writeJsonFieldPrefix(writer, &wrote_any, "content_uri");
            if (data.content_uri) |value| {
                try writeJsonString(writer, value);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeByte('}');
        }

        fn writeNFTCollectionInspectJson(self: *@This(), writer: anytype, contract_address: []const u8) !void {
            if (!supports_standard_wrappers) {
                return writeErrorObjectJson(writer, "UnsupportedClientType");
            }

            var collection = NFTCollectionClient.init(contract_address, self.client);
            var data = collection.getCollectionData() catch |err| {
                return writeErrorObjectJson(writer, @errorName(err));
            };
            defer data.deinit(self.allocator);

            const next_item_index = try self.formatU256Alloc(data.next_item_index);
            defer self.allocator.free(next_item_index);
            const owner = if (data.owner) |value| try address_mod.formatRaw(self.allocator, &value) else null;
            defer if (owner) |value| self.allocator.free(value);

            try writer.writeByte('{');
            var wrote_any = false;
            try writeJsonFieldPrefix(writer, &wrote_any, "owner");
            if (owner) |value| {
                try writeJsonString(writer, value);
            } else {
                try writer.writeAll("null");
            }
            try writeJsonFieldPrefix(writer, &wrote_any, "next_item_index");
            try writeJsonString(writer, next_item_index);
            try writeJsonFieldPrefix(writer, &wrote_any, "content_uri");
            if (data.content_uri) |value| {
                try writeJsonString(writer, value);
            } else {
                try writer.writeAll("null");
            }
            try writer.writeByte('}');
        }

        fn buildContractDetailsJsonAlloc(
            self: *@This(),
            contract_address: []const u8,
            supported: abi_adapter.SupportedInterfaces,
        ) !?[]u8 {
            var writer = std.io.Writer.Allocating.init(self.allocator);
            errdefer writer.deinit();

            try writer.writer.writeByte('{');
            var wrote_any = false;

            if (supported.has_wallet) {
                try writeJsonFieldPrefix(&writer.writer, &wrote_any, "wallet");
                try self.writeWalletInspectJson(&writer.writer, contract_address);
            }

            if (supported.has_jetton_master) {
                try writeJsonFieldPrefix(&writer.writer, &wrote_any, "jetton_master");
                try self.writeJettonMasterInspectJson(&writer.writer, contract_address);
            }

            if (supported.has_jetton_wallet) {
                try writeJsonFieldPrefix(&writer.writer, &wrote_any, "jetton_wallet");
                try self.writeJettonWalletInspectJson(&writer.writer, contract_address);
            }

            if (supported.has_nft_item) {
                try writeJsonFieldPrefix(&writer.writer, &wrote_any, "nft_item");
                try self.writeNFTItemInspectJson(&writer.writer, contract_address);
            }

            if (supported.has_nft_collection) {
                try writeJsonFieldPrefix(&writer.writer, &wrote_any, "nft_collection");
                try self.writeNFTCollectionInspectJson(&writer.writer, contract_address);
            }

            try writer.writer.writeByte('}');

            if (!wrote_any) {
                writer.deinit();
                return null;
            }

            return try writer.toOwnedSlice();
        }

        fn decodedBodyError(
            address: []const u8,
            kind: tools_types.DecodedBodyKind,
            error_message: []const u8,
        ) tools_types.DecodedBodyResult {
            return .{
                .address = address,
                .kind = kind,
                .selector = "",
                .opcode = null,
                .decoded_json = "",
                .success = false,
                .error_message = error_message,
            };
        }

        fn tryDecodeMessageFunctionAtAlloc(
            self: *@This(),
            owned_contract_address: []u8,
            body_boc: []const u8,
        ) ?tools_types.DecodedBodyResult {
            var abi = abi_adapter.queryAbiDocumentAlloc(self.client, owned_contract_address) catch {
                self.allocator.free(owned_contract_address);
                return null;
            } orelse {
                self.allocator.free(owned_contract_address);
                return null;
            };
            defer abi.deinit(self.allocator);

            const function = abi_adapter.resolveFunctionByBodyBoc(&abi.abi, null, body_boc) catch {
                self.allocator.free(owned_contract_address);
                return null;
            };

            const selector = abi_adapter.buildFunctionSelectorAlloc(self.allocator, function.*) catch {
                self.allocator.free(owned_contract_address);
                return null;
            };

            const decoded_json = abi_adapter.decodeFunctionBodyJsonAlloc(self.allocator, function.*, body_boc) catch {
                self.allocator.free(selector);
                self.allocator.free(owned_contract_address);
                return null;
            };

            return .{
                .address = owned_contract_address,
                .kind = .function,
                .selector = selector,
                .opcode = function.opcode,
                .decoded_json = decoded_json,
                .success = true,
                .error_message = null,
            };
        }

        fn tryDecodeMessageEventAtAlloc(
            self: *@This(),
            owned_contract_address: []u8,
            body_boc: []const u8,
        ) ?tools_types.DecodedBodyResult {
            var abi = abi_adapter.queryAbiDocumentAlloc(self.client, owned_contract_address) catch {
                self.allocator.free(owned_contract_address);
                return null;
            } orelse {
                self.allocator.free(owned_contract_address);
                return null;
            };
            defer abi.deinit(self.allocator);

            const event = abi_adapter.resolveEventByBodyBoc(&abi.abi, null, body_boc) catch {
                self.allocator.free(owned_contract_address);
                return null;
            };

            const selector = abi_adapter.buildEventSelectorAlloc(self.allocator, event.*) catch {
                self.allocator.free(owned_contract_address);
                return null;
            };

            const decoded_json = abi_adapter.decodeEventBodyJsonAlloc(self.allocator, event.*, body_boc) catch {
                self.allocator.free(selector);
                self.allocator.free(owned_contract_address);
                return null;
            };

            return .{
                .address = owned_contract_address,
                .kind = .event,
                .selector = selector,
                .opcode = event.opcode,
                .decoded_json = decoded_json,
                .success = true,
                .error_message = null,
            };
        }

        fn tryDecodeMessageBodyAutoAlloc(
            self: *@This(),
            msg: *const core_types.Message,
        ) ?tools_types.DecodedBodyResult {
            const body = msg.body orelse return null;
            const body_boc = boc.serializeBoc(self.allocator, body) catch return null;
            defer self.allocator.free(body_boc);

            if (msg.destination) |addr| {
                const raw = address_mod.formatRaw(self.allocator, &addr) catch return null;
                if (self.tryDecodeMessageFunctionAtAlloc(raw, body_boc)) |decoded| {
                    return decoded;
                }
            }

            if (msg.source) |addr| {
                const raw = address_mod.formatRaw(self.allocator, &addr) catch return null;
                if (self.tryDecodeMessageEventAtAlloc(raw, body_boc)) |decoded| {
                    return decoded;
                }
            }

            return null;
        }

        fn buildMessageResultAlloc(self: *@This(), msg: *const core_types.Message) !tools_types.MessageResult {
            const hash = try self.allocator.dupe(u8, msg.hash);
            errdefer self.allocator.free(hash);

            const source = try self.formatOptionalAddressAlloc(msg.source);
            errdefer if (source) |value| self.allocator.free(value);

            const destination = try self.formatOptionalAddressAlloc(msg.destination);
            errdefer if (destination) |value| self.allocator.free(value);

            const body_boc = if (msg.body) |body| blk: {
                const serialized = try boc.serializeBoc(self.allocator, body);
                defer self.allocator.free(serialized);
                break :blk try encodeBase64Alloc(self.allocator, serialized);
            } else null;
            errdefer if (body_boc) |value| self.allocator.free(value);

            const raw_body_utf8 = if (msg.raw_body.len > 0 and std.unicode.utf8ValidateSlice(msg.raw_body))
                try self.allocator.dupe(u8, msg.raw_body)
            else
                null;
            errdefer if (raw_body_utf8) |value| self.allocator.free(value);

            const raw_body_base64 = if (msg.raw_body.len > 0 and !std.unicode.utf8ValidateSlice(msg.raw_body))
                try encodeBase64Alloc(self.allocator, msg.raw_body)
            else
                null;
            errdefer if (raw_body_base64) |value| self.allocator.free(value);

            var decoded_body = self.tryDecodeMessageBodyAutoAlloc(msg);
            errdefer if (decoded_body) |*value| freeDecodedBodyAlloc(self.allocator, value);

            return .{
                .hash = hash,
                .source = source,
                .destination = destination,
                .value = msg.value,
                .body_bits = if (msg.body) |body| body.bit_len else 0,
                .body_refs = if (msg.body) |body| body.ref_cnt else 0,
                .body_boc = body_boc,
                .raw_body_utf8 = raw_body_utf8,
                .raw_body_base64 = raw_body_base64,
                .decoded_body = decoded_body,
            };
        }

        fn buildTxSummaryResultAlloc(self: *@This(), tx: *const core_types.Transaction) !tools_types.TxResult {
            const hash = try self.allocator.dupe(u8, tx.hash);
            errdefer self.allocator.free(hash);

            const from = if (tx.in_msg) |msg|
                try self.formatOptionalAddressAlloc(msg.source)
            else
                null;
            errdefer if (from) |value| self.allocator.free(value);

            const to = if (tx.in_msg) |msg|
                try self.formatOptionalAddressAlloc(msg.destination)
            else
                null;
            errdefer if (to) |value| self.allocator.free(value);

            return .{
                .hash = hash,
                .lt = tx.lt,
                .timestamp = tx.timestamp,
                .from = from,
                .to = to,
                .value = if (tx.in_msg) |msg| msg.value else 0,
                .status = .confirmed,
                .success = true,
                .error_message = null,
            };
        }

        fn buildTransactionDetailResultAlloc(self: *@This(), tx: *const core_types.Transaction) !tools_types.TransactionDetailResult {
            const hash = try self.allocator.dupe(u8, tx.hash);
            errdefer self.allocator.free(hash);

            const in_message = if (tx.in_msg) |msg|
                try self.buildMessageResultAlloc(msg)
            else
                null;
            errdefer if (in_message) |value| {
                var owned = value;
                owned.deinit(self.allocator);
            };

            const out_messages = try self.allocator.alloc(tools_types.MessageResult, tx.out_msgs.len);
            var built: usize = 0;
            errdefer {
                for (out_messages[0..built]) |*msg| msg.deinit(self.allocator);
                if (out_messages.len > 0) self.allocator.free(out_messages);
            }

            for (tx.out_msgs, 0..) |msg, idx| {
                out_messages[idx] = try self.buildMessageResultAlloc(msg);
                built += 1;
            }

            return .{
                .hash = hash,
                .lt = tx.lt,
                .timestamp = tx.timestamp,
                .in_message = in_message,
                .out_messages = out_messages,
                .success = true,
                .error_message = null,
            };
        }

        fn transactionListError(address: []const u8, error_message: []const u8) tools_types.TransactionListResult {
            return .{
                .address = address,
                .items = &.{},
                .success = false,
                .error_message = error_message,
            };
        }

        fn transactionDetailError(lt: i64, error_message: []const u8) tools_types.TransactionDetailResult {
            return .{
                .hash = "",
                .lt = lt,
                .timestamp = 0,
                .in_message = null,
                .out_messages = &.{},
                .success = false,
                .error_message = error_message,
            };
        }

        fn contractInspectError(
            contract_address: []const u8,
            error_message: []const u8,
        ) tools_types.ContractInspectResult {
            return .{
                .address = contract_address,
                .has_wallet = false,
                .has_jetton = false,
                .has_jetton_master = false,
                .has_jetton_wallet = false,
                .has_nft = false,
                .has_nft_item = false,
                .has_nft_collection = false,
                .has_abi = false,
                .abi_uri = null,
                .abi_version = null,
                .abi_json = null,
                .functions = &.{},
                .events = &.{},
                .details_json = null,
                .success = false,
                .error_message = error_message,
            };
        }

        /// Decode a function body using a provided ABI document.
        pub fn decodeFunctionBodyAbi(
            self: *@This(),
            contract_address: []const u8,
            abi_json: []const u8,
            body_boc: []const u8,
            function_selector: ?[]const u8,
        ) !tools_types.DecodedBodyResult {
            var abi = abi_adapter.loadAbiInfoSourceAlloc(self.allocator, abi_json) catch |err| {
                return decodedBodyError(contract_address, .function, @errorName(err));
            };
            defer abi.deinit(self.allocator);

            const function = abi_adapter.resolveFunctionByBodyBoc(&abi.abi, function_selector, body_boc) catch |err| {
                return decodedBodyError(contract_address, .function, @errorName(err));
            };

            const selector = abi_adapter.buildFunctionSelectorAlloc(self.allocator, function.*) catch |err| {
                return decodedBodyError(contract_address, .function, @errorName(err));
            };
            errdefer self.allocator.free(selector);

            const decoded_json = abi_adapter.decodeFunctionBodyJsonAlloc(self.allocator, function.*, body_boc) catch |err| {
                self.allocator.free(selector);
                return decodedBodyError(contract_address, .function, @errorName(err));
            };
            errdefer self.allocator.free(decoded_json);

            return .{
                .address = contract_address,
                .kind = .function,
                .selector = selector,
                .opcode = function.opcode,
                .decoded_json = decoded_json,
                .success = true,
                .error_message = null,
            };
        }

        /// Discover ABI on-chain and decode a function body.
        pub fn decodeFunctionBodyAuto(
            self: *@This(),
            contract_address: []const u8,
            body_boc: []const u8,
            function_selector: ?[]const u8,
        ) !tools_types.DecodedBodyResult {
            var abi = abi_adapter.queryAbiDocumentAlloc(self.client, contract_address) catch |err| {
                return decodedBodyError(contract_address, .function, @errorName(err));
            } orelse return decodedBodyError(contract_address, .function, "AbiNotFound");
            defer abi.deinit(self.allocator);

            const function = abi_adapter.resolveFunctionByBodyBoc(&abi.abi, function_selector, body_boc) catch |err| {
                return decodedBodyError(contract_address, .function, @errorName(err));
            };

            const selector = abi_adapter.buildFunctionSelectorAlloc(self.allocator, function.*) catch |err| {
                return decodedBodyError(contract_address, .function, @errorName(err));
            };
            errdefer self.allocator.free(selector);

            const decoded_json = abi_adapter.decodeFunctionBodyJsonAlloc(self.allocator, function.*, body_boc) catch |err| {
                self.allocator.free(selector);
                return decodedBodyError(contract_address, .function, @errorName(err));
            };
            errdefer self.allocator.free(decoded_json);

            return .{
                .address = contract_address,
                .kind = .function,
                .selector = selector,
                .opcode = function.opcode,
                .decoded_json = decoded_json,
                .success = true,
                .error_message = null,
            };
        }

        /// Decode an event body using a provided ABI document.
        pub fn decodeEventBodyAbi(
            self: *@This(),
            contract_address: []const u8,
            abi_json: []const u8,
            body_boc: []const u8,
            event_selector: ?[]const u8,
        ) !tools_types.DecodedBodyResult {
            var abi = abi_adapter.loadAbiInfoSourceAlloc(self.allocator, abi_json) catch |err| {
                return decodedBodyError(contract_address, .event, @errorName(err));
            };
            defer abi.deinit(self.allocator);

            const event = abi_adapter.resolveEventByBodyBoc(&abi.abi, event_selector, body_boc) catch |err| {
                return decodedBodyError(contract_address, .event, @errorName(err));
            };

            const selector = abi_adapter.buildEventSelectorAlloc(self.allocator, event.*) catch |err| {
                return decodedBodyError(contract_address, .event, @errorName(err));
            };
            errdefer self.allocator.free(selector);

            const decoded_json = abi_adapter.decodeEventBodyJsonAlloc(self.allocator, event.*, body_boc) catch |err| {
                self.allocator.free(selector);
                return decodedBodyError(contract_address, .event, @errorName(err));
            };
            errdefer self.allocator.free(decoded_json);

            return .{
                .address = contract_address,
                .kind = .event,
                .selector = selector,
                .opcode = event.opcode,
                .decoded_json = decoded_json,
                .success = true,
                .error_message = null,
            };
        }

        /// Discover ABI on-chain and decode an event body.
        pub fn decodeEventBodyAuto(
            self: *@This(),
            contract_address: []const u8,
            body_boc: []const u8,
            event_selector: ?[]const u8,
        ) !tools_types.DecodedBodyResult {
            var abi = abi_adapter.queryAbiDocumentAlloc(self.client, contract_address) catch |err| {
                return decodedBodyError(contract_address, .event, @errorName(err));
            } orelse return decodedBodyError(contract_address, .event, "AbiNotFound");
            defer abi.deinit(self.allocator);

            const event = abi_adapter.resolveEventByBodyBoc(&abi.abi, event_selector, body_boc) catch |err| {
                return decodedBodyError(contract_address, .event, @errorName(err));
            };

            const selector = abi_adapter.buildEventSelectorAlloc(self.allocator, event.*) catch |err| {
                return decodedBodyError(contract_address, .event, @errorName(err));
            };
            errdefer self.allocator.free(selector);

            const decoded_json = abi_adapter.decodeEventBodyJsonAlloc(self.allocator, event.*, body_boc) catch |err| {
                self.allocator.free(selector);
                return decodedBodyError(contract_address, .event, @errorName(err));
            };
            errdefer self.allocator.free(decoded_json);

            return .{
                .address = contract_address,
                .kind = .event,
                .selector = selector,
                .opcode = event.opcode,
                .decoded_json = decoded_json,
                .success = true,
                .error_message = null,
            };
        }

        /// Load any ABI source and return structured function/event call templates.
        pub fn describeAbi(self: *@This(), abi_source: []const u8) !tools_types.AbiDescribeResult {
            var abi = abi_adapter.loadAbiInfoSourceAlloc(self.allocator, abi_source) catch |err| {
                return try self.abiDescribeErrorAlloc(abi_source, @errorName(err));
            };
            defer abi.deinit(self.allocator);

            return self.buildAbiDescribeResultAlloc(abi_source, null, &abi.abi) catch |err| {
                return try self.abiDescribeErrorAlloc(abi_source, @errorName(err));
            };
        }

        /// Discover a contract ABI on-chain and return structured function/event call templates.
        pub fn describeAbiAuto(self: *@This(), contract_address: []const u8) !tools_types.AbiDescribeResult {
            var abi = abi_adapter.queryAbiDocumentAlloc(self.client, contract_address) catch |err| {
                const source = try std.fmt.allocPrint(self.allocator, "auto:{s}", .{contract_address});
                defer self.allocator.free(source);
                return try self.abiDescribeErrorAlloc(source, @errorName(err));
            } orelse {
                const source = try std.fmt.allocPrint(self.allocator, "auto:{s}", .{contract_address});
                defer self.allocator.free(source);
                return try self.abiDescribeErrorAlloc(source, "AbiNotFound");
            };
            defer abi.deinit(self.allocator);

            const source = try std.fmt.allocPrint(self.allocator, "auto:{s}", .{contract_address});
            defer self.allocator.free(source);

            return self.buildAbiDescribeResultAlloc(source, contract_address, &abi.abi) catch |err| {
                const fallback_source = try std.fmt.allocPrint(self.allocator, "auto:{s}", .{contract_address});
                defer self.allocator.free(fallback_source);
                return try self.abiDescribeErrorAlloc(fallback_source, @errorName(err));
            };
        }

        /// List recent transactions for an address using the current provider path.
        pub fn getTransactions(self: *@This(), account_address: []const u8, limit: u32) !tools_types.TransactionListResult {
            const txs = self.client.getTransactions(account_address, limit) catch |err| {
                return transactionListError(account_address, @errorName(err));
            };
            defer self.client.freeTransactions(txs);

            const items = try self.allocator.alloc(tools_types.TxResult, txs.len);
            var built: usize = 0;
            errdefer {
                for (items[0..built]) |*item| item.deinit(self.allocator);
                if (items.len > 0) self.allocator.free(items);
            }

            for (txs, 0..) |*tx, idx| {
                items[idx] = try self.buildTxSummaryResultAlloc(tx);
                built += 1;
            }

            return .{
                .address = account_address,
                .items = items,
                .success = true,
                .error_message = null,
            };
        }

        /// Lookup one transaction and best-effort decode its message bodies via ABI discovery.
        pub fn lookupTransaction(self: *@This(), lt: i64, hash: []const u8) !tools_types.TransactionDetailResult {
            var tx = (self.client.lookupTx(lt, hash) catch |err| {
                return transactionDetailError(lt, @errorName(err));
            }) orelse return transactionDetailError(lt, "NotFound");
            defer self.client.freeTransaction(&tx);

            return self.buildTransactionDetailResultAlloc(&tx) catch |err| {
                return transactionDetailError(lt, @errorName(err));
            };
        }

        /// Inspect a contract, summarize supported interfaces, discovered ABI, and best-effort standard metadata.
        pub fn inspectContract(self: *@This(), contract_address: []const u8) !tools_types.ContractInspectResult {
            const supported_opt = abi_adapter.querySupportedInterfaces(self.client, contract_address) catch |err| {
                return contractInspectError(contract_address, @errorName(err));
            };
            const supported = supported_opt orelse abi_adapter.SupportedInterfaces{
                .has_wallet = false,
                .has_jetton = false,
                .has_jetton_master = false,
                .has_jetton_wallet = false,
                .has_nft = false,
                .has_nft_item = false,
                .has_nft_collection = false,
                .has_abi = false,
            };

            var abi_summary = self.buildAbiSummaryJsonAlloc(contract_address) catch |err| {
                return contractInspectError(contract_address, @errorName(err));
            };
            errdefer abi_summary.deinit(self.allocator);

            const details_json = self.buildContractDetailsJsonAlloc(contract_address, supported) catch |err| {
                abi_summary.deinit(self.allocator);
                return contractInspectError(contract_address, @errorName(err));
            };
            errdefer if (details_json) |value| self.allocator.free(value);

            return .{
                .address = contract_address,
                .has_wallet = supported.has_wallet,
                .has_jetton = supported.has_jetton,
                .has_jetton_master = supported.has_jetton_master,
                .has_jetton_wallet = supported.has_jetton_wallet,
                .has_nft = supported.has_nft,
                .has_nft_item = supported.has_nft_item,
                .has_nft_collection = supported.has_nft_collection,
                .has_abi = supported.has_abi,
                .abi_uri = abi_summary.uri,
                .abi_version = abi_summary.version,
                .abi_json = abi_summary.json,
                .functions = abi_summary.functions,
                .events = abi_summary.events,
                .details_json = details_json,
                .success = true,
                .error_message = null,
            };
        }

        /// Compute the deployed contract address for a StateInit BoC and workchain.
        pub fn computeStateInitAddress(
            self: *@This(),
            workchain: i8,
            state_init_boc: []const u8,
        ) !tools_types.AddressResult {
            const addr = state_init.computeStateInitAddressFromBoc(self.allocator, workchain, state_init_boc) catch |err| {
                return tools_types.AddressResult{
                    .raw_address = "",
                    .user_friendly_address = "",
                    .workchain = workchain,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };

            const raw_address = address_mod.formatRaw(self.allocator, &addr) catch |err| {
                return tools_types.AddressResult{
                    .raw_address = "",
                    .user_friendly_address = "",
                    .workchain = workchain,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            errdefer self.allocator.free(raw_address);

            const user_friendly_address = address_mod.addressToUserFriendlyAlloc(self.allocator, &addr, true, false) catch |err| {
                return tools_types.AddressResult{
                    .raw_address = "",
                    .user_friendly_address = "",
                    .workchain = workchain,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            errdefer self.allocator.free(user_friendly_address);

            return tools_types.AddressResult{
                .raw_address = raw_address,
                .user_friendly_address = user_friendly_address,
                .workchain = workchain,
                .success = true,
                .error_message = null,
            };
        }

        /// Derive the default wallet v4 address and StateInit from the configured private key.
        pub fn deriveWalletInit(self: *@This()) !tools_types.WalletInitResult {
            const private_key = self.config.wallet_private_key orelse {
                return tools_types.WalletInitResult{
                    .raw_address = "",
                    .user_friendly_address = "",
                    .workchain = self.config.wallet_workchain,
                    .wallet_id = self.config.wallet_id,
                    .public_key_hex = "",
                    .state_init_boc = "",
                    .success = false,
                    .error_message = "Wallet not configured",
                };
            };

            return self.buildWalletInitResultAlloc(private_key) catch |err| {
                return tools_types.WalletInitResult{
                    .raw_address = "",
                    .user_friendly_address = "",
                    .workchain = self.config.wallet_workchain,
                    .wallet_id = self.config.wallet_id,
                    .public_key_hex = "",
                    .state_init_boc = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
        }

        /// Run any contract get-method with typed stack arguments
        pub fn runGetMethod(self: *@This(), contract_address: []const u8, method: []const u8, args: []const contract.StackArg) !tools_types.RunMethodResult {
            const stack_input = contract.buildStackArgsJsonAlloc(self.allocator, args) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = method,
                    .exit_code = -1,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.allocator.free(stack_input);

            var result = self.client.runGetMethodJson(contract_address, method, stack_input) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = method,
                    .exit_code = -1,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.client.freeRunGetMethodResponse(&result);

            const stack_json = contract.stackToJsonAlloc(self.allocator, result.stack) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = method,
                    .exit_code = result.exit_code,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };

            const logs = try self.allocator.dupe(u8, result.logs);
            return tools_types.RunMethodResult{
                .address = contract_address,
                .method = method,
                .exit_code = result.exit_code,
                .stack_json = stack_json,
                .decoded_json = null,
                .logs = logs,
                .success = true,
                .error_message = null,
            };
        }

        /// Run a get-method using ABI input/output definitions
        pub fn runGetMethodAbi(
            self: *@This(),
            contract_address: []const u8,
            abi_json: []const u8,
            function_name: []const u8,
            values: []const abi_adapter.AbiValue,
        ) !tools_types.RunMethodResult {
            var abi = abi_adapter.loadAbiInfoSourceAlloc(self.allocator, abi_json) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = -1,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer abi.deinit(self.client.allocator);

            const function = abi_adapter.resolveFunctionByValueCount(&abi.abi, function_name, values.len) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = -1,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };

            const prepared_values = if (function.inputs.len == values.len)
                null
            else
                abi_adapter.expandValuesForFunctionAlloc(self.allocator, function.*, values) catch |err| {
                    return tools_types.RunMethodResult{
                        .address = contract_address,
                        .method = function_name,
                        .exit_code = -1,
                        .stack_json = "[]",
                        .decoded_json = null,
                        .logs = "",
                        .success = false,
                        .error_message = @errorName(err),
                    };
                };
            defer if (prepared_values) |owned| self.allocator.free(owned);

            var args = abi_adapter.buildStackArgsFromFunctionAlloc(
                self.allocator,
                function.*,
                if (prepared_values) |owned| owned else values,
            ) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = -1,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer args.deinit(self.allocator);

            const stack_input = contract.buildStackArgsJsonAlloc(self.allocator, args.args) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = -1,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.allocator.free(stack_input);

            var result = self.client.runGetMethodJson(contract_address, function.name, stack_input) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = -1,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.client.freeRunGetMethodResponse(&result);

            const stack_json = contract.stackToJsonAlloc(self.allocator, result.stack) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = result.exit_code,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            errdefer self.allocator.free(stack_json);

            const logs = try self.allocator.dupe(u8, result.logs);
            errdefer self.allocator.free(logs);

            const decoded_json = abi_adapter.decodeFunctionOutputsJsonAlloc(
                self.allocator,
                function.*,
                result.stack,
            ) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = result.exit_code,
                    .stack_json = stack_json,
                    .decoded_json = null,
                    .logs = logs,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            errdefer self.allocator.free(decoded_json);

            return tools_types.RunMethodResult{
                .address = contract_address,
                .method = function_name,
                .exit_code = result.exit_code,
                .stack_json = stack_json,
                .decoded_json = decoded_json,
                .logs = logs,
                .success = true,
                .error_message = null,
            };
        }

        /// Run a get-method by discovering the contract ABI URI on-chain
        pub fn runGetMethodAuto(
            self: *@This(),
            contract_address: []const u8,
            function_name: []const u8,
            values: []const abi_adapter.AbiValue,
        ) !tools_types.RunMethodResult {
            var abi = abi_adapter.queryAbiDocumentAlloc(self.client, contract_address) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = -1,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            } orelse return tools_types.RunMethodResult{
                .address = contract_address,
                .method = function_name,
                .exit_code = -1,
                .stack_json = "[]",
                .decoded_json = null,
                .logs = "",
                .success = false,
                .error_message = "AbiNotFound",
            };
            defer abi.deinit(self.client.allocator);

            const function = abi_adapter.resolveFunctionByValueCount(&abi.abi, function_name, values.len) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = -1,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };

            const prepared_values = if (function.inputs.len == values.len)
                null
            else
                abi_adapter.expandValuesForFunctionAlloc(self.allocator, function.*, values) catch |err| {
                    return tools_types.RunMethodResult{
                        .address = contract_address,
                        .method = function_name,
                        .exit_code = -1,
                        .stack_json = "[]",
                        .decoded_json = null,
                        .logs = "",
                        .success = false,
                        .error_message = @errorName(err),
                    };
                };
            defer if (prepared_values) |owned| self.allocator.free(owned);

            var args = abi_adapter.buildStackArgsFromFunctionAlloc(
                self.allocator,
                function.*,
                if (prepared_values) |owned| owned else values,
            ) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = -1,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer args.deinit(self.allocator);

            const stack_input = contract.buildStackArgsJsonAlloc(self.allocator, args.args) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = -1,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.allocator.free(stack_input);

            var result = self.client.runGetMethodJson(contract_address, function.name, stack_input) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = -1,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.client.freeRunGetMethodResponse(&result);

            const stack_json = contract.stackToJsonAlloc(self.allocator, result.stack) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = result.exit_code,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            errdefer self.allocator.free(stack_json);

            const logs = try self.allocator.dupe(u8, result.logs);
            errdefer self.allocator.free(logs);

            const decoded_json = abi_adapter.decodeFunctionOutputsJsonAlloc(
                self.allocator,
                function.*,
                result.stack,
            ) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = result.exit_code,
                    .stack_json = stack_json,
                    .decoded_json = null,
                    .logs = logs,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            errdefer self.allocator.free(decoded_json);

            return tools_types.RunMethodResult{
                .address = contract_address,
                .method = function_name,
                .exit_code = result.exit_code,
                .stack_json = stack_json,
                .decoded_json = decoded_json,
                .logs = logs,
                .success = true,
                .error_message = null,
            };
        }

        /// Create payment invoice
        pub fn createInvoice(self: *@This(), amount: u64, description: []const u8) !tools_types.InvoiceResult {
            const dest = self.config.wallet_address orelse "";

            const invoice = paywatch.invoice.createInvoice(self.allocator, dest, amount, description) catch |err| {
                return tools_types.InvoiceResult{
                    .invoice_id = "",
                    .address = dest,
                    .amount = amount,
                    .comment = "",
                    .payment_url = "",
                    .expires_at = 0,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };

            return tools_types.InvoiceResult{
                .invoice_id = invoice.id,
                .address = invoice.address,
                .amount = invoice.amount,
                .comment = invoice.comment,
                .payment_url = invoice.payment_url,
                .expires_at = invoice.expires_at.?,
                .success = true,
                .error_message = null,
            };
        }

        /// Verify payment by comment
        pub fn verifyPayment(self: *@This(), comment: []const u8) !tools_types.VerifyResult {
            const dest = self.config.wallet_address orelse "";

            // Create temporary invoice for verification
            const temp_invoice = paywatch.invoice.Invoice{
                .id = "verify",
                .address = dest,
                .comment = comment,
                .amount = 0,
                .description = "",
                .payment_url = "",
                .created_at = std.time.timestamp(),
                .expires_at = null,
                .status = .pending,
            };

            const result = paywatch.verifier.verifyPayment(self.client, &temp_invoice) catch |err| {
                return tools_types.VerifyResult{
                    .verified = false,
                    .tx_hash = null,
                    .tx_lt = null,
                    .amount = null,
                    .sender = null,
                    .timestamp = null,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };

            return tools_types.VerifyResult{
                .verified = result.verified,
                .tx_hash = result.tx_hash,
                .tx_lt = result.tx_lt,
                .amount = result.amount,
                .sender = result.sender,
                .timestamp = result.timestamp,
                .success = true,
                .error_message = null,
            };
        }

        /// Wait for payment with timeout
        pub fn waitPayment(self: *@This(), comment: []const u8, timeout_ms: u32) !tools_types.VerifyResult {
            const dest = self.config.wallet_address orelse "";

            const temp_invoice = paywatch.invoice.Invoice{
                .id = "wait",
                .address = dest,
                .comment = comment,
                .amount = 0,
                .description = "",
                .payment_url = "",
                .created_at = std.time.timestamp(),
                .expires_at = std.time.timestamp() + @divTrunc(timeout_ms, 1000),
                .status = .pending,
            };

            const result = paywatch.watcher.waitPaymentWithClient(
                self.client,
                &temp_invoice,
                5000, // 5s poll interval
                timeout_ms,
            ) catch |err| {
                return tools_types.VerifyResult{
                    .verified = false,
                    .tx_hash = null,
                    .tx_lt = null,
                    .amount = null,
                    .sender = null,
                    .timestamp = null,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };

            return tools_types.VerifyResult{
                .verified = result.found,
                .tx_hash = result.tx_hash,
                .tx_lt = result.tx_lt,
                .amount = result.amount,
                .sender = result.sender,
                .timestamp = result.confirmed_at,
                .success = true,
                .error_message = null,
            };
        }

        /// Get Jetton balance
        pub fn getJettonBalance(self: *@This(), wallet_address: []const u8, jetton_master: []const u8) !tools_types.JettonBalanceResult {
            var result = self.client.runGetMethod(wallet_address, "get_wallet_data", &.{}) catch |err| {
                return tools_types.JettonBalanceResult{
                    .address = wallet_address,
                    .jetton_master = jetton_master,
                    .balance = "0",
                    .decimals = 9,
                    .symbol = null,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.client.freeRunGetMethodResponse(&result);

            if (result.exit_code != 0) {
                return tools_types.JettonBalanceResult{
                    .address = wallet_address,
                    .jetton_master = jetton_master,
                    .balance = "0",
                    .decimals = 9,
                    .symbol = null,
                    .success = false,
                    .error_message = "ContractError",
                };
            }

            var data = jetton.parseJettonWalletData(self.allocator, result.stack) catch |err| {
                return tools_types.JettonBalanceResult{
                    .address = wallet_address,
                    .jetton_master = jetton_master,
                    .balance = "0",
                    .decimals = 9,
                    .symbol = null,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer data.deinit(self.allocator);

            const balance = try std.fmt.allocPrint(self.allocator, "{d}", .{data.balance});

            return tools_types.JettonBalanceResult{
                .address = wallet_address,
                .jetton_master = jetton_master,
                .balance = balance,
                .decimals = 9,
                .symbol = null,
                .success = true,
                .error_message = null,
            };
        }

        /// Get Jetton master metadata
        pub fn getJettonInfo(self: *@This(), jetton_master_address: []const u8) !tools_types.JettonInfoResult {
            var master = JettonMasterClient.init(jetton_master_address, self.client);
            var data = master.getJettonData() catch |err| {
                return tools_types.JettonInfoResult{
                    .address = jetton_master_address,
                    .total_supply = "0",
                    .mintable = false,
                    .admin = null,
                    .content = null,
                    .content_uri = null,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            errdefer data.deinit(self.allocator);

            const total_supply = try std.fmt.allocPrint(self.allocator, "{d}", .{data.total_supply});
            errdefer self.allocator.free(total_supply);

            const admin = if (data.admin) |value| try address_mod.formatRaw(self.allocator, &value) else null;
            errdefer if (admin) |value| self.allocator.free(value);

            const content = data.content;
            data.content = null;
            const content_uri = data.content_uri;
            data.content_uri = null;

            return tools_types.JettonInfoResult{
                .address = jetton_master_address,
                .total_supply = total_supply,
                .mintable = data.mintable,
                .admin = admin,
                .content = content,
                .content_uri = content_uri,
                .success = true,
                .error_message = null,
            };
        }

        /// Resolve a Jetton wallet address from master + owner address.
        pub fn getJettonWalletAddress(self: *@This(), jetton_master_address: []const u8, owner_address: []const u8) !tools_types.JettonWalletAddressResult {
            var master = JettonMasterClient.init(jetton_master_address, self.client);
            const wallet_address = master.getWalletAddress(owner_address) catch |err| {
                return tools_types.JettonWalletAddressResult{
                    .owner_address = owner_address,
                    .jetton_master = jetton_master_address,
                    .wallet_address = null,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };

            return tools_types.JettonWalletAddressResult{
                .owner_address = owner_address,
                .jetton_master = jetton_master_address,
                .wallet_address = wallet_address,
                .success = true,
                .error_message = null,
            };
        }

        /// Get NFT info
        pub fn getNFTInfo(self: *@This(), nft_address: []const u8) !tools_types.NFTInfoResult {
            var result = self.client.runGetMethod(nft_address, "get_nft_data", &.{}) catch |err| {
                return tools_types.NFTInfoResult{
                    .address = nft_address,
                    .owner = null,
                    .collection = null,
                    .index = "0",
                    .content = null,
                    .content_uri = null,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.client.freeRunGetMethodResponse(&result);

            if (result.exit_code != 0) {
                return tools_types.NFTInfoResult{
                    .address = nft_address,
                    .owner = null,
                    .collection = null,
                    .index = "0",
                    .content = null,
                    .content_uri = null,
                    .success = false,
                    .error_message = "ContractError",
                };
            }

            var data = nft.parseNFTData(self.allocator, result.stack) catch |err| {
                return tools_types.NFTInfoResult{
                    .address = nft_address,
                    .owner = null,
                    .collection = null,
                    .index = "0",
                    .content = null,
                    .content_uri = null,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            errdefer data.deinit(self.allocator);

            const owner = if (data.owner) |value| try address_mod.formatRaw(self.allocator, &value) else null;
            errdefer if (owner) |value| self.allocator.free(value);

            const collection = if (data.collection) |value| try address_mod.formatRaw(self.allocator, &value) else null;
            errdefer if (collection) |value| self.allocator.free(value);

            const index = try std.fmt.allocPrint(self.allocator, "{d}", .{data.index});
            errdefer self.allocator.free(index);

            const content = data.content;
            data.content = null;
            const content_uri = data.content_uri;
            data.content_uri = null;

            return tools_types.NFTInfoResult{
                .address = nft_address,
                .owner = owner,
                .collection = collection,
                .index = index,
                .content = content,
                .content_uri = content_uri,
                .success = true,
                .error_message = null,
            };
        }

        /// Get NFT collection metadata
        pub fn getNFTCollectionInfo(self: *@This(), collection_address: []const u8) !tools_types.NFTCollectionInfoResult {
            var collection = NFTCollectionClient.init(collection_address, self.client);
            var data = collection.getCollectionData() catch |err| {
                return tools_types.NFTCollectionInfoResult{
                    .address = collection_address,
                    .owner = null,
                    .next_item_index = "0",
                    .content = null,
                    .content_uri = null,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            errdefer data.deinit(self.allocator);

            const owner = if (data.owner) |value| try address_mod.formatRaw(self.allocator, &value) else null;
            errdefer if (owner) |value| self.allocator.free(value);

            const next_item_index = try std.fmt.allocPrint(self.allocator, "{d}", .{data.next_item_index});
            errdefer self.allocator.free(next_item_index);

            const content = data.content;
            data.content = null;
            const content_uri = data.content_uri;
            data.content_uri = null;

            return tools_types.NFTCollectionInfoResult{
                .address = collection_address,
                .owner = owner,
                .next_item_index = next_item_index,
                .content = content,
                .content_uri = content_uri,
                .success = true,
                .error_message = null,
            };
        }

        /// Send TON transfer (if wallet configured)
        pub fn sendTransfer(self: *@This(), destination: []const u8, amount: u64, comment: ?[]const u8) !tools_types.SendResult {
            const msgs = &[_]wallet.signing.WalletMessage{
                .{
                    .destination = destination,
                    .amount = amount,
                    .comment = comment,
                },
            };
            return self.sendWalletMessages(destination, amount, msgs);
        }

        /// Deploy the configured wallet itself using its derived v4 address and StateInit.
        pub fn deployWalletSelf(self: *@This()) !tools_types.SendResult {
            const private_key = self.config.wallet_private_key orelse {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = "",
                    .amount = 0,
                    .success = false,
                    .error_message = "Wallet not configured",
                };
            };

            const derived_raw = self.deriveConfiguredWalletRawAddressAlloc() catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = "",
                    .amount = 0,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            errdefer self.allocator.free(derived_raw);

            const result = signing.deployWallet(
                self.client,
                .v4,
                private_key,
                self.config.wallet_workchain,
                self.config.wallet_id,
            ) catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = derived_raw,
                    .amount = 0,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };

            return tools_types.SendResult{
                .hash = result.hash,
                .lt = result.lt,
                .destination = derived_raw,
                .amount = 0,
                .success = true,
                .error_message = null,
            };
        }

        /// Send the first transfer from an undeployed derived wallet, including wallet StateInit.
        pub fn sendInitialTransfer(self: *@This(), destination: []const u8, amount: u64, comment: ?[]const u8) !tools_types.SendResult {
            const private_key = self.config.wallet_private_key orelse {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = destination,
                    .amount = amount,
                    .success = false,
                    .error_message = "Wallet not configured",
                };
            };

            const result = signing.sendInitialTransfer(
                self.client,
                .v4,
                private_key,
                self.config.wallet_workchain,
                self.config.wallet_id,
                destination,
                amount,
                comment,
            ) catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = destination,
                    .amount = amount,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };

            return tools_types.SendResult{
                .hash = result.hash,
                .lt = result.lt,
                .destination = destination,
                .amount = amount,
                .success = true,
                .error_message = null,
            };
        }

        /// Build a contract body BoC from a single function schema and typed values.
        pub fn buildContractBodyFunction(
            self: *@This(),
            function: abi_adapter.FunctionDef,
            values: []const abi_adapter.AbiValue,
        ) !tools_types.BuiltBodyResult {
            const selector = abi_adapter.buildFunctionSelectorAlloc(self.allocator, function) catch |err| {
                return builtBodyError(@errorName(err));
            };
            defer self.allocator.free(selector);

            const body_boc = abi_adapter.buildFunctionBodyBocAlloc(self.allocator, function, values) catch |err| {
                return builtBodyError(@errorName(err));
            };
            defer self.allocator.free(body_boc);

            return self.buildBodyResultAlloc(null, selector, body_boc) catch |err| {
                return builtBodyError(@errorName(err));
            };
        }

        /// Build a contract body BoC from a loaded ABI source and function name or signature.
        pub fn buildContractBodyAbi(
            self: *@This(),
            abi_json: []const u8,
            function_name: []const u8,
            values: []const abi_adapter.AbiValue,
        ) !tools_types.BuiltBodyResult {
            var abi = abi_adapter.loadAbiInfoSourceAlloc(self.allocator, abi_json) catch |err| {
                return builtBodyError(@errorName(err));
            };
            defer abi.deinit(self.allocator);

            const function = abi_adapter.resolveFunctionByValueCount(&abi.abi, function_name, values.len) catch |err| {
                return builtBodyError(@errorName(err));
            };

            const selector = abi_adapter.buildFunctionSelectorAlloc(self.allocator, function.*) catch |err| {
                return builtBodyError(@errorName(err));
            };
            defer self.allocator.free(selector);

            const body_boc = abi_adapter.buildFunctionBodyFromAbiAlloc(self.allocator, &abi.abi, function_name, values) catch |err| {
                return builtBodyError(@errorName(err));
            };
            defer self.allocator.free(body_boc);

            return self.buildBodyResultAlloc(null, selector, body_boc) catch |err| {
                return builtBodyError(@errorName(err));
            };
        }

        /// Discover ABI on-chain and build a contract body BoC for the destination contract.
        pub fn buildContractBodyAuto(
            self: *@This(),
            contract_address: []const u8,
            function_name: []const u8,
            values: []const abi_adapter.AbiValue,
        ) !tools_types.BuiltBodyResult {
            var abi = abi_adapter.queryAbiDocumentAlloc(self.client, contract_address) catch |err| {
                return builtBodyError(@errorName(err));
            } orelse return builtBodyError("AbiNotFound");
            defer abi.deinit(self.allocator);

            const function = abi_adapter.resolveFunctionByValueCount(&abi.abi, function_name, values.len) catch |err| {
                return builtBodyError(@errorName(err));
            };

            const selector = abi_adapter.buildFunctionSelectorAlloc(self.allocator, function.*) catch |err| {
                return builtBodyError(@errorName(err));
            };
            defer self.allocator.free(selector);

            const body_boc = abi_adapter.buildFunctionBodyFromAbiAlloc(self.allocator, &abi.abi, function_name, values) catch |err| {
                return builtBodyError(@errorName(err));
            };
            defer self.allocator.free(body_boc);

            return self.buildBodyResultAlloc(contract_address, selector, body_boc) catch |err| {
                return builtBodyError(@errorName(err));
            };
        }

        /// Wrap a built body in a generic external incoming message envelope.
        pub fn buildExternalMessageEnvelope(
            self: *@This(),
            destination: []const u8,
            body_boc: []const u8,
            state_init_boc: ?[]const u8,
        ) !tools_types.BuiltExternalMessageResult {
            const ext_boc = external_message.buildExternalIncomingMessageBocAlloc(
                self.allocator,
                destination,
                body_boc,
                state_init_boc,
            ) catch |err| {
                return builtExternalError(@errorName(err));
            };
            defer self.allocator.free(ext_boc);

            return self.buildExternalMessageResultAlloc(destination, body_boc, ext_boc, state_init_boc != null) catch |err| {
                return builtExternalError(@errorName(err));
            };
        }

        /// Build an external incoming message from a single function schema and typed values.
        pub fn buildExternalMessageEnvelopeFunction(
            self: *@This(),
            destination: []const u8,
            function: abi_adapter.FunctionDef,
            values: []const abi_adapter.AbiValue,
            state_init_boc: ?[]const u8,
        ) !tools_types.BuiltExternalMessageResult {
            var body = self.buildContractBodyFunction(function, values) catch |err| {
                return builtExternalError(@errorName(err));
            };
            defer body.deinit(self.allocator);

            return self.buildExternalMessageEnvelopeFromBase64(destination, body.body_boc, state_init_boc);
        }

        /// Build an external incoming message from an ABI document and function name or signature.
        pub fn buildExternalMessageEnvelopeAbi(
            self: *@This(),
            destination: []const u8,
            abi_json: []const u8,
            function_name: []const u8,
            values: []const abi_adapter.AbiValue,
            state_init_boc: ?[]const u8,
        ) !tools_types.BuiltExternalMessageResult {
            var body = self.buildContractBodyAbi(abi_json, function_name, values) catch |err| {
                return builtExternalError(@errorName(err));
            };
            defer body.deinit(self.allocator);

            return self.buildExternalMessageEnvelopeFromBase64(destination, body.body_boc, state_init_boc);
        }

        /// Discover ABI on-chain and build an external incoming message envelope.
        pub fn buildExternalMessageEnvelopeAuto(
            self: *@This(),
            destination: []const u8,
            function_name: []const u8,
            values: []const abi_adapter.AbiValue,
            state_init_boc: ?[]const u8,
        ) !tools_types.BuiltExternalMessageResult {
            var body = self.buildContractBodyAuto(destination, function_name, values) catch |err| {
                return builtExternalError(@errorName(err));
            };
            defer body.deinit(self.allocator);

            return self.buildExternalMessageEnvelopeFromBase64(destination, body.body_boc, state_init_boc);
        }

        /// Build a wallet-wrapped signed transfer without submitting it.
        pub fn buildWalletTransfer(
            self: *@This(),
            destination: []const u8,
            amount: u64,
            comment: ?[]const u8,
        ) !tools_types.BuiltWalletMessageResult {
            const private_key = self.config.wallet_private_key orelse {
                return builtWalletError(destination, amount, "Wallet not configured");
            };

            const msgs = &[_]wallet.signing.WalletMessage{
                .{
                    .destination = destination,
                    .amount = amount,
                    .comment = comment,
                },
            };

            var built = signing.buildSignedMessagesAutoAlloc(
                self.client,
                self.allocator,
                .v4,
                private_key,
                self.config.wallet_address,
                self.config.wallet_workchain,
                self.config.wallet_id,
                msgs,
            ) catch |err| {
                return builtWalletError(destination, amount, @errorName(err));
            };
            errdefer built.deinit(self.allocator);

            return self.buildWalletMessageResultAlloc(&built, destination, amount) catch |err| {
                built.deinit(self.allocator);
                return builtWalletError(destination, amount, @errorName(err));
            };
        }

        /// Build a wallet-wrapped signed contract message without submitting it.
        pub fn buildWalletContractMessage(
            self: *@This(),
            destination: []const u8,
            amount: u64,
            body_boc: []const u8,
        ) !tools_types.BuiltWalletMessageResult {
            const private_key = self.config.wallet_private_key orelse {
                return builtWalletError(destination, amount, "Wallet not configured");
            };

            const msgs = &[_]wallet.signing.WalletMessage{
                .{
                    .destination = destination,
                    .amount = amount,
                    .body = body_boc,
                },
            };

            var built = signing.buildSignedMessagesAutoAlloc(
                self.client,
                self.allocator,
                .v4,
                private_key,
                self.config.wallet_address,
                self.config.wallet_workchain,
                self.config.wallet_id,
                msgs,
            ) catch |err| {
                return builtWalletError(destination, amount, @errorName(err));
            };
            errdefer built.deinit(self.allocator);

            return self.buildWalletMessageResultAlloc(&built, destination, amount) catch |err| {
                built.deinit(self.allocator);
                return builtWalletError(destination, amount, @errorName(err));
            };
        }

        /// Build a wallet-wrapped signed contract message from a single function schema.
        pub fn buildWalletContractMessageFunction(
            self: *@This(),
            destination: []const u8,
            amount: u64,
            function: abi_adapter.FunctionDef,
            values: []const abi_adapter.AbiValue,
        ) !tools_types.BuiltWalletMessageResult {
            const body_boc = abi_adapter.buildFunctionBodyBocAlloc(self.allocator, function, values) catch |err| {
                return builtWalletError(destination, amount, @errorName(err));
            };
            defer self.allocator.free(body_boc);

            return self.buildWalletContractMessage(destination, amount, body_boc);
        }

        /// Build a wallet-wrapped signed contract message from an ABI document.
        pub fn buildWalletContractMessageAbi(
            self: *@This(),
            destination: []const u8,
            amount: u64,
            abi_json: []const u8,
            function_name: []const u8,
            values: []const abi_adapter.AbiValue,
        ) !tools_types.BuiltWalletMessageResult {
            var abi = abi_adapter.loadAbiInfoSourceAlloc(self.allocator, abi_json) catch |err| {
                return builtWalletError(destination, amount, @errorName(err));
            };
            defer abi.deinit(self.allocator);

            const body_boc = abi_adapter.buildFunctionBodyFromAbiAlloc(
                self.allocator,
                &abi.abi,
                function_name,
                values,
            ) catch |err| {
                return builtWalletError(destination, amount, @errorName(err));
            };
            defer self.allocator.free(body_boc);

            return self.buildWalletContractMessage(destination, amount, body_boc);
        }

        /// Discover ABI on-chain and build a wallet-wrapped signed contract message.
        pub fn buildWalletContractMessageAuto(
            self: *@This(),
            destination: []const u8,
            amount: u64,
            function_name: []const u8,
            values: []const abi_adapter.AbiValue,
        ) !tools_types.BuiltWalletMessageResult {
            var abi = abi_adapter.queryAbiDocumentAlloc(self.client, destination) catch |err| {
                return builtWalletError(destination, amount, @errorName(err));
            } orelse return builtWalletError(destination, amount, "AbiNotFound");
            defer abi.deinit(self.allocator);

            const body_boc = abi_adapter.buildFunctionBodyFromAbiAlloc(
                self.allocator,
                &abi.abi,
                function_name,
                values,
            ) catch |err| {
                return builtWalletError(destination, amount, @errorName(err));
            };
            defer self.allocator.free(body_boc);

            return self.buildWalletContractMessage(destination, amount, body_boc);
        }

        /// Build a wallet-wrapped signed contract deployment without submitting it.
        pub fn buildContractDeploy(
            self: *@This(),
            destination: []const u8,
            amount: u64,
            state_init_boc: []const u8,
            body_boc: ?[]const u8,
        ) !tools_types.BuiltWalletMessageResult {
            const private_key = self.config.wallet_private_key orelse {
                return builtWalletError(destination, amount, "Wallet not configured");
            };

            const msgs = &[_]wallet.signing.WalletMessage{
                .{
                    .destination = destination,
                    .amount = amount,
                    .state_init = state_init_boc,
                    .body = body_boc,
                    .bounce = false,
                },
            };

            var built = signing.buildSignedMessagesAutoAlloc(
                self.client,
                self.allocator,
                .v4,
                private_key,
                self.config.wallet_address,
                self.config.wallet_workchain,
                self.config.wallet_id,
                msgs,
            ) catch |err| {
                return builtWalletError(destination, amount, @errorName(err));
            };
            errdefer built.deinit(self.allocator);

            return self.buildWalletMessageResultAlloc(&built, destination, amount) catch |err| {
                built.deinit(self.allocator);
                return builtWalletError(destination, amount, @errorName(err));
            };
        }

        /// Derive deployment address from StateInit and build a signed deploy message there.
        pub fn buildContractDeployAuto(
            self: *@This(),
            workchain: i8,
            amount: u64,
            state_init_boc: []const u8,
            body_boc: ?[]const u8,
        ) !tools_types.BuiltWalletMessageResult {
            const addr = try self.computeStateInitAddress(workchain, state_init_boc);
            defer {
                if (addr.raw_address.len > 0) self.allocator.free(addr.raw_address);
                if (addr.user_friendly_address.len > 0) self.allocator.free(addr.user_friendly_address);
            }

            if (!addr.success) {
                return builtWalletError("", amount, addr.error_message orelse "InvalidStateInitAddress");
            }

            return self.buildContractDeploy(addr.raw_address, amount, state_init_boc, body_boc);
        }

        fn buildExternalMessageEnvelopeFromBase64(
            self: *@This(),
            destination: []const u8,
            body_boc_base64: []const u8,
            state_init_boc: ?[]const u8,
        ) !tools_types.BuiltExternalMessageResult {
            const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(body_boc_base64) catch {
                return builtExternalError("InvalidBodyBocBase64");
            };
            const decoded = try self.allocator.alloc(u8, decoded_len);
            defer self.allocator.free(decoded);
            std.base64.standard.Decoder.decode(decoded, body_boc_base64) catch {
                return builtExternalError("InvalidBodyBocBase64");
            };

            return self.buildExternalMessageEnvelope(destination, decoded, state_init_boc);
        }

        /// Send an arbitrary contract body BoC via the configured wallet
        pub fn sendContractMessage(self: *@This(), destination: []const u8, amount: u64, body_boc: []const u8) !tools_types.SendResult {
            const msgs = &[_]wallet.signing.WalletMessage{
                .{
                    .destination = destination,
                    .amount = amount,
                    .body = body_boc,
                },
            };
            return self.sendWalletMessages(destination, amount, msgs);
        }

        /// Build and send an arbitrary contract body from typed operations
        pub fn sendContractMessageOps(self: *@This(), destination: []const u8, amount: u64, ops: []const body_builder.BodyOp) !tools_types.SendResult {
            const body_boc = body_builder.buildBodyBocAlloc(self.allocator, ops) catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = destination,
                    .amount = amount,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.allocator.free(body_boc);

            return self.sendContractMessage(destination, amount, body_boc);
        }

        /// Build and send a contract body from a function schema and typed values
        pub fn sendContractMessageFunction(
            self: *@This(),
            destination: []const u8,
            amount: u64,
            function: abi_adapter.FunctionDef,
            values: []const abi_adapter.AbiValue,
        ) !tools_types.SendResult {
            const body_boc = abi_adapter.buildFunctionBodyBocAlloc(self.allocator, function, values) catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = destination,
                    .amount = amount,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.allocator.free(body_boc);

            return self.sendContractMessage(destination, amount, body_boc);
        }

        /// Build and send a contract body from a full ABI document and function name
        pub fn sendContractMessageAbi(
            self: *@This(),
            destination: []const u8,
            amount: u64,
            abi_json: []const u8,
            function_name: []const u8,
            values: []const abi_adapter.AbiValue,
        ) !tools_types.SendResult {
            var abi = abi_adapter.loadAbiInfoSourceAlloc(self.allocator, abi_json) catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = destination,
                    .amount = amount,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer abi.deinit(self.allocator);

            const body_boc = abi_adapter.buildFunctionBodyFromAbiAlloc(
                self.allocator,
                &abi.abi,
                function_name,
                values,
            ) catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = destination,
                    .amount = amount,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.allocator.free(body_boc);

            return self.sendContractMessage(destination, amount, body_boc);
        }

        /// Build and send a contract body by discovering the destination ABI URI on-chain
        pub fn sendContractMessageAuto(
            self: *@This(),
            destination: []const u8,
            amount: u64,
            function_name: []const u8,
            values: []const abi_adapter.AbiValue,
        ) !tools_types.SendResult {
            var abi = abi_adapter.queryAbiDocumentAlloc(self.client, destination) catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = destination,
                    .amount = amount,
                    .success = false,
                    .error_message = @errorName(err),
                };
            } orelse return tools_types.SendResult{
                .hash = "",
                .lt = 0,
                .destination = destination,
                .amount = amount,
                .success = false,
                .error_message = "AbiNotFound",
            };
            defer abi.deinit(self.allocator);

            const body_boc = abi_adapter.buildFunctionBodyFromAbiAlloc(
                self.allocator,
                &abi.abi,
                function_name,
                values,
            ) catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = destination,
                    .amount = amount,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.allocator.free(body_boc);

            return self.sendContractMessage(destination, amount, body_boc);
        }

        /// Send an external incoming message directly to a contract, without wallet wrapping.
        pub fn sendExternalMessage(
            self: *@This(),
            destination: []const u8,
            body_boc: []const u8,
            state_init_boc: ?[]const u8,
        ) !tools_types.SendResult {
            const ext_boc = external_message.buildExternalIncomingMessageBocAlloc(
                self.allocator,
                destination,
                body_boc,
                state_init_boc,
            ) catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = destination,
                    .amount = 0,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.allocator.free(ext_boc);

            const result = self.client.sendBoc(ext_boc) catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = destination,
                    .amount = 0,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };

            return tools_types.SendResult{
                .hash = result.hash,
                .lt = result.lt,
                .destination = destination,
                .amount = 0,
                .success = true,
                .error_message = null,
            };
        }

        /// Build and send an external incoming message body from a function schema.
        pub fn sendExternalMessageFunction(
            self: *@This(),
            destination: []const u8,
            function: abi_adapter.FunctionDef,
            values: []const abi_adapter.AbiValue,
            state_init_boc: ?[]const u8,
        ) !tools_types.SendResult {
            const body_boc = abi_adapter.buildFunctionBodyBocAlloc(self.allocator, function, values) catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = destination,
                    .amount = 0,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.allocator.free(body_boc);

            return self.sendExternalMessage(destination, body_boc, state_init_boc);
        }

        /// Build and send an external incoming message body from an ABI document.
        pub fn sendExternalMessageAbi(
            self: *@This(),
            destination: []const u8,
            abi_json: []const u8,
            function_name: []const u8,
            values: []const abi_adapter.AbiValue,
            state_init_boc: ?[]const u8,
        ) !tools_types.SendResult {
            var abi = abi_adapter.loadAbiInfoSourceAlloc(self.allocator, abi_json) catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = destination,
                    .amount = 0,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer abi.deinit(self.allocator);

            const body_boc = abi_adapter.buildFunctionBodyFromAbiAlloc(
                self.allocator,
                &abi.abi,
                function_name,
                values,
            ) catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = destination,
                    .amount = 0,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.allocator.free(body_boc);

            return self.sendExternalMessage(destination, body_boc, state_init_boc);
        }

        /// Discover ABI on-chain, build a body, and send it as an external incoming message.
        pub fn sendExternalMessageAuto(
            self: *@This(),
            destination: []const u8,
            function_name: []const u8,
            values: []const abi_adapter.AbiValue,
            state_init_boc: ?[]const u8,
        ) !tools_types.SendResult {
            var abi = abi_adapter.queryAbiDocumentAlloc(self.client, destination) catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = destination,
                    .amount = 0,
                    .success = false,
                    .error_message = @errorName(err),
                };
            } orelse return tools_types.SendResult{
                .hash = "",
                .lt = 0,
                .destination = destination,
                .amount = 0,
                .success = false,
                .error_message = "AbiNotFound",
            };
            defer abi.deinit(self.allocator);

            const body_boc = abi_adapter.buildFunctionBodyFromAbiAlloc(
                self.allocator,
                &abi.abi,
                function_name,
                values,
            ) catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = destination,
                    .amount = 0,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.allocator.free(body_boc);

            return self.sendExternalMessage(destination, body_boc, state_init_boc);
        }

        /// Deploy a contract by sending StateInit and an optional body.
        pub fn sendContractDeploy(
            self: *@This(),
            destination: []const u8,
            amount: u64,
            state_init_boc: []const u8,
            body_boc: ?[]const u8,
        ) !tools_types.SendResult {
            const msgs = &[_]wallet.signing.WalletMessage{
                .{
                    .destination = destination,
                    .amount = amount,
                    .state_init = state_init_boc,
                    .body = body_boc,
                    .bounce = false,
                },
            };

            return self.sendWalletMessages(destination, amount, msgs);
        }

        /// Derive destination from StateInit and send a deploy message there.
        pub fn sendContractDeployAuto(
            self: *@This(),
            workchain: i8,
            amount: u64,
            state_init_boc: []const u8,
            body_boc: ?[]const u8,
        ) !tools_types.SendResult {
            const addr = try self.computeStateInitAddress(workchain, state_init_boc);
            if (!addr.success) {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = "",
                    .amount = amount,
                    .success = false,
                    .error_message = addr.error_message,
                };
            }

            return self.sendContractDeploy(addr.raw_address, amount, state_init_boc, body_boc);
        }

        fn sendWalletMessages(self: *@This(), destination: []const u8, amount: u64, msgs: []const wallet.signing.WalletMessage) !tools_types.SendResult {
            const private_key = self.config.wallet_private_key orelse {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = destination,
                    .amount = amount,
                    .success = false,
                    .error_message = "Wallet not configured",
                };
            };

            const result = signing.sendMessagesAuto(
                self.client,
                .v4,
                private_key,
                self.config.wallet_address,
                self.config.wallet_workchain,
                self.config.wallet_id,
                msgs,
            ) catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = destination,
                    .amount = amount,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };

            return tools_types.SendResult{
                .hash = result.hash,
                .lt = result.lt,
                .destination = destination,
                .amount = amount,
                .success = true,
                .error_message = null,
            };
        }
    };
}

pub const AgentTools = AgentToolsImpl(*http_client.TonHttpClient);
pub const ProviderAgentTools = AgentToolsImpl(*provider_mod.MultiProvider);

// Re-export types
pub const BalanceResult = tools_types.BalanceResult;
pub const AddressResult = tools_types.AddressResult;
pub const SendResult = tools_types.SendResult;
pub const RunMethodResult = tools_types.RunMethodResult;
pub const DecodedBodyKind = tools_types.DecodedBodyKind;
pub const DecodedBodyResult = tools_types.DecodedBodyResult;
pub const BuiltBodyResult = tools_types.BuiltBodyResult;
pub const BuiltExternalMessageResult = tools_types.BuiltExternalMessageResult;
pub const BuiltWalletMessageResult = tools_types.BuiltWalletMessageResult;
pub const MessageResult = tools_types.MessageResult;
pub const InvoiceResult = tools_types.InvoiceResult;
pub const VerifyResult = tools_types.VerifyResult;
pub const TxResult = tools_types.TxResult;
pub const TransactionListResult = tools_types.TransactionListResult;
pub const TransactionDetailResult = tools_types.TransactionDetailResult;
pub const ContractInspectResult = tools_types.ContractInspectResult;
pub const AbiParamTemplateResult = tools_types.AbiParamTemplateResult;
pub const AbiFunctionTemplateResult = tools_types.AbiFunctionTemplateResult;
pub const AbiEventTemplateResult = tools_types.AbiEventTemplateResult;
pub const AbiDescribeResult = tools_types.AbiDescribeResult;
pub const JettonBalanceResult = tools_types.JettonBalanceResult;
pub const JettonInfoResult = tools_types.JettonInfoResult;
pub const JettonWalletAddressResult = tools_types.JettonWalletAddressResult;
pub const NFTInfoResult = tools_types.NFTInfoResult;
pub const NFTCollectionInfoResult = tools_types.NFTCollectionInfoResult;
pub const WalletInitResult = tools_types.WalletInitResult;
pub const AgentToolsConfig = tools_types.AgentToolsConfig;
pub const ToolResponse = tools_types.ToolResponse;
pub const ToolError = tools_types.ToolError;
pub const ErrorCode = tools_types.ErrorCode;

test "agent tools init" {
    const allocator = std.testing.allocator;
    var client = try http_client.TonHttpClient.init(allocator, "https://toncenter.com/api/v2/jsonRPC", null);
    defer client.deinit();

    const config = tools_types.AgentToolsConfig{
        .rpc_url = "https://toncenter.com/api/v2/jsonRPC",
    };

    const tools = AgentTools.init(allocator, &client, config);
    _ = tools;
}

test "agent tools getBalance" {
    const allocator = std.testing.allocator;
    var client = try http_client.TonHttpClient.init(allocator, "https://toncenter.com/api/v2/jsonRPC", null);
    defer client.deinit();

    const config = tools_types.AgentToolsConfig{
        .rpc_url = "https://toncenter.com/api/v2/jsonRPC",
    };

    var tools = AgentTools.init(allocator, &client, config);
    const result = try tools.getBalance("EQCD39vd5kB8FW5w6KH7HpNmP8GCvGajvLKGPMgY4sUXJyxqH");

    // Note: May fail if network unavailable, but struct should be valid
    _ = result;
}

test "agent tools deriveWalletInit matches signing helper" {
    const allocator = std.testing.allocator;

    const FakeClient = struct {};
    const FakeTools = AgentToolsImpl(*FakeClient);

    var client = FakeClient{};
    const keypair = try signing.generateKeypair("tools-wallet-init");
    const config = tools_types.AgentToolsConfig{
        .rpc_url = "https://example.invalid",
        .wallet_private_key = keypair[0],
        .wallet_workchain = -1,
        .wallet_id = 0xA1B2C3D4,
    };

    var tools = FakeTools.init(allocator, &client, config);
    const result = try tools.deriveWalletInit();
    defer allocator.free(result.raw_address);
    defer allocator.free(result.user_friendly_address);
    defer allocator.free(result.public_key_hex);
    defer allocator.free(result.state_init_boc);

    try std.testing.expect(result.success);

    var expected = try signing.deriveWalletV4InitFromPrivateKeyAlloc(allocator, -1, 0xA1B2C3D4, keypair[0]);
    defer expected.deinit(allocator);
    const expected_raw = try address_mod.formatRaw(allocator, &expected.address);
    defer allocator.free(expected_raw);

    try std.testing.expectEqualStrings(expected_raw, result.raw_address);
    try std.testing.expectEqual(@as(i8, -1), result.workchain);
    try std.testing.expectEqual(@as(u32, 0xA1B2C3D4), result.wallet_id);
}

test "agent tools deployWalletSelf submits derived wallet deployment" {
    const allocator = std.testing.allocator;

    const FakeClient = struct {
        allocator: std.mem.Allocator,
        last_boc: ?[]u8 = null,

        pub fn sendBoc(self: *@This(), payload: []const u8) !core_types.SendBocResponse {
            self.last_boc = try self.allocator.dupe(u8, payload);
            return .{
                .hash = try self.allocator.dupe(u8, "fake"),
                .lt = 123,
            };
        }
    };
    const FakeTools = AgentToolsImpl(*FakeClient);

    var client = FakeClient{ .allocator = allocator };
    defer if (client.last_boc) |value| allocator.free(value);

    const keypair = try signing.generateKeypair("tools-wallet-deploy");
    const config = tools_types.AgentToolsConfig{
        .rpc_url = "https://example.invalid",
        .wallet_private_key = keypair[0],
    };

    var tools = FakeTools.init(allocator, &client, config);
    const result = try tools.deployWalletSelf();
    defer allocator.free(result.hash);
    defer allocator.free(result.destination);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(i64, 123), result.lt);
    try std.testing.expect(client.last_boc != null);
}

test "agent tools sendInitialTransfer submits first transfer without configured wallet address" {
    const allocator = std.testing.allocator;

    const FakeClient = struct {
        allocator: std.mem.Allocator,
        last_boc: ?[]u8 = null,

        pub fn sendBoc(self: *@This(), payload: []const u8) !core_types.SendBocResponse {
            self.last_boc = try self.allocator.dupe(u8, payload);
            return .{
                .hash = try self.allocator.dupe(u8, "fake"),
                .lt = 456,
            };
        }
    };
    const FakeTools = AgentToolsImpl(*FakeClient);

    var client = FakeClient{ .allocator = allocator };
    defer if (client.last_boc) |value| allocator.free(value);

    const keypair = try signing.generateKeypair("tools-wallet-first-send");
    const config = tools_types.AgentToolsConfig{
        .rpc_url = "https://example.invalid",
        .wallet_private_key = keypair[0],
    };

    var tools = FakeTools.init(allocator, &client, config);
    const result = try tools.sendInitialTransfer(
        "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
        999,
        null,
    );
    defer allocator.free(result.hash);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(i64, 456), result.lt);
    try std.testing.expectEqualStrings(
        "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
        result.destination,
    );
    try std.testing.expect(client.last_boc != null);
}

test "agent tools sendTransfer auto-derives wallet and falls back to initial deployment" {
    const allocator = std.testing.allocator;

    const FakeClient = struct {
        allocator: std.mem.Allocator,
        last_boc: ?[]u8 = null,

        pub fn runGetMethod(self: *@This(), wallet_address: []const u8, method: []const u8, stack: []const []const u8) !core_types.RunGetMethodResponse {
            _ = self;
            _ = wallet_address;
            _ = method;
            _ = stack;
            return error.InvalidResponse;
        }

        pub fn freeRunGetMethodResponse(self: *@This(), response: *core_types.RunGetMethodResponse) void {
            _ = self;
            _ = response;
        }

        pub fn sendBoc(self: *@This(), payload: []const u8) !core_types.SendBocResponse {
            self.last_boc = try self.allocator.dupe(u8, payload);
            return .{
                .hash = try self.allocator.dupe(u8, "fake"),
                .lt = 789,
            };
        }
    };
    const FakeTools = AgentToolsImpl(*FakeClient);

    var client = FakeClient{ .allocator = allocator };
    defer if (client.last_boc) |value| allocator.free(value);

    const keypair = try signing.generateKeypair("tools-wallet-send-auto");
    const config = tools_types.AgentToolsConfig{
        .rpc_url = "https://example.invalid",
        .wallet_private_key = keypair[0],
    };

    var tools = FakeTools.init(allocator, &client, config);
    const result = try tools.sendTransfer(
        "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
        321,
        null,
    );
    defer allocator.free(result.hash);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(i64, 789), result.lt);
    try std.testing.expect(client.last_boc != null);
}

test "agent tools sendExternalMessage wraps body without wallet" {
    const allocator = std.testing.allocator;

    const FakeClient = struct {
        allocator: std.mem.Allocator,
        last_boc: ?[]u8 = null,

        pub fn sendBoc(self: *@This(), payload: []const u8) !core_types.SendBocResponse {
            self.last_boc = try self.allocator.dupe(u8, payload);
            return .{
                .hash = try self.allocator.dupe(u8, "fake"),
                .lt = 987,
            };
        }
    };
    const FakeTools = AgentToolsImpl(*FakeClient);

    var client = FakeClient{ .allocator = allocator };
    defer if (client.last_boc) |value| allocator.free(value);

    const body_boc = try body_builder.buildBodyBocAlloc(allocator, &.{
        .{ .uint = .{ .bits = 16, .value = 0xCAFE } },
    });
    defer allocator.free(body_boc);

    var tools = FakeTools.init(allocator, &client, .{ .rpc_url = "https://example.invalid" });
    const result = try tools.sendExternalMessage(
        "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
        body_boc,
        null,
    );
    defer allocator.free(result.hash);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(i64, 987), result.lt);
    try std.testing.expect(client.last_boc != null);
}

test "agent tools buildContractBodyAbi returns encoded body and selector" {
    const allocator = std.testing.allocator;

    const FakeClient = struct {};
    const FakeTools = AgentToolsImpl(*FakeClient);

    const abi_json =
        \\{
        \\  "version": "1.0",
        \\  "functions": [
        \\    {
        \\      "name": "set_flag",
        \\      "opcode": "0x10203040",
        \\      "inputs": [
        \\        {"name": "enabled", "type": "bool"},
        \\        {"name": "count", "type": "uint8"}
        \\      ],
        \\      "outputs": []
        \\    }
        \\  ],
        \\  "events": []
        \\}
    ;

    var client = FakeClient{};
    var tools = FakeTools.init(allocator, &client, .{ .rpc_url = "https://example.invalid" });

    var result = try tools.buildContractBodyAbi(abi_json, "set_flag", &.{
        .{ .uint = 1 },
        .{ .uint = 7 },
    });
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(result.address == null);
    try std.testing.expectEqualStrings("set_flag(bool,uint8)", result.selector);

    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(result.body_boc);
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, result.body_boc);

    const root = try boc.deserializeBoc(allocator, decoded);
    defer root.deinit(allocator);

    var slice = root.toSlice();
    try std.testing.expectEqual(@as(u64, 0x10203040), try slice.loadUint(32));
    try std.testing.expectEqual(@as(u64, 1), try slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 7), try slice.loadUint(8));
    try std.testing.expect(std.mem.startsWith(u8, result.body_hex, "b5ee9c72"));
}

test "agent tools buildExternalMessageEnvelopeAuto discovers abi and wraps state init" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abi_json =
        \\{
        \\  "version": "1.0",
        \\  "functions": [
        \\    {
        \\      "name": "ping",
        \\      "opcode": "0xAABBCCDD",
        \\      "inputs": [],
        \\      "outputs": []
        \\    }
        \\  ],
        \\  "events": []
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "build_ext_abi.json", .data = abi_json });
    const abi_path = try tmp.dir.realpathAlloc(allocator, "build_ext_abi.json");
    defer allocator.free(abi_path);
    const abi_uri = try std.fmt.allocPrint(allocator, "file://{s}", .{abi_path});
    defer allocator.free(abi_uri);

    var code_builder = core_types.Builder.init();
    try code_builder.storeUint(0xAA, 8);
    const code_cell = try code_builder.toCell(allocator);
    defer code_cell.deinit(allocator);
    const code_boc = try boc.serializeBoc(allocator, code_cell);
    defer allocator.free(code_boc);

    const state_init_boc = try state_init.buildStateInitBocAlloc(allocator, code_boc, null);
    defer allocator.free(state_init_boc);

    const FakeClient = struct {
        allocator: std.mem.Allocator,
        abi_uri: []const u8,

        pub fn runGetMethod(self: *@This(), addr: []const u8, method: []const u8, stack: []const []const u8) anyerror!core_types.RunGetMethodResponse {
            _ = addr;
            _ = stack;
            if (!std.mem.eql(u8, method, "get_abi_uri")) return error.InvalidResponse;

            var builder = core_types.Builder.init();
            try builder.storeUint(0x01, 8);
            try builder.storeBits(self.abi_uri, @intCast(self.abi_uri.len * 8));
            const value = try builder.toCell(self.allocator);

            const entries = try self.allocator.alloc(core_types.StackEntry, 1);
            entries[0] = .{ .cell = value };
            return .{
                .exit_code = 0,
                .stack = entries,
                .logs = "",
            };
        }

        pub fn freeRunGetMethodResponse(self: *@This(), response: *core_types.RunGetMethodResponse) void {
            for (response.stack) |*entry| {
                switch (entry.*) {
                    .cell => |value| value.deinit(self.allocator),
                    else => {},
                }
            }
            if (response.stack.len > 0) self.allocator.free(response.stack);
        }
    };
    const FakeTools = AgentToolsImpl(*FakeClient);

    var client = FakeClient{ .allocator = allocator, .abi_uri = abi_uri };
    var tools = FakeTools.init(allocator, &client, .{ .rpc_url = "https://example.invalid" });

    var result = try tools.buildExternalMessageEnvelopeAuto(
        "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
        "ping",
        &.{},
        state_init_boc,
    );
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(result.state_init_attached);

    const ext_len = try std.base64.standard.Decoder.calcSizeForSlice(result.external_boc);
    const ext_bytes = try allocator.alloc(u8, ext_len);
    defer allocator.free(ext_bytes);
    try std.base64.standard.Decoder.decode(ext_bytes, result.external_boc);

    const ext_msg = try boc.deserializeBoc(allocator, ext_bytes);
    defer ext_msg.deinit(allocator);

    var slice = ext_msg.toSlice();
    try std.testing.expectEqual(@as(u64, 0b10), try slice.loadUint(2));
    try std.testing.expectEqual(@as(u64, 0), try slice.loadUint(2));
    _ = try slice.loadAddress();
    try std.testing.expectEqual(@as(u64, 0), try slice.loadCoins());
    try std.testing.expectEqual(@as(u64, 1), try slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 1), try slice.loadUint(1));
    _ = try slice.loadRef();
    try std.testing.expectEqual(@as(u64, 1), try slice.loadUint(1));
    const body_ref = try slice.loadRef();
    var body_slice = body_ref.toSlice();
    try std.testing.expectEqual(@as(u64, 0xAABBCCDD), try body_slice.loadUint(32));
}

test "agent tools buildWalletContractMessage signs for deployed wallet" {
    const allocator = std.testing.allocator;

    const keypair = try signing.generateKeypair("tools-wallet-build");

    var body_cell_builder = core_types.Builder.init();
    try body_cell_builder.storeUint(0xCAFE, 16);
    const body_cell = try body_cell_builder.toCell(allocator);
    defer body_cell.deinit(allocator);
    const body_boc = try boc.serializeBoc(allocator, body_cell);
    defer allocator.free(body_boc);

    const FakeClient = struct {
        allocator: std.mem.Allocator,
        public_key_hex: []const u8,

        pub fn runGetMethod(self: *@This(), addr: []const u8, method: []const u8, stack: []const []const u8) anyerror!core_types.RunGetMethodResponse {
            _ = addr;
            _ = stack;

            const entries = try self.allocator.alloc(core_types.StackEntry, 1);
            errdefer self.allocator.free(entries);

            if (std.mem.eql(u8, method, "seqno")) {
                entries[0] = .{ .number = 7 };
            } else if (std.mem.eql(u8, method, "get_subwallet_id")) {
                entries[0] = .{ .number = 0xAABBCCDD };
            } else if (std.mem.eql(u8, method, "get_public_key")) {
                entries[0] = .{ .big_number = try self.allocator.dupe(u8, self.public_key_hex) };
            } else {
                return error.InvalidResponse;
            }

            return .{
                .exit_code = 0,
                .stack = entries,
                .logs = "",
            };
        }

        pub fn freeRunGetMethodResponse(self: *@This(), response: *core_types.RunGetMethodResponse) void {
            for (response.stack) |*entry| {
                switch (entry.*) {
                    .big_number => |value| if (value.len > 0) self.allocator.free(value),
                    else => {},
                }
            }
            if (response.stack.len > 0) self.allocator.free(response.stack);
        }
    };
    const FakeTools = AgentToolsImpl(*FakeClient);

    const public_key_hex = blk: {
        const hex_chars = "0123456789abcdef";
        const out = try allocator.alloc(u8, 2 + keypair[1].len * 2);
        out[0] = '0';
        out[1] = 'x';
        for (keypair[1], 0..) |byte, idx| {
            out[2 + idx * 2] = hex_chars[byte >> 4];
            out[2 + idx * 2 + 1] = hex_chars[byte & 0x0f];
        }
        break :blk out;
    };
    defer allocator.free(public_key_hex);

    var client = FakeClient{ .allocator = allocator, .public_key_hex = public_key_hex };
    var tools = FakeTools.init(allocator, &client, .{
        .rpc_url = "https://example.invalid",
        .wallet_private_key = keypair[0],
        .wallet_address = "0:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    });

    var result = try tools.buildWalletContractMessage(
        "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
        123,
        body_boc,
    );
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("0:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", result.wallet_address);
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), result.wallet_id);
    try std.testing.expectEqual(@as(u32, 7), result.seqno);
    try std.testing.expect(!result.state_init_attached);
    try std.testing.expect(std.mem.startsWith(u8, result.external_hex, "b5ee9c72"));
}

test "agent tools buildWalletTransfer auto-attaches wallet state init when undeployed" {
    const allocator = std.testing.allocator;

    const keypair = try signing.generateKeypair("tools-wallet-build-initial");

    const FakeClient = struct {
        pub fn runGetMethod(_: *@This(), _: []const u8, _: []const u8, _: []const []const u8) anyerror!core_types.RunGetMethodResponse {
            return error.InvalidResponse;
        }

        pub fn freeRunGetMethodResponse(_: *@This(), _: *core_types.RunGetMethodResponse) void {}
    };
    const FakeTools = AgentToolsImpl(*FakeClient);

    var client = FakeClient{};
    var tools = FakeTools.init(allocator, &client, .{
        .rpc_url = "https://example.invalid",
        .wallet_private_key = keypair[0],
    });

    var result = try tools.buildWalletTransfer(
        "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
        999,
        "hello",
    );
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(result.state_init_attached);
    try std.testing.expect(result.wallet_address.len > 0);

    const ext_len = try std.base64.standard.Decoder.calcSizeForSlice(result.external_boc);
    const ext_bytes = try allocator.alloc(u8, ext_len);
    defer allocator.free(ext_bytes);
    try std.base64.standard.Decoder.decode(ext_bytes, result.external_boc);

    const ext_msg = try boc.deserializeBoc(allocator, ext_bytes);
    defer ext_msg.deinit(allocator);

    var slice = ext_msg.toSlice();
    _ = try slice.loadUint(2);
    _ = try slice.loadUint(2);
    _ = try slice.loadAddress();
    _ = try slice.loadCoins();
    try std.testing.expectEqual(@as(u64, 1), try slice.loadUint(1));
}

test "agent tools buildWalletContractMessageAbi encodes abi body then signs" {
    const allocator = std.testing.allocator;

    const keypair = try signing.generateKeypair("tools-wallet-build-abi");

    const abi_json =
        \\{
        \\  "version": "1.0",
        \\  "functions": [
        \\    {
        \\      "name": "set_flag",
        \\      "opcode": "0x10203040",
        \\      "inputs": [
        \\        {"name": "enabled", "type": "bool"},
        \\        {"name": "count", "type": "uint8"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    const FakeClient = struct {
        allocator: std.mem.Allocator,
        public_key_hex: []const u8,

        pub fn runGetMethod(self: *@This(), _: []const u8, method: []const u8, _: []const []const u8) anyerror!core_types.RunGetMethodResponse {
            const entries = try self.allocator.alloc(core_types.StackEntry, 1);
            errdefer self.allocator.free(entries);

            if (std.mem.eql(u8, method, "seqno")) {
                entries[0] = .{ .number = 11 };
            } else if (std.mem.eql(u8, method, "get_subwallet_id")) {
                entries[0] = .{ .number = signing.default_wallet_id_v4 };
            } else if (std.mem.eql(u8, method, "get_public_key")) {
                entries[0] = .{ .big_number = try self.allocator.dupe(u8, self.public_key_hex) };
            } else {
                return error.InvalidResponse;
            }

            return .{
                .exit_code = 0,
                .stack = entries,
                .logs = "",
            };
        }

        pub fn freeRunGetMethodResponse(self: *@This(), response: *core_types.RunGetMethodResponse) void {
            for (response.stack) |*entry| {
                switch (entry.*) {
                    .big_number => |value| if (value.len > 0) self.allocator.free(value),
                    else => {},
                }
            }
            if (response.stack.len > 0) self.allocator.free(response.stack);
        }
    };
    const FakeTools = AgentToolsImpl(*FakeClient);

    const public_key_hex = blk: {
        const hex_chars = "0123456789abcdef";
        const out = try allocator.alloc(u8, 2 + keypair[1].len * 2);
        out[0] = '0';
        out[1] = 'x';
        for (keypair[1], 0..) |byte, idx| {
            out[2 + idx * 2] = hex_chars[byte >> 4];
            out[2 + idx * 2 + 1] = hex_chars[byte & 0x0f];
        }
        break :blk out;
    };
    defer allocator.free(public_key_hex);

    var client = FakeClient{ .allocator = allocator, .public_key_hex = public_key_hex };
    var tools = FakeTools.init(allocator, &client, .{
        .rpc_url = "https://example.invalid",
        .wallet_private_key = keypair[0],
        .wallet_address = "0:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    });

    var result = try tools.buildWalletContractMessageAbi(
        "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
        321,
        abi_json,
        "set_flag",
        &.{
            .{ .uint = 1 },
            .{ .uint = 7 },
        },
    );
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u32, signing.default_wallet_id_v4), result.wallet_id);
    try std.testing.expectEqual(@as(u32, 11), result.seqno);
    try std.testing.expect(!result.state_init_attached);

    const ext_len = try std.base64.standard.Decoder.calcSizeForSlice(result.external_boc);
    const ext_bytes = try allocator.alloc(u8, ext_len);
    defer allocator.free(ext_bytes);
    try std.base64.standard.Decoder.decode(ext_bytes, result.external_boc);

    const ext_msg = try boc.deserializeBoc(allocator, ext_bytes);
    defer ext_msg.deinit(allocator);

    var msg_slice = ext_msg.toSlice();
    _ = try msg_slice.loadUint(2);
    _ = try msg_slice.loadUint(2);
    _ = try msg_slice.loadAddress();
    _ = try msg_slice.loadCoins();
    _ = try msg_slice.loadUint(1);
    const body_ref = try msg_slice.loadRef();

    var signed_body = body_ref.toSlice();
    _ = try signed_body.loadBits(512);
    _ = try signed_body.loadUint(32);
    _ = try signed_body.loadUint(32);
    try std.testing.expectEqual(@as(u64, 11), try signed_body.loadUint(32));
    try std.testing.expectEqual(@as(u64, 0), try signed_body.loadUint(32));
    try std.testing.expectEqual(@as(u64, 3), try signed_body.loadUint(8));
    const internal_ref = try signed_body.loadRef();
    var internal_slice = internal_ref.toSlice();
    _ = try internal_slice.loadUint(1);
    _ = try internal_slice.loadUint(1);
    _ = try internal_slice.loadUint(1);
    _ = try internal_slice.loadUint(1);
    _ = try internal_slice.loadUint(2);
    _ = try internal_slice.loadAddress();
    _ = try internal_slice.loadCoins();
    _ = try internal_slice.loadUint(1);
    _ = try internal_slice.loadCoins();
    _ = try internal_slice.loadCoins();
    _ = try internal_slice.loadUint(64);
    _ = try internal_slice.loadUint(32);
    try std.testing.expectEqual(@as(u64, 0), try internal_slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 1), try internal_slice.loadUint(1));
    const contract_body = try internal_slice.loadRef();
    var body_slice = contract_body.toSlice();
    try std.testing.expectEqual(@as(u64, 0x10203040), try body_slice.loadUint(32));
    try std.testing.expectEqual(@as(u64, 1), try body_slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 7), try body_slice.loadUint(8));
}

test "agent tools buildWalletContractMessageAuto discovers abi before signing" {
    const allocator = std.testing.allocator;

    const keypair = try signing.generateKeypair("tools-wallet-build-auto");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abi_json =
        \\{
        \\  "version": "1.0",
        \\  "functions": [
        \\    {
        \\      "name": "ping",
        \\      "opcode": "0xAABBCCDD",
        \\      "inputs": []
        \\    }
        \\  ]
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "wallet_build_auto_abi.json", .data = abi_json });
    const abi_path = try tmp.dir.realpathAlloc(allocator, "wallet_build_auto_abi.json");
    defer allocator.free(abi_path);
    const abi_uri = try std.fmt.allocPrint(allocator, "file://{s}", .{abi_path});
    defer allocator.free(abi_uri);

    const FakeClient = struct {
        allocator: std.mem.Allocator,
        abi_uri: []const u8,
        public_key_hex: []const u8,

        pub fn runGetMethod(self: *@This(), _: []const u8, method: []const u8, _: []const []const u8) anyerror!core_types.RunGetMethodResponse {
            const entries = try self.allocator.alloc(core_types.StackEntry, 1);
            errdefer self.allocator.free(entries);

            if (std.mem.eql(u8, method, "get_abi_uri")) {
                var builder = core_types.Builder.init();
                try builder.storeUint(0x01, 8);
                try builder.storeBits(self.abi_uri, @intCast(self.abi_uri.len * 8));
                const value = try builder.toCell(self.allocator);
                entries[0] = .{ .cell = value };
            } else if (std.mem.eql(u8, method, "seqno")) {
                entries[0] = .{ .number = 4 };
            } else if (std.mem.eql(u8, method, "get_subwallet_id")) {
                entries[0] = .{ .number = signing.default_wallet_id_v4 };
            } else if (std.mem.eql(u8, method, "get_public_key")) {
                entries[0] = .{ .big_number = try self.allocator.dupe(u8, self.public_key_hex) };
            } else {
                return error.InvalidResponse;
            }

            return .{
                .exit_code = 0,
                .stack = entries,
                .logs = "",
            };
        }

        pub fn freeRunGetMethodResponse(self: *@This(), response: *core_types.RunGetMethodResponse) void {
            for (response.stack) |*entry| {
                switch (entry.*) {
                    .big_number => |value| if (value.len > 0) self.allocator.free(value),
                    .cell => |value| value.deinit(self.allocator),
                    else => {},
                }
            }
            if (response.stack.len > 0) self.allocator.free(response.stack);
        }
    };
    const FakeTools = AgentToolsImpl(*FakeClient);

    const public_key_hex = blk: {
        const hex_chars = "0123456789abcdef";
        const out = try allocator.alloc(u8, 2 + keypair[1].len * 2);
        out[0] = '0';
        out[1] = 'x';
        for (keypair[1], 0..) |byte, idx| {
            out[2 + idx * 2] = hex_chars[byte >> 4];
            out[2 + idx * 2 + 1] = hex_chars[byte & 0x0f];
        }
        break :blk out;
    };
    defer allocator.free(public_key_hex);

    var client = FakeClient{
        .allocator = allocator,
        .abi_uri = abi_uri,
        .public_key_hex = public_key_hex,
    };
    var tools = FakeTools.init(allocator, &client, .{
        .rpc_url = "https://example.invalid",
        .wallet_private_key = keypair[0],
        .wallet_address = "0:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    });

    var result = try tools.buildWalletContractMessageAuto(
        "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
        222,
        "ping",
        &.{},
    );
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u32, 4), result.seqno);
    try std.testing.expect(!result.state_init_attached);

    const ext_len = try std.base64.standard.Decoder.calcSizeForSlice(result.external_boc);
    const ext_bytes = try allocator.alloc(u8, ext_len);
    defer allocator.free(ext_bytes);
    try std.base64.standard.Decoder.decode(ext_bytes, result.external_boc);

    const ext_msg = try boc.deserializeBoc(allocator, ext_bytes);
    defer ext_msg.deinit(allocator);

    var msg_slice = ext_msg.toSlice();
    _ = try msg_slice.loadUint(2);
    _ = try msg_slice.loadUint(2);
    _ = try msg_slice.loadAddress();
    _ = try msg_slice.loadCoins();
    _ = try msg_slice.loadUint(1);
    const body_ref = try msg_slice.loadRef();

    var signed_body = body_ref.toSlice();
    _ = try signed_body.loadBits(512);
    _ = try signed_body.loadUint(32);
    _ = try signed_body.loadUint(32);
    try std.testing.expectEqual(@as(u64, 4), try signed_body.loadUint(32));
    try std.testing.expectEqual(@as(u64, 0), try signed_body.loadUint(32));
    try std.testing.expectEqual(@as(u64, 3), try signed_body.loadUint(8));
    const internal_ref = try signed_body.loadRef();
    var internal_slice = internal_ref.toSlice();
    _ = try internal_slice.loadUint(1);
    _ = try internal_slice.loadUint(1);
    _ = try internal_slice.loadUint(1);
    _ = try internal_slice.loadUint(1);
    _ = try internal_slice.loadUint(2);
    _ = try internal_slice.loadAddress();
    _ = try internal_slice.loadCoins();
    _ = try internal_slice.loadUint(1);
    _ = try internal_slice.loadCoins();
    _ = try internal_slice.loadCoins();
    _ = try internal_slice.loadUint(64);
    _ = try internal_slice.loadUint(32);
    try std.testing.expectEqual(@as(u64, 0), try internal_slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 1), try internal_slice.loadUint(1));
    const contract_body = try internal_slice.loadRef();
    var body_slice = contract_body.toSlice();
    try std.testing.expectEqual(@as(u64, 0xAABBCCDD), try body_slice.loadUint(32));
}

test "agent tools buildContractDeploy signs deploy message with state init" {
    const allocator = std.testing.allocator;

    const keypair = try signing.generateKeypair("tools-wallet-build-deploy");

    var code_builder = core_types.Builder.init();
    try code_builder.storeUint(0xCAFE, 16);
    const code_cell = try code_builder.toCell(allocator);
    defer code_cell.deinit(allocator);
    const code_boc = try boc.serializeBoc(allocator, code_cell);
    defer allocator.free(code_boc);

    const state_init_boc = try state_init.buildStateInitBocAlloc(allocator, code_boc, null);
    defer allocator.free(state_init_boc);
    const expected_state_init = try boc.deserializeBoc(allocator, state_init_boc);
    defer expected_state_init.deinit(allocator);

    const FakeClient = struct {
        allocator: std.mem.Allocator,
        public_key_hex: []const u8,

        pub fn runGetMethod(self: *@This(), _: []const u8, method: []const u8, _: []const []const u8) anyerror!core_types.RunGetMethodResponse {
            const entries = try self.allocator.alloc(core_types.StackEntry, 1);
            errdefer self.allocator.free(entries);

            if (std.mem.eql(u8, method, "seqno")) {
                entries[0] = .{ .number = 2 };
            } else if (std.mem.eql(u8, method, "get_subwallet_id")) {
                entries[0] = .{ .number = signing.default_wallet_id_v4 };
            } else if (std.mem.eql(u8, method, "get_public_key")) {
                entries[0] = .{ .big_number = try self.allocator.dupe(u8, self.public_key_hex) };
            } else {
                return error.InvalidResponse;
            }

            return .{
                .exit_code = 0,
                .stack = entries,
                .logs = "",
            };
        }

        pub fn freeRunGetMethodResponse(self: *@This(), response: *core_types.RunGetMethodResponse) void {
            for (response.stack) |*entry| {
                switch (entry.*) {
                    .big_number => |value| if (value.len > 0) self.allocator.free(value),
                    else => {},
                }
            }
            if (response.stack.len > 0) self.allocator.free(response.stack);
        }
    };
    const FakeTools = AgentToolsImpl(*FakeClient);

    const public_key_hex = blk: {
        const hex_chars = "0123456789abcdef";
        const out = try allocator.alloc(u8, 2 + keypair[1].len * 2);
        out[0] = '0';
        out[1] = 'x';
        for (keypair[1], 0..) |byte, idx| {
            out[2 + idx * 2] = hex_chars[byte >> 4];
            out[2 + idx * 2 + 1] = hex_chars[byte & 0x0f];
        }
        break :blk out;
    };
    defer allocator.free(public_key_hex);

    var client = FakeClient{ .allocator = allocator, .public_key_hex = public_key_hex };
    var tools = FakeTools.init(allocator, &client, .{
        .rpc_url = "https://example.invalid",
        .wallet_private_key = keypair[0],
        .wallet_address = "0:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    });

    var result = try tools.buildContractDeploy(
        "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
        777,
        state_init_boc,
        null,
    );
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u32, 2), result.seqno);

    const ext_len = try std.base64.standard.Decoder.calcSizeForSlice(result.external_boc);
    const ext_bytes = try allocator.alloc(u8, ext_len);
    defer allocator.free(ext_bytes);
    try std.base64.standard.Decoder.decode(ext_bytes, result.external_boc);

    const ext_msg = try boc.deserializeBoc(allocator, ext_bytes);
    defer ext_msg.deinit(allocator);

    var ext_slice = ext_msg.toSlice();
    _ = try ext_slice.loadUint(2);
    _ = try ext_slice.loadUint(2);
    _ = try ext_slice.loadAddress();
    _ = try ext_slice.loadCoins();
    _ = try ext_slice.loadUint(1);
    _ = try ext_slice.loadUint(1);

    const signed_body = try ext_slice.loadRef();
    var signed_slice = signed_body.toSlice();
    _ = try signed_slice.loadBits(512);
    _ = try signed_slice.loadUint32();
    _ = try signed_slice.loadUint32();
    _ = try signed_slice.loadUint32();
    _ = try signed_slice.loadUint32();
    _ = try signed_slice.loadUint8();

    const out_msg = try signed_slice.loadRef();
    var out_slice = out_msg.toSlice();
    _ = try out_slice.loadUint(1);
    _ = try out_slice.loadUint(1);
    _ = try out_slice.loadUint(1);
    try std.testing.expectEqual(@as(u64, 0), try out_slice.loadUint(1));
    _ = try out_slice.loadUint(2);
    _ = try out_slice.loadAddress();
    try std.testing.expectEqual(@as(u64, 777), try out_slice.loadCoins());
    _ = try out_slice.loadUint(1);
    _ = try out_slice.loadCoins();
    _ = try out_slice.loadCoins();
    _ = try out_slice.loadUint(64);
    _ = try out_slice.loadUint(32);
    try std.testing.expectEqual(@as(u64, 1), try out_slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 1), try out_slice.loadUint(1));

    const state_init_ref = try out_slice.loadRef();
    try std.testing.expectEqualSlices(u8, &state_init_ref.hash(), &expected_state_init.hash());
    try std.testing.expectEqual(@as(u64, 0), try out_slice.loadUint(1));
}

test "agent tools buildContractDeployAuto derives destination from state init" {
    const allocator = std.testing.allocator;

    const keypair = try signing.generateKeypair("tools-wallet-build-deploy-auto");

    var code_builder = core_types.Builder.init();
    try code_builder.storeUint(0xBEEF, 16);
    const code_cell = try code_builder.toCell(allocator);
    defer code_cell.deinit(allocator);
    const code_boc = try boc.serializeBoc(allocator, code_cell);
    defer allocator.free(code_boc);

    const state_init_boc = try state_init.buildStateInitBocAlloc(allocator, code_boc, null);
    defer allocator.free(state_init_boc);

    const computed_addr = try state_init.computeStateInitAddressFromBoc(allocator, 0, state_init_boc);
    const expected_raw = try address_mod.formatRaw(allocator, &computed_addr);
    defer allocator.free(expected_raw);

    const FakeClient = struct {
        pub fn runGetMethod(_: *@This(), _: []const u8, _: []const u8, _: []const []const u8) anyerror!core_types.RunGetMethodResponse {
            return error.InvalidResponse;
        }

        pub fn freeRunGetMethodResponse(_: *@This(), _: *core_types.RunGetMethodResponse) void {}
    };
    const FakeTools = AgentToolsImpl(*FakeClient);

    var client = FakeClient{};
    var tools = FakeTools.init(allocator, &client, .{
        .rpc_url = "https://example.invalid",
        .wallet_private_key = keypair[0],
    });

    var result = try tools.buildContractDeployAuto(0, 123, state_init_boc, null);
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings(expected_raw, result.destination);
    try std.testing.expect(result.state_init_attached);
}

test "agent tools decodeFunctionBodyAbi decodes function input json" {
    const allocator = std.testing.allocator;

    const FakeClient = struct {};
    const FakeTools = AgentToolsImpl(*FakeClient);

    const abi_json =
        \\{
        \\  "version": "1.0",
        \\  "functions": [
        \\    {
        \\      "name": "transfer",
        \\      "opcode": "0x11223344",
        \\      "inputs": [
        \\        {"name": "to", "type": "address"},
        \\        {"name": "amount", "type": "coins"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var parsed_abi = try abi_adapter.parseAbiInfoJsonAlloc(allocator, abi_json);
    defer parsed_abi.deinit(allocator);

    const body_boc = try abi_adapter.buildFunctionBodyFromAbiAlloc(
        allocator,
        &parsed_abi.abi,
        "transfer",
        &.{
            .{ .text = "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8" },
            .{ .uint = 1234 },
        },
    );
    defer allocator.free(body_boc);

    var client = FakeClient{};
    var tools = FakeTools.init(allocator, &client, .{ .rpc_url = "https://example.invalid" });
    const result = try tools.decodeFunctionBodyAbi(
        "0:1111111111111111111111111111111111111111111111111111111111111111",
        abi_json,
        body_boc,
        null,
    );
    defer allocator.free(result.selector);
    defer allocator.free(result.decoded_json);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(tools_types.DecodedBodyKind.function, result.kind);
    try std.testing.expectEqual(@as(?u32, 0x11223344), result.opcode);
    try std.testing.expectEqualStrings("transfer(address,coins)", result.selector);
    try std.testing.expectEqualStrings(
        "{\"to\":\"0:83dfd552e63729b472fcbcc8c45ebcc6691702558b68ec7527e1ba403a0f31a8\",\"amount\":1234}",
        result.decoded_json,
    );
}

test "agent tools decodeEventBodyAuto discovers abi and decodes event body" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abi_json =
        \\{
        \\  "version": "1.0",
        \\  "events": [
        \\    {
        \\      "name": "Transfer",
        \\      "opcode": "0x01020304",
        \\      "inputs": [
        \\        {"name": "amount", "type": "coins"},
        \\        {"name": "active", "type": "bool"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "abi.json", .data = abi_json });
    const abi_path = try tmp.dir.realpathAlloc(allocator, "abi.json");
    defer allocator.free(abi_path);
    const abi_uri = try std.fmt.allocPrint(allocator, "file://{s}", .{abi_path});
    defer allocator.free(abi_uri);

    const FakeClient = struct {
        allocator: std.mem.Allocator,
        abi_uri: []const u8,

        pub fn runGetMethod(self: *@This(), addr: []const u8, method: []const u8, stack: []const []const u8) anyerror!core_types.RunGetMethodResponse {
            _ = addr;
            _ = method;
            _ = stack;

            var builder = core_types.Builder.init();
            try builder.storeUint(0x01, 8);
            try builder.storeBits(self.abi_uri, @intCast(self.abi_uri.len * 8));
            const cell_value = try builder.toCell(self.allocator);

            const entries = try self.allocator.alloc(core_types.StackEntry, 1);
            entries[0] = .{ .cell = cell_value };
            return .{
                .exit_code = 0,
                .stack = entries,
                .logs = "",
            };
        }

        pub fn freeRunGetMethodResponse(self: *@This(), response: *core_types.RunGetMethodResponse) void {
            for (response.stack) |*entry| {
                switch (entry.*) {
                    .cell => |value| value.deinit(self.allocator),
                    else => {},
                }
            }
            if (response.stack.len > 0) self.allocator.free(response.stack);
        }
    };
    const FakeTools = AgentToolsImpl(*FakeClient);

    var event_builder = core_types.Builder.init();
    try event_builder.storeUint(0x01020304, 32);
    try event_builder.storeCoins(99);
    try event_builder.storeUint(1, 1);
    const event_cell = try event_builder.toCell(allocator);
    defer event_cell.deinit(allocator);
    const event_body_boc = try boc.serializeBoc(allocator, event_cell);
    defer allocator.free(event_body_boc);

    var client = FakeClient{ .allocator = allocator, .abi_uri = abi_uri };
    var tools = FakeTools.init(allocator, &client, .{ .rpc_url = "https://example.invalid" });
    const result = try tools.decodeEventBodyAuto(
        "0:2222222222222222222222222222222222222222222222222222222222222222",
        event_body_boc,
        null,
    );
    defer allocator.free(result.selector);
    defer allocator.free(result.decoded_json);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(tools_types.DecodedBodyKind.event, result.kind);
    try std.testing.expectEqual(@as(?u32, 0x01020304), result.opcode);
    try std.testing.expectEqualStrings("Transfer(coins,bool)", result.selector);
    try std.testing.expectEqualStrings("{\"amount\":99,\"active\":true}", result.decoded_json);
}

test "agent tools getTransactions returns summary results" {
    const allocator = std.testing.allocator;

    const FakeClient = struct {
        allocator: std.mem.Allocator,

        fn freeMessage(self: *@This(), msg: *core_types.Message) void {
            if (msg.hash.len > 0) self.allocator.free(msg.hash);
            if (msg.raw_body.len > 0) self.allocator.free(msg.raw_body);
            if (msg.body) |body| body.deinit(self.allocator);
            self.allocator.destroy(msg);
        }

        pub fn getTransactions(self: *@This(), addr: []const u8, limit: u32) ![]core_types.Transaction {
            _ = addr;
            _ = limit;

            const txs = try self.allocator.alloc(core_types.Transaction, 1);
            errdefer self.allocator.free(txs);

            const in_msg = try self.allocator.create(core_types.Message);
            errdefer self.allocator.destroy(in_msg);

            in_msg.* = .{
                .hash = try self.allocator.dupe(u8, "msg-summary"),
                .source = try address_mod.parseAddress("0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8"),
                .destination = try address_mod.parseAddress("EQCD39VS5jcptHL8vMjEXrzGaRcCVYto7HUn4bpAOg8xqB2N"),
                .value = 777,
                .body = null,
                .raw_body = &.{},
            };

            txs[0] = .{
                .hash = try self.allocator.dupe(u8, "tx-summary"),
                .lt = 42,
                .timestamp = 99,
                .in_msg = in_msg,
                .out_msgs = &.{},
            };
            return txs;
        }

        pub fn freeTransactions(self: *@This(), txs: []core_types.Transaction) void {
            for (txs) |*tx| self.freeTransaction(tx);
            if (txs.len > 0) self.allocator.free(txs);
        }

        pub fn freeTransaction(self: *@This(), tx: *core_types.Transaction) void {
            if (tx.hash.len > 0) self.allocator.free(tx.hash);
            if (tx.in_msg) |msg| self.freeMessage(msg);
            if (tx.out_msgs.len > 0) self.allocator.free(tx.out_msgs);
            tx.* = undefined;
        }
    };
    const FakeTools = AgentToolsImpl(*FakeClient);

    var client = FakeClient{ .allocator = allocator };
    var tools = FakeTools.init(allocator, &client, .{ .rpc_url = "https://example.invalid" });

    var result = try tools.getTransactions("0:1111111111111111111111111111111111111111111111111111111111111111", 5);
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expectEqualStrings("tx-summary", result.items[0].hash);
    try std.testing.expectEqual(@as(i64, 42), result.items[0].lt);
    try std.testing.expectEqualStrings(
        "0:83dfd552e63729b472fcbcc8c45ebcc6691702558b68ec7527e1ba403a0f31a8",
        result.items[0].from.?,
    );
    try std.testing.expectEqualStrings(
        "0:83dfd552e63729b472fcbcc8c45ebcc6691702558b68ec7527e1ba403a0f31a8",
        result.items[0].to.?,
    );
    try std.testing.expectEqual(@as(u64, 777), result.items[0].value);
    try std.testing.expectEqual(tools_types.TxStatus.confirmed, result.items[0].status);
}

test "agent tools lookupTransaction decodes message bodies automatically" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abi_json =
        \\{
        \\  "version": "1.0",
        \\  "functions": [
        \\    {
        \\      "name": "transfer",
        \\      "opcode": "0x11223344",
        \\      "inputs": [
        \\        {"name": "to", "type": "address"},
        \\        {"name": "amount", "type": "coins"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "abi.json", .data = abi_json });
    const abi_path = try tmp.dir.realpathAlloc(allocator, "abi.json");
    defer allocator.free(abi_path);
    const abi_uri = try std.fmt.allocPrint(allocator, "file://{s}", .{abi_path});
    defer allocator.free(abi_uri);

    var parsed_abi = try abi_adapter.parseAbiInfoJsonAlloc(allocator, abi_json);
    defer parsed_abi.deinit(allocator);
    const body_boc = try abi_adapter.buildFunctionBodyFromAbiAlloc(
        allocator,
        &parsed_abi.abi,
        "transfer",
        &.{
            .{ .text = "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8" },
            .{ .uint = 1234 },
        },
    );
    defer allocator.free(body_boc);

    const FakeClient = struct {
        allocator: std.mem.Allocator,
        abi_uri: []const u8,
        body_boc: []const u8,

        fn freeMessage(self: *@This(), msg: *core_types.Message) void {
            if (msg.hash.len > 0) self.allocator.free(msg.hash);
            if (msg.raw_body.len > 0) self.allocator.free(msg.raw_body);
            if (msg.body) |body| body.deinit(self.allocator);
            self.allocator.destroy(msg);
        }

        pub fn lookupTx(self: *@This(), lt: i64, hash: []const u8) !?core_types.Transaction {
            _ = lt;
            _ = hash;

            const in_msg = try self.allocator.create(core_types.Message);
            errdefer self.allocator.destroy(in_msg);

            const body_cell = try boc.deserializeBoc(self.allocator, self.body_boc);
            errdefer body_cell.deinit(self.allocator);

            in_msg.* = .{
                .hash = try self.allocator.dupe(u8, "msg-detail"),
                .source = try address_mod.parseAddress("0:9999999999999999999999999999999999999999999999999999999999999999"),
                .destination = try address_mod.parseAddress("0:2222222222222222222222222222222222222222222222222222222222222222"),
                .value = 321,
                .body = body_cell,
                .raw_body = try self.allocator.dupe(u8, "hello tx"),
            };

            return .{
                .hash = try self.allocator.dupe(u8, "tx-detail"),
                .lt = 777,
                .timestamp = 888,
                .in_msg = in_msg,
                .out_msgs = &.{},
            };
        }

        pub fn freeTransaction(self: *@This(), tx: *core_types.Transaction) void {
            if (tx.hash.len > 0) self.allocator.free(tx.hash);
            if (tx.in_msg) |msg| self.freeMessage(msg);
            if (tx.out_msgs.len > 0) self.allocator.free(tx.out_msgs);
            tx.* = undefined;
        }

        pub fn runGetMethod(self: *@This(), addr: []const u8, method: []const u8, stack: []const []const u8) anyerror!core_types.RunGetMethodResponse {
            _ = addr;
            _ = method;
            _ = stack;

            var builder = core_types.Builder.init();
            try builder.storeUint(0x01, 8);
            try builder.storeBits(self.abi_uri, @intCast(self.abi_uri.len * 8));
            const cell_value = try builder.toCell(self.allocator);

            const entries = try self.allocator.alloc(core_types.StackEntry, 1);
            entries[0] = .{ .cell = cell_value };
            return .{
                .exit_code = 0,
                .stack = entries,
                .logs = "",
            };
        }

        pub fn freeRunGetMethodResponse(self: *@This(), response: *core_types.RunGetMethodResponse) void {
            for (response.stack) |*entry| {
                switch (entry.*) {
                    .cell => |value| value.deinit(self.allocator),
                    else => {},
                }
            }
            if (response.stack.len > 0) self.allocator.free(response.stack);
        }
    };
    const FakeTools = AgentToolsImpl(*FakeClient);

    var client = FakeClient{
        .allocator = allocator,
        .abi_uri = abi_uri,
        .body_boc = body_boc,
    };
    var tools = FakeTools.init(allocator, &client, .{ .rpc_url = "https://example.invalid" });

    var result = try tools.lookupTransaction(777, "tx-detail");
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("tx-detail", result.hash);
    try std.testing.expect(result.in_message != null);
    try std.testing.expectEqualStrings("hello tx", result.in_message.?.raw_body_utf8.?);
    try std.testing.expect(result.in_message.?.body_boc != null);
    try std.testing.expect(result.in_message.?.decoded_body != null);
    try std.testing.expectEqualStrings(
        "transfer(address,coins)",
        result.in_message.?.decoded_body.?.selector,
    );
    try std.testing.expectEqualStrings(
        "{\"to\":\"0:83dfd552e63729b472fcbcc8c45ebcc6691702558b68ec7527e1ba403a0f31a8\",\"amount\":1234}",
        result.in_message.?.decoded_body.?.decoded_json,
    );
}

test "agent tools inspectContract summarizes wallet and abi metadata" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abi_json =
        \\{
        \\  "version": "1.0",
        \\  "functions": [
        \\    {
        \\      "name": "transfer",
        \\      "opcode": "0x11223344",
        \\      "inputs": [
        \\        {"name": "to", "type": "address"},
        \\        {"name": "amount", "type": "coins"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "inspect_abi.json", .data = abi_json });
    const abi_path = try tmp.dir.realpathAlloc(allocator, "inspect_abi.json");
    defer allocator.free(abi_path);
    const abi_uri = try std.fmt.allocPrint(allocator, "file://{s}", .{abi_path});
    defer allocator.free(abi_uri);

    const FakeClient = struct {
        allocator: std.mem.Allocator,
        abi_uri: []const u8,

        pub fn runGetMethod(self: *@This(), addr: []const u8, method: []const u8, stack: []const []const u8) anyerror!core_types.RunGetMethodResponse {
            _ = addr;
            _ = stack;

            const entries = try self.allocator.alloc(core_types.StackEntry, 1);
            errdefer self.allocator.free(entries);

            if (std.mem.eql(u8, method, "seqno")) {
                entries[0] = .{ .number = 7 };
            } else if (std.mem.eql(u8, method, "get_subwallet_id")) {
                entries[0] = .{ .number = 0xAABBCCDD };
            } else if (std.mem.eql(u8, method, "get_public_key")) {
                entries[0] = .{ .big_number = try self.allocator.dupe(u8, "0x00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff") };
            } else if (std.mem.eql(u8, method, "get_abi_uri")) {
                var builder = core_types.Builder.init();
                try builder.storeUint(0x01, 8);
                try builder.storeBits(self.abi_uri, @intCast(self.abi_uri.len * 8));
                entries[0] = .{ .cell = try builder.toCell(self.allocator) };
            } else {
                return error.InvalidResponse;
            }

            return .{
                .exit_code = 0,
                .stack = entries,
                .logs = "",
            };
        }

        pub fn freeRunGetMethodResponse(self: *@This(), response: *core_types.RunGetMethodResponse) void {
            for (response.stack) |*entry| {
                switch (entry.*) {
                    .big_number => |value| if (value.len > 0) self.allocator.free(value),
                    .bytes => |value| if (value.len > 0) self.allocator.free(value),
                    .cell => |value| value.deinit(self.allocator),
                    else => {},
                }
            }
            if (response.stack.len > 0) self.allocator.free(response.stack);
        }
    };
    const FakeTools = AgentToolsImpl(*FakeClient);

    var client = FakeClient{ .allocator = allocator, .abi_uri = abi_uri };
    var tools = FakeTools.init(allocator, &client, .{ .rpc_url = "https://example.invalid" });

    var result = try tools.inspectContract("0:2222222222222222222222222222222222222222222222222222222222222222");
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(result.has_wallet);
    try std.testing.expect(result.has_abi);
    try std.testing.expect(!result.has_jetton);
    try std.testing.expect(result.abi_uri != null);
    try std.testing.expectEqualStrings(abi_uri, result.abi_uri.?);
    try std.testing.expect(result.abi_version != null);
    try std.testing.expectEqualStrings("1.0", result.abi_version.?);
    try std.testing.expect(result.abi_json != null);
    try std.testing.expect(std.mem.indexOf(u8, result.abi_json.?, "\"document_version\":\"1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.abi_json.?, "\"selector\":\"transfer(address,coins)\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.abi_json.?, "\"input_template\":\"addr:EQ... num:0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.abi_json.?, "\"named_input_template\":\"to=addr:EQ... amount=num:0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.abi_json.?, "\"decoded_output_template\":\"{}\"") != null);
    try std.testing.expectEqual(@as(usize, 1), result.functions.len);
    try std.testing.expectEqualStrings("transfer", result.functions[0].name);
    try std.testing.expectEqualStrings("to=addr:EQ... amount=num:0", result.functions[0].named_input_template);
    try std.testing.expectEqual(@as(usize, 2), result.functions[0].inputs.len);
    try std.testing.expectEqualStrings("address", result.functions[0].inputs[0].type_name);
    try std.testing.expectEqualStrings("addr:EQ...", result.functions[0].inputs[0].cli_template);
    try std.testing.expectEqual(@as(usize, 0), result.events.len);
    try std.testing.expect(result.details_json != null);
    try std.testing.expect(std.mem.indexOf(u8, result.details_json.?, "\"seqno\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.details_json.?, "\"wallet_id\":2864434397") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.details_json.?, "\"public_key\":\"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff\"") != null);
}

test "agent tools describeAbi returns structured templates for direct source" {
    const allocator = std.testing.allocator;

    const FakeClient = struct {};
    const FakeTools = AgentToolsImpl(*FakeClient);

    const abi_json =
        \\{
        \\  "version": "1.0",
        \\  "functions": [
        \\    {
        \\      "name": "transfer",
        \\      "opcode": "0x11223344",
        \\      "inputs": [
        \\        {"name": "to", "type": "address"},
        \\        {"name": "amount", "type": "coins"}
        \\      ],
        \\      "outputs": [
        \\        {"name": "ok", "type": "bool"}
        \\      ]
        \\    }
        \\  ],
        \\  "events": [
        \\    {
        \\      "name": "Transfer",
        \\      "opcode": "0x55667788",
        \\      "inputs": [
        \\        {"name": "amount", "type": "coins"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var client = FakeClient{};
    var tools = FakeTools.init(allocator, &client, .{ .rpc_url = "https://example.invalid" });

    var result = try tools.describeAbi(abi_json);
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings(abi_json, result.source);
    try std.testing.expect(result.address == null);
    try std.testing.expectEqualStrings("1.0", result.version);
    try std.testing.expectEqual(@as(usize, 1), result.functions.len);
    try std.testing.expectEqual(@as(usize, 1), result.events.len);
    try std.testing.expectEqualStrings("transfer", result.functions[0].name);
    try std.testing.expectEqualStrings("transfer(address,coins)", result.functions[0].selector);
    try std.testing.expectEqualStrings("addr:EQ... num:0", result.functions[0].input_template);
    try std.testing.expectEqualStrings("to=addr:EQ... amount=num:0", result.functions[0].named_input_template);
    try std.testing.expectEqualStrings("{\"ok\":true}", result.functions[0].decoded_output_template);
    try std.testing.expectEqual(@as(usize, 2), result.functions[0].inputs.len);
    try std.testing.expectEqualStrings("to", result.functions[0].inputs[0].name);
    try std.testing.expectEqualStrings("address", result.functions[0].inputs[0].type_name);
    try std.testing.expectEqualStrings("addr:EQ...", result.functions[0].inputs[0].cli_template);
    try std.testing.expectEqualStrings("\"EQ...\"", result.functions[0].inputs[0].json_template);
    try std.testing.expectEqualStrings("\"0:...\"", result.functions[0].inputs[0].decoded_template);
    try std.testing.expectEqual(@as(usize, 1), result.functions[0].outputs.len);
    try std.testing.expectEqualStrings("bool", result.functions[0].outputs[0].type_name);
    try std.testing.expectEqualStrings("Transfer", result.events[0].name);
    try std.testing.expectEqualStrings("Transfer(coins)", result.events[0].selector);
    try std.testing.expectEqualStrings("{\"amount\":0}", result.events[0].decoded_fields_template);
    try std.testing.expectEqual(@as(usize, 1), result.events[0].fields.len);
    try std.testing.expectEqualStrings("coins", result.events[0].fields[0].type_name);
}

test "agent tools describeAbiAuto discovers abi and returns templates" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abi_json =
        \\{
        \\  "version": "1.0",
        \\  "functions": [
        \\    {
        \\      "name": "ping",
        \\      "inputs": [],
        \\      "outputs": []
        \\    }
        \\  ],
        \\  "events": []
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "describe_abi.json", .data = abi_json });
    const abi_path = try tmp.dir.realpathAlloc(allocator, "describe_abi.json");
    defer allocator.free(abi_path);
    const abi_uri = try std.fmt.allocPrint(allocator, "file://{s}", .{abi_path});
    defer allocator.free(abi_uri);

    const FakeClient = struct {
        allocator: std.mem.Allocator,
        abi_uri: []const u8,

        pub fn runGetMethod(self: *@This(), addr: []const u8, method: []const u8, stack: []const []const u8) anyerror!core_types.RunGetMethodResponse {
            _ = addr;
            _ = stack;
            if (!std.mem.eql(u8, method, "get_abi_uri")) return error.InvalidResponse;

            var builder = core_types.Builder.init();
            try builder.storeUint(0x01, 8);
            try builder.storeBits(self.abi_uri, @intCast(self.abi_uri.len * 8));
            const cell_value = try builder.toCell(self.allocator);

            const entries = try self.allocator.alloc(core_types.StackEntry, 1);
            entries[0] = .{ .cell = cell_value };
            return .{
                .exit_code = 0,
                .stack = entries,
                .logs = "",
            };
        }

        pub fn freeRunGetMethodResponse(self: *@This(), response: *core_types.RunGetMethodResponse) void {
            for (response.stack) |*entry| {
                switch (entry.*) {
                    .cell => |value| value.deinit(self.allocator),
                    else => {},
                }
            }
            if (response.stack.len > 0) self.allocator.free(response.stack);
        }
    };
    const FakeTools = AgentToolsImpl(*FakeClient);

    var client = FakeClient{ .allocator = allocator, .abi_uri = abi_uri };
    var tools = FakeTools.init(allocator, &client, .{ .rpc_url = "https://example.invalid" });

    var result = try tools.describeAbiAuto("0:3333333333333333333333333333333333333333333333333333333333333333");
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("auto:0:3333333333333333333333333333333333333333333333333333333333333333", result.source);
    try std.testing.expect(result.address != null);
    try std.testing.expectEqualStrings("0:3333333333333333333333333333333333333333333333333333333333333333", result.address.?);
    try std.testing.expect(result.uri != null);
    try std.testing.expectEqualStrings(abi_uri, result.uri.?);
    try std.testing.expectEqual(@as(usize, 1), result.functions.len);
    try std.testing.expectEqualStrings("ping()", result.functions[0].selector);
    try std.testing.expectEqual(@as(usize, 0), result.functions[0].inputs.len);
    try std.testing.expectEqual(@as(usize, 0), result.functions[0].outputs.len);
}

test "agent tools describeAbi preserves nested parameter schemas" {
    const allocator = std.testing.allocator;

    const FakeClient = struct {};
    const FakeTools = AgentToolsImpl(*FakeClient);

    const abi_json =
        \\{
        \\  "version": "1.0",
        \\  "functions": [
        \\    {
        \\      "name": "set_config",
        \\      "inputs": [
        \\        {
        \\          "name": "config",
        \\          "type": "tuple",
        \\          "components": [
        \\            {"name": "enabled", "type": "bool"},
        \\            {"name": "label", "type": "optional<string>"}
        \\          ]
        \\        }
        \\      ],
        \\      "outputs": []
        \\    }
        \\  ],
        \\  "events": []
        \\}
    ;

    var client = FakeClient{};
    var tools = FakeTools.init(allocator, &client, .{ .rpc_url = "https://example.invalid" });

    var result = try tools.describeAbi(abi_json);
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 1), result.functions.len);
    try std.testing.expectEqual(@as(usize, 1), result.functions[0].inputs.len);
    try std.testing.expectEqualStrings("tuple", result.functions[0].inputs[0].type_name);
    try std.testing.expectEqual(@as(usize, 2), result.functions[0].inputs[0].components.len);
    try std.testing.expectEqualStrings("enabled", result.functions[0].inputs[0].components[0].name);
    try std.testing.expectEqualStrings("bool", result.functions[0].inputs[0].components[0].type_name);
    try std.testing.expectEqualStrings("label", result.functions[0].inputs[0].components[1].name);
    try std.testing.expectEqualStrings("optional<string>", result.functions[0].inputs[0].components[1].type_name);
    try std.testing.expectEqualStrings("null", result.functions[0].inputs[0].components[1].cli_template);
}

test "agent tools generic runGetMethod result type is exported" {
    _ = AgentTools.describeAbi;
    _ = AgentTools.describeAbiAuto;
    _ = AgentTools.decodeFunctionBodyAbi;
    _ = AgentTools.decodeFunctionBodyAuto;
    _ = AgentTools.decodeEventBodyAbi;
    _ = AgentTools.decodeEventBodyAuto;
    _ = AgentTools.buildContractBodyFunction;
    _ = AgentTools.buildContractBodyAbi;
    _ = AgentTools.buildContractBodyAuto;
    _ = AgentTools.buildExternalMessageEnvelope;
    _ = AgentTools.buildExternalMessageEnvelopeFunction;
    _ = AgentTools.buildExternalMessageEnvelopeAbi;
    _ = AgentTools.buildExternalMessageEnvelopeAuto;
    _ = AgentTools.buildWalletTransfer;
    _ = AgentTools.buildWalletContractMessage;
    _ = AgentTools.buildWalletContractMessageFunction;
    _ = AgentTools.buildWalletContractMessageAbi;
    _ = AgentTools.buildWalletContractMessageAuto;
    _ = AgentTools.buildContractDeploy;
    _ = AgentTools.buildContractDeployAuto;
    _ = AgentTools.inspectContract;
    _ = AgentTools.getTransactions;
    _ = AgentTools.lookupTransaction;
    _ = AgentTools.runGetMethod;
    _ = AgentTools.runGetMethodAbi;
    _ = AgentTools.runGetMethodAuto;
    _ = AgentTools.computeStateInitAddress;
    _ = AgentTools.deriveWalletInit;
    _ = AgentTools.sendContractMessage;
    _ = AgentTools.sendContractMessageOps;
    _ = AgentTools.sendContractMessageFunction;
    _ = AgentTools.sendContractMessageAbi;
    _ = AgentTools.sendContractMessageAuto;
    _ = AgentTools.sendExternalMessage;
    _ = AgentTools.sendExternalMessageFunction;
    _ = AgentTools.sendExternalMessageAbi;
    _ = AgentTools.sendExternalMessageAuto;
    _ = AgentTools.sendContractDeploy;
    _ = AgentTools.sendContractDeployAuto;
    _ = AgentTools.deployWalletSelf;
    _ = AgentTools.sendInitialTransfer;
    _ = ProviderAgentTools.runGetMethod;
    _ = ProviderAgentTools.runGetMethodAbi;
    _ = ProviderAgentTools.runGetMethodAuto;
    _ = ProviderAgentTools.describeAbi;
    _ = ProviderAgentTools.describeAbiAuto;
    _ = ProviderAgentTools.inspectContract;
    _ = ProviderAgentTools.getTransactions;
    _ = ProviderAgentTools.lookupTransaction;
    _ = ProviderAgentTools.decodeFunctionBodyAbi;
    _ = ProviderAgentTools.decodeFunctionBodyAuto;
    _ = ProviderAgentTools.decodeEventBodyAbi;
    _ = ProviderAgentTools.decodeEventBodyAuto;
    _ = ProviderAgentTools.buildContractBodyFunction;
    _ = ProviderAgentTools.buildContractBodyAbi;
    _ = ProviderAgentTools.buildContractBodyAuto;
    _ = ProviderAgentTools.buildExternalMessageEnvelope;
    _ = ProviderAgentTools.buildExternalMessageEnvelopeFunction;
    _ = ProviderAgentTools.buildExternalMessageEnvelopeAbi;
    _ = ProviderAgentTools.buildExternalMessageEnvelopeAuto;
    _ = ProviderAgentTools.buildWalletTransfer;
    _ = ProviderAgentTools.buildWalletContractMessage;
    _ = ProviderAgentTools.buildWalletContractMessageFunction;
    _ = ProviderAgentTools.buildWalletContractMessageAbi;
    _ = ProviderAgentTools.buildWalletContractMessageAuto;
    _ = ProviderAgentTools.buildContractDeploy;
    _ = ProviderAgentTools.buildContractDeployAuto;
    _ = ProviderAgentTools.deriveWalletInit;
    _ = ProviderAgentTools.verifyPayment;
    _ = ProviderAgentTools.waitPayment;
    _ = ProviderAgentTools.getJettonBalance;
    _ = ProviderAgentTools.getJettonInfo;
    _ = ProviderAgentTools.getJettonWalletAddress;
    _ = ProviderAgentTools.getNFTInfo;
    _ = ProviderAgentTools.getNFTCollectionInfo;
    _ = ProviderAgentTools.sendTransfer;
    _ = ProviderAgentTools.sendExternalMessage;
    _ = ProviderAgentTools.sendExternalMessageAbi;
    _ = ProviderAgentTools.sendExternalMessageAuto;
    _ = ProviderAgentTools.deployWalletSelf;
    _ = ProviderAgentTools.sendInitialTransfer;
    _ = AddressResult;
    _ = DecodedBodyResult;
    _ = BuiltBodyResult;
    _ = BuiltExternalMessageResult;
    _ = BuiltWalletMessageResult;
    _ = MessageResult;
    _ = RunMethodResult;
    _ = TransactionListResult;
    _ = TransactionDetailResult;
    _ = ContractInspectResult;
    _ = AbiParamTemplateResult;
    _ = AbiFunctionTemplateResult;
    _ = AbiEventTemplateResult;
    _ = AbiDescribeResult;
    _ = WalletInitResult;
    _ = JettonInfoResult;
    _ = JettonWalletAddressResult;
    _ = NFTCollectionInfoResult;
}
