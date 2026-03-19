//! Agent tool types and results

const std = @import("std");
const types = @import("../core/types.zig");

pub const BalanceResult = struct {
    address: []const u8,
    balance: u64,
    formatted: []const u8,
};

pub const SendResult = struct {
    hash: []const u8,
    lt: i64,
    destination: []const u8,
    amount: u64,
};

pub const InvoiceResult = struct {
    invoice_id: []const u8,
    address: []const u8,
    amount: u64,
    comment: []const u8,
    payment_url: []const u8,
};

pub const VerifyResult = struct {
    verified: bool,
    tx_hash: ?[]const u8,
    tx_lt: ?i64,
    amount: ?u64,
};

pub const TxResult = struct {
    hash: []const u8,
    lt: i64,
    timestamp: i64,
    from: ?[]const u8,
    to: ?[]const u8,
    value: u64,
    status: TxStatus,
};

pub const TxStatus = enum {
    pending,
    confirmed,
    failed,
};

pub const AgentToolsConfig = struct {
    rpc_url: []const u8,
    api_key: ?[]const u8 = null,
};
