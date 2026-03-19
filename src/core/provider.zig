//! Multi-provider failover support

const std = @import("std");
const http_client = @import("http_client.zig");
const types = @import("types.zig");

pub const ProviderConfig = struct {
    url: []const u8,
    api_key: ?[]const u8 = null,
};

pub const Network = enum {
    mainnet,
    testnet,
};

pub const MultiProvider = struct {
    allocator: std.mem.Allocator,
    providers: []const ProviderConfig,
    current_index: usize = 0,
    owned_providers: ?[]ProviderConfig = null,

    pub fn init(allocator: std.mem.Allocator, providers: []const ProviderConfig) !MultiProvider {
        if (providers.len == 0) return error.NoProvidersConfigured;
        return MultiProvider{
            .allocator = allocator,
            .providers = providers,
            .current_index = 0,
            .owned_providers = null,
        };
    }

    pub fn initOwned(allocator: std.mem.Allocator, providers: []const ProviderConfig) !MultiProvider {
        if (providers.len == 0) return error.NoProvidersConfigured;

        const owned = try allocator.alloc(ProviderConfig, providers.len);
        var built: usize = 0;
        errdefer {
            for (owned[0..built]) |provider| {
                allocator.free(provider.url);
                if (provider.api_key) |api_key| allocator.free(api_key);
            }
            allocator.free(owned);
        }

        for (providers, 0..) |provider, idx| {
            owned[idx] = .{
                .url = try allocator.dupe(u8, provider.url),
                .api_key = if (provider.api_key) |api_key| try allocator.dupe(u8, api_key) else null,
            };
            built += 1;
        }

        return .{
            .allocator = allocator,
            .providers = owned,
            .current_index = 0,
            .owned_providers = owned,
        };
    }

    pub fn deinit(self: *MultiProvider) void {
        if (self.owned_providers) |providers| {
            for (providers) |provider| {
                self.allocator.free(provider.url);
                if (provider.api_key) |api_key| self.allocator.free(api_key);
            }
            self.allocator.free(providers);
        }

        self.providers = &.{};
        self.current_index = 0;
        self.owned_providers = null;
    }

    pub fn getClient(self: *MultiProvider) !http_client.TonHttpClient {
        const config = self.providers[self.current_index];
        return http_client.TonHttpClient.init(self.allocator, config.url, config.api_key);
    }

    pub fn getBalance(self: *MultiProvider, addr: []const u8) !types.BalanceResponse {
        return self.callWithFailover(GetBalanceOp{ .addr = addr });
    }

    pub fn runGetMethod(self: *MultiProvider, addr: []const u8, method_name: []const u8, stack: []const []const u8) !types.RunGetMethodResponse {
        return self.callWithFailover(RunGetMethodOp{
            .addr = addr,
            .method_name = method_name,
            .stack = stack,
        });
    }

    pub fn runGetMethodJson(self: *MultiProvider, addr: []const u8, method_name: []const u8, stack_json: []const u8) !types.RunGetMethodResponse {
        return self.callWithFailover(RunGetMethodJsonOp{
            .addr = addr,
            .method_name = method_name,
            .stack_json = stack_json,
        });
    }

    pub fn sendBoc(self: *MultiProvider, body: []const u8) !types.SendBocResponse {
        return self.callWithFailover(SendBocOp{ .body = body });
    }

    pub fn sendBocBase64(self: *MultiProvider, body_base64: []const u8) !types.SendBocResponse {
        return self.callWithFailover(SendBocBase64Op{ .body_base64 = body_base64 });
    }

    pub fn sendBocHex(self: *MultiProvider, body_hex: []const u8) !types.SendBocResponse {
        return self.callWithFailover(SendBocHexOp{ .body_hex = body_hex });
    }

    pub fn getTransactions(self: *MultiProvider, addr: []const u8, limit: u32) ![]types.Transaction {
        return self.callWithFailover(GetTransactionsOp{
            .addr = addr,
            .limit = limit,
        });
    }

    pub fn lookupTx(self: *MultiProvider, lt: i64, hash: []const u8) !?types.Transaction {
        return self.callWithFailover(LookupTxOp{
            .lt = lt,
            .hash = hash,
        });
    }

    pub fn freeRunGetMethodResponse(self: *MultiProvider, response: *types.RunGetMethodResponse) void {
        for (response.stack) |*entry| {
            freeStackEntry(self.allocator, entry);
        }
        if (response.stack.len > 0) self.allocator.free(response.stack);
        if (response.logs.len > 0) self.allocator.free(response.logs);

        response.stack = &.{};
        response.logs = "";
    }

    pub fn freeSendBocResponse(self: *MultiProvider, response: *types.SendBocResponse) void {
        if (response.hash.len > 0) self.allocator.free(response.hash);
        response.hash = "";
        response.lt = 0;
    }

    pub fn freeTransaction(self: *MultiProvider, tx: *types.Transaction) void {
        if (tx.hash.len > 0) self.allocator.free(tx.hash);
        if (tx.in_msg) |msg| self.freeMessage(msg);
        for (tx.out_msgs) |msg| self.freeMessage(msg);
        if (tx.out_msgs.len > 0) self.allocator.free(tx.out_msgs);
        tx.* = undefined;
    }

    pub fn freeTransactions(self: *MultiProvider, txs: []types.Transaction) void {
        for (txs) |*tx| self.freeTransaction(tx);
        if (txs.len > 0) self.allocator.free(txs);
    }

    pub fn failover(self: *MultiProvider) void {
        self.current_index = (self.current_index + 1) % self.providers.len;
    }

    fn callWithFailover(self: *MultiProvider, op: anytype) !OperationPayloadType(@TypeOf(op)) {
        if (self.providers.len == 0) return error.NoProvidersConfigured;

        var attempts: usize = 0;
        var index = self.current_index;
        var last_err: anyerror = error.NoProvidersConfigured;

        while (attempts < self.providers.len) : (attempts += 1) {
            const config = self.providers[index];
            var client = http_client.TonHttpClient.init(self.allocator, config.url, config.api_key) catch |err| {
                last_err = err;
                index = nextIndex(self, index);
                self.current_index = index;
                continue;
            };
            defer client.deinit();

            const result = op.run(&client) catch |err| {
                last_err = err;
                index = nextIndex(self, index);
                self.current_index = index;
                continue;
            };

            self.current_index = index;
            return result;
        }

        return last_err;
    }

    fn freeMessage(self: *MultiProvider, msg: *types.Message) void {
        if (msg.hash.len > 0) self.allocator.free(msg.hash);
        if (msg.raw_body.len > 0) self.allocator.free(msg.raw_body);
        if (msg.body) |body| body.deinit(self.allocator);
        self.allocator.destroy(msg);
    }

    fn nextIndex(self: *MultiProvider, index: usize) usize {
        return (index + 1) % self.providers.len;
    }
};

fn OperationPayloadType(comptime Op: type) type {
    const run_fn = @typeInfo(@TypeOf(Op.run)).@"fn";
    const run_return = run_fn.return_type orelse @compileError("MultiProvider op must return a value");
    return switch (@typeInfo(run_return)) {
        .error_union => |err_union| err_union.payload,
        else => run_return,
    };
}

const GetBalanceOp = struct {
    addr: []const u8,

    fn run(self: @This(), client: *http_client.TonHttpClient) !types.BalanceResponse {
        return client.getBalance(self.addr);
    }
};

const RunGetMethodOp = struct {
    addr: []const u8,
    method_name: []const u8,
    stack: []const []const u8,

    fn run(self: @This(), client: *http_client.TonHttpClient) !types.RunGetMethodResponse {
        return client.runGetMethod(self.addr, self.method_name, self.stack);
    }
};

const RunGetMethodJsonOp = struct {
    addr: []const u8,
    method_name: []const u8,
    stack_json: []const u8,

    fn run(self: @This(), client: *http_client.TonHttpClient) !types.RunGetMethodResponse {
        return client.runGetMethodJson(self.addr, self.method_name, self.stack_json);
    }
};

const SendBocOp = struct {
    body: []const u8,

    fn run(self: @This(), client: *http_client.TonHttpClient) !types.SendBocResponse {
        return client.sendBoc(self.body);
    }
};

const SendBocBase64Op = struct {
    body_base64: []const u8,

    fn run(self: @This(), client: *http_client.TonHttpClient) !types.SendBocResponse {
        return client.sendBocBase64(self.body_base64);
    }
};

const SendBocHexOp = struct {
    body_hex: []const u8,

    fn run(self: @This(), client: *http_client.TonHttpClient) !types.SendBocResponse {
        return client.sendBocHex(self.body_hex);
    }
};

const GetTransactionsOp = struct {
    addr: []const u8,
    limit: u32,

    fn run(self: @This(), client: *http_client.TonHttpClient) ![]types.Transaction {
        return client.getTransactions(self.addr, self.limit);
    }
};

const LookupTxOp = struct {
    lt: i64,
    hash: []const u8,

    fn run(self: @This(), client: *http_client.TonHttpClient) !?types.Transaction {
        return client.lookupTx(self.lt, self.hash);
    }
};

fn freeStackEntry(allocator: std.mem.Allocator, entry: *types.StackEntry) void {
    switch (entry.*) {
        .null, .number => {},
        .big_number => |value| if (value.len > 0) allocator.free(value),
        .unsupported => |value| if (value.len > 0) allocator.free(value),
        .cell => |value| value.deinit(allocator),
        .slice => |value| value.deinit(allocator),
        .builder => |value| value.deinit(allocator),
        .tuple => |items| {
            for (items) |*child| freeStackEntry(allocator, child);
            if (items.len > 0) allocator.free(items);
        },
        .list => |items| {
            for (items) |*child| freeStackEntry(allocator, child);
            if (items.len > 0) allocator.free(items);
        },
        .bytes => |value| if (value.len > 0) allocator.free(value),
    }
}

pub fn createDefaultProvider(allocator: std.mem.Allocator) !MultiProvider {
    return createProviderForNetwork(allocator, .mainnet);
}

pub fn createProviderForNetwork(allocator: std.mem.Allocator, network: Network) !MultiProvider {
    const default_url = switch (network) {
        .mainnet => "https://toncenter.com/api/v2/jsonRPC",
        .testnet => "https://testnet.toncenter.com/api/v2/jsonRPC",
    };

    return MultiProvider.init(allocator, &.{
        .{ .url = default_url },
    });
}

pub fn createProviderFromProcessEnv(allocator: std.mem.Allocator) !MultiProvider {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    return createProviderFromEnvMap(allocator, &env_map);
}

pub fn createProviderFromEnvMap(allocator: std.mem.Allocator, env_map: *const std.process.EnvMap) !MultiProvider {
    if (env_map.get("TON_RPC_URLS")) |rpc_urls| {
        if (env_map.get("TON_API_KEYS")) |api_keys| {
            return createProviderFromCsvAlloc(allocator, rpc_urls, api_keys, null);
        }
        return createProviderFromCsvAlloc(allocator, rpc_urls, null, env_map.get("TON_API_KEY"));
    }

    if (env_map.get("TON_RPC_URL")) |rpc_url| {
        const trimmed = std.mem.trim(u8, rpc_url, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidProviderConfig;

        return MultiProvider.initOwned(allocator, &.{
            .{
                .url = trimmed,
                .api_key = if (env_map.get("TON_API_KEY")) |api_key|
                    if (std.mem.trim(u8, api_key, " \t\r\n").len > 0) std.mem.trim(u8, api_key, " \t\r\n") else null
                else
                    null,
            },
        });
    }

    return createProviderForNetwork(allocator, try parseNetworkEnv(env_map.get("TON_NETWORK")));
}

fn createProviderFromCsvAlloc(
    allocator: std.mem.Allocator,
    rpc_urls: []const u8,
    api_keys_csv: ?[]const u8,
    shared_api_key: ?[]const u8,
) !MultiProvider {
    var list = std.array_list.Managed(ProviderConfig).init(allocator);
    defer list.deinit();

    var key_iter = if (api_keys_csv) |value|
        std.mem.splitScalar(u8, value, ',')
    else
        std.mem.splitScalar(u8, "", ',');
    const has_aligned_keys = api_keys_csv != null;
    const trimmed_shared_api_key = if (shared_api_key) |value|
        std.mem.trim(u8, value, " \t\r\n")
    else
        "";

    var url_iter = std.mem.splitScalar(u8, rpc_urls, ',');
    while (url_iter.next()) |raw_url| {
        const trimmed_url = std.mem.trim(u8, raw_url, " \t\r\n");
        if (trimmed_url.len == 0) continue;

        const next_key = if (has_aligned_keys) key_iter.next() else null;
        const trimmed_key = if (has_aligned_keys)
            if (next_key) |value| std.mem.trim(u8, value, " \t\r\n") else ""
        else
            trimmed_shared_api_key;

        try list.append(.{
            .url = trimmed_url,
            .api_key = if (trimmed_key.len > 0) trimmed_key else null,
        });
    }

    if (list.items.len == 0) return error.InvalidProviderConfig;

    if (has_aligned_keys) {
        while (key_iter.next()) |extra_key| {
            if (std.mem.trim(u8, extra_key, " \t\r\n").len > 0) return error.InvalidProviderConfig;
        }
    }

    return MultiProvider.initOwned(allocator, list.items);
}

fn parseNetworkEnv(value: ?[]const u8) !Network {
    const trimmed = std.mem.trim(u8, value orelse "", " \t\r\n");
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "mainnet")) return .mainnet;
    if (std.ascii.eqlIgnoreCase(trimmed, "testnet")) return .testnet;
    return error.InvalidProviderConfig;
}

test "multi provider failover selects next provider on error" {
    const allocator = std.testing.allocator;

    var provider = try MultiProvider.init(allocator, &.{
        .{ .url = "provider-a" },
        .{ .url = "provider-b" },
    });

    const Op = struct {
        fn run(_: @This(), client: *http_client.TonHttpClient) ![]const u8 {
            if (std.mem.eql(u8, client.base_url, "provider-a")) return error.MockFailure;
            return client.base_url;
        }
    };

    const result = try provider.callWithFailover(Op{});
    try std.testing.expectEqualStrings("provider-b", result);
    try std.testing.expectEqual(@as(usize, 1), provider.current_index);
}

test "multi provider returns last error after exhausting providers" {
    const allocator = std.testing.allocator;

    var provider = try MultiProvider.init(allocator, &.{
        .{ .url = "provider-a" },
        .{ .url = "provider-b" },
    });

    const Op = struct {
        fn run(_: @This(), client: *http_client.TonHttpClient) !void {
            _ = client;
            return error.AllProvidersFailed;
        }
    };

    try std.testing.expectError(error.AllProvidersFailed, provider.callWithFailover(Op{}));
}

test "multi provider public methods are exported" {
    _ = MultiProvider.getBalance;
    _ = MultiProvider.runGetMethod;
    _ = MultiProvider.runGetMethodJson;
    _ = MultiProvider.sendBoc;
    _ = MultiProvider.sendBocBase64;
    _ = MultiProvider.sendBocHex;
    _ = MultiProvider.getTransactions;
    _ = MultiProvider.lookupTx;
    _ = MultiProvider.freeRunGetMethodResponse;
    _ = MultiProvider.freeSendBocResponse;
    _ = MultiProvider.freeTransaction;
    _ = MultiProvider.freeTransactions;
}

test "provider env supports rpc url list and aligned api keys" {
    const allocator = std.testing.allocator;

    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();
    try env_map.put("TON_RPC_URLS", "https://rpc-a.example/jsonRPC, https://rpc-b.example/jsonRPC");
    try env_map.put("TON_API_KEYS", "key-a,");

    var provider = try createProviderFromEnvMap(allocator, &env_map);
    defer provider.deinit();

    try std.testing.expectEqual(@as(usize, 2), provider.providers.len);
    try std.testing.expectEqualStrings("https://rpc-a.example/jsonRPC", provider.providers[0].url);
    try std.testing.expectEqualStrings("https://rpc-b.example/jsonRPC", provider.providers[1].url);
    try std.testing.expectEqualStrings("key-a", provider.providers[0].api_key.?);
    try std.testing.expect(provider.providers[1].api_key == null);
}

test "provider env supports singular rpc url and api key" {
    const allocator = std.testing.allocator;

    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();
    try env_map.put("TON_RPC_URL", " https://single.example/jsonRPC ");
    try env_map.put("TON_API_KEY", " secret ");

    var provider = try createProviderFromEnvMap(allocator, &env_map);
    defer provider.deinit();

    try std.testing.expectEqual(@as(usize, 1), provider.providers.len);
    try std.testing.expectEqualStrings("https://single.example/jsonRPC", provider.providers[0].url);
    try std.testing.expectEqualStrings("secret", provider.providers[0].api_key.?);
}

test "provider env applies shared api key to rpc url list" {
    const allocator = std.testing.allocator;

    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();
    try env_map.put("TON_RPC_URLS", "https://rpc-a.example/jsonRPC,https://rpc-b.example/jsonRPC");
    try env_map.put("TON_API_KEY", "shared-key");

    var provider = try createProviderFromEnvMap(allocator, &env_map);
    defer provider.deinit();

    try std.testing.expectEqual(@as(usize, 2), provider.providers.len);
    try std.testing.expectEqualStrings("shared-key", provider.providers[0].api_key.?);
    try std.testing.expectEqualStrings("shared-key", provider.providers[1].api_key.?);
}

test "provider env falls back to selected network" {
    const allocator = std.testing.allocator;

    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();
    try env_map.put("TON_NETWORK", "testnet");

    var provider = try createProviderFromEnvMap(allocator, &env_map);
    defer provider.deinit();

    try std.testing.expectEqual(@as(usize, 1), provider.providers.len);
    try std.testing.expectEqualStrings("https://testnet.toncenter.com/api/v2/jsonRPC", provider.providers[0].url);
}

test "provider env rejects invalid network values" {
    const allocator = std.testing.allocator;

    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();
    try env_map.put("TON_NETWORK", "devnet");

    try std.testing.expectError(error.InvalidProviderConfig, createProviderFromEnvMap(allocator, &env_map));
}
