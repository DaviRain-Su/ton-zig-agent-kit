//! ABI adapter for self-describing contracts

const std = @import("std");
const types = @import("../core/types.zig");
const cell = @import("../core/cell.zig");
const boc = @import("../core/boc.zig");
const body_builder = @import("../core/body_builder.zig");
const generic_contract = @import("contract.zig");

pub const SupportedInterfaces = struct {
    has_wallet: bool,
    has_jetton: bool,
    has_jetton_master: bool,
    has_jetton_wallet: bool,
    has_nft: bool,
    has_nft_item: bool,
    has_nft_collection: bool,
    has_abi: bool,
};

pub const AbiInfo = struct {
    version: []const u8,
    uri: ?[]const u8 = null,
    functions: []const FunctionDef,
    events: []const EventDef,

    pub fn deinit(self: *AbiInfo, allocator: std.mem.Allocator) void {
        if (self.uri) |uri| allocator.free(uri);
        self.uri = null;
    }
};

pub const FunctionDef = struct {
    name: []const u8,
    opcode: ?u32 = null,
    inputs: []const ParamDef,
    outputs: []const ParamDef,
};

pub const EventDef = struct {
    name: []const u8,
    opcode: ?u32 = null,
    inputs: []const ParamDef,
};

pub const ParamDef = struct {
    name: []const u8,
    type_name: []const u8,
    components: []const ParamDef = &.{},
};

pub const OwnedFunctionDef = struct {
    function: FunctionDef,

    pub fn deinit(self: *OwnedFunctionDef, allocator: std.mem.Allocator) void {
        allocator.free(self.function.name);
        freeParamDefs(allocator, self.function.inputs);
        freeParamDefs(allocator, self.function.outputs);
    }
};

pub const OwnedAbiInfo = struct {
    abi: AbiInfo,

    pub fn deinit(self: *OwnedAbiInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.abi.version);
        if (self.abi.uri) |uri| allocator.free(uri);
        freeFunctionDefs(allocator, self.abi.functions);
        freeEventDefs(allocator, self.abi.events);
        self.abi.uri = null;
    }
};

pub const AbiValue = union(enum) {
    null: void,
    uint: u64,
    int: i64,
    numeric_text: []const u8,
    text: []const u8,
    bytes: []const u8,
    boc: []const u8,
    json: []const u8,
};

pub const OwnedStackArgs = struct {
    args: []generic_contract.StackArg,
    owned_buffers: []?[]u8,

    pub fn deinit(self: *OwnedStackArgs, allocator: std.mem.Allocator) void {
        for (self.owned_buffers) |buffer| {
            if (buffer) |value| allocator.free(value);
        }
        if (self.owned_buffers.len > 0) allocator.free(self.owned_buffers);
        if (self.args.len > 0) allocator.free(self.args);
        self.args = &.{};
        self.owned_buffers = &.{};
    }
};

pub const ContractAdapter = struct {
    address: []const u8,
    abi: ?AbiInfo,
};

const max_abi_source_bytes: usize = 1 << 20;
const default_ipfs_gateway = "https://ipfs.io";
const abi_array_length_bits: u16 = 32;

pub fn querySupportedInterfaces(client: anytype, addr: []const u8) !?SupportedInterfaces {
    const supported = supportedInterfacesFromMethodSupport(
        try probeMethodSupport(client, addr, "seqno"),
        try probeMethodSupport(client, addr, "get_jetton_data"),
        try probeMethodSupport(client, addr, "get_wallet_data"),
        try probeMethodSupport(client, addr, "get_nft_data"),
        try probeMethodSupport(client, addr, "get_collection_data"),
        try probeAbiSupport(client, addr),
    );

    return supported;
}

pub fn queryAbiIpfs(client: anytype, addr: []const u8) !?AbiInfo {
    for (abi_method_candidates) |method_name| {
        var result = client.runGetMethod(addr, method_name, &.{}) catch |err| switch (err) {
            types.TonError.RpcError,
            error.InvalidResponse,
            error.UnsupportedStackEntry,
            => continue,
            else => return err,
        };
        defer client.freeRunGetMethodResponse(&result);

        if (result.exit_code != 0) continue;
        if (try abiInfoFromStack(client.allocator, result.stack)) |info| return info;
    }

    return null;
}

pub fn queryAbiDocumentAlloc(client: anytype, addr: []const u8) !?OwnedAbiInfo {
    var abi_ref = try queryAbiIpfs(client, addr) orelse return null;
    defer abi_ref.deinit(client.allocator);

    const uri = abi_ref.uri orelse return null;
    var abi = try loadAbiInfoSourceAlloc(client.allocator, uri);
    errdefer abi.deinit(client.allocator);

    if (abi.abi.uri == null) {
        abi.abi.uri = try client.allocator.dupe(u8, uri);
    }

    return abi;
}

pub fn adaptToContract(addr: []const u8, abi: ?AbiInfo) ContractAdapter {
    return ContractAdapter{ .address = addr, .abi = abi };
}

pub fn loadAbiInfoSourceAlloc(allocator: std.mem.Allocator, source: []const u8) !OwnedAbiInfo {
    const abi_json = try loadAbiTextSourceAlloc(allocator, source);
    defer allocator.free(abi_json);

    return parseAbiInfoJsonAlloc(allocator, abi_json);
}

pub fn loadAbiTextSourceAlloc(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidAbiDefinition;

    if (trimmed[0] == '{' or trimmed[0] == '[') {
        return allocator.dupe(u8, trimmed);
    }

    if (trimmed[0] == '@' and trimmed.len > 1) {
        return readAbiFileAlloc(allocator, trimmed[1..]);
    }

    if (std.mem.startsWith(u8, trimmed, "file://")) {
        return readAbiFileAlloc(allocator, trimmed["file://".len..]);
    }

    if (std.mem.startsWith(u8, trimmed, "http://") or
        std.mem.startsWith(u8, trimmed, "https://") or
        std.mem.startsWith(u8, trimmed, "ipfs://") or
        std.mem.startsWith(u8, trimmed, "ipns://"))
    {
        return fetchAbiUrlAlloc(allocator, trimmed);
    }

    if (readAbiFileAlloc(allocator, trimmed)) |file_text| {
        return file_text;
    } else |_| {}

    return allocator.dupe(u8, trimmed);
}

pub fn parseAbiInfoJsonAlloc(allocator: std.mem.Allocator, json_text: []const u8) !OwnedAbiInfo {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidAbiDefinition;
    const object = parsed.value.object;

    const version = if (object.get("version")) |value|
        switch (value) {
            .string => try allocator.dupe(u8, value.string),
            else => return error.InvalidAbiDefinition,
        }
    else
        try allocator.dupe(u8, "json");
    errdefer allocator.free(version);

    const functions = if (getAbiFunctionArray(object)) |value|
        try parseFunctionDefsAlloc(allocator, value)
    else
        &.{};
    errdefer freeFunctionDefs(allocator, functions);

    const events = if (object.get("events")) |value|
        try parseEventDefsAlloc(allocator, value)
    else
        &.{};
    errdefer freeEventDefs(allocator, events);

    return .{
        .abi = .{
            .version = version,
            .uri = null,
            .functions = functions,
            .events = events,
        },
    };
}

pub fn parseFunctionDefJsonAlloc(allocator: std.mem.Allocator, json_text: []const u8) !OwnedFunctionDef {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidAbiDefinition;

    return .{
        .function = try parseFunctionDefObjectAlloc(allocator, parsed.value.object),
    };
}

pub fn findFunction(abi: *const AbiInfo, function_name: []const u8) ?*const FunctionDef {
    if (selectorUsesFullSignature(function_name)) {
        for (abi.functions) |*function| {
            if (functionMatchesSelector(function, function_name)) return function;
        }
        return null;
    }

    for (abi.functions) |*function| {
        if (std.mem.eql(u8, function.name, function_name)) return function;
    }
    return null;
}

pub fn findEvent(abi: *const AbiInfo, event_name: []const u8) ?*const EventDef {
    if (selectorUsesFullSignature(event_name)) {
        for (abi.events) |*event| {
            if (eventMatchesSelector(event, event_name)) return event;
        }
        return null;
    }

    for (abi.events) |*event| {
        if (std.mem.eql(u8, event.name, event_name)) return event;
    }
    return null;
}

pub fn buildFunctionSelectorAlloc(allocator: std.mem.Allocator, function: FunctionDef) ![]u8 {
    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    try writer.writer.print("{s}(", .{function.name});
    for (function.inputs, 0..) |param, idx| {
        if (idx != 0) try writer.writer.writeByte(',');
        try writer.writer.writeAll(std.mem.trim(u8, param.type_name, " \t\r\n"));
    }
    try writer.writer.writeByte(')');

    return try writer.toOwnedSlice();
}

pub fn buildEventSelectorAlloc(allocator: std.mem.Allocator, event: EventDef) ![]u8 {
    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    try writer.writer.print("{s}(", .{event.name});
    for (event.inputs, 0..) |param, idx| {
        if (idx != 0) try writer.writer.writeByte(',');
        try writer.writer.writeAll(std.mem.trim(u8, param.type_name, " \t\r\n"));
    }
    try writer.writer.writeByte(')');

    return try writer.toOwnedSlice();
}

pub fn buildFunctionBodyBocAlloc(
    allocator: std.mem.Allocator,
    function: FunctionDef,
    values: []const AbiValue,
) ![]u8 {
    if (function.inputs.len != values.len) return error.InvalidAbiArguments;

    var builder = cell.Builder.init();
    errdefer deinitBuilderRefs(allocator, &builder);

    if (function.opcode) |opcode| {
        try builder.storeUint(opcode, 32);
    }

    for (function.inputs, values) |param, value| {
        try storeAbiValue(&builder, allocator, param, value);
    }

    const root = try builder.toCell(allocator);
    defer root.deinit(allocator);

    return boc.serializeBoc(allocator, root);
}

pub fn buildFunctionBodyFromAbiAlloc(
    allocator: std.mem.Allocator,
    abi: *const AbiInfo,
    function_name: []const u8,
    values: []const AbiValue,
) ![]u8 {
    const function = try resolveFunctionByValueCount(abi, function_name, values.len);
    if (function.inputs.len == values.len) {
        return buildFunctionBodyBocAlloc(allocator, function.*, values);
    }

    const expanded_values = try expandValuesForFunctionAlloc(allocator, function.*, values);
    defer allocator.free(expanded_values);
    return buildFunctionBodyBocAlloc(allocator, function.*, expanded_values);
}

pub fn buildStackArgsFromFunctionAlloc(
    allocator: std.mem.Allocator,
    function: FunctionDef,
    values: []const AbiValue,
) !OwnedStackArgs {
    if (function.inputs.len != values.len) return error.InvalidAbiArguments;
    if (values.len == 0) {
        return .{
            .args = &.{},
            .owned_buffers = &.{},
        };
    }

    const args = try allocator.alloc(generic_contract.StackArg, values.len);
    errdefer allocator.free(args);

    const owned_buffers = try allocator.alloc(?[]u8, values.len);
    for (owned_buffers) |*buffer| buffer.* = null;
    errdefer {
        for (owned_buffers) |buffer| {
            if (buffer) |value| allocator.free(value);
        }
        allocator.free(owned_buffers);
    }

    for (function.inputs, values, 0..) |param, value, idx| {
        const built = try abiValueToStackArgAlloc(allocator, param, value);
        args[idx] = built.arg;
        owned_buffers[idx] = built.owned_buffer;
    }

    return .{
        .args = args,
        .owned_buffers = owned_buffers,
    };
}

pub fn buildStackArgsFromAbiAlloc(
    allocator: std.mem.Allocator,
    abi: *const AbiInfo,
    function_name: []const u8,
    values: []const AbiValue,
) !OwnedStackArgs {
    const function = try resolveFunctionByValueCount(abi, function_name, values.len);
    if (function.inputs.len == values.len) {
        return buildStackArgsFromFunctionAlloc(allocator, function.*, values);
    }

    const expanded_values = try expandValuesForFunctionAlloc(allocator, function.*, values);
    defer allocator.free(expanded_values);
    return buildStackArgsFromFunctionAlloc(allocator, function.*, expanded_values);
}

pub fn decodeFunctionOutputsJsonAlloc(
    allocator: std.mem.Allocator,
    function: FunctionDef,
    stack: []const types.StackEntry,
) ![]u8 {
    if (function.outputs.len != stack.len) return error.InvalidAbiOutputs;

    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    if (allParamNamesMissing(function.outputs)) {
        try writer.writer.writeByte('[');
        for (function.outputs, stack, 0..) |param, *entry, idx| {
            if (idx != 0) try writer.writer.writeByte(',');
            try writeDecodedOutputJson(&writer.writer, allocator, param, entry);
        }
        try writer.writer.writeByte(']');
    } else {
        try writer.writer.writeByte('{');
        for (function.outputs, stack, 0..) |param, *entry, idx| {
            if (idx != 0) try writer.writer.writeByte(',');
            try writeDecodedFieldName(&writer.writer, param.name, idx);
            try writer.writer.writeByte(':');
            try writeDecodedOutputJson(&writer.writer, allocator, param, entry);
        }
        try writer.writer.writeByte('}');
    }

    return try writer.toOwnedSlice();
}

pub fn decodeFunctionOutputsFromAbiJsonAlloc(
    allocator: std.mem.Allocator,
    abi: *const AbiInfo,
    function_name: []const u8,
    stack: []const types.StackEntry,
) ![]u8 {
    const function = findFunction(abi, function_name) orelse return error.FunctionNotFound;
    return decodeFunctionOutputsJsonAlloc(allocator, function.*, stack);
}

pub fn resolveFunctionByBodyBoc(
    abi: *const AbiInfo,
    function_selector: ?[]const u8,
    body_boc: []const u8,
) !*const FunctionDef {
    const opcode = peekBodyOpcodeFromBoc(body_boc) catch null;

    if (function_selector) |selector| {
        return resolveFunctionSelector(abi, selector, opcode);
    }

    if (abi.functions.len == 1) return &abi.functions[0];

    if (opcode) |value| {
        var matched: ?*const FunctionDef = null;
        var match_count: usize = 0;

        for (abi.functions) |*function| {
            if (function.opcode != null and function.opcode.? == value) {
                match_count += 1;
                if (matched == null) matched = function;
            }
        }

        if (matched) |function| {
            if (match_count > 1) return error.AmbiguousFunctionOverload;
            return function;
        }
    }

    var opcode_less: ?*const FunctionDef = null;
    var opcode_less_count: usize = 0;
    for (abi.functions) |*function| {
        if (function.opcode == null) {
            opcode_less_count += 1;
            if (opcode_less == null) opcode_less = function;
        }
    }

    if (opcode_less) |function| {
        if (opcode_less_count > 1) return error.AmbiguousFunctionOverload;
        return function;
    }

    return error.FunctionNotFound;
}

pub fn decodeFunctionBodyJsonAlloc(
    allocator: std.mem.Allocator,
    function: FunctionDef,
    body_boc: []const u8,
) ![]u8 {
    const root = try boc.deserializeBoc(allocator, body_boc);
    defer root.deinit(allocator);

    var slice = root.toSlice();
    if (function.opcode) |opcode| {
        const actual = try loadUintDynamic(&slice, 32);
        if (actual != opcode) return error.InvalidAbiOutputs;
    }

    const decoded = try decodeBodyFieldsJsonAlloc(allocator, function.inputs, &slice, true);
    errdefer allocator.free(decoded);
    if (!slice.empty()) return error.InvalidAbiOutputs;
    return decoded;
}

pub fn decodeFunctionBodyFromAbiJsonAlloc(
    allocator: std.mem.Allocator,
    abi: *const AbiInfo,
    function_selector: ?[]const u8,
    body_boc: []const u8,
) ![]u8 {
    const function = try resolveFunctionByBodyBoc(abi, function_selector, body_boc);
    return decodeFunctionBodyJsonAlloc(allocator, function.*, body_boc);
}

pub fn resolveEventByBodyBoc(
    abi: *const AbiInfo,
    event_selector: ?[]const u8,
    body_boc: []const u8,
) !*const EventDef {
    if (event_selector) |selector| {
        return resolveEventSelector(abi, selector);
    }

    if (abi.events.len == 1) return &abi.events[0];

    const opcode = peekBodyOpcodeFromBoc(body_boc) catch null;
    if (opcode) |value| {
        var matched: ?*const EventDef = null;
        var match_count: usize = 0;

        for (abi.events) |*event| {
            if (event.opcode != null and event.opcode.? == value) {
                match_count += 1;
                if (matched == null) matched = event;
            }
        }

        if (matched) |event| {
            if (match_count > 1) return error.AmbiguousEventOverload;
            return event;
        }
    }

    return error.EventNotFound;
}

pub fn decodeEventBodyJsonAlloc(
    allocator: std.mem.Allocator,
    event: EventDef,
    body_boc: []const u8,
) ![]u8 {
    const root = try boc.deserializeBoc(allocator, body_boc);
    defer root.deinit(allocator);

    var slice = root.toSlice();
    if (event.opcode) |opcode| {
        const actual = try loadUintDynamic(&slice, 32);
        if (actual != opcode) return error.InvalidAbiOutputs;
    }

    const decoded = try decodeBodyFieldsJsonAlloc(allocator, event.inputs, &slice, true);
    errdefer allocator.free(decoded);
    if (!slice.empty()) return error.InvalidAbiOutputs;
    return decoded;
}

pub fn decodeEventBodyFromAbiJsonAlloc(
    allocator: std.mem.Allocator,
    abi: *const AbiInfo,
    event_selector: ?[]const u8,
    body_boc: []const u8,
) ![]u8 {
    const event = try resolveEventByBodyBoc(abi, event_selector, body_boc);
    return decodeEventBodyJsonAlloc(allocator, event.*, body_boc);
}

pub fn resolveFunctionByValueCount(
    abi: *const AbiInfo,
    function_name: []const u8,
    value_count: usize,
) !*const FunctionDef {
    if (selectorUsesFullSignature(function_name)) {
        return findFunction(abi, function_name) orelse error.FunctionNotFound;
    }

    var exact_match: ?*const FunctionDef = null;
    var exact_count: usize = 0;
    var optional_match: ?*const FunctionDef = null;
    var optional_count: usize = 0;

    for (abi.functions) |*function| {
        if (!std.mem.eql(u8, function.name, function_name)) continue;

        if (function.inputs.len == value_count) {
            exact_count += 1;
            if (exact_match == null) exact_match = function;
            continue;
        }

        if (functionAcceptsValueCount(function.*, value_count)) {
            optional_count += 1;
            if (optional_match == null) optional_match = function;
        }
    }

    if (exact_match) |function| {
        if (exact_count > 1) return error.AmbiguousFunctionOverload;
        return function;
    }

    if (optional_match) |function| {
        if (optional_count > 1) return error.AmbiguousFunctionOverload;
        return function;
    }

    return error.FunctionNotFound;
}

pub fn expandValuesForFunctionAlloc(
    allocator: std.mem.Allocator,
    function: FunctionDef,
    values: []const AbiValue,
) ![]AbiValue {
    if (!functionAcceptsValueCount(function, values.len)) return error.InvalidAbiArguments;

    const expanded = try allocator.alloc(AbiValue, function.inputs.len);
    errdefer allocator.free(expanded);

    @memcpy(expanded[0..values.len], values);
    for (values.len..function.inputs.len) |idx| {
        expanded[idx] = .{ .null = {} };
    }

    return expanded;
}

const abi_method_candidates = [_][]const u8{
    "get_abi",
    "get_abi_uri",
    "get_contract_abi",
    "abi",
};

fn probeMethodSupport(client: anytype, addr: []const u8, method_name: []const u8) !bool {
    var result = client.runGetMethod(addr, method_name, &.{}) catch |err| switch (err) {
        types.TonError.RpcError,
        error.InvalidResponse,
        error.UnsupportedStackEntry,
        => return false,
        else => return err,
    };
    defer client.freeRunGetMethodResponse(&result);

    return result.exit_code == 0;
}

fn probeAbiSupport(client: anytype, addr: []const u8) !bool {
    if (try queryAbiIpfs(client, addr)) |abi_info| {
        var abi = abi_info;
        abi.deinit(client.allocator);
        return true;
    }
    return false;
}

fn supportedInterfacesFromMethodSupport(
    has_seqno: bool,
    has_jetton_master: bool,
    has_jetton_wallet: bool,
    has_nft_item: bool,
    has_nft_collection: bool,
    has_abi: bool,
) ?SupportedInterfaces {
    const supported = SupportedInterfaces{
        .has_wallet = has_seqno,
        .has_jetton = has_jetton_master or has_jetton_wallet,
        .has_jetton_master = has_jetton_master,
        .has_jetton_wallet = has_jetton_wallet,
        .has_nft = has_nft_item or has_nft_collection,
        .has_nft_item = has_nft_item,
        .has_nft_collection = has_nft_collection,
        .has_abi = has_abi,
    };

    if (!supported.has_wallet and !supported.has_jetton and !supported.has_nft and !supported.has_abi) {
        return null;
    }

    return supported;
}

fn abiInfoFromStack(allocator: std.mem.Allocator, stack: []const types.StackEntry) !?AbiInfo {
    const uri = try findOffchainUriInStack(allocator, stack) orelse return null;
    return AbiInfo{
        .version = "offchain-uri",
        .uri = uri,
        .functions = &.{},
        .events = &.{},
    };
}

fn findOffchainUriInStack(allocator: std.mem.Allocator, stack: []const types.StackEntry) anyerror!?[]u8 {
    for (stack) |*entry| {
        if (try abiUriFromEntry(allocator, entry)) |uri| return uri;
    }
    return null;
}

fn readAbiFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        return file.readToEndAlloc(allocator, max_abi_source_bytes);
    }

    return std.fs.cwd().readFileAlloc(allocator, path, max_abi_source_bytes);
}

fn fetchAbiUrlAlloc(allocator: std.mem.Allocator, source_url: []const u8) ![]u8 {
    const resolved_url = try normalizeAbiUrlAlloc(allocator, source_url);
    defer allocator.free(resolved_url);

    const uri = try std.Uri.parse(resolved_url);
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var headers = [_]std.http.Header{
        .{ .name = "accept", .value = "application/json, text/plain;q=0.9, */*;q=0.1" },
    };

    var request = try client.request(.GET, uri, .{
        .redirect_behavior = .unhandled,
        .extra_headers = headers[0..1],
        .keep_alive = false,
    });
    defer request.deinit();

    try request.sendBodiless();

    var response = try request.receiveHead(&.{});

    const decompress_buffer = switch (response.head.content_encoding) {
        .identity => null,
        .gzip, .deflate => try allocator.alloc(u8, std.compress.flate.max_window_len),
        else => return error.UnsupportedCompressionMethod,
    };
    defer if (decompress_buffer) |buffer| allocator.free(buffer);

    var response_writer = std.io.Writer.Allocating.init(allocator);
    errdefer response_writer.deinit();

    var transfer_buffer: [512]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer orelse &.{});
    _ = try reader.streamRemaining(&response_writer.writer);

    return try response_writer.toOwnedSlice();
}

fn normalizeAbiUrlAlloc(allocator: std.mem.Allocator, source_url: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, source_url, "ipfs://")) {
        const path = std.mem.trimLeft(u8, source_url["ipfs://".len..], "/");
        return std.fmt.allocPrint(allocator, "{s}/ipfs/{s}", .{ default_ipfs_gateway, path });
    }

    if (std.mem.startsWith(u8, source_url, "ipns://")) {
        const path = std.mem.trimLeft(u8, source_url["ipns://".len..], "/");
        return std.fmt.allocPrint(allocator, "{s}/ipns/{s}", .{ default_ipfs_gateway, path });
    }

    return allocator.dupe(u8, source_url);
}

fn abiUriFromEntry(allocator: std.mem.Allocator, entry: *const types.StackEntry) anyerror!?[]u8 {
    return switch (entry.*) {
        .cell, .slice, .builder => try generic_contract.stackEntryAsOffchainContentUriAlloc(allocator, entry),
        .bytes => |value| if (looksLikeOffchainUri(value))
            try allocator.dupe(u8, value)
        else
            null,
        .tuple => |items| try findOffchainUriInStack(allocator, items),
        .list => |items| try findOffchainUriInStack(allocator, items),
        else => null,
    };
}

fn looksLikeOffchainUri(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "ipfs://") or
        std.mem.startsWith(u8, value, "http://") or
        std.mem.startsWith(u8, value, "https://");
}

fn getAbiFunctionArray(object: std.json.ObjectMap) ?std.json.Value {
    return object.get("functions") orelse object.get("messages") orelse object.get("methods");
}

fn selectorUsesFullSignature(function_name: []const u8) bool {
    const trimmed = std.mem.trim(u8, function_name, " \t\r\n");
    return std.mem.indexOfScalar(u8, trimmed, '(') != null and trimmed.len > 0 and trimmed[trimmed.len - 1] == ')';
}

fn functionMatchesSelector(function: *const FunctionDef, selector: []const u8) bool {
    const trimmed = std.mem.trim(u8, selector, " \t\r\n");
    const open_idx = std.mem.indexOfScalar(u8, trimmed, '(') orelse return false;
    if (trimmed.len == 0 or trimmed[trimmed.len - 1] != ')') return false;

    const name = std.mem.trim(u8, trimmed[0..open_idx], " \t\r\n");
    if (!std.mem.eql(u8, function.name, name)) return false;

    const type_list = trimmed[open_idx + 1 .. trimmed.len - 1];
    return functionInputTypesMatch(function.inputs, type_list);
}

fn resolveFunctionSelector(
    abi: *const AbiInfo,
    function_selector: []const u8,
    opcode: ?u32,
) !*const FunctionDef {
    if (selectorUsesFullSignature(function_selector)) {
        return findFunction(abi, function_selector) orelse error.FunctionNotFound;
    }

    var exact_opcode_match: ?*const FunctionDef = null;
    var exact_opcode_count: usize = 0;
    var fallback_match: ?*const FunctionDef = null;
    var fallback_count: usize = 0;

    for (abi.functions) |*function| {
        if (!std.mem.eql(u8, function.name, function_selector)) continue;

        fallback_count += 1;
        if (fallback_match == null) fallback_match = function;

        if (opcode != null and function.opcode != null and function.opcode.? == opcode.?) {
            exact_opcode_count += 1;
            if (exact_opcode_match == null) exact_opcode_match = function;
        }
    }

    if (exact_opcode_match) |function| {
        if (exact_opcode_count > 1) return error.AmbiguousFunctionOverload;
        return function;
    }

    if (fallback_match) |function| {
        if (fallback_count > 1) return error.AmbiguousFunctionOverload;
        return function;
    }

    return error.FunctionNotFound;
}

fn eventMatchesSelector(event: *const EventDef, selector: []const u8) bool {
    const trimmed = std.mem.trim(u8, selector, " \t\r\n");
    const open_idx = std.mem.indexOfScalar(u8, trimmed, '(') orelse return false;
    if (trimmed.len == 0 or trimmed[trimmed.len - 1] != ')') return false;

    const name = std.mem.trim(u8, trimmed[0..open_idx], " \t\r\n");
    if (!std.mem.eql(u8, event.name, name)) return false;

    const type_list = trimmed[open_idx + 1 .. trimmed.len - 1];
    return functionInputTypesMatch(event.inputs, type_list);
}

fn resolveEventSelector(abi: *const AbiInfo, event_selector: []const u8) !*const EventDef {
    if (selectorUsesFullSignature(event_selector)) {
        return findEvent(abi, event_selector) orelse error.EventNotFound;
    }

    var matched: ?*const EventDef = null;
    var match_count: usize = 0;

    for (abi.events) |*event| {
        if (!std.mem.eql(u8, event.name, event_selector)) continue;
        match_count += 1;
        if (matched == null) matched = event;
    }

    if (matched) |event| {
        if (match_count > 1) return error.AmbiguousEventOverload;
        return event;
    }

    return error.EventNotFound;
}

fn functionInputTypesMatch(params: []const ParamDef, type_list: []const u8) bool {
    var idx: usize = 0;
    var param_idx: usize = 0;

    while (idx < type_list.len) {
        while (idx < type_list.len and std.ascii.isWhitespace(type_list[idx])) : (idx += 1) {}
        if (idx == type_list.len) break;

        if (param_idx >= params.len) return false;

        const start = idx;
        var generic_depth: usize = 0;
        while (idx < type_list.len) : (idx += 1) {
            const char = type_list[idx];
            switch (char) {
                '<' => generic_depth += 1,
                '>' => {
                    if (generic_depth == 0) return false;
                    generic_depth -= 1;
                },
                ',' => if (generic_depth == 0) break,
                else => {},
            }
        }

        const selector_type = std.mem.trim(u8, type_list[start..idx], " \t\r\n");
        const param_type = std.mem.trim(u8, params[param_idx].type_name, " \t\r\n");
        if (!std.mem.eql(u8, param_type, selector_type)) return false;

        param_idx += 1;

        if (idx < type_list.len) {
            if (type_list[idx] != ',') return false;
            idx += 1;
        }
    }

    return param_idx == params.len;
}

fn functionAcceptsValueCount(function: FunctionDef, value_count: usize) bool {
    if (value_count > function.inputs.len) return false;
    if (value_count == function.inputs.len) return true;

    for (function.inputs[value_count..]) |param| {
        if (optionalInnerType(param.type_name) == null) return false;
    }

    return true;
}

fn parseFunctionDefsAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]FunctionDef {
    if (value != .array) return error.InvalidAbiDefinition;
    if (value.array.items.len == 0) return &.{};

    const functions = try allocator.alloc(FunctionDef, value.array.items.len);
    var built: usize = 0;
    errdefer {
        freeFunctionDefsPartial(allocator, functions, built);
        allocator.free(functions);
    }

    for (value.array.items, 0..) |item, idx| {
        if (item != .object) return error.InvalidAbiDefinition;
        functions[idx] = try parseFunctionDefObjectAlloc(allocator, item.object);
        built += 1;
    }

    return functions;
}

fn parseFunctionDefObjectAlloc(allocator: std.mem.Allocator, object: std.json.ObjectMap) !FunctionDef {
    const name = try dupRequiredObjectString(allocator, object, "name");
    errdefer allocator.free(name);

    const inputs = if (object.get("inputs")) |value|
        try parseParamDefsAlloc(allocator, value)
    else
        &.{};
    errdefer freeParamDefs(allocator, inputs);

    const outputs = if (object.get("outputs")) |value|
        try parseParamDefsAlloc(allocator, value)
    else
        &.{};
    errdefer freeParamDefs(allocator, outputs);

    return .{
        .name = name,
        .opcode = try parseOptionalOpcode(object),
        .inputs = inputs,
        .outputs = outputs,
    };
}

fn parseEventDefsAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]EventDef {
    if (value != .array) return error.InvalidAbiDefinition;
    if (value.array.items.len == 0) return &.{};

    const events = try allocator.alloc(EventDef, value.array.items.len);
    var built: usize = 0;
    errdefer {
        freeEventDefsPartial(allocator, events, built);
        allocator.free(events);
    }

    for (value.array.items, 0..) |item, idx| {
        if (item != .object) return error.InvalidAbiDefinition;
        events[idx] = try parseEventDefObjectAlloc(allocator, item.object);
        built += 1;
    }

    return events;
}

fn parseEventDefObjectAlloc(allocator: std.mem.Allocator, object: std.json.ObjectMap) !EventDef {
    const name = try dupRequiredObjectString(allocator, object, "name");
    errdefer allocator.free(name);

    const inputs = if (object.get("inputs")) |value|
        try parseParamDefsAlloc(allocator, value)
    else
        &.{};
    errdefer freeParamDefs(allocator, inputs);

    return .{
        .name = name,
        .opcode = try parseOptionalOpcode(object),
        .inputs = inputs,
    };
}

fn parseParamDefsAlloc(allocator: std.mem.Allocator, value: std.json.Value) anyerror![]ParamDef {
    if (value != .array) return error.InvalidAbiDefinition;
    if (value.array.items.len == 0) return &.{};

    const params = try allocator.alloc(ParamDef, value.array.items.len);
    var built: usize = 0;
    errdefer {
        freeParamDefsPartial(allocator, params, built);
        allocator.free(params);
    }

    for (value.array.items, 0..) |item, idx| {
        if (item != .object) return error.InvalidAbiDefinition;
        params[idx] = try parseParamDefObjectAlloc(allocator, item.object);
        built += 1;
    }

    return params;
}

fn parseParamDefObjectAlloc(allocator: std.mem.Allocator, object: std.json.ObjectMap) anyerror!ParamDef {
    const name = try dupOptionalObjectString(allocator, object, "name");
    errdefer allocator.free(name);

    const type_name = try dupObjectStringWithFallback(allocator, object, "type", "type_name");
    errdefer allocator.free(type_name);

    const components = if (getParamComponentArray(object)) |value|
        try parseParamDefsAlloc(allocator, value)
    else
        &.{};
    errdefer freeParamDefs(allocator, components);

    return .{
        .name = name,
        .type_name = type_name,
        .components = components,
    };
}

fn getParamComponentArray(object: std.json.ObjectMap) ?std.json.Value {
    return object.get("components") orelse object.get("fields");
}

fn freeParamDefs(allocator: std.mem.Allocator, params: []const ParamDef) void {
    freeParamDefsPartial(allocator, params, params.len);
    if (params.len > 0) allocator.free(params);
}

fn freeFunctionDefs(allocator: std.mem.Allocator, functions: []const FunctionDef) void {
    freeFunctionDefsPartial(allocator, functions, functions.len);
    if (functions.len > 0) allocator.free(functions);
}

fn freeFunctionDefsPartial(allocator: std.mem.Allocator, functions: []const FunctionDef, len: usize) void {
    for (functions[0..len]) |function| {
        allocator.free(function.name);
        freeParamDefs(allocator, function.inputs);
        freeParamDefs(allocator, function.outputs);
    }
}

fn freeEventDefs(allocator: std.mem.Allocator, events: []const EventDef) void {
    freeEventDefsPartial(allocator, events, events.len);
    if (events.len > 0) allocator.free(events);
}

fn freeEventDefsPartial(allocator: std.mem.Allocator, events: []const EventDef, len: usize) void {
    for (events[0..len]) |event| {
        allocator.free(event.name);
        freeParamDefs(allocator, event.inputs);
    }
}

fn freeParamDefsPartial(allocator: std.mem.Allocator, params: []const ParamDef, len: usize) void {
    for (params[0..len]) |param| {
        freeParamDefs(allocator, param.components);
        allocator.free(param.name);
        allocator.free(param.type_name);
    }
}

fn dupRequiredObjectString(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) ![]u8 {
    const value = object.get(key) orelse return error.InvalidAbiDefinition;
    return switch (value) {
        .string => allocator.dupe(u8, value.string),
        else => error.InvalidAbiDefinition,
    };
}

fn dupOptionalObjectString(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
) ![]u8 {
    const value = object.get(key) orelse return allocator.dupe(u8, "");
    return switch (value) {
        .string => allocator.dupe(u8, value.string),
        else => error.InvalidAbiDefinition,
    };
}

fn dupObjectStringWithFallback(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    key: []const u8,
    fallback_key: []const u8,
) ![]u8 {
    if (object.get(key)) |value| {
        return switch (value) {
            .string => allocator.dupe(u8, value.string),
            else => error.InvalidAbiDefinition,
        };
    }

    return dupRequiredObjectString(allocator, object, fallback_key);
}

fn parseOpcodeValue(value: std.json.Value) !u32 {
    return switch (value) {
        .integer => @intCast(value.integer),
        .string => try parseUintText(value.string),
        else => error.InvalidAbiDefinition,
    };
}

fn parseOptionalOpcode(object: std.json.ObjectMap) !?u32 {
    if (object.get("opcode")) |value| return try parseOpcodeValue(value);
    if (object.get("id")) |value| return try parseOpcodeValue(value);
    if (object.get("op")) |value| return try parseOpcodeValue(value);
    return null;
}

fn parseUintText(text: []const u8) !u32 {
    if (std.mem.startsWith(u8, text, "0x")) {
        return std.fmt.parseInt(u32, text[2..], 16);
    }
    return std.fmt.parseInt(u32, text, 10);
}

const BuiltStackArg = struct {
    arg: generic_contract.StackArg,
    owned_buffer: ?[]u8 = null,
};

fn storeAbiValue(
    builder: *cell.Builder,
    allocator: std.mem.Allocator,
    param: ParamDef,
    value: AbiValue,
) !void {
    if (optionalInnerType(param.type_name)) |inner_type| {
        if (std.meta.activeTag(value) == .null) {
            try builder.storeUint(0, 1);
            return;
        }

        try builder.storeUint(1, 1);
        return storeAbiValue(builder, allocator, paramWithType(param, inner_type), value);
    }

    if (arrayInnerType(param.type_name)) |inner_type| {
        const json_text = switch (value) {
            .json => |text| text,
            else => return error.InvalidAbiArguments,
        };
        return storeArrayJsonText(builder, allocator, paramWithType(param, inner_type), json_text);
    }

    if (std.meta.activeTag(value) == .numeric_text and isNumericAbiType(param.type_name)) {
        return storeNumericTextValue(builder, allocator, param.type_name, value.numeric_text);
    }

    if (isCompositeParam(param)) {
        const json_text = switch (value) {
            .json => |text| text,
            else => return error.InvalidAbiArguments,
        };
        return storeCompositeJsonText(builder, allocator, param, json_text);
    }

    if (std.mem.eql(u8, param.type_name, "coins")) {
        try builder.storeCoins(try abiValueAsUint(value));
        return;
    }
    if (std.mem.eql(u8, param.type_name, "address")) {
        try builder.storeAddress(try abiValueAsText(value));
        return;
    }
    if (fixedBytesLength(param.type_name)) |byte_len| {
        const bytes = try abiValueAsBytes(value);
        try validateFixedBytesLength(bytes.len, byte_len);
        try builder.storeBits(bytes, @intCast(bytes.len * 8));
        return;
    }
    if (std.mem.eql(u8, param.type_name, "bytes") or std.mem.eql(u8, param.type_name, "string")) {
        const bytes = try abiValueAsBytes(value);
        try builder.storeBits(bytes, @intCast(bytes.len * 8));
        return;
    }
    if (isInlineCellLikeAbiType(param.type_name)) {
        try storeInlineBoc(builder, allocator, try abiValueAsBoc(value));
        return;
    }
    if (isRefCellLikeAbiType(param.type_name)) {
        try body_builder.storeRefBoc(builder, allocator, try abiValueAsBoc(value));
        return;
    }
    if (std.mem.eql(u8, param.type_name, "bool")) {
        try builder.storeUint(if (try abiValueAsUint(value) == 0) 0 else 1, 1);
        return;
    }
    if (std.mem.startsWith(u8, param.type_name, "uint")) {
        const bits = try parseSizedTypeBits(param.type_name, "uint", 64);
        const numeric_value = try abiValueAsUint(value);
        if (bits > 64) {
            var text_buf: [32]u8 = undefined;
            const text = try formatUnsignedDecimalText(&text_buf, numeric_value);
            try storeNumericTextValue(builder, allocator, param.type_name, text);
            return;
        }
        try builder.storeUint(numeric_value, bits);
        return;
    }
    if (std.mem.startsWith(u8, param.type_name, "int")) {
        const bits = try parseSizedTypeBits(param.type_name, "int", 64);
        const numeric_value = try abiValueAsInt(value);
        if (bits > 64) {
            var text_buf: [32]u8 = undefined;
            const text = try formatSignedDecimalText(&text_buf, numeric_value);
            try storeNumericTextValue(builder, allocator, param.type_name, text);
            return;
        }
        try builder.storeInt(numeric_value, bits);
        return;
    }

    return error.UnsupportedAbiType;
}

fn abiValueToStackArgAlloc(
    allocator: std.mem.Allocator,
    param: ParamDef,
    value: AbiValue,
) !BuiltStackArg {
    if (optionalInnerType(param.type_name)) |inner_type| {
        if (std.meta.activeTag(value) == .null) {
            return .{ .arg = .{ .null = {} } };
        }

        return abiValueToStackArgAlloc(allocator, paramWithType(param, inner_type), value);
    }

    if (arrayInnerType(param.type_name)) |inner_type| {
        const json_text = switch (value) {
            .json => |text| text,
            else => return error.InvalidAbiArguments,
        };
        const encoded = try buildArrayStackArgJsonAlloc(allocator, paramWithType(param, inner_type), json_text);
        return .{
            .arg = .{ .raw_json = encoded },
            .owned_buffer = encoded,
        };
    }

    if (isCompositeParam(param)) {
        const json_text = switch (value) {
            .json => |text| text,
            else => return error.InvalidAbiArguments,
        };
        const encoded = try buildCompositeStackArgJsonAlloc(allocator, param, json_text);
        return .{
            .arg = .{ .raw_json = encoded },
            .owned_buffer = encoded,
        };
    }

    if (std.mem.eql(u8, param.type_name, "coins") or
        std.mem.startsWith(u8, param.type_name, "uint") or
        std.mem.startsWith(u8, param.type_name, "int") or
        std.mem.eql(u8, param.type_name, "bool"))
    {
        const use_raw_numeric = try numericTypeUsesWideEncoding(param.type_name);

        if (std.meta.activeTag(value) == .numeric_text) {
            const raw_json = try buildNumericStackArgJsonAlloc(allocator, param.type_name, value.numeric_text);
            return .{
                .arg = .{ .raw_json = raw_json },
                .owned_buffer = raw_json,
            };
        }

        return switch (value) {
            .uint => |v| if (use_raw_numeric or v > @as(u64, @intCast(std.math.maxInt(i64))))
                try buildUnsignedNumericStackArgAlloc(allocator, param.type_name, v)
            else
                .{ .arg = .{ .int = @intCast(v) } },
            .int => |v| if (use_raw_numeric)
                try buildSignedNumericStackArgAlloc(allocator, param.type_name, v)
            else
                .{ .arg = .{ .int = v } },
            else => error.InvalidAbiArguments,
        };
    }

    if (std.mem.eql(u8, param.type_name, "address")) {
        return switch (value) {
            .text => |v| .{ .arg = .{ .address = v } },
            else => error.InvalidAbiArguments,
        };
    }

    if (fixedBytesLength(param.type_name)) |byte_len| {
        const bytes = try abiValueAsBytes(value);
        try validateFixedBytesLength(bytes.len, byte_len);
        const encoded = try buildBytesSliceBocAlloc(allocator, bytes);
        return .{
            .arg = .{ .slice = encoded },
            .owned_buffer = encoded,
        };
    }

    if (std.mem.eql(u8, param.type_name, "bytes") or std.mem.eql(u8, param.type_name, "string")) {
        const encoded = try buildBytesSliceBocAlloc(allocator, try abiValueAsBytes(value));
        return .{
            .arg = .{ .slice = encoded },
            .owned_buffer = encoded,
        };
    }

    if (stackCellLikeKind(param.type_name)) |kind| {
        return switch (value) {
            .boc => |v| switch (kind) {
                .cell => .{ .arg = .{ .cell = v } },
                .slice => .{ .arg = .{ .slice = v } },
                .builder => .{ .arg = .{ .builder = v } },
            },
            else => error.InvalidAbiArguments,
        };
    }

    return error.UnsupportedAbiType;
}

fn parseSizedTypeBits(type_name: []const u8, prefix: []const u8, default_bits: u16) !u16 {
    if (type_name.len == prefix.len) return default_bits;
    return std.fmt.parseInt(u16, type_name[prefix.len..], 10);
}

fn numericTypeUsesWideEncoding(type_name: []const u8) !bool {
    if (std.mem.startsWith(u8, type_name, "uint")) {
        return (try parseSizedTypeBits(type_name, "uint", 64)) > 64;
    }

    if (std.mem.startsWith(u8, type_name, "int")) {
        return (try parseSizedTypeBits(type_name, "int", 64)) > 64;
    }

    return false;
}

fn formatUnsignedDecimalText(buffer: *[32]u8, value: u64) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{}", .{value});
}

fn formatSignedDecimalText(buffer: *[32]u8, value: i64) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{}", .{value});
}

fn buildUnsignedNumericStackArgAlloc(
    allocator: std.mem.Allocator,
    type_name: []const u8,
    value: u64,
) !BuiltStackArg {
    var text_buf: [32]u8 = undefined;
    const text = try formatUnsignedDecimalText(&text_buf, value);
    const raw_json = try buildNumericStackArgJsonAlloc(allocator, type_name, text);
    return .{
        .arg = .{ .raw_json = raw_json },
        .owned_buffer = raw_json,
    };
}

fn buildSignedNumericStackArgAlloc(
    allocator: std.mem.Allocator,
    type_name: []const u8,
    value: i64,
) !BuiltStackArg {
    var text_buf: [32]u8 = undefined;
    const text = try formatSignedDecimalText(&text_buf, value);
    const raw_json = try buildNumericStackArgJsonAlloc(allocator, type_name, text);
    return .{
        .arg = .{ .raw_json = raw_json },
        .owned_buffer = raw_json,
    };
}

fn abiValueAsUint(value: AbiValue) !u64 {
    return switch (value) {
        .uint => |v| v,
        .int => |v| if (v >= 0)
            @intCast(v)
        else
            error.InvalidAbiArguments,
        else => error.InvalidAbiArguments,
    };
}

fn abiValueAsInt(value: AbiValue) !i64 {
    return switch (value) {
        .int => |v| v,
        .uint => |v| if (v <= @as(u64, @intCast(std.math.maxInt(i64))))
            @intCast(v)
        else
            error.InvalidAbiArguments,
        else => error.InvalidAbiArguments,
    };
}

fn abiValueAsText(value: AbiValue) ![]const u8 {
    return switch (value) {
        .text => |v| v,
        else => error.InvalidAbiArguments,
    };
}

fn abiValueAsBytes(value: AbiValue) ![]const u8 {
    return switch (value) {
        .text => |v| v,
        .bytes => |v| v,
        else => error.InvalidAbiArguments,
    };
}

fn abiValueAsBoc(value: AbiValue) ![]const u8 {
    return switch (value) {
        .boc => |v| v,
        else => error.InvalidAbiArguments,
    };
}

const ParsedNumericText = struct {
    bytes: []u8,
    negative: bool,
    significant_bits: u16,

    fn deinit(self: ParsedNumericText, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

fn parseNumericTextAlloc(allocator: std.mem.Allocator, text: []const u8) !ParsedNumericText {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidAbiArguments;

    const negative = trimmed[0] == '-';
    const unsigned_text = if (negative) trimmed[1..] else trimmed;
    const bytes = try parseUnsignedTextBytesAlloc(allocator, unsigned_text);
    errdefer allocator.free(bytes);

    return .{
        .bytes = bytes,
        .negative = negative and countByteSignificantBits(bytes) != 0,
        .significant_bits = countByteSignificantBits(bytes),
    };
}

fn parseUnsignedTextBytesAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidAbiArguments;

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
        if (char < '0' or char > '9') return error.InvalidAbiArguments;

        var carry: u16 = char - '0';
        for (bytes_le.items) |*byte| {
            const next: u16 = @as(u16, byte.*) * 10 + carry;
            byte.* = @intCast(next & 0xFF);
            carry = next >> 8;
        }

        while (carry > 0) {
            try bytes_le.append(@intCast(carry & 0xFF));
            carry >>= 8;
        }
    }

    var significant_len = bytes_le.items.len;
    while (significant_len > 0 and bytes_le.items[significant_len - 1] == 0) : (significant_len -= 1) {}

    const out = try allocator.alloc(u8, significant_len);
    errdefer allocator.free(out);
    for (0..significant_len) |idx| {
        out[idx] = bytes_le.items[significant_len - 1 - idx];
    }
    return out;
}

fn dupeTrimmedBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var start: usize = 0;
    while (start < bytes.len and bytes[start] == 0) : (start += 1) {}
    return allocator.dupe(u8, bytes[start..]);
}

fn countByteSignificantBits(bytes: []const u8) u16 {
    for (bytes, 0..) |byte, idx| {
        if (byte == 0) continue;

        var bit_idx: u16 = 0;
        while (bit_idx < 8) : (bit_idx += 1) {
            if (((byte >> @as(u3, @intCast(7 - bit_idx))) & 1) != 0) {
                return @intCast((bytes.len - idx) * 8 - bit_idx);
            }
        }
    }
    return 0;
}

fn isNumericAbiType(type_name: []const u8) bool {
    return std.mem.eql(u8, type_name, "bool") or
        std.mem.eql(u8, type_name, "coins") or
        std.mem.startsWith(u8, type_name, "uint") or
        std.mem.startsWith(u8, type_name, "int");
}

fn fixedBytesLength(type_name: []const u8) ?usize {
    const trimmed = std.mem.trim(u8, type_name, " \t\r\n");

    if (parseFixedBytesSuffix(trimmed, "bytes")) |value| return value;
    if (parseFixedBytesSuffix(trimmed, "fixedbytes")) |value| return value;
    if (parseFixedBytesSuffix(trimmed, "fixed_bytes")) |value| return value;

    if (parseFixedBytesGeneric(trimmed, "fixedbytes<")) |value| return value;
    if (parseFixedBytesGeneric(trimmed, "fixed_bytes<")) |value| return value;

    return null;
}

fn parseFixedBytesSuffix(trimmed: []const u8, comptime prefix: []const u8) ?usize {
    if (trimmed.len <= prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(trimmed[0..prefix.len], prefix)) return null;

    const digits = trimmed[prefix.len..];
    if (digits.len == 0) return null;
    for (digits) |char| {
        if (!std.ascii.isDigit(char)) return null;
    }

    return std.fmt.parseInt(usize, digits, 10) catch null;
}

fn parseFixedBytesGeneric(trimmed: []const u8, comptime prefix: []const u8) ?usize {
    if (!std.ascii.startsWithIgnoreCase(trimmed, prefix)) return null;
    if (trimmed.len <= prefix.len or trimmed[trimmed.len - 1] != '>') return null;
    return std.fmt.parseInt(usize, trimmed[prefix.len .. trimmed.len - 1], 10) catch null;
}

fn validateFixedBytesLength(actual_len: usize, expected_len: usize) !void {
    if (actual_len != expected_len) return error.InvalidAbiArguments;
}

fn matchesAbiTypeBase(type_name: []const u8, base: []const u8) bool {
    const trimmed = std.mem.trim(u8, type_name, " \t\r\n");
    if (trimmed.len < base.len) return false;
    if (!std.ascii.eqlIgnoreCase(trimmed[0..base.len], base)) return false;
    return trimmed.len == base.len or trimmed[base.len] == '<' or trimmed[base.len] == ' ';
}

fn isInlineCellLikeAbiType(type_name: []const u8) bool {
    return std.mem.eql(u8, type_name, "cell") or
        std.mem.eql(u8, type_name, "slice") or
        std.mem.eql(u8, type_name, "builder") or
        matchesAbiTypeBase(type_name, "dict") or
        matchesAbiTypeBase(type_name, "map") or
        matchesAbiTypeBase(type_name, "hashmap") or
        matchesAbiTypeBase(type_name, "hashmape");
}

fn isRefCellLikeAbiType(type_name: []const u8) bool {
    return std.mem.eql(u8, type_name, "ref") or
        std.mem.eql(u8, type_name, "boc") or
        std.mem.eql(u8, type_name, "ref_boc") or
        std.mem.eql(u8, type_name, "cell_ref") or
        matchesAbiTypeBase(type_name, "dict_ref") or
        matchesAbiTypeBase(type_name, "map_ref") or
        matchesAbiTypeBase(type_name, "hashmap_ref") or
        matchesAbiTypeBase(type_name, "hashmape_ref");
}

const StackCellLikeKind = enum {
    cell,
    slice,
    builder,
};

fn stackCellLikeKind(type_name: []const u8) ?StackCellLikeKind {
    if (std.mem.eql(u8, type_name, "slice")) return .slice;
    if (std.mem.eql(u8, type_name, "builder")) return .builder;
    if (isInlineCellLikeAbiType(type_name) or isRefCellLikeAbiType(type_name)) return .cell;
    return null;
}

fn storeNumericTextValue(
    builder: *cell.Builder,
    allocator: std.mem.Allocator,
    type_name: []const u8,
    text: []const u8,
) !void {
    const parsed = try parseNumericTextAlloc(allocator, text);
    defer parsed.deinit(allocator);

    try validateNumericTextBits(type_name, parsed.negative, parsed.significant_bits, parsed.bytes);

    if (std.mem.eql(u8, type_name, "bool")) {
        try builder.storeUintBytes(parsed.bytes, 1);
        return;
    }

    if (std.mem.eql(u8, type_name, "coins")) {
        try builder.storeCoinsBytes(parsed.bytes);
        return;
    }

    if (std.mem.startsWith(u8, type_name, "uint")) {
        const bits = try parseSizedTypeBits(type_name, "uint", 64);
        try builder.storeUintBytes(parsed.bytes, bits);
        return;
    }

    if (std.mem.startsWith(u8, type_name, "int")) {
        const bits = try parseSizedTypeBits(type_name, "int", 64);
        try storeSignedNumericBytes(builder, allocator, parsed.bytes, parsed.negative, bits);
        return;
    }

    return error.UnsupportedAbiType;
}

fn storeSignedNumericBytes(
    builder: *cell.Builder,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    negative: bool,
    bits: u16,
) !void {
    if (!negative) {
        try builder.storeUintBytes(bytes, bits);
        return;
    }

    const encoded = try encodeSignedBitsAlloc(allocator, bytes, bits);
    defer allocator.free(encoded);
    try builder.storeBits(encoded, bits);
}

fn encodeSignedBitsAlloc(allocator: std.mem.Allocator, magnitude: []const u8, bits: u16) ![]u8 {
    const byte_len: usize = @intCast(@divTrunc(bits + 7, 8));
    const out = try allocator.alloc(u8, byte_len);
    errdefer allocator.free(out);
    @memset(out, 0);

    const significant_bits = countByteSignificantBits(magnitude);
    if (significant_bits > bits) return error.InvalidAbiArguments;

    const leading_zero_bits = bits - significant_bits;
    var idx: u16 = 0;
    while (idx < significant_bits) : (idx += 1) {
        setAlignedBit(out, leading_zero_bits + idx, getMagnitudeBit(magnitude, significant_bits, idx));
    }

    invertAlignedBits(out, bits);
    addOneToAlignedBits(out, bits);
    return out;
}

fn getMagnitudeBit(bytes: []const u8, significant_bits: u16, bit_index: u16) u1 {
    const source_bit_index = @as(u16, @intCast(bytes.len * 8)) - significant_bits + bit_index;
    return getAlignedBit(bytes, source_bit_index);
}

fn getAlignedBit(bytes: []const u8, bit_index: u16) u1 {
    const byte_idx = bit_index / 8;
    const bit_idx = 7 - @as(u3, @intCast(bit_index % 8));
    return @intCast((bytes[byte_idx] >> bit_idx) & 1);
}

fn setAlignedBit(bytes: []u8, bit_index: u16, bit: u1) void {
    const byte_idx = bit_index / 8;
    const bit_idx = 7 - @as(u3, @intCast(bit_index % 8));
    const mask = @as(u8, 1) << bit_idx;
    bytes[byte_idx] &= ~mask;
    bytes[byte_idx] |= @as(u8, bit) << bit_idx;
}

fn invertAlignedBits(bytes: []u8, bit_count: u16) void {
    var idx: u16 = 0;
    while (idx < bit_count) : (idx += 1) {
        const current = getAlignedBit(bytes, idx);
        setAlignedBit(bytes, idx, if (current == 0) 1 else 0);
    }
}

fn addOneToAlignedBits(bytes: []u8, bit_count: u16) void {
    var idx: u16 = bit_count;
    while (idx > 0) {
        idx -= 1;
        const current = getAlignedBit(bytes, idx);
        if (current == 0) {
            setAlignedBit(bytes, idx, 1);
            return;
        }
        setAlignedBit(bytes, idx, 0);
    }
}

fn isPowerOfTwoBytes(bytes: []const u8) bool {
    var seen = false;
    for (bytes) |byte| {
        if (byte == 0) continue;
        if ((byte & (byte - 1)) != 0) return false;
        if (seen) return false;
        seen = true;
    }
    return seen;
}

fn buildNumericStackArgJsonAlloc(allocator: std.mem.Allocator, type_name: []const u8, text: []const u8) ![]u8 {
    const parsed = try parseNumericTextAlloc(allocator, text);
    defer parsed.deinit(allocator);

    try validateNumericTextBits(type_name, parsed.negative, parsed.significant_bits, parsed.bytes);

    const encoded = try formatTonNumTextAlloc(allocator, parsed.bytes, parsed.negative);
    defer allocator.free(encoded);

    return std.fmt.allocPrint(allocator, "[\"num\",\"{s}\"]", .{encoded});
}

fn validateNumericTextBits(type_name: []const u8, negative: bool, significant_bits: u16, bytes: []const u8) !void {
    if (std.mem.eql(u8, type_name, "bool")) {
        if (negative or significant_bits > 1) return error.InvalidAbiArguments;
        return;
    }

    if (std.mem.eql(u8, type_name, "coins")) {
        if (negative or significant_bits > 120) return error.InvalidAbiArguments;
        return;
    }

    if (std.mem.startsWith(u8, type_name, "uint")) {
        const bits = try parseSizedTypeBits(type_name, "uint", 64);
        if (negative or significant_bits > bits) return error.InvalidAbiArguments;
        return;
    }

    if (std.mem.startsWith(u8, type_name, "int")) {
        const bits = try parseSizedTypeBits(type_name, "int", 64);
        if (negative) {
            if (bits == 0 or significant_bits > bits) return error.InvalidAbiArguments;
            if (significant_bits == bits and !isPowerOfTwoBytes(bytes)) return error.InvalidAbiArguments;
        } else if (bits == 0 or significant_bits > bits - 1) {
            return error.InvalidAbiArguments;
        }
        return;
    }
}

fn formatTonNumTextAlloc(allocator: std.mem.Allocator, bytes: []const u8, negative: bool) ![]u8 {
    if (bytes.len == 0) {
        return allocator.dupe(u8, "0x0");
    }

    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    if (negative) try writer.writer.writeByte('-');
    try writer.writer.writeAll("0x");
    for (bytes) |byte| {
        try writer.writer.print("{X:0>2}", .{byte});
    }

    return try writer.toOwnedSlice();
}

fn paramWithType(param: ParamDef, type_name: []const u8) ParamDef {
    return .{
        .name = param.name,
        .type_name = type_name,
        .components = param.components,
    };
}

fn isCompositeParam(param: ParamDef) bool {
    return param.components.len > 0 or
        std.mem.eql(u8, param.type_name, "tuple") or
        std.mem.eql(u8, param.type_name, "struct");
}

fn storeCompositeJsonText(
    builder: *cell.Builder,
    allocator: std.mem.Allocator,
    param: ParamDef,
    json_text: []const u8,
) anyerror!void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();

    try storeAbiJsonValue(builder, allocator, param, parsed.value);
}

fn storeArrayJsonText(
    builder: *cell.Builder,
    allocator: std.mem.Allocator,
    element_param: ParamDef,
    json_text: []const u8,
) anyerror!void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();

    try storeAbiArrayJsonValue(builder, allocator, element_param, parsed.value);
}

fn buildCompositeStackArgJsonAlloc(
    allocator: std.mem.Allocator,
    param: ParamDef,
    json_text: []const u8,
) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();

    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    try writeAbiStackArgJson(&writer.writer, allocator, param, parsed.value);
    return try writer.toOwnedSlice();
}

fn buildArrayStackArgJsonAlloc(
    allocator: std.mem.Allocator,
    element_param: ParamDef,
    json_text: []const u8,
) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();

    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    try writeAbiArrayStackArgJson(&writer.writer, allocator, element_param, parsed.value);
    return try writer.toOwnedSlice();
}

fn storeAbiJsonValue(
    builder: *cell.Builder,
    allocator: std.mem.Allocator,
    param: ParamDef,
    json_value: std.json.Value,
) anyerror!void {
    if (optionalInnerType(param.type_name)) |inner_type| {
        if (json_value == .null) {
            try builder.storeUint(0, 1);
            return;
        }

        try builder.storeUint(1, 1);
        return storeAbiJsonValue(builder, allocator, paramWithType(param, inner_type), json_value);
    }

    if (arrayInnerType(param.type_name)) |inner_type| {
        return storeAbiArrayJsonValue(builder, allocator, paramWithType(param, inner_type), json_value);
    }

    if (isCompositeParam(param)) {
        return storeCompositeFieldsJsonValue(builder, allocator, param.components, json_value);
    }

    if (std.mem.eql(u8, param.type_name, "bool")) {
        return switch (json_value) {
            .bool => |value| builder.storeUint(if (value) 1 else 0, 1),
            .integer => |value| if (value == 0)
                builder.storeUint(0, 1)
            else
                builder.storeUint(1, 1),
            .string => |value| storeNumericTextValue(builder, allocator, param.type_name, value),
            else => error.InvalidAbiArguments,
        };
    }

    if (std.mem.eql(u8, param.type_name, "address")) {
        return switch (json_value) {
            .string => |value| builder.storeAddress(value),
            else => error.InvalidAbiArguments,
        };
    }

    if (std.mem.eql(u8, param.type_name, "string")) {
        return switch (json_value) {
            .string => |value| builder.storeBits(value, @intCast(value.len * 8)),
            else => error.InvalidAbiArguments,
        };
    }

    if (fixedBytesLength(param.type_name)) |byte_len| {
        const decoded = try decodeJsonBytesAlloc(allocator, json_value);
        defer decoded.deinit(allocator);
        try validateFixedBytesLength(decoded.value.len, byte_len);
        try builder.storeBits(decoded.value, @intCast(decoded.value.len * 8));
        return;
    }

    if (std.mem.eql(u8, param.type_name, "bytes")) {
        const decoded = try decodeJsonBytesAlloc(allocator, json_value);
        defer decoded.deinit(allocator);
        try builder.storeBits(decoded.value, @intCast(decoded.value.len * 8));
        return;
    }

    if (isInlineCellLikeAbiType(param.type_name)) {
        const decoded = try decodeJsonBocAlloc(allocator, json_value);
        defer decoded.deinit(allocator);
        try storeInlineBoc(builder, allocator, decoded.value);
        return;
    }

    if (isRefCellLikeAbiType(param.type_name)) {
        const decoded = try decodeJsonBocAlloc(allocator, json_value);
        defer decoded.deinit(allocator);
        try body_builder.storeRefBoc(builder, allocator, decoded.value);
        return;
    }

    if (std.mem.eql(u8, param.type_name, "coins") or std.mem.startsWith(u8, param.type_name, "uint")) {
        return switch (json_value) {
            .integer => |value| {
                if (value < 0) return error.InvalidAbiArguments;
                if (std.mem.eql(u8, param.type_name, "coins")) {
                    try builder.storeCoins(@intCast(value));
                } else {
                    const bits = try parseSizedTypeBits(param.type_name, "uint", 64);
                    if (bits > 64) {
                        var text_buf: [32]u8 = undefined;
                        const text = try formatUnsignedDecimalText(&text_buf, @intCast(value));
                        try storeNumericTextValue(builder, allocator, param.type_name, text);
                        return;
                    }
                    try builder.storeUint(@intCast(value), bits);
                }
            },
            .string => |value| storeNumericTextValue(builder, allocator, param.type_name, value),
            else => error.InvalidAbiArguments,
        };
    }

    if (std.mem.startsWith(u8, param.type_name, "int")) {
        return switch (json_value) {
            .integer => |value| {
                const bits = try parseSizedTypeBits(param.type_name, "int", 64);
                if (bits > 64) {
                    var text_buf: [32]u8 = undefined;
                    const text = try formatSignedDecimalText(&text_buf, value);
                    try storeNumericTextValue(builder, allocator, param.type_name, text);
                    return;
                }
                try builder.storeInt(value, bits);
            },
            .string => |value| storeNumericTextValue(builder, allocator, param.type_name, value),
            else => error.InvalidAbiArguments,
        };
    }

    return error.UnsupportedAbiType;
}

fn storeAbiArrayJsonValue(
    builder: *cell.Builder,
    allocator: std.mem.Allocator,
    element_param: ParamDef,
    json_value: std.json.Value,
) anyerror!void {
    const items = switch (json_value) {
        .array => |value| value.items,
        else => return error.InvalidAbiArguments,
    };

    if (items.len > std.math.maxInt(u32)) return error.InvalidAbiArguments;

    try builder.storeUint(items.len, abi_array_length_bits);
    for (items) |item| {
        try storeAbiJsonValue(builder, allocator, element_param, item);
    }
}

fn storeCompositeFieldsJsonValue(
    builder: *cell.Builder,
    allocator: std.mem.Allocator,
    components: []const ParamDef,
    json_value: std.json.Value,
) anyerror!void {
    switch (json_value) {
        .object => |object| {
            for (components) |component| {
                const child = object.get(component.name) orelse return error.InvalidAbiArguments;
                try storeAbiJsonValue(builder, allocator, component, child);
            }
        },
        .array => |array| {
            if (array.items.len != components.len) return error.InvalidAbiArguments;
            for (components, array.items) |component, child| {
                try storeAbiJsonValue(builder, allocator, component, child);
            }
        },
        else => return error.InvalidAbiArguments,
    }
}

fn writeAbiStackArgJson(
    writer: anytype,
    allocator: std.mem.Allocator,
    param: ParamDef,
    json_value: std.json.Value,
) anyerror!void {
    if (optionalInnerType(param.type_name)) |inner_type| {
        if (json_value == .null) {
            try writer.writeAll("[\"null\"]");
            return;
        }

        return writeAbiStackArgJson(writer, allocator, paramWithType(param, inner_type), json_value);
    }

    if (arrayInnerType(param.type_name)) |inner_type| {
        return writeAbiArrayStackArgJson(writer, allocator, paramWithType(param, inner_type), json_value);
    }

    if (isCompositeParam(param)) {
        return writeAbiCompositeStackArgJson(writer, allocator, param, json_value);
    }

    if (std.mem.eql(u8, param.type_name, "bool")) {
        return switch (json_value) {
            .bool => |value| writer.print("[\"num\",{d}]", .{if (value) @as(i64, 1) else 0}),
            .integer => |value| writer.print("[\"num\",{d}]", .{if (value == 0) @as(i64, 0) else 1}),
            .string => |value| writeNumericStackArgJson(writer, allocator, param.type_name, value),
            else => error.InvalidAbiArguments,
        };
    }

    if (std.mem.eql(u8, param.type_name, "coins") or
        std.mem.startsWith(u8, param.type_name, "uint") or
        std.mem.startsWith(u8, param.type_name, "int"))
    {
        return switch (json_value) {
            .integer => |value| writer.print("[\"num\",{d}]", .{value}),
            .string => |value| writeNumericStackArgJson(writer, allocator, param.type_name, value),
            else => error.InvalidAbiArguments,
        };
    }

    if (std.mem.eql(u8, param.type_name, "address")) {
        return switch (json_value) {
            .string => |value| {
                const address_boc = try buildAddressStackSliceBocAlloc(allocator, value);
                defer allocator.free(address_boc);
                try writeStackBocArgJson(writer, allocator, "slice", address_boc);
            },
            else => error.InvalidAbiArguments,
        };
    }

    if (fixedBytesLength(param.type_name)) |byte_len| {
        const decoded = try decodeJsonBytesAlloc(allocator, json_value);
        defer decoded.deinit(allocator);
        try validateFixedBytesLength(decoded.value.len, byte_len);
        const body_boc = try buildBytesSliceBocAlloc(allocator, decoded.value);
        defer allocator.free(body_boc);
        try writeStackBocArgJson(writer, allocator, "slice", body_boc);
        return;
    }

    if (std.mem.eql(u8, param.type_name, "bytes") or std.mem.eql(u8, param.type_name, "string")) {
        if (std.mem.eql(u8, param.type_name, "string")) {
            return switch (json_value) {
                .string => |value| {
                    const body_boc = try buildBytesSliceBocAlloc(allocator, value);
                    defer allocator.free(body_boc);
                    try writeStackBocArgJson(writer, allocator, "slice", body_boc);
                },
                else => error.InvalidAbiArguments,
            };
        }

        const decoded = try decodeJsonBytesAlloc(allocator, json_value);
        defer decoded.deinit(allocator);
        const body_boc = try buildBytesSliceBocAlloc(allocator, decoded.value);
        defer allocator.free(body_boc);
        try writeStackBocArgJson(writer, allocator, "slice", body_boc);
        return;
    }

    if (stackCellLikeKind(param.type_name)) |kind| {
        const decoded = try decodeJsonBocAlloc(allocator, json_value);
        defer decoded.deinit(allocator);
        const tag = switch (kind) {
            .cell => "cell",
            .slice => "slice",
            .builder => "builder",
        };
        try writeStackBocArgJson(writer, allocator, tag, decoded.value);
        return;
    }

    return error.UnsupportedAbiType;
}

fn writeNumericStackArgJson(
    writer: anytype,
    allocator: std.mem.Allocator,
    type_name: []const u8,
    text: []const u8,
) !void {
    const encoded = try buildNumericStackArgJsonAlloc(allocator, type_name, text);
    defer allocator.free(encoded);
    try writer.writeAll(encoded);
}

fn writeAbiArrayStackArgJson(
    writer: anytype,
    allocator: std.mem.Allocator,
    element_param: ParamDef,
    json_value: std.json.Value,
) anyerror!void {
    const items = switch (json_value) {
        .array => |value| value.items,
        else => return error.InvalidAbiArguments,
    };

    try writer.writeAll("[\"list\",[");
    for (items, 0..) |item, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writeAbiStackArgJson(writer, allocator, element_param, item);
    }
    try writer.writeAll("]]");
}

fn writeAbiCompositeStackArgJson(
    writer: anytype,
    allocator: std.mem.Allocator,
    param: ParamDef,
    json_value: std.json.Value,
) anyerror!void {
    try writer.print("[\"{s}\",", .{compositeStackTag(param.type_name)});
    try writeCompositeItemsJson(writer, allocator, param.components, json_value);
    try writer.writeByte(']');
}

fn writeCompositeItemsJson(
    writer: anytype,
    allocator: std.mem.Allocator,
    components: []const ParamDef,
    json_value: std.json.Value,
) anyerror!void {
    try writer.writeByte('[');

    switch (json_value) {
        .object => |object| {
            for (components, 0..) |component, idx| {
                if (idx != 0) try writer.writeByte(',');
                const child = object.get(component.name) orelse return error.InvalidAbiArguments;
                try writeAbiStackArgJson(writer, allocator, component, child);
            }
        },
        .array => |array| {
            if (array.items.len != components.len) return error.InvalidAbiArguments;
            for (components, array.items, 0..) |component, child, idx| {
                if (idx != 0) try writer.writeByte(',');
                try writeAbiStackArgJson(writer, allocator, component, child);
            }
        },
        else => return error.InvalidAbiArguments,
    }

    try writer.writeByte(']');
}

const OwnedDecodedBytes = struct {
    value: []const u8,
    owned: ?[]u8 = null,

    fn deinit(self: OwnedDecodedBytes, allocator: std.mem.Allocator) void {
        if (self.owned) |buffer| allocator.free(buffer);
    }
};

fn compositeStackTag(type_name: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, type_name, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "list") or
        std.mem.startsWith(u8, trimmed, "list<") or
        std.mem.startsWith(u8, trimmed, "list "))
    {
        return "list";
    }
    return "tuple";
}

fn arrayInnerType(type_name: []const u8) ?[]const u8 {
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

fn writeStackBocArgJson(writer: anytype, allocator: std.mem.Allocator, tag: []const u8, boc_bytes: []const u8) !void {
    const encoded_len = std.base64.standard.Encoder.calcSize(boc_bytes.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, boc_bytes);

    try writer.print("[\"{s}\",\"{s}\"]", .{ tag, encoded });
}

fn decodeJsonBytesAlloc(allocator: std.mem.Allocator, json_value: std.json.Value) !OwnedDecodedBytes {
    return switch (json_value) {
        .string => |value| .{ .value = value },
        .object => |object| {
            if (object.get("text")) |text_value| {
                return switch (text_value) {
                    .string => |value| .{ .value = value },
                    else => error.InvalidAbiArguments,
                };
            }
            if (object.get("hex")) |hex_value| {
                return switch (hex_value) {
                    .string => |value| blk: {
                        const decoded = try hexToBytesAlloc(allocator, value);
                        break :blk .{ .value = decoded, .owned = decoded };
                    },
                    else => error.InvalidAbiArguments,
                };
            }
            if (object.get("base64")) |base64_value| {
                return switch (base64_value) {
                    .string => |value| blk: {
                        const decoded = try decodeBase64FlexibleAlloc(allocator, value);
                        break :blk .{ .value = decoded, .owned = decoded };
                    },
                    else => error.InvalidAbiArguments,
                };
            }
            return error.InvalidAbiArguments;
        },
        else => error.InvalidAbiArguments,
    };
}

fn decodeJsonBocAlloc(allocator: std.mem.Allocator, json_value: std.json.Value) !OwnedDecodedBytes {
    return switch (json_value) {
        .string => |value| blk: {
            const decoded = try decodeBase64FlexibleAlloc(allocator, value);
            break :blk .{ .value = decoded, .owned = decoded };
        },
        .object => |object| {
            if (object.get("boc")) |boc_value| {
                return switch (boc_value) {
                    .string => |value| blk: {
                        const decoded = try decodeBase64FlexibleAlloc(allocator, value);
                        break :blk .{ .value = decoded, .owned = decoded };
                    },
                    else => error.InvalidAbiArguments,
                };
            }
            if (object.get("base64")) |base64_value| {
                return switch (base64_value) {
                    .string => |value| blk: {
                        const decoded = try decodeBase64FlexibleAlloc(allocator, value);
                        break :blk .{ .value = decoded, .owned = decoded };
                    },
                    else => error.InvalidAbiArguments,
                };
            }
            if (object.get("hex")) |hex_value| {
                return switch (hex_value) {
                    .string => |value| blk: {
                        const decoded = try hexToBytesAlloc(allocator, value);
                        break :blk .{ .value = decoded, .owned = decoded };
                    },
                    else => error.InvalidAbiArguments,
                };
            }
            if (object.get("boc_hex")) |hex_value| {
                return switch (hex_value) {
                    .string => |value| blk: {
                        const decoded = try hexToBytesAlloc(allocator, value);
                        break :blk .{ .value = decoded, .owned = decoded };
                    },
                    else => error.InvalidAbiArguments,
                };
            }
            return error.InvalidAbiArguments;
        },
        else => error.InvalidAbiArguments,
    };
}

fn storeInlineBoc(builder: *cell.Builder, allocator: std.mem.Allocator, body_boc: []const u8) !void {
    const root = try boc.deserializeBoc(allocator, body_boc);
    errdefer root.deinit(allocator);

    const byte_len: usize = @intCast(@divTrunc(root.bit_len + 7, 8));
    try builder.storeBits(root.data[0..byte_len], root.bit_len);

    for (0..root.ref_cnt) |idx| {
        const ref = root.refs[idx] orelse return error.InvalidBoc;
        root.refs[idx] = null;
        try builder.storeRef(ref);
    }
    root.ref_cnt = 0;
    root.deinit(allocator);
}

fn buildAddressStackSliceBocAlloc(allocator: std.mem.Allocator, address_text: []const u8) ![]u8 {
    var builder = cell.Builder.init();
    try builder.storeAddress(address_text);

    const value = try builder.toCell(allocator);
    defer value.deinit(allocator);

    return boc.serializeBoc(allocator, value);
}

fn hexToBytesAlloc(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidHex;

    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);

    for (0..out.len) |idx| {
        const hi = try hexCharValue(hex[idx * 2]);
        const lo = try hexCharValue(hex[idx * 2 + 1]);
        out[idx] = (hi << 4) | lo;
    }

    return out;
}

fn hexCharValue(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
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

fn checkedAbiUintToI64(value: u64) !i64 {
    if (value > @as(u64, @intCast(std.math.maxInt(i64)))) return error.InvalidAbiArguments;
    return @intCast(value);
}

fn buildBytesSliceBocAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var builder = cell.Builder.init();
    try builder.storeBits(bytes, @intCast(bytes.len * 8));

    const value = try builder.toCell(allocator);
    defer value.deinit(allocator);

    return boc.serializeBoc(allocator, value);
}

fn deinitBuilderRefs(allocator: std.mem.Allocator, builder: *cell.Builder) void {
    for (builder.refs[0..builder.ref_cnt]) |ref| {
        if (ref) |value| value.deinit(allocator);
    }
}

fn optionalInnerType(type_name: []const u8) ?[]const u8 {
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

fn peekBodyOpcodeFromBoc(body_boc: []const u8) !u32 {
    const root = try boc.deserializeBoc(std.heap.page_allocator, body_boc);
    defer root.deinit(std.heap.page_allocator);

    var slice = root.toSlice();
    return @intCast(try loadUintDynamic(&slice, 32));
}

fn decodeBodyFieldsJsonAlloc(
    allocator: std.mem.Allocator,
    params: []const ParamDef,
    slice: *cell.Slice,
    allow_tail_variable: bool,
) ![]u8 {
    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    try writeDecodedBodyFieldsJson(&writer.writer, allocator, params, slice, allow_tail_variable);
    return try writer.toOwnedSlice();
}

fn writeDecodedBodyFieldsJson(
    writer: anytype,
    allocator: std.mem.Allocator,
    params: []const ParamDef,
    slice: *cell.Slice,
    allow_tail_variable: bool,
) anyerror!void {
    if (allParamNamesMissing(params)) {
        try writer.writeByte('[');
        for (params, 0..) |param, idx| {
            if (idx != 0) try writer.writeByte(',');
            try writeDecodedBodyParamJson(
                writer,
                allocator,
                param,
                slice,
                allow_tail_variable and idx + 1 == params.len,
            );
        }
        try writer.writeByte(']');
        return;
    }

    try writer.writeByte('{');
    for (params, 0..) |param, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writeDecodedFieldName(writer, param.name, idx);
        try writer.writeByte(':');
        try writeDecodedBodyParamJson(
            writer,
            allocator,
            param,
            slice,
            allow_tail_variable and idx + 1 == params.len,
        );
    }
    try writer.writeByte('}');
}

fn writeDecodedBodyParamJson(
    writer: anytype,
    allocator: std.mem.Allocator,
    param: ParamDef,
    slice: *cell.Slice,
    is_last: bool,
) anyerror!void {
    if (optionalInnerType(param.type_name)) |inner_type| {
        const present = try loadUintDynamic(slice, 1);
        if (present == 0) {
            try writer.writeAll("null");
            return;
        }

        return writeDecodedBodyParamJson(writer, allocator, paramWithType(param, inner_type), slice, is_last);
    }

    if (arrayInnerType(param.type_name)) |inner_type| {
        const inner_param = paramWithType(param, inner_type);
        const length = try loadUintDynamic(slice, abi_array_length_bits);
        if (!paramIsBodySelfDelimited(inner_param)) {
            if (!is_last or length > 1) return error.UnsupportedAbiType;
        }

        try writer.writeByte('[');
        var idx: u64 = 0;
        while (idx < length) : (idx += 1) {
            if (idx != 0) try writer.writeByte(',');
            try writeDecodedBodyParamJson(
                writer,
                allocator,
                inner_param,
                slice,
                is_last and idx + 1 == length,
            );
        }
        try writer.writeByte(']');
        return;
    }

    if (isCompositeParam(param)) {
        return writeDecodedBodyFieldsJson(writer, allocator, param.components, slice, is_last);
    }

    return writeDecodedBodyJsonType(writer, allocator, param.type_name, slice, is_last);
}

fn writeDecodedBodyJsonType(
    writer: anytype,
    allocator: std.mem.Allocator,
    type_name: []const u8,
    slice: *cell.Slice,
    is_last: bool,
) anyerror!void {
    if (std.mem.eql(u8, type_name, "bool")) {
        const value = (try loadUintDynamic(slice, 1)) != 0;
        try writer.writeAll(if (value) "true" else "false");
        return;
    }

    if (std.mem.eql(u8, type_name, "coins")) {
        try writer.print("{d}", .{try slice.loadCoins()});
        return;
    }

    if (std.mem.startsWith(u8, type_name, "uint")) {
        const bits = try parseSizedTypeBits(type_name, "uint", 64);
        if (bits <= 64) {
            try writer.print("{d}", .{try loadUintDynamic(slice, bits)});
            return;
        }

        const text = try decodeUnsignedBodyBitsTextAlloc(allocator, slice, bits);
        defer allocator.free(text);
        try writeJsonString(writer, text);
        return;
    }

    if (std.mem.startsWith(u8, type_name, "int")) {
        const bits = try parseSizedTypeBits(type_name, "int", 64);
        if (bits <= 64) {
            try writer.print("{d}", .{try loadIntDynamic(slice, bits)});
            return;
        }

        const text = try decodeSignedBodyBitsTextAlloc(allocator, slice, bits);
        defer allocator.free(text);
        try writeJsonString(writer, text);
        return;
    }

    if (std.mem.eql(u8, type_name, "address")) {
        const addr = try loadAddressFromBody(slice);
        if (addr) |value| {
            const raw = try value.toRawAlloc(allocator);
            defer allocator.free(raw);
            try writeJsonString(writer, raw);
        } else {
            try writer.writeAll("null");
        }
        return;
    }

    if (fixedBytesLength(type_name)) |byte_len| {
        const bytes = try loadBitsRightAlignedAlloc(allocator, slice, @intCast(byte_len * 8));
        defer allocator.free(bytes);
        const encoded = try base64EncodeAlloc(allocator, bytes);
        defer allocator.free(encoded);
        try writeJsonString(writer, encoded);
        return;
    }

    if (std.mem.eql(u8, type_name, "string")) {
        if (!is_last) return error.UnsupportedAbiType;
        const bytes = try loadRemainingBodyBytesAlloc(allocator, slice);
        defer allocator.free(bytes);
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidAbiOutputs;
        try writeJsonString(writer, bytes);
        return;
    }

    if (std.mem.eql(u8, type_name, "bytes")) {
        if (!is_last) return error.UnsupportedAbiType;
        const bytes = try loadRemainingBodyBytesAlloc(allocator, slice);
        defer allocator.free(bytes);
        const encoded = try base64EncodeAlloc(allocator, bytes);
        defer allocator.free(encoded);
        try writeJsonString(writer, encoded);
        return;
    }

    if (isRefCellLikeAbiType(type_name)) {
        const body = try loadRefBodyBocAlloc(allocator, slice);
        defer allocator.free(body);
        const encoded = try base64EncodeAlloc(allocator, body);
        defer allocator.free(encoded);
        try writeJsonString(writer, encoded);
        return;
    }

    if (isInlineCellLikeAbiType(type_name)) {
        if (!is_last) return error.UnsupportedAbiType;
        const body = try buildRemainingBodyBocAlloc(allocator, slice);
        defer allocator.free(body);
        const encoded = try base64EncodeAlloc(allocator, body);
        defer allocator.free(encoded);
        try writeJsonString(writer, encoded);
        return;
    }

    return error.UnsupportedAbiType;
}

fn paramIsBodySelfDelimited(param: ParamDef) bool {
    if (optionalInnerType(param.type_name)) |inner_type| {
        return paramIsBodySelfDelimited(paramWithType(param, inner_type));
    }

    if (arrayInnerType(param.type_name)) |inner_type| {
        return paramIsBodySelfDelimited(paramWithType(param, inner_type));
    }

    if (isCompositeParam(param)) {
        for (param.components) |component| {
            if (!paramIsBodySelfDelimited(component)) return false;
        }
        return true;
    }

    if (std.mem.eql(u8, param.type_name, "string") or std.mem.eql(u8, param.type_name, "bytes")) {
        return false;
    }

    if (isRefCellLikeAbiType(param.type_name)) {
        return true;
    }

    if (isInlineCellLikeAbiType(param.type_name)) {
        return false;
    }

    return true;
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

fn loadIntDynamic(slice: *cell.Slice, bits: u16) !i64 {
    if (bits > 64) return error.UnsupportedAbiType;
    const value = try loadUintDynamic(slice, bits);
    if (bits == 0) return 0;

    const sign_bit = @as(u64, 1) << @intCast(bits - 1);
    if ((value & sign_bit) == 0) return @intCast(value);
    if (bits == 64) return @bitCast(value);
    return @bitCast(value | (@as(u64, 0xFFFFFFFFFFFFFFFF) << @intCast(bits)));
}

fn loadBitsRightAlignedAlloc(allocator: std.mem.Allocator, slice: *cell.Slice, bits: u16) ![]u8 {
    if (slice.remainingBits() < bits) return error.NotEnoughData;

    const byte_len: usize = @intCast(@divTrunc(bits + 7, 8));
    const out = try allocator.alloc(u8, byte_len);
    errdefer allocator.free(out);
    @memset(out, 0);

    if (bits == 0) return out;

    const padding_bits: usize = byte_len * 8 - bits;
    var idx: usize = 0;
    while (idx < bits) : (idx += 1) {
        const bit = try slice.loadUint(1);
        const abs_idx = padding_bits + idx;
        out[abs_idx / 8] |= @as(u8, @intCast(bit)) << @as(u3, @intCast(7 - (abs_idx % 8)));
    }

    return out;
}

fn trimLeadingZeroBytesView(bytes: []const u8) []const u8 {
    var start: usize = 0;
    while (start < bytes.len and bytes[start] == 0) : (start += 1) {}
    return bytes[start..];
}

fn decodeUnsignedBodyBitsTextAlloc(allocator: std.mem.Allocator, slice: *cell.Slice, bits: u16) ![]u8 {
    const bytes = try loadBitsRightAlignedAlloc(allocator, slice, bits);
    defer allocator.free(bytes);
    return formatTonNumTextAlloc(allocator, trimLeadingZeroBytesView(bytes), false);
}

fn decodeSignedBodyBitsTextAlloc(allocator: std.mem.Allocator, slice: *cell.Slice, bits: u16) ![]u8 {
    const bytes = try loadBitsRightAlignedAlloc(allocator, slice, bits);
    defer allocator.free(bytes);
    if (bits == 0) return allocator.dupe(u8, "0x0");

    const padding_bits: u16 = @intCast(bytes.len * 8 - bits);
    const sign_mask = @as(u8, 1) << @as(u3, @intCast(7 - padding_bits));
    if ((bytes[0] & sign_mask) == 0) {
        return formatTonNumTextAlloc(allocator, trimLeadingZeroBytesView(bytes), false);
    }

    const magnitude = try decodeSignedMagnitudeAlloc(allocator, bytes, bits);
    defer allocator.free(magnitude);
    return formatTonNumTextAlloc(allocator, magnitude, true);
}

fn decodeSignedMagnitudeAlloc(allocator: std.mem.Allocator, bytes: []const u8, bits: u16) ![]u8 {
    const out = try allocator.dupe(u8, bytes);
    errdefer allocator.free(out);
    if (out.len == 0) return out;

    const padding_bits: u16 = @intCast(out.len * 8 - bits);
    const leading_mask: u8 = if (padding_bits == 0)
        0xFF
    else
        @as(u8, @intCast(@as(u16, 0xFF) >> @intCast(padding_bits)));

    out[0] &= leading_mask;
    out[0] = ~out[0] & leading_mask;
    for (out[1..]) |*byte| {
        byte.* = ~byte.*;
    }

    var carry: u16 = 1;
    var idx = out.len;
    while (idx > 0 and carry != 0) {
        idx -= 1;
        const sum = @as(u16, out[idx]) + carry;
        out[idx] = @intCast(sum & 0xFF);
        carry = sum >> 8;
    }
    out[0] &= leading_mask;

    const trimmed = try dupeTrimmedBytes(allocator, out);
    allocator.free(out);
    return trimmed;
}

fn loadAddressFromBody(slice: *cell.Slice) !?types.Address {
    const tag = try loadUintDynamic(slice, 2);
    if (tag == 0) return null;
    if (tag != 0b10) return error.InvalidAbiOutputs;

    const has_anycast = try loadUintDynamic(slice, 1);
    if (has_anycast != 0) return error.UnsupportedAddress;

    var raw: [32]u8 = undefined;
    const workchain = try slice.loadInt8();
    for (&raw) |*byte| {
        byte.* = try slice.loadUint8();
    }

    return .{
        .raw = raw,
        .workchain = workchain,
    };
}

fn loadRemainingBodyBytesAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) ![]u8 {
    if (slice.remainingRefs() != 0) return error.UnsupportedAbiType;
    if (slice.remainingBits() % 8 != 0) return error.InvalidAbiOutputs;
    return loadBitsRightAlignedAlloc(allocator, slice, slice.remainingBits());
}

fn loadRefBodyBocAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) ![]u8 {
    const value = try slice.loadRef();
    return boc.serializeBoc(allocator, value);
}

fn buildRemainingBodyBocAlloc(allocator: std.mem.Allocator, slice: *cell.Slice) ![]u8 {
    var builder = cell.Builder.init();
    try builder.storeSlice(slice);

    const value = try builder.toCell(allocator);
    defer value.deinit(allocator);

    return boc.serializeBoc(allocator, value);
}

fn writeDecodedOutputJson(
    writer: anytype,
    allocator: std.mem.Allocator,
    param: ParamDef,
    entry: *const types.StackEntry,
) anyerror!void {
    if (optionalInnerType(param.type_name)) |inner_type| {
        if (std.meta.activeTag(entry.*) == .null) {
            try writer.writeAll("null");
            return;
        }

        return writeDecodedOutputJson(writer, allocator, paramWithType(param, inner_type), entry);
    }

    if (arrayInnerType(param.type_name)) |inner_type| {
        return writeDecodedArrayJson(writer, allocator, paramWithType(param, inner_type), entry);
    }

    if (isCompositeParam(param)) {
        return writeDecodedCompositeJson(writer, allocator, param.components, entry);
    }

    return writeDecodedOutputJsonType(writer, allocator, param.type_name, entry);
}

fn writeDecodedOutputJsonType(
    writer: anytype,
    allocator: std.mem.Allocator,
    type_name: []const u8,
    entry: *const types.StackEntry,
) anyerror!void {
    if (std.mem.eql(u8, type_name, "coins") or
        std.mem.startsWith(u8, type_name, "uint") or
        std.mem.startsWith(u8, type_name, "int"))
    {
        switch (entry.*) {
            .number => |value| try writer.print("{d}", .{value}),
            .big_number => |value| try writeJsonString(writer, value),
            else => return error.InvalidAbiOutputs,
        }
        return;
    }

    if (std.mem.eql(u8, type_name, "bool")) {
        const value = (try generic_contract.stackEntryAsInt(entry)) != 0;
        try writer.writeAll(if (value) "true" else "false");
        return;
    }

    if (std.mem.eql(u8, type_name, "address")) {
        const addr = try generic_contract.stackEntryAsOptionalAddress(entry);
        if (addr) |value| {
            const raw = try value.toRawAlloc(allocator);
            defer allocator.free(raw);
            try writeJsonString(writer, raw);
        } else {
            try writer.writeAll("null");
        }
        return;
    }

    if (std.mem.eql(u8, type_name, "string")) {
        const text = try decodeStringOutputAlloc(allocator, entry);
        defer allocator.free(text);
        try writeJsonString(writer, text);
        return;
    }

    if (fixedBytesLength(type_name)) |byte_len| {
        const bytes = try decodeBytesOutputAlloc(allocator, entry);
        defer allocator.free(bytes);
        if (bytes.len != byte_len) return error.InvalidAbiOutputs;
        const encoded = try base64EncodeAlloc(allocator, bytes);
        defer allocator.free(encoded);
        try writeJsonString(writer, encoded);
        return;
    }

    if (std.mem.eql(u8, type_name, "bytes")) {
        const bytes = try decodeBytesOutputAlloc(allocator, entry);
        defer allocator.free(bytes);
        const encoded = try base64EncodeAlloc(allocator, bytes);
        defer allocator.free(encoded);
        try writeJsonString(writer, encoded);
        return;
    }

    if (isInlineCellLikeAbiType(type_name) or isRefCellLikeAbiType(type_name)) {
        const body = try generic_contract.stackEntryToBocAlloc(allocator, entry);
        defer allocator.free(body);
        const encoded = try base64EncodeAlloc(allocator, body);
        defer allocator.free(encoded);
        try writeJsonString(writer, encoded);
        return;
    }

    if (std.meta.activeTag(entry.*) == .null) {
        try writer.writeAll("null");
        return;
    }

    return error.UnsupportedAbiType;
}

fn writeDecodedCompositeJson(
    writer: anytype,
    allocator: std.mem.Allocator,
    components: []const ParamDef,
    entry: *const types.StackEntry,
) anyerror!void {
    const items = switch (entry.*) {
        .tuple => |value| value,
        .list => |value| value,
        else => return error.InvalidAbiOutputs,
    };

    if (items.len != components.len) return error.InvalidAbiOutputs;

    if (allParamNamesMissing(components)) {
        try writer.writeByte('[');
        for (components, items, 0..) |component, *child, idx| {
            if (idx != 0) try writer.writeByte(',');
            try writeDecodedOutputJson(writer, allocator, component, child);
        }
        try writer.writeByte(']');
        return;
    }

    try writer.writeByte('{');
    for (components, items, 0..) |component, *child, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writeDecodedFieldName(writer, component.name, idx);
        try writer.writeByte(':');
        try writeDecodedOutputJson(writer, allocator, component, child);
    }
    try writer.writeByte('}');
}

fn writeDecodedArrayJson(
    writer: anytype,
    allocator: std.mem.Allocator,
    element_param: ParamDef,
    entry: *const types.StackEntry,
) anyerror!void {
    const items = switch (entry.*) {
        .list => |value| value,
        .tuple => |value| value,
        else => return error.InvalidAbiOutputs,
    };

    try writer.writeByte('[');
    for (items, 0..) |*child, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writeDecodedOutputJson(writer, allocator, element_param, child);
    }
    try writer.writeByte(']');
}

fn decodeBytesOutputAlloc(allocator: std.mem.Allocator, entry: *const types.StackEntry) ![]u8 {
    return switch (entry.*) {
        .bytes => |value| allocator.dupe(u8, value),
        .cell, .slice, .builder => {
            const cell_value = try generic_contract.stackEntryAsCell(entry);
            return generic_contract.flattenSnakeBytesAlloc(allocator, cell_value);
        },
        else => error.InvalidAbiOutputs,
    };
}

fn decodeStringOutputAlloc(allocator: std.mem.Allocator, entry: *const types.StackEntry) ![]u8 {
    const bytes = try decodeBytesOutputAlloc(allocator, entry);
    errdefer allocator.free(bytes);
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidAbiOutputs;
    return bytes;
}

fn base64EncodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(bytes.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return encoded;
}

fn allParamNamesMissing(params: []const ParamDef) bool {
    if (params.len == 0) return false;
    for (params) |param| {
        if (param.name.len != 0) return false;
    }
    return true;
}

fn writeDecodedFieldName(writer: anytype, name: []const u8, idx: usize) !void {
    if (name.len != 0) {
        try writeJsonString(writer, name);
        return;
    }

    var fallback_name_buf: [32]u8 = undefined;
    const fallback_name = try std.fmt.bufPrint(&fallback_name_buf, "value{d}", .{idx});
    try writeJsonString(writer, fallback_name);
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

test "abi adapter" {
    _ = querySupportedInterfaces;
    _ = queryAbiIpfs;
    _ = queryAbiDocumentAlloc;
    _ = loadAbiInfoSourceAlloc;
    _ = loadAbiTextSourceAlloc;
    _ = adaptToContract;
}

test "supported interface detection combines standard probes" {
    const supported = supportedInterfacesFromMethodSupport(true, false, true, false, true, true).?;
    try std.testing.expect(supported.has_wallet);
    try std.testing.expect(supported.has_jetton);
    try std.testing.expect(!supported.has_jetton_master);
    try std.testing.expect(supported.has_jetton_wallet);
    try std.testing.expect(supported.has_nft);
    try std.testing.expect(!supported.has_nft_item);
    try std.testing.expect(supported.has_nft_collection);
    try std.testing.expect(supported.has_abi);
}

test "supported interface detection returns null when nothing matches" {
    try std.testing.expect(supportedInterfacesFromMethodSupport(false, false, false, false, false, false) == null);
}

test "abi adapter extracts offchain uri from stack cell" {
    const allocator = std.testing.allocator;
    const ton_cell = @import("../core/cell.zig");

    var tail_builder = ton_cell.Builder.init();
    try tail_builder.storeBits("abi.json", "abi.json".len * 8);
    const tail = try tail_builder.toCell(allocator);

    var head_builder = ton_cell.Builder.init();
    try head_builder.storeUint(1, 8);
    try head_builder.storeBits("ipfs://example/", "ipfs://example/".len * 8);
    try head_builder.storeRef(tail);
    const root = try head_builder.toCell(allocator);
    defer root.deinit(allocator);

    const stack = [_]types.StackEntry{
        .{ .cell = root },
    };

    var info = (try abiInfoFromStack(allocator, stack[0..])).?;
    defer info.deinit(allocator);

    try std.testing.expectEqualStrings("offchain-uri", info.version);
    try std.testing.expectEqualStrings("ipfs://example/abi.json", info.uri.?);
}

test "abi adapter loads abi text from @file source" {
    const allocator = std.testing.allocator;
    const abi_json =
        \\{
        \\  "functions": [
        \\    {
        \\      "name": "ping",
        \\      "outputs": []
        \\    }
        \\  ]
        \\}
    ;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "abi.json", .data = abi_json });
    const abi_path = try tmp.dir.realpathAlloc(allocator, "abi.json");
    defer allocator.free(abi_path);

    const source = try std.fmt.allocPrint(allocator, "@{s}", .{abi_path});
    defer allocator.free(source);

    const loaded = try loadAbiTextSourceAlloc(allocator, source);
    defer allocator.free(loaded);

    try std.testing.expectEqualStrings(abi_json, loaded);
}

test "abi adapter loads abi info from file uri source" {
    const allocator = std.testing.allocator;
    const abi_json =
        \\{
        \\  "version": "1.2",
        \\  "functions": [
        \\    {
        \\      "name": "ping",
        \\      "outputs": []
        \\    }
        \\  ]
        \\}
    ;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "abi.json", .data = abi_json });
    const abi_path = try tmp.dir.realpathAlloc(allocator, "abi.json");
    defer allocator.free(abi_path);

    const source = try std.fmt.allocPrint(allocator, "file://{s}", .{abi_path});
    defer allocator.free(source);

    var loaded = try loadAbiInfoSourceAlloc(allocator, source);
    defer loaded.deinit(allocator);

    try std.testing.expectEqualStrings("1.2", loaded.abi.version);
    try std.testing.expectEqual(@as(usize, 1), loaded.abi.functions.len);
    try std.testing.expectEqualStrings("ping", loaded.abi.functions[0].name);
}

test "abi adapter can extract plain uri bytes from tuple stack" {
    const allocator = std.testing.allocator;
    var nested = [_]types.StackEntry{
        .{ .bytes = "https://example.com/abi.json" },
    };
    var stack = [_]types.StackEntry{
        .{ .tuple = nested[0..] },
    };

    var info = (try abiInfoFromStack(allocator, stack[0..])).?;
    defer info.deinit(allocator);

    try std.testing.expectEqualStrings("https://example.com/abi.json", info.uri.?);
}

test "abi adapter parses function definition json" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "name": "transfer",
        \\  "opcode": "0x0f8a7ea5",
        \\  "inputs": [
        \\    {"name": "query_id", "type": "uint64"},
        \\    {"name": "amount", "type": "coins"},
        \\    {"name": "recipient", "type": "address"},
        \\    {"name": "payload", "type": "ref"}
        \\  ]
        \\}
    ;

    var parsed = try parseFunctionDefJsonAlloc(allocator, json);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("transfer", parsed.function.name);
    try std.testing.expectEqual(@as(u32, 0x0f8a7ea5), parsed.function.opcode.?);
    try std.testing.expectEqual(@as(usize, 4), parsed.function.inputs.len);
    try std.testing.expectEqualStrings("address", parsed.function.inputs[2].type_name);
}

test "abi adapter parses tuple components from abi json" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "name": "set_config",
        \\  "inputs": [
        \\    {
        \\      "name": "config",
        \\      "type": "tuple",
        \\      "components": [
        \\        {"name": "enabled", "type": "bool"},
        \\        {"name": "owner", "type": "address"},
        \\        {"name": "label", "type": "optional<string>"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parseFunctionDefJsonAlloc(allocator, json);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), parsed.function.inputs.len);
    try std.testing.expectEqualStrings("tuple", parsed.function.inputs[0].type_name);
    try std.testing.expectEqual(@as(usize, 3), parsed.function.inputs[0].components.len);
    try std.testing.expectEqualStrings("enabled", parsed.function.inputs[0].components[0].name);
    try std.testing.expectEqualStrings("optional<string>", parsed.function.inputs[0].components[2].type_name);
}

test "abi adapter allows unnamed params and tuple components" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "name": "get_value",
        \\  "outputs": [
        \\    {"type": "uint32"},
        \\    {
        \\      "type": "tuple",
        \\      "components": [
        \\        {"type": "bool"},
        \\        {"name": "owner", "type": "address"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parseFunctionDefJsonAlloc(allocator, json);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.function.outputs.len);
    try std.testing.expectEqualStrings("", parsed.function.outputs[0].name);
    try std.testing.expectEqualStrings("", parsed.function.outputs[1].components[0].name);
    try std.testing.expectEqualStrings("owner", parsed.function.outputs[1].components[1].name);
}

test "abi adapter parses abi document json and finds function" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "version": "1.0",
        \\  "functions": [
        \\    {
        \\      "name": "transfer",
        \\      "id": "0x0f8a7ea5",
        \\      "inputs": [
        \\        {"name": "query_id", "type": "uint64"},
        \\        {"name": "amount", "type": "coins"}
        \\      ]
        \\    },
        \\    {
        \\      "name": "burn",
        \\      "opcode": 1499400124,
        \\      "inputs": [
        \\        {"name": "amount", "type": "coins"}
        \\      ]
        \\    }
        \\  ],
        \\  "events": [
        \\    {
        \\      "name": "Transfer",
        \\      "opcode": "0x11223344",
        \\      "inputs": [
        \\        {"name": "from", "type": "address"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parseAbiInfoJsonAlloc(allocator, json);
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("1.0", parsed.abi.version);
    try std.testing.expectEqual(@as(usize, 2), parsed.abi.functions.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.abi.events.len);
    try std.testing.expectEqualStrings("Transfer", parsed.abi.events[0].name);
    try std.testing.expectEqual(@as(u32, 0x11223344), parsed.abi.events[0].opcode.?);
    try std.testing.expectEqual(@as(u32, 0x0f8a7ea5), findFunction(&parsed.abi, "transfer").?.opcode.?);
    try std.testing.expect(findFunction(&parsed.abi, "missing") == null);
}

test "abi adapter builds event selector and resolves event by signature" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "version": "1.0",
        \\  "events": [
        \\    {
        \\      "name": "Transfer",
        \\      "opcode": "0x11223344",
        \\      "inputs": [
        \\        {"name": "from", "type": "address"},
        \\        {"name": "amount", "type": "coins"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parseAbiInfoJsonAlloc(allocator, json);
    defer parsed.deinit(allocator);

    const selector = try buildEventSelectorAlloc(allocator, parsed.abi.events[0]);
    defer allocator.free(selector);

    try std.testing.expectEqualStrings("Transfer(address,coins)", selector);
    try std.testing.expectEqualStrings(
        "Transfer",
        findEvent(&parsed.abi, "Transfer(address,coins)").?.name,
    );
}

test "abi adapter decodes event body from abi by opcode" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "version": "1.0",
        \\  "events": [
        \\    {
        \\      "name": "Transfer",
        \\      "opcode": "0x11223344",
        \\      "inputs": [
        \\        {"name": "from", "type": "address"},
        \\        {"name": "amount", "type": "coins"},
        \\        {"name": "active", "type": "bool"}
        \\      ]
        \\    },
        \\    {
        \\      "name": "Burn",
        \\      "opcode": "0x55667788",
        \\      "inputs": [
        \\        {"name": "amount", "type": "coins"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parseAbiInfoJsonAlloc(allocator, json);
    defer parsed.deinit(allocator);

    var builder = cell.Builder.init();
    try builder.storeUint(0x11223344, 32);
    try builder.storeAddress(@as([]const u8, "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8"));
    try builder.storeCoins(1234);
    try builder.storeUint(1, 1);
    const body = try builder.toCell(allocator);
    defer body.deinit(allocator);
    const body_boc = try boc.serializeBoc(allocator, body);
    defer allocator.free(body_boc);

    const decoded = try decodeEventBodyFromAbiJsonAlloc(allocator, &parsed.abi, null, body_boc);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(
        "{\"from\":\"0:83dfd552e63729b472fcbcc8c45ebcc6691702558b68ec7527e1ba403a0f31a8\",\"amount\":1234,\"active\":true}",
        decoded,
    );
}

test "abi adapter decodes function body from abi by opcode" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "version": "1.0",
        \\  "functions": [
        \\    {
        \\      "name": "transfer",
        \\      "opcode": "0x11223344",
        \\      "inputs": [
        \\        {"name": "to", "type": "address"},
        \\        {"name": "amount", "type": "coins"},
        \\        {"name": "notify", "type": "bool"}
        \\      ]
        \\    },
        \\    {
        \\      "name": "burn",
        \\      "opcode": "0x55667788",
        \\      "inputs": [
        \\        {"name": "amount", "type": "coins"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parseAbiInfoJsonAlloc(allocator, json);
    defer parsed.deinit(allocator);

    const body = try buildFunctionBodyBocAlloc(allocator, parsed.abi.functions[0], &.{
        .{ .text = "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8" },
        .{ .uint = 777 },
        .{ .uint = 1 },
    });
    defer allocator.free(body);

    const function = try resolveFunctionByBodyBoc(&parsed.abi, null, body);
    try std.testing.expectEqualStrings("transfer", function.name);

    const decoded = try decodeFunctionBodyFromAbiJsonAlloc(allocator, &parsed.abi, null, body);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(
        "{\"to\":\"0:83dfd552e63729b472fcbcc8c45ebcc6691702558b68ec7527e1ba403a0f31a8\",\"amount\":777,\"notify\":true}",
        decoded,
    );
}

test "abi adapter decodes function body with ref payload before trailing scalar" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "version": "1.0",
        \\  "functions": [
        \\    {
        \\      "name": "set_payload",
        \\      "opcode": "0xAA55AA55",
        \\      "inputs": [
        \\        {"name": "count", "type": "uint16"},
        \\        {"name": "payload", "type": "ref"},
        \\        {"name": "enabled", "type": "bool"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var payload_builder = cell.Builder.init();
    try payload_builder.storeUint(0xABCD, 16);
    const payload = try payload_builder.toCell(allocator);
    defer payload.deinit(allocator);
    const payload_boc = try boc.serializeBoc(allocator, payload);
    defer allocator.free(payload_boc);
    const payload_b64 = try base64EncodeAlloc(allocator, payload_boc);
    defer allocator.free(payload_b64);

    var parsed = try parseAbiInfoJsonAlloc(allocator, json);
    defer parsed.deinit(allocator);

    const body = try buildFunctionBodyBocAlloc(allocator, parsed.abi.functions[0], &.{
        .{ .uint = 9 },
        .{ .boc = payload_boc },
        .{ .uint = 1 },
    });
    defer allocator.free(body);

    const decoded = try decodeFunctionBodyFromAbiJsonAlloc(allocator, &parsed.abi, null, body);
    defer allocator.free(decoded);

    const expected = try std.fmt.allocPrint(
        allocator,
        "{{\"count\":9,\"payload\":\"{s}\",\"enabled\":true}}",
        .{payload_b64},
    );
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, decoded);
}

test "abi adapter decodes opcode-less function body by explicit selector" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "version": "1.0",
        \\  "functions": [
        \\    {
        \\      "name": "set_config",
        \\      "inputs": [
        \\        {"name": "enabled", "type": "bool"},
        \\        {"name": "limit", "type": "uint32"}
        \\      ]
        \\    },
        \\    {
        \\      "name": "set_config",
        \\      "inputs": [
        \\        {"name": "enabled", "type": "bool"},
        \\        {"name": "owner", "type": "address"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parseAbiInfoJsonAlloc(allocator, json);
    defer parsed.deinit(allocator);

    const selector = "set_config(bool,uint32)";
    const function = findFunction(&parsed.abi, selector).?;
    const body = try buildFunctionBodyBocAlloc(allocator, function.*, &.{
        .{ .uint = 1 },
        .{ .uint = 42 },
    });
    defer allocator.free(body);

    const resolved = try resolveFunctionByBodyBoc(&parsed.abi, selector, body);
    try std.testing.expectEqualStrings("uint32", resolved.inputs[1].type_name);

    const decoded = try decodeFunctionBodyFromAbiJsonAlloc(allocator, &parsed.abi, selector, body);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(
        "{\"enabled\":true,\"limit\":42}",
        decoded,
    );
}

test "abi adapter decodes event body with ref payload before trailing scalar" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "version": "1.0",
        \\  "events": [
        \\    {
        \\      "name": "PayloadSet",
        \\      "opcode": "0x01020304",
        \\      "inputs": [
        \\        {"name": "payload", "type": "ref"},
        \\        {"name": "enabled", "type": "bool"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var payload_builder = cell.Builder.init();
    try payload_builder.storeUint(0xCAFE, 16);
    const payload = try payload_builder.toCell(allocator);
    defer payload.deinit(allocator);
    const payload_boc = try boc.serializeBoc(allocator, payload);
    defer allocator.free(payload_boc);
    const payload_b64 = try base64EncodeAlloc(allocator, payload_boc);
    defer allocator.free(payload_b64);

    var parsed = try parseAbiInfoJsonAlloc(allocator, json);
    defer parsed.deinit(allocator);

    var builder = cell.Builder.init();
    try builder.storeUint(0x01020304, 32);
    try body_builder.storeRefBoc(&builder, allocator, payload_boc);
    try builder.storeUint(1, 1);
    const body_cell = try builder.toCell(allocator);
    defer body_cell.deinit(allocator);
    const body_boc = try boc.serializeBoc(allocator, body_cell);
    defer allocator.free(body_boc);

    const decoded = try decodeEventBodyFromAbiJsonAlloc(allocator, &parsed.abi, null, body_boc);
    defer allocator.free(decoded);

    const expected = try std.fmt.allocPrint(
        allocator,
        "{{\"payload\":\"{s}\",\"enabled\":true}}",
        .{payload_b64},
    );
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, decoded);
}

test "abi adapter resolves overloaded functions by full selector" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "version": "1.0",
        \\  "functions": [
        \\    {
        \\      "name": "transfer",
        \\      "opcode": 1,
        \\      "inputs": [
        \\        {"name": "to", "type": "address"},
        \\        {"name": "amount", "type": "coins"}
        \\      ]
        \\    },
        \\    {
        \\      "name": "transfer",
        \\      "opcode": 2,
        \\      "inputs": [
        \\        {"name": "to", "type": "address"},
        \\        {"name": "amount", "type": "coins"},
        \\        {"name": "memo", "type": "bytes"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parseAbiInfoJsonAlloc(allocator, json);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 1), findFunction(&parsed.abi, "transfer").?.opcode.?);
    try std.testing.expectEqual(@as(u32, 1), findFunction(&parsed.abi, "transfer(address,coins)").?.opcode.?);
    try std.testing.expectEqual(@as(u32, 2), findFunction(&parsed.abi, "transfer(address, coins, bytes)").?.opcode.?);

    const selector = try buildFunctionSelectorAlloc(allocator, findFunction(&parsed.abi, "transfer(address, coins, bytes)").?.*);
    defer allocator.free(selector);
    try std.testing.expectEqualStrings("transfer(address,coins,bytes)", selector);

    const built = try buildFunctionBodyFromAbiAlloc(allocator, &parsed.abi, "transfer(address,coins,bytes)", &.{
        .{ .text = "EQDKbjIcfM6ezt8KjKJJLshZJJSqX7XOA4ff-W72r5gqPrHF" },
        .{ .numeric_text = "1000" },
        .{ .bytes = "memo" },
    });
    defer allocator.free(built);

    const parsed_cell = try boc.deserializeBoc(allocator, built);
    defer parsed_cell.deinit(allocator);

    var slice = parsed_cell.toSlice();
    try std.testing.expectEqual(@as(u64, 2), try slice.loadUint(32));
}

test "abi adapter resolves bare overloaded names by value count and fills optional tail args" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "version": "1.0",
        \\  "functions": [
        \\    {
        \\      "name": "set_flag",
        \\      "opcode": 7,
        \\      "inputs": [
        \\        {"name": "enabled", "type": "bool"}
        \\      ]
        \\    },
        \\    {
        \\      "name": "set_flag",
        \\      "opcode": 9,
        \\      "inputs": [
        \\        {"name": "enabled", "type": "bool"},
        \\        {"name": "memo", "type": "optional<string>"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parseAbiInfoJsonAlloc(allocator, json);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 7), (try resolveFunctionByValueCount(&parsed.abi, "set_flag", 1)).opcode.?);
    try std.testing.expectEqual(@as(u32, 9), (try resolveFunctionByValueCount(&parsed.abi, "set_flag", 2)).opcode.?);
    try std.testing.expectError(error.FunctionNotFound, resolveFunctionByValueCount(&parsed.abi, "set_flag", 0));
}

test "abi adapter fills omitted trailing optional args in body and stack builders" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "version": "1.0",
        \\  "functions": [
        \\    {
        \\      "name": "set_flag",
        \\      "opcode": 9,
        \\      "inputs": [
        \\        {"name": "enabled", "type": "bool"},
        \\        {"name": "memo", "type": "optional<string>"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parseAbiInfoJsonAlloc(allocator, json);
    defer parsed.deinit(allocator);

    const function = try resolveFunctionByValueCount(&parsed.abi, "set_flag", 1);
    const expanded = try expandValuesForFunctionAlloc(allocator, function.*, &.{
        .{ .numeric_text = "1" },
    });
    defer allocator.free(expanded);

    try std.testing.expectEqual(@as(usize, 2), expanded.len);
    try std.testing.expect(std.meta.activeTag(expanded[1]) == .null);

    const built = try buildFunctionBodyFromAbiAlloc(allocator, &parsed.abi, "set_flag", &.{
        .{ .numeric_text = "1" },
    });
    defer allocator.free(built);

    const parsed_cell = try boc.deserializeBoc(allocator, built);
    defer parsed_cell.deinit(allocator);

    var slice = parsed_cell.toSlice();
    try std.testing.expectEqual(@as(u64, 9), try slice.loadUint(32));
    try std.testing.expectEqual(@as(u64, 1), try slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 0), try slice.loadUint(1));

    var stack_args = try buildStackArgsFromAbiAlloc(allocator, &parsed.abi, "set_flag", &.{
        .{ .numeric_text = "1" },
    });
    defer stack_args.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), stack_args.args.len);
    try std.testing.expect(std.meta.activeTag(stack_args.args[1]) == .null);
}

test "abi adapter builds function body boc from schema" {
    const allocator = std.testing.allocator;

    var payload_builder = @import("../core/cell.zig").Builder.init();
    try payload_builder.storeUint(0xAB, 8);
    const payload = try payload_builder.toCell(allocator);
    defer payload.deinit(allocator);

    const payload_boc = try @import("../core/boc.zig").serializeBoc(allocator, payload);
    defer allocator.free(payload_boc);

    const function = FunctionDef{
        .name = "transfer",
        .opcode = 0x12345678,
        .inputs = &.{
            .{ .name = "query_id", .type_name = "uint64" },
            .{ .name = "amount", .type_name = "coins" },
            .{ .name = "recipient", .type_name = "address" },
            .{ .name = "comment", .type_name = "bytes" },
            .{ .name = "payload", .type_name = "ref" },
        },
        .outputs = &.{},
    };

    const built = try buildFunctionBodyBocAlloc(allocator, function, &.{
        .{ .uint = 7 },
        .{ .uint = 10 },
        .{ .text = "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8" },
        .{ .text = "OK" },
        .{ .boc = payload_boc },
    });
    defer allocator.free(built);

    const root = try @import("../core/boc.zig").deserializeBoc(allocator, built);
    defer root.deinit(allocator);

    var slice = root.toSlice();
    try std.testing.expectEqual(@as(u64, 0x12345678), try slice.loadUint(32));
    try std.testing.expectEqual(@as(u64, 7), try slice.loadUint(64));
    try std.testing.expectEqual(@as(u64, 10), try slice.loadCoins());
    _ = try slice.loadAddress();
    try std.testing.expectEqual(@as(u8, 'O'), try slice.loadUint8());
    try std.testing.expectEqual(@as(u8, 'K'), try slice.loadUint8());

    const payload_ref = try slice.loadRef();
    var payload_slice = payload_ref.toSlice();
    try std.testing.expectEqual(@as(u64, 0xAB), try payload_slice.loadUint(8));
}

test "abi adapter builds function body from abi by function name" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "functions": [
        \\    {
        \\      "name": "set_flag",
        \\      "opcode": "0x11223344",
        \\      "inputs": [
        \\        {"name": "enabled", "type": "bool"},
        \\        {"name": "note", "type": "bytes"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parseAbiInfoJsonAlloc(allocator, json);
    defer parsed.deinit(allocator);

    const built = try buildFunctionBodyFromAbiAlloc(allocator, &parsed.abi, "set_flag", &.{
        .{ .uint = 1 },
        .{ .text = "ok" },
    });
    defer allocator.free(built);

    const root = try @import("../core/boc.zig").deserializeBoc(allocator, built);
    defer root.deinit(allocator);

    var slice = root.toSlice();
    try std.testing.expectEqual(@as(u64, 0x11223344), try slice.loadUint(32));
    try std.testing.expectEqual(@as(u64, 1), try slice.loadUint(1));
    try std.testing.expectEqual(@as(u8, 'o'), try slice.loadUint8());
    try std.testing.expectEqual(@as(u8, 'k'), try slice.loadUint8());
}

test "abi adapter supports fixed bytes in body encoding" {
    const allocator = std.testing.allocator;
    const abi_json =
        \\{
        \\  "functions": [
        \\    {
        \\      "name": "set_hashes",
        \\      "opcode": "0x55667788",
        \\      "inputs": [
        \\        {"name": "hash", "type": "bytes32"},
        \\        {"name": "salt", "type": "fixedbytes<4>"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var abi = try parseAbiInfoJsonAlloc(allocator, abi_json);
    defer abi.deinit(allocator);

    const hash_bytes = [_]u8{
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        0x10, 0x21, 0x32, 0x43, 0x54, 0x65, 0x76, 0x87,
        0x98, 0xA9, 0xBA, 0xCB, 0xDC, 0xED, 0xFE, 0x0F,
    };
    const salt_bytes = [_]u8{ 0xCA, 0xFE, 0xBA, 0xBE };

    const built = try buildFunctionBodyFromAbiAlloc(allocator, &abi.abi, "set_hashes", &.{
        .{ .bytes = hash_bytes[0..] },
        .{ .bytes = salt_bytes[0..] },
    });
    defer allocator.free(built);

    const root = try boc.deserializeBoc(allocator, built);
    defer root.deinit(allocator);

    var slice = root.toSlice();
    try std.testing.expectEqual(@as(u64, 0x55667788), try slice.loadUint(32));
    try std.testing.expectEqualSlices(u8, hash_bytes[0..], try slice.loadBits(hash_bytes.len * 8));
    try std.testing.expectEqualSlices(u8, salt_bytes[0..], try slice.loadBits(salt_bytes.len * 8));
}

test "abi adapter builds tuple body from json abi value" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "functions": [
        \\    {
        \\      "name": "set_config",
        \\      "opcode": "0x10203040",
        \\      "inputs": [
        \\        {
        \\          "name": "config",
        \\          "type": "tuple",
        \\          "components": [
        \\            {"name": "enabled", "type": "bool"},
        \\            {"name": "owner", "type": "address"},
        \\            {"name": "label", "type": "optional<string>"}
        \\          ]
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parseAbiInfoJsonAlloc(allocator, json);
    defer parsed.deinit(allocator);

    const built = try buildFunctionBodyFromAbiAlloc(allocator, &parsed.abi, "set_config", &.{
        .{ .json = "{\"enabled\":true,\"owner\":\"0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8\",\"label\":\"demo\"}" },
    });
    defer allocator.free(built);

    const root = try boc.deserializeBoc(allocator, built);
    defer root.deinit(allocator);

    var slice = root.toSlice();
    try std.testing.expectEqual(@as(u64, 0x10203040), try slice.loadUint(32));
    try std.testing.expectEqual(@as(u64, 1), try slice.loadUint(1));
    _ = try slice.loadAddress();
    try std.testing.expectEqual(@as(u64, 1), try slice.loadUint(1));
    try std.testing.expectEqual(@as(u8, 'd'), try slice.loadUint8());
    try std.testing.expectEqual(@as(u8, 'e'), try slice.loadUint8());
    try std.testing.expectEqual(@as(u8, 'm'), try slice.loadUint8());
    try std.testing.expectEqual(@as(u8, 'o'), try slice.loadUint8());
}

test "abi adapter builds composite body from json bytes and boc leaves" {
    const allocator = std.testing.allocator;

    var inline_builder = cell.Builder.init();
    try inline_builder.storeUint(0xABCD, 16);
    const inline_cell = try inline_builder.toCell(allocator);
    defer inline_cell.deinit(allocator);
    const inline_boc = try boc.serializeBoc(allocator, inline_cell);
    defer allocator.free(inline_boc);
    const inline_b64 = try base64EncodeAlloc(allocator, inline_boc);
    defer allocator.free(inline_b64);

    var ref_builder = cell.Builder.init();
    try ref_builder.storeUint(0xCAFE, 16);
    const ref_cell = try ref_builder.toCell(allocator);
    defer ref_cell.deinit(allocator);
    const ref_boc = try boc.serializeBoc(allocator, ref_cell);
    defer allocator.free(ref_boc);
    const ref_b64 = try base64EncodeAlloc(allocator, ref_boc);
    defer allocator.free(ref_b64);

    const payload_json = try std.fmt.allocPrint(
        allocator,
        "{{\"tag\":7,\"data\":{{\"hex\":\"CAFE\"}},\"body\":{{\"boc\":\"{s}\"}},\"nested\":{{\"boc\":\"{s}\"}}}}",
        .{ inline_b64, ref_b64 },
    );
    defer allocator.free(payload_json);

    const function = FunctionDef{
        .name = "set_payload",
        .opcode = 0x55667788,
        .inputs = &.{
            .{
                .name = "payload",
                .type_name = "tuple",
                .components = &.{
                    .{ .name = "tag", .type_name = "uint8" },
                    .{ .name = "data", .type_name = "bytes" },
                    .{ .name = "body", .type_name = "slice" },
                    .{ .name = "nested", .type_name = "ref" },
                },
            },
        },
        .outputs = &.{},
    };

    const built = try buildFunctionBodyBocAlloc(allocator, function, &.{
        .{ .json = payload_json },
    });
    defer allocator.free(built);

    const root = try boc.deserializeBoc(allocator, built);
    defer root.deinit(allocator);

    var slice = root.toSlice();
    try std.testing.expectEqual(@as(u64, 0x55667788), try slice.loadUint(32));
    try std.testing.expectEqual(@as(u64, 7), try slice.loadUint(8));
    try std.testing.expectEqual(@as(u8, 0xCA), try slice.loadUint8());
    try std.testing.expectEqual(@as(u8, 0xFE), try slice.loadUint8());
    try std.testing.expectEqual(@as(u64, 0xABCD), try slice.loadUint(16));

    const nested_ref = try slice.loadRef();
    var nested_slice = nested_ref.toSlice();
    try std.testing.expectEqual(@as(u64, 0xCAFE), try nested_slice.loadUint(16));
}

test "abi adapter supports dict aliases in body encoding" {
    const allocator = std.testing.allocator;

    var inline_builder = cell.Builder.init();
    try inline_builder.storeUint(0xBEEF, 16);
    const inline_cell = try inline_builder.toCell(allocator);
    defer inline_cell.deinit(allocator);
    const inline_boc = try boc.serializeBoc(allocator, inline_cell);
    defer allocator.free(inline_boc);

    var ref_builder = cell.Builder.init();
    try ref_builder.storeUint(0xCAFE, 16);
    const ref_cell = try ref_builder.toCell(allocator);
    defer ref_cell.deinit(allocator);
    const ref_boc = try boc.serializeBoc(allocator, ref_cell);
    defer allocator.free(ref_boc);

    const function = FunctionDef{
        .name = "set_dicts",
        .opcode = 0x44556677,
        .inputs = &.{
            .{ .name = "settings", .type_name = "HashmapE<32, uint32>" },
            .{ .name = "cache", .type_name = "map_ref<address, cell>" },
        },
        .outputs = &.{},
    };

    const built = try buildFunctionBodyBocAlloc(allocator, function, &.{
        .{ .boc = inline_boc },
        .{ .boc = ref_boc },
    });
    defer allocator.free(built);

    const root = try boc.deserializeBoc(allocator, built);
    defer root.deinit(allocator);

    var slice = root.toSlice();
    try std.testing.expectEqual(@as(u64, 0x44556677), try slice.loadUint(32));
    try std.testing.expectEqual(@as(u64, 0xBEEF), try slice.loadUint(16));

    const cache_ref = try slice.loadRef();
    var cache_slice = cache_ref.toSlice();
    try std.testing.expectEqual(@as(u64, 0xCAFE), try cache_slice.loadUint(16));
}

test "abi adapter builds stack args and decodes outputs for abi function" {
    const allocator = std.testing.allocator;
    const abi_json =
        \\{
        \\  "functions": [
        \\    {
        \\      "name": "get_data",
        \\      "inputs": [
        \\        {"name": "owner", "type": "address"},
        \\        {"name": "index", "type": "uint32"}
        \\      ],
        \\      "outputs": [
        \\        {"name": "enabled", "type": "bool"},
        \\        {"name": "owner", "type": "address"},
        \\        {"name": "name", "type": "string"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var abi = try parseAbiInfoJsonAlloc(allocator, abi_json);
    defer abi.deinit(allocator);

    var args = try buildStackArgsFromAbiAlloc(allocator, &abi.abi, "get_data", &.{
        .{ .text = "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8" },
        .{ .uint = 7 },
    });
    defer args.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), args.args.len);
    try std.testing.expect(args.args[0] == .address);
    try std.testing.expectEqual(@as(i64, 7), args.args[1].int);

    var owner_builder = @import("../core/cell.zig").Builder.init();
    try owner_builder.storeAddress(@as([]const u8, "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8"));
    const owner_cell = try owner_builder.toCell(allocator);
    defer owner_cell.deinit(allocator);

    var name_builder = @import("../core/cell.zig").Builder.init();
    try name_builder.storeBits("demo", 32);
    const name_cell = try name_builder.toCell(allocator);
    defer name_cell.deinit(allocator);

    const stack = [_]types.StackEntry{
        .{ .number = 1 },
        .{ .slice = owner_cell },
        .{ .cell = name_cell },
    };

    const decoded = try decodeFunctionOutputsFromAbiJsonAlloc(allocator, &abi.abi, "get_data", stack[0..]);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(
        "{\"enabled\":true,\"owner\":\"0:83dfd552e63729b472fcbcc8c45ebcc6691702558b68ec7527e1ba403a0f31a8\",\"name\":\"demo\"}",
        decoded,
    );
}

test "abi adapter supports optional inputs in body encoding" {
    const allocator = std.testing.allocator;

    var payload_builder = cell.Builder.init();
    try payload_builder.storeUint(0xCAFE, 16);
    const payload = try payload_builder.toCell(allocator);
    defer payload.deinit(allocator);

    const payload_boc = try boc.serializeBoc(allocator, payload);
    defer allocator.free(payload_boc);

    const function = FunctionDef{
        .name = "set_optional",
        .opcode = 0xA1B2C3D4,
        .inputs = &.{
            .{ .name = "count", .type_name = "maybe<uint8>" },
            .{ .name = "owner", .type_name = "optional<address>" },
            .{ .name = "note", .type_name = "maybe<string>" },
            .{ .name = "payload", .type_name = "optional<ref>" },
        },
        .outputs = &.{},
    };

    const built = try buildFunctionBodyBocAlloc(allocator, function, &.{
        .{ .uint = 7 },
        .{ .text = "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8" },
        .{ .text = "ok" },
        .{ .boc = payload_boc },
    });
    defer allocator.free(built);

    const root = try boc.deserializeBoc(allocator, built);
    defer root.deinit(allocator);

    var slice = root.toSlice();
    try std.testing.expectEqual(@as(u64, 0xA1B2C3D4), try slice.loadUint(32));
    try std.testing.expectEqual(@as(u64, 1), try slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 7), try slice.loadUint(8));
    try std.testing.expectEqual(@as(u64, 1), try slice.loadUint(1));
    _ = try slice.loadAddress();
    try std.testing.expectEqual(@as(u64, 1), try slice.loadUint(1));
    try std.testing.expectEqual(@as(u8, 'o'), try slice.loadUint8());
    try std.testing.expectEqual(@as(u8, 'k'), try slice.loadUint8());
    try std.testing.expectEqual(@as(u64, 1), try slice.loadUint(1));

    const payload_ref = try slice.loadRef();
    var payload_slice = payload_ref.toSlice();
    try std.testing.expectEqual(@as(u64, 0xCAFE), try payload_slice.loadUint(16));
}

test "abi adapter supports large numeric text in body encoding" {
    const allocator = std.testing.allocator;

    const function = FunctionDef{
        .name = "set_big",
        .opcode = 0x99AABBCC,
        .inputs = &.{
            .{ .name = "nonce", .type_name = "uint128" },
            .{ .name = "amount", .type_name = "coins" },
        },
        .outputs = &.{},
    };

    const built = try buildFunctionBodyBocAlloc(allocator, function, &.{
        .{ .numeric_text = "0x1234567890abcdef1234567890abcdef" },
        .{ .numeric_text = "0x0102030405060708090A0B0C0D0E0F" },
    });
    defer allocator.free(built);

    const root = try boc.deserializeBoc(allocator, built);
    defer root.deinit(allocator);

    var slice = root.toSlice();
    try std.testing.expectEqual(@as(u64, 0x99AABBCC), try slice.loadUint(32));
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF, 0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF }, try slice.loadBits(128));
    try std.testing.expectEqual(@as(u64, 15), try slice.loadUint(4));
    for ([_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F }) |byte| {
        try std.testing.expectEqual(byte, try slice.loadUint8());
    }
}

test "abi adapter supports signed large numeric text in body encoding" {
    const allocator = std.testing.allocator;
    const expected = [_]u8{0xFF} ** 16;

    const function = FunctionDef{
        .name = "set_delta",
        .opcode = 0x77889900,
        .inputs = &.{
            .{ .name = "delta", .type_name = "int128" },
        },
        .outputs = &.{},
    };

    const built = try buildFunctionBodyBocAlloc(allocator, function, &.{
        .{ .numeric_text = "-1" },
    });
    defer allocator.free(built);

    const root = try boc.deserializeBoc(allocator, built);
    defer root.deinit(allocator);

    var slice = root.toSlice();
    try std.testing.expectEqual(@as(u64, 0x77889900), try slice.loadUint(32));
    try std.testing.expectEqualSlices(u8, &expected, try slice.loadBits(128));
}

test "abi adapter supports direct small values for large integer body encoding" {
    const allocator = std.testing.allocator;
    const expected_unsigned = [_]u8{
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x2A,
    };
    const expected_signed = [_]u8{
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xF9,
    };

    const function = FunctionDef{
        .name = "set_direct_big",
        .opcode = 0x55667788,
        .inputs = &.{
            .{ .name = "nonce", .type_name = "uint128" },
            .{ .name = "delta", .type_name = "int128" },
        },
        .outputs = &.{},
    };

    const built = try buildFunctionBodyBocAlloc(allocator, function, &.{
        .{ .uint = 42 },
        .{ .int = -7 },
    });
    defer allocator.free(built);

    const root = try boc.deserializeBoc(allocator, built);
    defer root.deinit(allocator);

    var slice = root.toSlice();
    try std.testing.expectEqual(@as(u64, 0x55667788), try slice.loadUint(32));
    try std.testing.expectEqualSlices(u8, &expected_unsigned, try slice.loadBits(128));
    try std.testing.expectEqualSlices(u8, &expected_signed, try slice.loadBits(128));
}

test "abi adapter supports big numeric json leaves in body encoding" {
    const allocator = std.testing.allocator;
    const expected_negative = [_]u8{0xFF} ** 16;

    const function = FunctionDef{
        .name = "set_config",
        .opcode = 0xCAFEBABE,
        .inputs = &.{
            .{
                .name = "config",
                .type_name = "tuple",
                .components = &.{
                    .{ .name = "supply", .type_name = "uint128" },
                    .{ .name = "delta", .type_name = "int128" },
                },
            },
        },
        .outputs = &.{},
    };

    const built = try buildFunctionBodyBocAlloc(allocator, function, &.{
        .{ .json = "{\"supply\":\"0x1234567890abcdef1234567890abcdef\",\"delta\":\"-1\"}" },
    });
    defer allocator.free(built);

    const root = try boc.deserializeBoc(allocator, built);
    defer root.deinit(allocator);

    var slice = root.toSlice();
    try std.testing.expectEqual(@as(u64, 0xCAFEBABE), try slice.loadUint(32));
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF, 0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF }, try slice.loadBits(128));
    try std.testing.expectEqualSlices(u8, &expected_negative, try slice.loadBits(128));
}

test "abi adapter supports small integer json leaves for large integer body encoding" {
    const allocator = std.testing.allocator;
    const expected_unsigned = [_]u8{
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x2A,
    };
    const expected_signed = [_]u8{
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xF9,
    };

    const function = FunctionDef{
        .name = "set_json_config",
        .opcode = 0xCAFED00D,
        .inputs = &.{
            .{
                .name = "config",
                .type_name = "tuple",
                .components = &.{
                    .{ .name = "supply", .type_name = "uint128" },
                    .{ .name = "delta", .type_name = "int128" },
                },
            },
        },
        .outputs = &.{},
    };

    const built = try buildFunctionBodyBocAlloc(allocator, function, &.{
        .{ .json = "{\"supply\":42,\"delta\":-7}" },
    });
    defer allocator.free(built);

    const root = try boc.deserializeBoc(allocator, built);
    defer root.deinit(allocator);

    var slice = root.toSlice();
    try std.testing.expectEqual(@as(u64, 0xCAFED00D), try slice.loadUint(32));
    try std.testing.expectEqualSlices(u8, &expected_unsigned, try slice.loadBits(128));
    try std.testing.expectEqualSlices(u8, &expected_signed, try slice.loadBits(128));
}

test "abi adapter supports scalar and tuple arrays in body encoding" {
    const allocator = std.testing.allocator;

    const function = FunctionDef{
        .name = "set_many",
        .opcode = 0x13572468,
        .inputs = &.{
            .{ .name = "values", .type_name = "uint16[]" },
            .{
                .name = "configs",
                .type_name = "tuple[]",
                .components = &.{
                    .{ .name = "enabled", .type_name = "bool" },
                    .{ .name = "index", .type_name = "uint8" },
                },
            },
        },
        .outputs = &.{},
    };

    const built = try buildFunctionBodyBocAlloc(allocator, function, &.{
        .{ .json = "[1,2,3]" },
        .{ .json = "[{\"enabled\":true,\"index\":7},{\"enabled\":false,\"index\":9}]" },
    });
    defer allocator.free(built);

    const root = try boc.deserializeBoc(allocator, built);
    defer root.deinit(allocator);

    var slice = root.toSlice();
    try std.testing.expectEqual(@as(u64, 0x13572468), try slice.loadUint(32));

    try std.testing.expectEqual(@as(u64, 3), try slice.loadUint(abi_array_length_bits));
    try std.testing.expectEqual(@as(u64, 1), try slice.loadUint(16));
    try std.testing.expectEqual(@as(u64, 2), try slice.loadUint(16));
    try std.testing.expectEqual(@as(u64, 3), try slice.loadUint(16));

    try std.testing.expectEqual(@as(u64, 2), try slice.loadUint(abi_array_length_bits));
    try std.testing.expectEqual(@as(u64, 1), try slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 7), try slice.loadUint(8));
    try std.testing.expectEqual(@as(u64, 0), try slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 9), try slice.loadUint(8));
}

test "abi adapter supports optional and string stack args" {
    const allocator = std.testing.allocator;
    const abi_json =
        \\{
        \\  "functions": [
        \\    {
        \\      "name": "lookup",
        \\      "inputs": [
        \\        {"name": "key", "type": "string"},
        \\        {"name": "owner", "type": "optional<address>"},
        \\        {"name": "tag", "type": "maybe<bytes>"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var abi = try parseAbiInfoJsonAlloc(allocator, abi_json);
    defer abi.deinit(allocator);

    var args = try buildStackArgsFromAbiAlloc(allocator, &abi.abi, "lookup", &.{
        .{ .text = "demo" },
        .{ .null = {} },
        .{ .bytes = &.{ 0xCA, 0xFE } },
    });
    defer args.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), args.args.len);
    try std.testing.expect(args.args[0] == .slice);
    try std.testing.expect(args.args[1] == .null);
    try std.testing.expect(args.args[2] == .slice);
    try std.testing.expect(args.owned_buffers[0] != null);
    try std.testing.expect(args.owned_buffers[2] != null);

    const first = try boc.deserializeBoc(allocator, args.args[0].slice);
    defer first.deinit(allocator);
    var first_slice = first.toSlice();
    try std.testing.expectEqualSlices(u8, "demo", try first_slice.loadBits(32));

    const third = try boc.deserializeBoc(allocator, args.args[2].slice);
    defer third.deinit(allocator);
    var third_slice = third.toSlice();
    try std.testing.expectEqualSlices(u8, &.{ 0xCA, 0xFE }, try third_slice.loadBits(16));
}

test "abi adapter supports fixed bytes stack args" {
    const allocator = std.testing.allocator;
    const abi_json =
        \\{
        \\  "functions": [
        \\    {
        \\      "name": "lookup_hash",
        \\      "inputs": [
        \\        {"name": "hash", "type": "fixedbytes32"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var abi = try parseAbiInfoJsonAlloc(allocator, abi_json);
    defer abi.deinit(allocator);

    const hash_bytes = [_]u8{
        0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33,
        0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB,
        0xCC, 0xDD, 0xEE, 0xFF, 0x13, 0x24, 0x35, 0x46,
        0x57, 0x68, 0x79, 0x8A, 0x9B, 0xAC, 0xBD, 0xCE,
    };

    var args = try buildStackArgsFromAbiAlloc(allocator, &abi.abi, "lookup_hash", &.{
        .{ .bytes = hash_bytes[0..] },
    });
    defer args.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), args.args.len);
    try std.testing.expect(args.args[0] == .slice);
    try std.testing.expect(args.owned_buffers[0] != null);

    const cell_value = try boc.deserializeBoc(allocator, args.args[0].slice);
    defer cell_value.deinit(allocator);
    var slice = cell_value.toSlice();
    try std.testing.expectEqualSlices(u8, hash_bytes[0..], try slice.loadBits(hash_bytes.len * 8));
}

test "abi adapter supports large numeric text stack args" {
    const allocator = std.testing.allocator;
    const abi_json =
        \\{
        \\  "functions": [
        \\    {
        \\      "name": "lookup_big",
        \\      "inputs": [
        \\        {"name": "nonce", "type": "uint128"},
        \\        {"name": "amount", "type": "coins"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var abi = try parseAbiInfoJsonAlloc(allocator, abi_json);
    defer abi.deinit(allocator);

    var args = try buildStackArgsFromAbiAlloc(allocator, &abi.abi, "lookup_big", &.{
        .{ .numeric_text = "0x1234567890abcdef1234567890abcdef" },
        .{ .numeric_text = "0x0102030405060708090A0B0C0D0E0F" },
    });
    defer args.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), args.args.len);
    try std.testing.expect(args.args[0] == .raw_json);
    try std.testing.expect(args.args[1] == .raw_json);
    try std.testing.expectEqualStrings("[\"num\",\"0x1234567890ABCDEF1234567890ABCDEF\"]", args.args[0].raw_json);
    try std.testing.expectEqualStrings("[\"num\",\"0x0102030405060708090A0B0C0D0E0F\"]", args.args[1].raw_json);
}

test "abi adapter supports direct small values for large integer stack args" {
    const allocator = std.testing.allocator;
    const abi_json =
        \\{
        \\  "functions": [
        \\    {
        \\      "name": "lookup_direct_big",
        \\      "inputs": [
        \\        {"name": "nonce", "type": "uint128"},
        \\        {"name": "delta", "type": "int128"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var abi = try parseAbiInfoJsonAlloc(allocator, abi_json);
    defer abi.deinit(allocator);

    var args = try buildStackArgsFromAbiAlloc(allocator, &abi.abi, "lookup_direct_big", &.{
        .{ .uint = 42 },
        .{ .int = -7 },
    });
    defer args.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), args.args.len);
    try std.testing.expect(args.args[0] == .raw_json);
    try std.testing.expect(args.args[1] == .raw_json);
    try std.testing.expectEqualStrings("[\"num\",\"0x2A\"]", args.args[0].raw_json);
    try std.testing.expectEqualStrings("[\"num\",\"-0x07\"]", args.args[1].raw_json);
}

test "abi adapter supports direct u64 stack args above i64 max" {
    const allocator = std.testing.allocator;
    const abi_json =
        \\{
        \\  "functions": [
        \\    {
        \\      "name": "lookup_u64",
        \\      "inputs": [
        \\        {"name": "value", "type": "uint64"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var abi = try parseAbiInfoJsonAlloc(allocator, abi_json);
    defer abi.deinit(allocator);

    var args = try buildStackArgsFromAbiAlloc(allocator, &abi.abi, "lookup_u64", &.{
        .{ .uint = std.math.maxInt(u64) },
    });
    defer args.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), args.args.len);
    try std.testing.expect(args.args[0] == .raw_json);
    try std.testing.expectEqualStrings("[\"num\",\"0xFFFFFFFFFFFFFFFF\"]", args.args[0].raw_json);
}

test "abi adapter supports big numeric json leaves in stack args" {
    const allocator = std.testing.allocator;
    const abi_json =
        \\{
        \\  "functions": [
        \\    {
        \\      "name": "lookup_big_tuple",
        \\      "inputs": [
        \\        {
        \\          "name": "config",
        \\          "type": "tuple",
        \\          "components": [
        \\            {"name": "nonce", "type": "uint128"},
        \\            {"name": "delta", "type": "int128"}
        \\          ]
        \\        }
        \\      ]
        \\    },
        \\    {
        \\      "name": "lookup_big_list",
        \\      "inputs": [
        \\        {"name": "values", "type": "uint128[]"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var abi = try parseAbiInfoJsonAlloc(allocator, abi_json);
    defer abi.deinit(allocator);

    var tuple_args = try buildStackArgsFromAbiAlloc(allocator, &abi.abi, "lookup_big_tuple", &.{
        .{ .json = "{\"nonce\":\"0x1234567890abcdef1234567890abcdef\",\"delta\":\"-1\"}" },
    });
    defer tuple_args.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), tuple_args.args.len);
    try std.testing.expect(tuple_args.args[0] == .raw_json);
    try std.testing.expect(std.mem.indexOf(u8, tuple_args.args[0].raw_json, "[\"num\",\"0x1234567890ABCDEF1234567890ABCDEF\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, tuple_args.args[0].raw_json, "[\"num\",\"-0x01\"]") != null);

    var list_args = try buildStackArgsFromAbiAlloc(allocator, &abi.abi, "lookup_big_list", &.{
        .{ .json = "[\"0x01\",\"0x02030405060708090A0B0C0D0E0F10\"]" },
    });
    defer list_args.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), list_args.args.len);
    try std.testing.expect(list_args.args[0] == .raw_json);
    try std.testing.expect(std.mem.indexOf(u8, list_args.args[0].raw_json, "[\"num\",\"0x01\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_args.args[0].raw_json, "[\"num\",\"0x02030405060708090A0B0C0D0E0F10\"]") != null);
}

test "abi adapter supports dict aliases in stack args" {
    const allocator = std.testing.allocator;
    const abi_json =
        \\{
        \\  "functions": [
        \\    {
        \\      "name": "lookup_dicts",
        \\      "inputs": [
        \\        {"name": "settings", "type": "dict<address,uint32>"},
        \\        {"name": "cache", "type": "HashmapE_ref<32,cell>"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var abi = try parseAbiInfoJsonAlloc(allocator, abi_json);
    defer abi.deinit(allocator);

    var dict_builder = cell.Builder.init();
    try dict_builder.storeUint(0xABCD, 16);
    const dict_cell = try dict_builder.toCell(allocator);
    defer dict_cell.deinit(allocator);
    const dict_boc = try boc.serializeBoc(allocator, dict_cell);
    defer allocator.free(dict_boc);

    var args = try buildStackArgsFromAbiAlloc(allocator, &abi.abi, "lookup_dicts", &.{
        .{ .boc = dict_boc },
        .{ .boc = dict_boc },
    });
    defer args.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), args.args.len);
    try std.testing.expect(args.args[0] == .cell);
    try std.testing.expect(args.args[1] == .cell);
    try std.testing.expectEqualSlices(u8, dict_boc, args.args[0].cell);
    try std.testing.expectEqualSlices(u8, dict_boc, args.args[1].cell);
}

test "abi adapter builds tuple and list get-method stack args from json" {
    const allocator = std.testing.allocator;
    const abi_json =
        \\{
        \\  "functions": [
        \\    {
        \\      "name": "lookup_tuple",
        \\      "inputs": [
        \\        {
        \\          "name": "config",
        \\          "type": "tuple",
        \\          "components": [
        \\            {"name": "enabled", "type": "bool"},
        \\            {"name": "owner", "type": "address"},
        \\            {"name": "label", "type": "optional<string>"}
        \\          ]
        \\        }
        \\      ]
        \\    },
        \\    {
        \\      "name": "lookup_list",
        \\      "inputs": [
        \\        {
        \\          "name": "items",
        \\          "type": "list",
        \\          "components": [
        \\            {"name": "enabled", "type": "bool"},
        \\            {"name": "index", "type": "uint32"}
        \\          ]
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var abi = try parseAbiInfoJsonAlloc(allocator, abi_json);
    defer abi.deinit(allocator);

    var tuple_args = try buildStackArgsFromAbiAlloc(allocator, &abi.abi, "lookup_tuple", &.{
        .{ .json = "{\"enabled\":true,\"owner\":\"0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8\",\"label\":\"demo\"}" },
    });
    defer tuple_args.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), tuple_args.args.len);
    try std.testing.expect(tuple_args.args[0] == .raw_json);
    try std.testing.expect(std.mem.startsWith(u8, tuple_args.args[0].raw_json, "[\"tuple\",["));
    try std.testing.expect(std.mem.indexOf(u8, tuple_args.args[0].raw_json, "[\"num\",1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, tuple_args.args[0].raw_json, "[\"slice\",\"") != null);

    var list_args = try buildStackArgsFromAbiAlloc(allocator, &abi.abi, "lookup_list", &.{
        .{ .json = "[true,7]" },
    });
    defer list_args.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), list_args.args.len);
    try std.testing.expect(list_args.args[0] == .raw_json);
    try std.testing.expectEqualStrings("[\"list\",[[\"num\",1],[\"num\",7]]]", list_args.args[0].raw_json);
}

test "abi adapter builds get-method stack args from json hex and boc leaves" {
    const allocator = std.testing.allocator;
    const abi_json =
        \\{
        \\  "functions": [
        \\    {
        \\      "name": "lookup_payload",
        \\      "inputs": [
        \\        {
        \\          "name": "payload",
        \\          "type": "tuple",
        \\          "components": [
        \\            {"name": "data", "type": "bytes"},
        \\            {"name": "body", "type": "slice"},
        \\            {"name": "code", "type": "builder"}
        \\          ]
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var abi = try parseAbiInfoJsonAlloc(allocator, abi_json);
    defer abi.deinit(allocator);

    var payload_builder = cell.Builder.init();
    try payload_builder.storeUint(0xBEEF, 16);
    const payload_cell = try payload_builder.toCell(allocator);
    defer payload_cell.deinit(allocator);
    const payload_boc = try boc.serializeBoc(allocator, payload_cell);
    defer allocator.free(payload_boc);
    const payload_b64 = try base64EncodeAlloc(allocator, payload_boc);
    defer allocator.free(payload_b64);

    const value_json = try std.fmt.allocPrint(
        allocator,
        "{{\"data\":{{\"hex\":\"CAFE\"}},\"body\":{{\"boc\":\"{s}\"}},\"code\":{{\"boc\":\"{s}\"}}}}",
        .{ payload_b64, payload_b64 },
    );
    defer allocator.free(value_json);

    var args = try buildStackArgsFromAbiAlloc(allocator, &abi.abi, "lookup_payload", &.{
        .{ .json = value_json },
    });
    defer args.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), args.args.len);
    try std.testing.expect(args.args[0] == .raw_json);
    try std.testing.expect(std.mem.startsWith(u8, args.args[0].raw_json, "[\"tuple\",[[\"slice\",\""));
    try std.testing.expect(std.mem.indexOf(u8, args.args[0].raw_json, "[\"slice\",\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, args.args[0].raw_json, "[\"builder\",\"") != null);
}

test "abi adapter builds scalar and tuple array get-method stack args from json" {
    const allocator = std.testing.allocator;
    const abi_json =
        \\{
        \\  "functions": [
        \\    {
        \\      "name": "sum_many",
        \\      "inputs": [
        \\        {"name": "values", "type": "uint32[]"}
        \\      ]
        \\    },
        \\    {
        \\      "name": "lookup_many",
        \\      "inputs": [
        \\        {
        \\          "name": "items",
        \\          "type": "tuple[]",
        \\          "components": [
        \\            {"name": "enabled", "type": "bool"},
        \\            {"name": "owner", "type": "address"}
        \\          ]
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var abi = try parseAbiInfoJsonAlloc(allocator, abi_json);
    defer abi.deinit(allocator);

    var scalar_args = try buildStackArgsFromAbiAlloc(allocator, &abi.abi, "sum_many", &.{
        .{ .json = "[1,2,3]" },
    });
    defer scalar_args.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), scalar_args.args.len);
    try std.testing.expect(scalar_args.args[0] == .raw_json);
    try std.testing.expectEqualStrings("[\"list\",[[\"num\",1],[\"num\",2],[\"num\",3]]]", scalar_args.args[0].raw_json);

    var tuple_args = try buildStackArgsFromAbiAlloc(allocator, &abi.abi, "lookup_many", &.{
        .{ .json = "[{\"enabled\":true,\"owner\":\"0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8\"},{\"enabled\":false,\"owner\":\"0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8\"}]" },
    });
    defer tuple_args.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), tuple_args.args.len);
    try std.testing.expect(tuple_args.args[0] == .raw_json);
    try std.testing.expect(std.mem.startsWith(
        u8,
        tuple_args.args[0].raw_json,
        "[\"list\",[[\"tuple\",[[\"num\",1],[\"slice\",\"",
    ));
    try std.testing.expect(std.mem.indexOf(u8, tuple_args.args[0].raw_json, "[\"tuple\",[[\"num\",0],[\"slice\",\"") != null);
}

test "abi adapter decodes optional outputs" {
    const allocator = std.testing.allocator;
    const abi_json =
        \\{
        \\  "functions": [
        \\    {
        \\      "name": "get_optional",
        \\      "outputs": [
        \\        {"name": "count", "type": "optional<uint32>"},
        \\        {"name": "owner", "type": "maybe<address>"},
        \\        {"name": "note", "type": "optional<string>"},
        \\        {"name": "blob", "type": "maybe<bytes>"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var abi = try parseAbiInfoJsonAlloc(allocator, abi_json);
    defer abi.deinit(allocator);

    var owner_builder = cell.Builder.init();
    try owner_builder.storeAddress(@as([]const u8, "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8"));
    const owner_cell = try owner_builder.toCell(allocator);
    defer owner_cell.deinit(allocator);

    var note_builder = cell.Builder.init();
    try note_builder.storeBits("demo", 32);
    const note_cell = try note_builder.toCell(allocator);
    defer note_cell.deinit(allocator);

    const stack = [_]types.StackEntry{
        .{ .null = {} },
        .{ .slice = owner_cell },
        .{ .cell = note_cell },
        .{ .bytes = &.{ 0xCA, 0xFE } },
    };

    const decoded = try decodeFunctionOutputsFromAbiJsonAlloc(allocator, &abi.abi, "get_optional", stack[0..]);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(
        "{\"count\":null,\"owner\":\"0:83dfd552e63729b472fcbcc8c45ebcc6691702558b68ec7527e1ba403a0f31a8\",\"note\":\"demo\",\"blob\":\"yv4=\"}",
        decoded,
    );
}

test "abi adapter decodes tuple outputs using component schema" {
    const allocator = std.testing.allocator;
    const abi_json =
        \\{
        \\  "functions": [
        \\    {
        \\      "name": "get_config",
        \\      "outputs": [
        \\        {
        \\          "name": "config",
        \\          "type": "tuple",
        \\          "components": [
        \\            {"name": "enabled", "type": "bool"},
        \\            {"name": "owner", "type": "address"},
        \\            {"name": "label", "type": "optional<string>"}
        \\          ]
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var abi = try parseAbiInfoJsonAlloc(allocator, abi_json);
    defer abi.deinit(allocator);

    var owner_builder = cell.Builder.init();
    try owner_builder.storeAddress(@as([]const u8, "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8"));
    const owner_cell = try owner_builder.toCell(allocator);
    defer owner_cell.deinit(allocator);

    var label_builder = cell.Builder.init();
    try label_builder.storeBits("demo", 32);
    const label_cell = try label_builder.toCell(allocator);
    defer label_cell.deinit(allocator);

    var tuple_items = [_]types.StackEntry{
        .{ .number = 1 },
        .{ .slice = owner_cell },
        .{ .cell = label_cell },
    };
    const stack = [_]types.StackEntry{
        .{ .tuple = tuple_items[0..] },
    };

    const decoded = try decodeFunctionOutputsFromAbiJsonAlloc(allocator, &abi.abi, "get_config", stack[0..]);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(
        "{\"config\":{\"enabled\":true,\"owner\":\"0:83dfd552e63729b472fcbcc8c45ebcc6691702558b68ec7527e1ba403a0f31a8\",\"label\":\"demo\"}}",
        decoded,
    );
}

test "abi adapter decodes scalar and tuple array outputs" {
    const allocator = std.testing.allocator;
    const abi_json =
        \\{
        \\  "functions": [
        \\    {
        \\      "name": "get_many",
        \\      "outputs": [
        \\        {"name": "values", "type": "uint32[]"}
        \\      ]
        \\    },
        \\    {
        \\      "name": "get_configs",
        \\      "outputs": [
        \\        {
        \\          "name": "items",
        \\          "type": "tuple[]",
        \\          "components": [
        \\            {"name": "enabled", "type": "bool"},
        \\            {"name": "owner", "type": "address"}
        \\          ]
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var abi = try parseAbiInfoJsonAlloc(allocator, abi_json);
    defer abi.deinit(allocator);

    var scalar_items = [_]types.StackEntry{
        .{ .number = 1 },
        .{ .number = 2 },
        .{ .number = 3 },
    };
    const scalar_stack = [_]types.StackEntry{
        .{ .list = scalar_items[0..] },
    };

    const scalar_decoded = try decodeFunctionOutputsFromAbiJsonAlloc(allocator, &abi.abi, "get_many", scalar_stack[0..]);
    defer allocator.free(scalar_decoded);
    try std.testing.expectEqualStrings("{\"values\":[1,2,3]}", scalar_decoded);

    var owner_builder = cell.Builder.init();
    try owner_builder.storeAddress(@as([]const u8, "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8"));
    const owner_cell = try owner_builder.toCell(allocator);
    defer owner_cell.deinit(allocator);

    var tuple_a = [_]types.StackEntry{
        .{ .number = 1 },
        .{ .slice = owner_cell },
    };
    var tuple_b = [_]types.StackEntry{
        .{ .number = 0 },
        .{ .slice = owner_cell },
    };
    var tuple_items = [_]types.StackEntry{
        .{ .tuple = tuple_a[0..] },
        .{ .tuple = tuple_b[0..] },
    };
    const tuple_stack = [_]types.StackEntry{
        .{ .list = tuple_items[0..] },
    };

    const tuple_decoded = try decodeFunctionOutputsFromAbiJsonAlloc(allocator, &abi.abi, "get_configs", tuple_stack[0..]);
    defer allocator.free(tuple_decoded);
    try std.testing.expectEqualStrings(
        "{\"items\":[{\"enabled\":true,\"owner\":\"0:83dfd552e63729b472fcbcc8c45ebcc6691702558b68ec7527e1ba403a0f31a8\"},{\"enabled\":false,\"owner\":\"0:83dfd552e63729b472fcbcc8c45ebcc6691702558b68ec7527e1ba403a0f31a8\"}]}",
        tuple_decoded,
    );
}

test "abi adapter decodes dict aliases as boc strings" {
    const allocator = std.testing.allocator;
    const abi_json =
        \\{
        \\  "functions": [
        \\    {
        \\      "name": "get_dicts",
        \\      "outputs": [
        \\        {"name": "settings", "type": "dict<address,uint32>"},
        \\        {"name": "cache", "type": "map_ref<uint32,cell>"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var abi = try parseAbiInfoJsonAlloc(allocator, abi_json);
    defer abi.deinit(allocator);

    var dict_builder = cell.Builder.init();
    try dict_builder.storeUint(0xCAFE, 16);
    const dict_cell = try dict_builder.toCell(allocator);
    defer dict_cell.deinit(allocator);
    const dict_boc = try boc.serializeBoc(allocator, dict_cell);
    defer allocator.free(dict_boc);
    const dict_b64 = try base64EncodeAlloc(allocator, dict_boc);
    defer allocator.free(dict_b64);

    const stack = [_]types.StackEntry{
        .{ .cell = dict_cell },
        .{ .cell = dict_cell },
    };

    const decoded = try decodeFunctionOutputsFromAbiJsonAlloc(allocator, &abi.abi, "get_dicts", stack[0..]);
    defer allocator.free(decoded);

    const expected = try std.fmt.allocPrint(
        allocator,
        "{{\"settings\":\"{s}\",\"cache\":\"{s}\"}}",
        .{ dict_b64, dict_b64 },
    );
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, decoded);
}

test "abi adapter preserves large numeric outputs as strings" {
    const allocator = std.testing.allocator;
    const abi_json =
        \\{
        \\  "functions": [
        \\    {
        \\      "name": "get_big",
        \\      "outputs": [
        \\        {"name": "total_supply", "type": "uint128"},
        \\        {"name": "balance", "type": "coins"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var abi = try parseAbiInfoJsonAlloc(allocator, abi_json);
    defer abi.deinit(allocator);

    const stack = [_]types.StackEntry{
        .{ .big_number = "0x1234567890ABCDEF1234567890ABCDEF" },
        .{ .big_number = "340282366920938463463374607431768211455" },
    };

    const decoded = try decodeFunctionOutputsFromAbiJsonAlloc(allocator, &abi.abi, "get_big", stack[0..]);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(
        "{\"total_supply\":\"0x1234567890ABCDEF1234567890ABCDEF\",\"balance\":\"340282366920938463463374607431768211455\"}",
        decoded,
    );
}

test "abi adapter decodes unnamed outputs and tuple components without empty keys" {
    const allocator = std.testing.allocator;
    const abi_json =
        \\{
        \\  "functions": [
        \\    {
        \\      "name": "get_unnamed",
        \\      "outputs": [
        \\        {"type": "uint32"},
        \\        {
        \\          "type": "tuple",
        \\          "components": [
        \\            {"type": "bool"},
        \\            {"name": "owner", "type": "address"}
        \\          ]
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var abi = try parseAbiInfoJsonAlloc(allocator, abi_json);
    defer abi.deinit(allocator);

    const addr_boc = try buildAddressStackSliceBocAlloc(allocator, "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8");
    defer allocator.free(addr_boc);
    const addr_cell = try boc.deserializeBoc(allocator, addr_boc);
    defer addr_cell.deinit(allocator);

    var nested = [_]types.StackEntry{
        .{ .number = 1 },
        .{ .slice = addr_cell },
    };
    const stack = [_]types.StackEntry{
        .{ .number = 7 },
        .{ .tuple = nested[0..] },
    };

    const decoded = try decodeFunctionOutputsFromAbiJsonAlloc(allocator, &abi.abi, "get_unnamed", stack[0..]);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(
        "[7,{\"value0\":true,\"owner\":\"0:83dfd552e63729b472fcbcc8c45ebcc6691702558b68ec7527e1ba403a0f31a8\"}]",
        decoded,
    );
}

test "abi adapter decodes fixed bytes outputs as base64 strings" {
    const allocator = std.testing.allocator;
    const abi_json =
        \\{
        \\  "functions": [
        \\    {
        \\      "name": "get_hash",
        \\      "outputs": [
        \\        {"name": "hash", "type": "bytes32"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var abi = try parseAbiInfoJsonAlloc(allocator, abi_json);
    defer abi.deinit(allocator);

    const hash_bytes = [_]u8{
        0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
        0xA8, 0xA9, 0xAA, 0xAB, 0xAC, 0xAD, 0xAE, 0xAF,
        0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7,
        0xB8, 0xB9, 0xBA, 0xBB, 0xBC, 0xBD, 0xBE, 0xBF,
    };
    const hash_b64 = try base64EncodeAlloc(allocator, hash_bytes[0..]);
    defer allocator.free(hash_b64);

    const stack = [_]types.StackEntry{
        .{ .bytes = hash_bytes[0..] },
    };

    const decoded = try decodeFunctionOutputsFromAbiJsonAlloc(allocator, &abi.abi, "get_hash", stack[0..]);
    defer allocator.free(decoded);

    const expected = try std.fmt.allocPrint(allocator, "{{\"hash\":\"{s}\"}}", .{hash_b64});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, decoded);
}
