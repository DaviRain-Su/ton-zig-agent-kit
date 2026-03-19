//! Generic contract interface

const std = @import("std");
const types = @import("../core/types.zig");
const http_client = @import("../core/http_client.zig");

pub const GenericContract = struct {
    client: *http_client.TonHttpClient,
    address: []const u8,

    pub fn callGetMethod(self: *GenericContract, method: []const u8, args: []const []const u8) !types.RunGetMethodResponse {
        return self.client.runGetMethod(self.address, method, args);
    }

    pub fn sendMessage(self: *GenericContract, body: []u8) !types.SendBocResponse {
        return self.client.sendBoc(body);
    }
};

pub const jetton = @import("jetton.zig");
pub const nft = @import("nft.zig");
pub const abi_adapter = @import("abi_adapter.zig");
