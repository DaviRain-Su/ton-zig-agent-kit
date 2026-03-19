//! ABI adapter for self-describing contracts

const std = @import("std");
const types = @import("../core/types.zig");
const http_client = @import("../core/http_client.zig");
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
    uint: u64,
    int: i64,
    text: []const u8,
    bytes: []const u8,
    boc: []const u8,
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

    const extra_len: usize = if (function.opcode != null) 1 else 0;
    const ops = try allocator.alloc(body_builder.BodyOp, function.inputs.len + extra_len);
    defer allocator.free(ops);

    var i: usize = 0;
    if (function.opcode) |opcode| {
        ops[0] = .{ .uint = .{
            .bits = 32,
            .value = opcode,
        } };
        i = 1;
    }

    for (function.inputs, values, 0..) |param, value, idx| {
        ops[i + idx] = try abiValueToBodyOp(param, value);
    }

    return body_builder.buildBodyBocAlloc(allocator, ops);
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

fn parseParamDefsAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]ParamDef {
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
        params[idx] = .{
            .name = try dupRequiredObjectString(allocator, item.object, "name"),
            .type_name = try dupObjectStringWithFallback(allocator, item.object, "type", "type_name"),
        };
        built += 1;
    }

    return params;
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

fn abiValueToBodyOp(param: ParamDef, value: AbiValue) !body_builder.BodyOp {
    if (std.mem.eql(u8, param.type_name, "coins")) {
        return .{ .coins = try abiValueAsUint(value) };
    }
    if (std.mem.eql(u8, param.type_name, "address")) {
        return .{ .address = try abiValueAsText(value) };
    }
    if (std.mem.eql(u8, param.type_name, "bytes") or std.mem.eql(u8, param.type_name, "string")) {
        return .{ .bytes = try abiValueAsBytes(value) };
    }
    if (std.mem.eql(u8, param.type_name, "ref") or
        std.mem.eql(u8, param.type_name, "boc") or
        std.mem.eql(u8, param.type_name, "ref_boc") or
        std.mem.eql(u8, param.type_name, "cell_ref"))
    {
        return .{ .ref_boc = try abiValueAsBoc(value) };
    }
    if (std.mem.eql(u8, param.type_name, "bool")) {
        return .{ .uint = .{
            .bits = 1,
            .value = if (try abiValueAsUint(value) == 0) 0 else 1,
        } };
    }
    if (std.mem.startsWith(u8, param.type_name, "uint")) {
        const bits = try parseSizedTypeBits(param.type_name, "uint", 64);
        if (bits > 64) return error.UnsupportedAbiType;
        return .{ .uint = .{
            .bits = bits,
            .value = try abiValueAsUint(value),
        } };
    }
    if (std.mem.startsWith(u8, param.type_name, "int")) {
        const bits = try parseSizedTypeBits(param.type_name, "int", 64);
        if (bits > 64) return error.UnsupportedAbiType;
        return .{ .int = .{
            .bits = bits,
            .value = try abiValueAsInt(value),
        } };
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
    const cell = @import("../core/cell.zig");

    var tail_builder = cell.Builder.init();
    try tail_builder.storeBits("abi.json", "abi.json".len * 8);
    const tail = try tail_builder.toCell(allocator);

    var head_builder = cell.Builder.init();
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
