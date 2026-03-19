//! Multi-provider failover support

const std = @import("std");
const http_client = @import("http_client.zig");
const types = @import("types.zig");

pub const ProviderConfig = struct {
    url: []const u8,
    api_key: ?[]const u8 = null,
};

pub const MultiProvider = struct {
    allocator: std.mem.Allocator,
    providers: []const ProviderConfig,
    current_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator, providers: []const ProviderConfig) !MultiProvider {
        return MultiProvider{
            .allocator = allocator,
            .providers = providers,
            .current_index = 0,
        };
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
        .null, .number, .big_number => {},
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
    return MultiProvider.init(allocator, &.{
        .{ .url = "https://toncenter.com/api/v2/jsonRPC" },
        .{ .url = "https://testnet.toncenter.com/api/v2/jsonRPC" },
    });
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
