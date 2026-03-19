//! Generic contract interface

const std = @import("std");
const types = @import("../core/types.zig");
const http_client = @import("../core/http_client.zig");

pub const GenericContract = struct {
    client: *http_client.TonHttpClient,
    address: []const u8,

    pub fn init(client: *http_client.TonHttpClient, address: []const u8) GenericContract {
        return .{
            .client = client,
            .address = address,
        };
    }

    pub fn callGetMethod(self: *GenericContract, method: []const u8, args: []const []const u8) !types.RunGetMethodResponse {
        return self.client.runGetMethod(self.address, method, args);
    }

    pub fn callGetMethodJson(self: *GenericContract, method: []const u8, stack_json: []const u8) !types.RunGetMethodResponse {
        return self.client.runGetMethodJson(self.address, method, stack_json);
    }

    pub fn sendMessage(self: *GenericContract, body: []const u8) !types.SendBocResponse {
        return self.client.sendBoc(body);
    }

    pub fn sendMessageBase64(self: *GenericContract, body_base64: []const u8) !types.SendBocResponse {
        return self.client.sendBocBase64(body_base64);
    }

    pub fn sendMessageHex(self: *GenericContract, body_hex: []const u8) !types.SendBocResponse {
        return self.client.sendBocHex(body_hex);
    }
};

pub const jetton = @import("jetton.zig");
pub const nft = @import("nft.zig");
pub const abi_adapter = @import("abi_adapter.zig");

test "generic contract init" {
    const allocator = std.testing.allocator;
    var client = try http_client.TonHttpClient.init(allocator, "https://toncenter.com/api/v2/jsonRPC", null);
    defer client.deinit();

    const contract = GenericContract.init(&client, "EQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM9c");
    try std.testing.expectEqualStrings("EQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM9c", contract.address);
}

test {
    _ = jetton;
    _ = nft;
    _ = abi_adapter;
}
