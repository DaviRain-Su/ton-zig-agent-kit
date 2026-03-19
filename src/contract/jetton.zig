//! Jetton (FT) standard implementation - TEP-74

const std = @import("std");
const types = @import("../core/types.zig");
const contract = @import("contract.zig");

pub const JettonMaster = struct {
    contract: contract.GenericContract,

    pub fn getJettonData(self: *JettonMaster) !JettonData {
        const resp = try self.contract.callGetMethod("get_jetton_data", &.{});
        _ = resp;
        return JettonData{};
    }
};

pub const JettonWallet = struct {
    contract: contract.GenericContract,
};

pub const JettonData = struct {
    total_supply: u64,
    mintable: bool,
    admin: ?types.Address,
    content: ?[]const u8,
};

pub fn getWalletAddress(master: *JettonMaster, owner: []const u8) ![]const u8 {
    _ = master;
    _ = owner;
    return "";
}

pub fn jettonTransfer(wallet: *JettonWallet, destination: []const u8, amount: u64, response_destination: []const u8) ![]u8 {
    _ = wallet;
    _ = destination;
    _ = amount;
    _ = response_destination;
    return &.{};
}

test "jetton basic" {
    _ = getWalletAddress;
    _ = jettonTransfer;
}
