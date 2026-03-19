//! ABI adapter for self-describing contracts

const std = @import("std");
const types = @import("../core/types.zig");
const http_client = @import("../core/http_client.zig");

pub const SupportedInterfaces = struct {
    has_wallet: bool,
    has_jetton: bool,
    has_nft: bool,
    has_abi: bool,
};

pub const AbiInfo = struct {
    version: []const u8,
    functions: []const FunctionDef,
    events: []const EventDef,
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
    _ = client;
    _ = addr;
    return null;
}

pub fn queryAbiIpfs(client: *http_client.TonHttpClient, addr: []const u8) !?AbiInfo {
    _ = client;
    _ = addr;
    return null;
}

pub fn adaptToContract(addr: []const u8, abi: ?AbiInfo) ContractAdapter {
    return ContractAdapter{ .address = addr, .abi = abi };
}

test "abi adapter" {
    _ = querySupportedInterfaces;
    _ = queryAbiIpfs;
    _ = adaptToContract;
}
