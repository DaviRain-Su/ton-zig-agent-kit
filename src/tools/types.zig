//! Agent tool types and results
//! Standardized return types for AI agent interactions

const std = @import("std");

pub const BalanceResult = struct {
    address: []const u8,
    balance: u64,
    formatted: []const u8,
    success: bool,
    error_message: ?[]const u8 = null,
};

pub const SendResult = struct {
    hash: []const u8,
    lt: i64,
    destination: []const u8,
    amount: u64,
    success: bool,
    error_message: ?[]const u8 = null,
};

pub const RunMethodResult = struct {
    address: []const u8,
    method: []const u8,
    exit_code: i32,
    stack_json: []const u8,
    logs: []const u8,
    success: bool,
    error_message: ?[]const u8 = null,
};

pub const InvoiceResult = struct {
    invoice_id: []const u8,
    address: []const u8,
    amount: u64,
    comment: []const u8,
    payment_url: []const u8,
    expires_at: i64,
    success: bool,
    error_message: ?[]const u8 = null,
};

pub const VerifyResult = struct {
    verified: bool,
    tx_hash: ?[]const u8,
    tx_lt: ?i64,
    amount: ?u64,
    sender: ?[]const u8,
    timestamp: ?i64,
    success: bool,
    error_message: ?[]const u8 = null,
};

pub const TxResult = struct {
    hash: []const u8,
    lt: i64,
    timestamp: i64,
    from: ?[]const u8,
    to: ?[]const u8,
    value: u64,
    status: TxStatus,
    success: bool,
    error_message: ?[]const u8 = null,
};

pub const TxStatus = enum {
    pending,
    confirmed,
    failed,
    unknown,
};

pub const AgentToolsConfig = struct {
    rpc_url: []const u8,
    api_key: ?[]const u8 = null,
    wallet_address: ?[]const u8 = null,
    wallet_private_key: ?[32]u8 = null,
};

pub const JettonBalanceResult = struct {
    address: []const u8,
    jetton_master: []const u8,
    balance: u64,
    decimals: u8,
    symbol: ?[]const u8,
    success: bool,
    error_message: ?[]const u8 = null,
};

pub const NFTInfoResult = struct {
    address: []const u8,
    owner: ?[]const u8,
    collection: ?[]const u8,
    index: u64,
    content: ?[]const u8,
    content_uri: ?[]const u8,
    success: bool,
    error_message: ?[]const u8 = null,
};

pub const ToolResponse = union(enum) {
    balance: BalanceResult,
    send: SendResult,
    run_method: RunMethodResult,
    invoice: InvoiceResult,
    verify: VerifyResult,
    transaction: TxResult,
    jetton_balance: JettonBalanceResult,
    nft_info: NFTInfoResult,
    err: ToolError,
};

pub const ToolError = struct {
    code: ErrorCode,
    message: []const u8,
};

pub const ErrorCode = enum {
    invalid_address,
    insufficient_balance,
    network_error,
    timeout,
    not_found,
    invalid_params,
    internal_error,
};
