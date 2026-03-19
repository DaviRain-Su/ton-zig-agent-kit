//! HTTP client for TonAPI / TON Center

const std = @import("std");
const types = @import("types.zig");
const address = @import("address.zig");

pub const TonHttpClient = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    api_key: ?[]const u8,
    http_client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8, api_key: ?[]const u8) !TonHttpClient {
        return TonHttpClient{
            .allocator = allocator,
            .base_url = base_url,
            .api_key = api_key,
            .http_client = std.http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *TonHttpClient) void {
        self.http_client.deinit();
    }

    pub fn getBalance(self: *TonHttpClient, addr: []const u8) !types.BalanceResponse {
        _ = self;
        return types.BalanceResponse{ .balance = 0, .address = addr };
    }

    pub fn runGetMethod(self: *TonHttpClient, addr: []const u8, method: []const u8, stack: []const []const u8) !types.RunGetMethodResponse {
        _ = self;
        _ = addr;
        _ = method;
        _ = stack;
        return types.RunGetMethodResponse{
            .exit_code = 0,
            .stack = &.{},
            .logs = "",
        };
    }

    pub fn sendBoc(self: *TonHttpClient, body: []const u8) !types.SendBocResponse {
        _ = self;
        _ = body;
        return types.SendBocResponse{ .hash = "", .lt = 0 };
    }

    pub fn getTransactions(self: *TonHttpClient, addr: []const u8, limit: u32) ![]types.Transaction {
        _ = self;
        _ = addr;
        _ = limit;
        return &.{};
    }

    pub fn lookupTx(self: *TonHttpClient, lt: i64, hash: []const u8) !?types.Transaction {
        _ = self;
        _ = lt;
        _ = hash;
        return null;
    }
};
