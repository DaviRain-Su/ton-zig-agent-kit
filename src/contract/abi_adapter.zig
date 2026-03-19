//! ABI adapter for self-describing contracts

const std = @import("std");
const types = @import("../core/types.zig");
const http_client = @import("../core/http_client.zig");
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
        .cell, .slice => try generic_contract.stackEntryAsOffchainContentUriAlloc(allocator, entry),
        .bytes => |value| if (looksLikeOffchainUri(value))
            try allocator.dupe(u8, value)
        else
            null,
        .tuple => |items| try findOffchainUriInStack(allocator, items),
        else => null,
    };
}

fn looksLikeOffchainUri(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "ipfs://") or
        std.mem.startsWith(u8, value, "http://") or
        std.mem.startsWith(u8, value, "https://");
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
