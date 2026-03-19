//! ABI adapter for self-describing contracts

const std = @import("std");
const types = @import("../core/types.zig");
const http_client = @import("../core/http_client.zig");
const cell = @import("../core/cell.zig");
const boc = @import("../core/boc.zig");
const body_builder = @import("../core/body_builder.zig");
const generic_contract = @import("contract.zig");

pub const SupportedInterfaces = struct {
    has_wallet: bool,
    has_jetton: bool,
    has_nft: bool,
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

pub fn querySupportedInterfaces(client: *http_client.TonHttpClient, addr: []const u8) !?SupportedInterfaces {
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

pub fn queryAbiIpfs(client: *http_client.TonHttpClient, addr: []const u8) !?AbiInfo {
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

pub fn adaptToContract(addr: []const u8, abi: ?AbiInfo) ContractAdapter {
    return ContractAdapter{ .address = addr, .abi = abi };
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
    for (abi.functions) |*function| {
        if (std.mem.eql(u8, function.name, function_name)) return function;
    }
    return null;
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
    const function = findFunction(abi, function_name) orelse return error.FunctionNotFound;
    return buildFunctionBodyBocAlloc(allocator, function.*, values);
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
    const function = findFunction(abi, function_name) orelse return error.FunctionNotFound;
    return buildStackArgsFromFunctionAlloc(allocator, function.*, values);
}

pub fn decodeFunctionOutputsJsonAlloc(
    allocator: std.mem.Allocator,
    function: FunctionDef,
    stack: []const types.StackEntry,
) ![]u8 {
    if (function.outputs.len != stack.len) return error.InvalidAbiOutputs;

    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    try writer.writer.writeByte('{');
    for (function.outputs, stack, 0..) |param, *entry, idx| {
        if (idx != 0) try writer.writer.writeByte(',');
        try writeJsonString(&writer.writer, param.name);
        try writer.writer.writeByte(':');
        try writeDecodedOutputJson(&writer.writer, allocator, param, entry);
    }
    try writer.writer.writeByte('}');

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

const abi_method_candidates = [_][]const u8{
    "get_abi",
    "get_abi_uri",
    "get_contract_abi",
    "abi",
};

fn probeMethodSupport(client: *http_client.TonHttpClient, addr: []const u8, method_name: []const u8) !bool {
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

fn probeAbiSupport(client: *http_client.TonHttpClient, addr: []const u8) !bool {
    if (try queryAbiIpfs(client, addr)) |*abi| {
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
        .has_nft = has_nft_item or has_nft_collection,
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
    const name = try dupRequiredObjectString(allocator, object, "name");
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
    if (std.mem.eql(u8, param.type_name, "bytes") or std.mem.eql(u8, param.type_name, "string")) {
        const bytes = try abiValueAsBytes(value);
        try builder.storeBits(bytes, @intCast(bytes.len * 8));
        return;
    }
    if (std.mem.eql(u8, param.type_name, "ref") or
        std.mem.eql(u8, param.type_name, "boc") or
        std.mem.eql(u8, param.type_name, "ref_boc") or
        std.mem.eql(u8, param.type_name, "cell_ref"))
    {
        try body_builder.storeRefBoc(builder, allocator, try abiValueAsBoc(value));
        return;
    }
    if (std.mem.eql(u8, param.type_name, "bool")) {
        try builder.storeUint(if (try abiValueAsUint(value) == 0) 0 else 1, 1);
        return;
    }
    if (std.mem.startsWith(u8, param.type_name, "uint")) {
        const bits = try parseSizedTypeBits(param.type_name, "uint", 64);
        if (bits > 64) return error.UnsupportedAbiType;
        try builder.storeUint(try abiValueAsUint(value), bits);
        return;
    }
    if (std.mem.startsWith(u8, param.type_name, "int")) {
        const bits = try parseSizedTypeBits(param.type_name, "int", 64);
        if (bits > 64) return error.UnsupportedAbiType;
        try builder.storeInt(try abiValueAsInt(value), bits);
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

    if (isCompositeParam(param)) return error.UnsupportedAbiType;

    if (std.mem.eql(u8, param.type_name, "coins") or
        std.mem.startsWith(u8, param.type_name, "uint") or
        std.mem.startsWith(u8, param.type_name, "int") or
        std.mem.eql(u8, param.type_name, "bool"))
    {
        return switch (value) {
            .uint => |v| .{ .arg = .{ .int = try checkedAbiUintToI64(v) } },
            .int => |v| .{ .arg = .{ .int = v } },
            else => error.InvalidAbiArguments,
        };
    }

    if (std.mem.eql(u8, param.type_name, "address")) {
        return switch (value) {
            .text => |v| .{ .arg = .{ .address = v } },
            else => error.InvalidAbiArguments,
        };
    }

    if (std.mem.eql(u8, param.type_name, "bytes") or std.mem.eql(u8, param.type_name, "string")) {
        const encoded = try buildBytesSliceBocAlloc(allocator, try abiValueAsBytes(value));
        return .{
            .arg = .{ .slice = encoded },
            .owned_buffer = encoded,
        };
    }

    if (std.mem.eql(u8, param.type_name, "cell") or
        std.mem.eql(u8, param.type_name, "ref") or
        std.mem.eql(u8, param.type_name, "boc") or
        std.mem.eql(u8, param.type_name, "cell_ref"))
    {
        return switch (value) {
            .boc => |v| .{ .arg = .{ .cell = v } },
            else => error.InvalidAbiArguments,
        };
    }

    if (std.mem.eql(u8, param.type_name, "slice")) {
        return switch (value) {
            .boc => |v| .{ .arg = .{ .slice = v } },
            else => error.InvalidAbiArguments,
        };
    }

    if (std.mem.eql(u8, param.type_name, "builder")) {
        return switch (value) {
            .boc => |v| .{ .arg = .{ .builder = v } },
            else => error.InvalidAbiArguments,
        };
    }

    return error.UnsupportedAbiType;
}

fn parseSizedTypeBits(type_name: []const u8, prefix: []const u8, default_bits: u16) !u16 {
    if (type_name.len == prefix.len) return default_bits;
    return std.fmt.parseInt(u16, type_name[prefix.len..], 10);
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
            else => error.InvalidAbiArguments,
        };
    }

    if (std.mem.eql(u8, param.type_name, "address")) {
        return switch (json_value) {
            .string => |value| builder.storeAddress(value),
            else => error.InvalidAbiArguments,
        };
    }

    if (std.mem.eql(u8, param.type_name, "bytes") or std.mem.eql(u8, param.type_name, "string")) {
        return switch (json_value) {
            .string => |value| builder.storeBits(value, @intCast(value.len * 8)),
            else => error.InvalidAbiArguments,
        };
    }

    if (std.mem.eql(u8, param.type_name, "coins") or std.mem.startsWith(u8, param.type_name, "uint")) {
        return switch (json_value) {
            .integer => |value| {
                if (value < 0) return error.InvalidAbiArguments;
                if (std.mem.eql(u8, param.type_name, "coins")) {
                    try builder.storeCoins(@intCast(value));
                } else {
                    const bits = try parseSizedTypeBits(param.type_name, "uint", 64);
                    if (bits > 64) return error.UnsupportedAbiType;
                    try builder.storeUint(@intCast(value), bits);
                }
            },
            else => error.InvalidAbiArguments,
        };
    }

    if (std.mem.startsWith(u8, param.type_name, "int")) {
        return switch (json_value) {
            .integer => |value| {
                const bits = try parseSizedTypeBits(param.type_name, "int", 64);
                if (bits > 64) return error.UnsupportedAbiType;
                try builder.storeInt(value, bits);
            },
            else => error.InvalidAbiArguments,
        };
    }

    return error.UnsupportedAbiType;
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
        const value = try generic_contract.stackEntryAsInt(entry);
        try writer.print("{d}", .{value});
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

    if (std.mem.eql(u8, type_name, "bytes")) {
        const bytes = try decodeBytesOutputAlloc(allocator, entry);
        defer allocator.free(bytes);
        const encoded = try base64EncodeAlloc(allocator, bytes);
        defer allocator.free(encoded);
        try writeJsonString(writer, encoded);
        return;
    }

    if (std.mem.eql(u8, type_name, "cell") or
        std.mem.eql(u8, type_name, "slice") or
        std.mem.eql(u8, type_name, "builder") or
        std.mem.eql(u8, type_name, "ref") or
        std.mem.eql(u8, type_name, "boc") or
        std.mem.eql(u8, type_name, "cell_ref"))
    {
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

    try writer.writeByte('{');
    for (components, items, 0..) |component, *child, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writeJsonString(writer, component.name);
        try writer.writeByte(':');
        try writeDecodedOutputJson(writer, allocator, component, child);
    }
    try writer.writeByte('}');
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
    _ = adaptToContract;
}

test "supported interface detection combines standard probes" {
    const supported = supportedInterfacesFromMethodSupport(true, false, true, false, true, true).?;
    try std.testing.expect(supported.has_wallet);
    try std.testing.expect(supported.has_jetton);
    try std.testing.expect(supported.has_nft);
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
    try std.testing.expectEqual(@as(u32, 0x0f8a7ea5), findFunction(&parsed.abi, "transfer").?.opcode.?);
    try std.testing.expect(findFunction(&parsed.abi, "missing") == null);
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
