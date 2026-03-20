//! Optional live integration tests.
//!
//! Enable with:
//! - `TON_LIVE_TESTS=1`
//! - and either:
//!   - `TON_NETWORK=testnet`
//!   - or explicit `TON_RPC_URL` / `TON_RPC_URLS`
//!
//! Recommended additional variables:
//! - `TON_TEST_ADDRESS`
//! - `TON_TEST_WALLET_ADDRESS`
//! - `TON_TEST_CONTRACT_ADDRESS`
//! - `TON_TEST_TX_LT`
//! - `TON_TEST_TX_HASH`

const std = @import("std");
const provider_mod = @import("../core/provider.zig");
const signing = @import("../wallet/signing.zig");
const tools_mod = @import("../tools/tools_mod.zig");

fn isTruthyEnv(value: ?[]const u8) bool {
    const trimmed = std.mem.trim(u8, value orelse return false, " \t\r\n");
    return std.ascii.eqlIgnoreCase(trimmed, "1") or
        std.ascii.eqlIgnoreCase(trimmed, "true") or
        std.ascii.eqlIgnoreCase(trimmed, "yes") or
        std.ascii.eqlIgnoreCase(trimmed, "on");
}

fn requireLiveEnvMap(allocator: std.mem.Allocator) !std.process.EnvMap {
    var env_map = try std.process.getEnvMap(allocator);
    errdefer env_map.deinit();

    if (!isTruthyEnv(env_map.get("TON_LIVE_TESTS"))) return error.SkipZigTest;

    const has_explicit_rpc = env_map.get("TON_RPC_URL") != null or env_map.get("TON_RPC_URLS") != null;
    if (!has_explicit_rpc) {
        const network = env_map.get("TON_NETWORK") orelse return error.SkipZigTest;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, network, " \t\r\n"), "testnet")) {
            return error.SkipZigTest;
        }
    }

    return env_map;
}

fn dupRequiredEnvFromMap(allocator: std.mem.Allocator, env_map: *const std.process.EnvMap, key: []const u8) ![]u8 {
    const value = env_map.get(key) orelse return error.SkipZigTest;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return error.SkipZigTest;
    return allocator.dupe(u8, trimmed);
}

fn dupOptionalEnvFromMap(allocator: std.mem.Allocator, env_map: *const std.process.EnvMap, key: []const u8) !?[]u8 {
    const value = env_map.get(key) orelse return null;
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    const owned = try allocator.dupe(u8, trimmed);
    return owned;
}

fn createLiveProvider(allocator: std.mem.Allocator, env_map: *const std.process.EnvMap) !provider_mod.MultiProvider {
    return provider_mod.createProviderFromEnvMap(allocator, env_map);
}

fn anyNonZero(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return true;
    }
    return false;
}

test "live integration fetches balance and recent transactions" {
    const allocator = std.testing.allocator;
    var env_map = try requireLiveEnvMap(allocator);
    defer env_map.deinit();

    const address = try dupRequiredEnvFromMap(allocator, &env_map, "TON_TEST_ADDRESS");
    defer allocator.free(address);

    var provider = try createLiveProvider(allocator, &env_map);
    defer provider.deinit();

    const balance = try provider.getBalance(address);
    try std.testing.expectEqualStrings(address, balance.address);

    const txs = try provider.getTransactions(address, 5);
    defer provider.freeTransactions(txs);

    try std.testing.expect(txs.len > 0);
    try std.testing.expect(txs[0].hash.len > 0);
}

test "live integration reads wallet info for deployed v4 or v5 wallet" {
    const allocator = std.testing.allocator;
    var env_map = try requireLiveEnvMap(allocator);
    defer env_map.deinit();

    const wallet_address = try dupRequiredEnvFromMap(allocator, &env_map, "TON_TEST_WALLET_ADDRESS");
    defer allocator.free(wallet_address);

    var provider = try createLiveProvider(allocator, &env_map);
    defer provider.deinit();

    const info = try signing.getWalletInfo(&provider, wallet_address);
    try std.testing.expect(info.version == .v4 or info.version == .v5);
    try std.testing.expect(anyNonZero(&info.public_key));
}

test "live integration inspects contract through high-level provider tools" {
    const allocator = std.testing.allocator;
    var env_map = try requireLiveEnvMap(allocator);
    defer env_map.deinit();

    const contract_address = try dupRequiredEnvFromMap(allocator, &env_map, "TON_TEST_CONTRACT_ADDRESS");
    defer allocator.free(contract_address);

    const rpc_url = (try dupOptionalEnvFromMap(allocator, &env_map, "TON_RPC_URL")) orelse try allocator.dupe(u8, "testnet");
    defer allocator.free(rpc_url);

    var provider = try createLiveProvider(allocator, &env_map);
    defer provider.deinit();

    var tools = tools_mod.ProviderAgentTools.init(allocator, &provider, .{
        .rpc_url = rpc_url,
        .api_key = if (env_map.get("TON_API_KEY")) |value|
            if (std.mem.trim(u8, value, " \t\r\n").len > 0) std.mem.trim(u8, value, " \t\r\n") else null
        else
            null,
    });

    var inspect = try tools.inspectContract(contract_address);
    defer inspect.deinit(allocator);

    try std.testing.expect(inspect.success);
    try std.testing.expect(inspect.has_abi or inspect.has_wallet or inspect.has_jetton or inspect.has_nft or inspect.observed_messages.len > 0);
}

test "live integration looks up a transaction and decodes available message metadata" {
    const allocator = std.testing.allocator;
    var env_map = try requireLiveEnvMap(allocator);
    defer env_map.deinit();

    const tx_lt_text = try dupRequiredEnvFromMap(allocator, &env_map, "TON_TEST_TX_LT");
    defer allocator.free(tx_lt_text);
    const tx_hash = try dupRequiredEnvFromMap(allocator, &env_map, "TON_TEST_TX_HASH");
    defer allocator.free(tx_hash);

    const lt = try std.fmt.parseInt(i64, tx_lt_text, 10);
    const rpc_url = (try dupOptionalEnvFromMap(allocator, &env_map, "TON_RPC_URL")) orelse try allocator.dupe(u8, "testnet");
    defer allocator.free(rpc_url);

    var provider = try createLiveProvider(allocator, &env_map);
    defer provider.deinit();

    var tools = tools_mod.ProviderAgentTools.init(allocator, &provider, .{
        .rpc_url = rpc_url,
        .api_key = if (env_map.get("TON_API_KEY")) |value|
            if (std.mem.trim(u8, value, " \t\r\n").len > 0) std.mem.trim(u8, value, " \t\r\n") else null
        else
            null,
    });

    var tx = try tools.lookupTransaction(lt, tx_hash);
    defer tx.deinit(allocator);

    try std.testing.expect(tx.success);
    try std.testing.expect(tx.hash.len > 0);
    if (tx.in_message) |msg| {
        try std.testing.expect(msg.hash.len > 0);
        if (msg.body_analysis) |analysis| {
            try std.testing.expect(analysis.opcode != null or analysis.comment != null or analysis.tail_utf8 != null or analysis.decoded_json != null);
        }
    }
}
