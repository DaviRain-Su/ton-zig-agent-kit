//! Jetton (Fungible Token) standard implementation - TEP-74
//! https://github.com/ton-blockchain/TEPs/blob/master/text/0074-jettons-standard.md

const std = @import("std");
const types = @import("../core/types.zig");
const cell = @import("../core/cell.zig");
const address_mod = @import("../core/address.zig");
const http_client = @import("../core/http_client.zig");
const generic_contract = @import("contract.zig");

pub const JettonMaster = struct {
    address: []const u8,
    client: *http_client.TonHttpClient,

    pub fn init(contract_address: []const u8, client: *http_client.TonHttpClient) JettonMaster {
        return .{
            .address = contract_address,
            .client = client,
        };
    }

    /// Get Jetton metadata (total_supply, mintable, admin, content)
    pub fn getJettonData(self: *JettonMaster) !JettonData {
        var result = try self.client.runGetMethod(self.address, "get_jetton_data", &.{});
        defer self.client.freeRunGetMethodResponse(&result);

        if (result.exit_code != 0) {
            return error.ContractError;
        }

        return parseJettonData(self.client.allocator, result.stack);
    }

    /// Get wallet address for owner
    pub fn getWalletAddress(self: *JettonMaster, owner_address: []const u8) ![]const u8 {
        const stack_json = try generic_contract.buildStackArgsJsonAlloc(self.client.allocator, &.{
            .{ .address = owner_address },
        });
        defer self.client.allocator.free(stack_json);

        var result = try self.client.runGetMethodJson(self.address, "get_wallet_address", stack_json);
        defer self.client.freeRunGetMethodResponse(&result);

        if (result.exit_code != 0) {
            return error.ContractError;
        }

        if (result.stack.len < 1) return error.InvalidResponse;
        const wallet_address = (try generic_contract.stackEntryAsOptionalAddress(&result.stack[0])) orelse return error.InvalidAddress;
        return address_mod.formatRaw(self.client.allocator, &wallet_address);
    }
};

pub const JettonWallet = struct {
    address: []const u8,
    client: *http_client.TonHttpClient,

    pub fn init(contract_address: []const u8, client: *http_client.TonHttpClient) JettonWallet {
        return .{
            .address = contract_address,
            .client = client,
        };
    }

    /// Get wallet data (balance, owner, master, code)
    pub fn getWalletData(self: *JettonWallet) !WalletData {
        var result = try self.client.runGetMethod(self.address, "get_wallet_data", &.{});
        defer self.client.freeRunGetMethodResponse(&result);

        if (result.exit_code != 0) {
            return error.ContractError;
        }

        return parseJettonWalletData(self.client.allocator, result.stack);
    }

    /// Get balance
    pub fn getBalance(self: *JettonWallet) !u64 {
        const data = try self.getWalletData();
        return data.balance;
    }
};

pub const JettonData = struct {
    total_supply: u64,
    mintable: bool,
    admin: ?types.Address,
    content: ?[]const u8,

    pub fn deinit(self: *JettonData, allocator: std.mem.Allocator) void {
        if (self.content) |content| allocator.free(content);
        self.content = null;
    }
};

pub const WalletData = struct {
    balance: u64,
    owner: []const u8,
    master: []const u8,

    pub fn deinit(self: *WalletData, allocator: std.mem.Allocator) void {
        allocator.free(self.owner);
        allocator.free(self.master);
        self.owner = "";
        self.master = "";
    }
};

fn parseJettonData(allocator: std.mem.Allocator, stack: []const types.StackEntry) !JettonData {
    if (stack.len < 4) return error.InvalidResponse;

    const total_supply_raw = try generic_contract.stackEntryAsInt(&stack[0]);
    if (total_supply_raw < 0) return error.InvalidResponse;

    return JettonData{
        .total_supply = @intCast(total_supply_raw),
        .mintable = (try generic_contract.stackEntryAsInt(&stack[1])) != 0,
        .admin = try generic_contract.stackEntryAsOptionalAddress(&stack[2]),
        .content = try generic_contract.stackEntryToBocAlloc(allocator, &stack[3]),
    };
}

fn parseJettonWalletData(allocator: std.mem.Allocator, stack: []const types.StackEntry) !WalletData {
    if (stack.len < 3) return error.InvalidResponse;

    const balance_raw = try generic_contract.stackEntryAsInt(&stack[0]);
    if (balance_raw < 0) return error.InvalidResponse;

    const owner_addr = (try generic_contract.stackEntryAsOptionalAddress(&stack[1])) orelse return error.InvalidAddress;
    const master_addr = (try generic_contract.stackEntryAsOptionalAddress(&stack[2])) orelse return error.InvalidAddress;

    return WalletData{
        .balance = @intCast(balance_raw),
        .owner = try address_mod.formatRaw(allocator, &owner_addr),
        .master = try address_mod.formatRaw(allocator, &master_addr),
    };
}

/// Create Jetton transfer message body
pub fn createTransferMessage(
    allocator: std.mem.Allocator,
    query_id: u64,
    amount: u64,
    destination: []const u8,
    response_destination: []const u8,
    custom_payload: ?[]const u8,
    forward_ton_amount: u64,
    forward_payload: ?[]const u8,
) ![]u8 {
    var builder = cell.Builder.init();

    // op::transfer = 0xf8a7ea5
    try builder.storeUint(0xf8a7ea5, 32);
    // query_id
    try builder.storeUint(query_id, 64);
    // amount
    try builder.storeCoins(amount);
    // destination
    try builder.storeAddress(destination);
    // response_destination
    try builder.storeAddress(response_destination);
    // custom_payload (either 0 or ref)
    if (custom_payload) |_| {
        try builder.storeUint(1, 1); // has custom payload
        // Would store as ref in real implementation
    } else {
        try builder.storeUint(0, 1); // no custom payload
    }
    // forward_ton_amount
    try builder.storeCoins(forward_ton_amount);
    // forward_payload
    if (forward_payload) |_| {
        try builder.storeUint(1, 1); // has forward payload
        // Would store as ref in real implementation
    } else {
        try builder.storeUint(0, 1); // no forward payload
    }

    const c = try builder.toCell(allocator);
    defer allocator.destroy(c);

    return try @import("../core/boc.zig").serializeBoc(allocator, c);
}

/// Create Jetton burn message body
pub fn createBurnMessage(
    allocator: std.mem.Allocator,
    query_id: u64,
    amount: u64,
    response_destination: []const u8,
    custom_payload: ?[]const u8,
) ![]u8 {
    var builder = cell.Builder.init();

    // op::burn = 0x595f07bc
    try builder.storeUint(0x595f07bc, 32);
    // query_id
    try builder.storeUint(query_id, 64);
    // amount
    try builder.storeCoins(amount);
    // response_destination
    try builder.storeAddress(response_destination);
    // custom_payload
    if (custom_payload) |_| {
        try builder.storeUint(1, 1);
    } else {
        try builder.storeUint(0, 1);
    }

    const c = try builder.toCell(allocator);
    defer allocator.destroy(c);

    return try @import("../core/boc.zig").serializeBoc(allocator, c);
}

test "jetton master" {
    const allocator = std.testing.allocator;
    var client = try http_client.TonHttpClient.init(allocator, "https://toncenter.com/api/v2/jsonRPC", null);
    defer client.deinit();

    const master = JettonMaster.init("EQBlqsm144Dq6SjbPIPcQWL1rzbDF7CWeYmpE6FsiVreAYeY", &client);
    _ = master;
}

test "jetton wallet" {
    const allocator = std.testing.allocator;
    var client = try http_client.TonHttpClient.init(allocator, "https://toncenter.com/api/v2/jsonRPC", null);
    defer client.deinit();

    const wallet = JettonWallet.init("EQ...", &client);
    _ = wallet;
}

test "parse jetton data stack" {
    const allocator = std.testing.allocator;

    var admin_builder = cell.Builder.init();
    try admin_builder.storeAddress(@as([]const u8, "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8"));
    const admin_cell = try admin_builder.toCell(allocator);
    defer admin_cell.deinit(allocator);

    var content_builder = cell.Builder.init();
    try content_builder.storeUint(0xCAFE, 16);
    const content_cell = try content_builder.toCell(allocator);
    defer content_cell.deinit(allocator);

    const stack = [_]types.StackEntry{
        .{ .number = 1234 },
        .{ .number = -1 },
        .{ .slice = admin_cell },
        .{ .cell = content_cell },
    };

    var data = try parseJettonData(allocator, stack[0..]);
    defer data.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 1234), data.total_supply);
    try std.testing.expect(data.mintable);
    try std.testing.expect(data.admin != null);
    try std.testing.expect(data.content != null);
}

test "parse jetton wallet data stack" {
    const allocator = std.testing.allocator;

    var owner_builder = cell.Builder.init();
    try owner_builder.storeAddress(@as([]const u8, "0:1111111111111111111111111111111111111111111111111111111111111111"));
    const owner_cell = try owner_builder.toCell(allocator);
    defer owner_cell.deinit(allocator);

    var master_builder = cell.Builder.init();
    try master_builder.storeAddress(@as([]const u8, "0:2222222222222222222222222222222222222222222222222222222222222222"));
    const master_cell = try master_builder.toCell(allocator);
    defer master_cell.deinit(allocator);

    const stack = [_]types.StackEntry{
        .{ .number = 777 },
        .{ .slice = owner_cell },
        .{ .slice = master_cell },
    };

    var data = try parseJettonWalletData(allocator, stack[0..]);
    defer data.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 777), data.balance);
    try std.testing.expectEqualStrings("0:1111111111111111111111111111111111111111111111111111111111111111", data.owner);
    try std.testing.expectEqualStrings("0:2222222222222222222222222222222222222222222222222222222222222222", data.master);
}
