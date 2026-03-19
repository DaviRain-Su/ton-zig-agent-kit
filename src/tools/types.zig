//! Agent tool types and results
//! Standardized return types for AI agent interactions

const std = @import("std");
const signing = @import("../wallet/signing.zig");

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
    decoded_json: ?[]const u8 = null,
    logs: []const u8,
    success: bool,
    error_message: ?[]const u8 = null,
};

pub const DecodedBodyKind = enum {
    function,
    event,
};

pub const DecodedBodyResult = struct {
    address: []const u8,
    kind: DecodedBodyKind,
    selector: []const u8,
    opcode: ?u32,
    decoded_json: []const u8,
    success: bool,
    error_message: ?[]const u8 = null,
};

pub const MessageResult = struct {
    hash: []const u8,
    source: ?[]const u8,
    destination: ?[]const u8,
    value: u64,
    body_bits: u16,
    body_refs: u8,
    body_boc: ?[]const u8,
    raw_body_utf8: ?[]const u8,
    raw_body_base64: ?[]const u8,
    decoded_body: ?DecodedBodyResult,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.hash.len > 0) allocator.free(self.hash);
        if (self.source) |value| allocator.free(value);
        if (self.destination) |value| allocator.free(value);
        if (self.body_boc) |value| allocator.free(value);
        if (self.raw_body_utf8) |value| allocator.free(value);
        if (self.raw_body_base64) |value| allocator.free(value);
        if (self.decoded_body) |*value| {
            if (value.address.len > 0) allocator.free(value.address);
            if (value.selector.len > 0) allocator.free(value.selector);
            if (value.decoded_json.len > 0) allocator.free(value.decoded_json);
        }
        self.* = undefined;
    }
};

pub const AddressResult = struct {
    raw_address: []const u8,
    user_friendly_address: []const u8,
    workchain: i8,
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

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.hash.len > 0) allocator.free(self.hash);
        if (self.from) |value| allocator.free(value);
        if (self.to) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const TransactionListResult = struct {
    address: []const u8,
    items: []TxResult,
    success: bool,
    error_message: ?[]const u8 = null,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        if (self.items.len > 0) allocator.free(self.items);
        self.* = undefined;
    }
};

pub const TransactionDetailResult = struct {
    hash: []const u8,
    lt: i64,
    timestamp: i64,
    in_message: ?MessageResult,
    out_messages: []MessageResult,
    success: bool,
    error_message: ?[]const u8 = null,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.hash.len > 0) allocator.free(self.hash);
        if (self.in_message) |*msg| msg.deinit(allocator);
        for (self.out_messages) |*msg| msg.deinit(allocator);
        if (self.out_messages.len > 0) allocator.free(self.out_messages);
        self.* = undefined;
    }
};

pub const ContractInspectResult = struct {
    address: []const u8,
    has_wallet: bool,
    has_jetton: bool,
    has_jetton_master: bool,
    has_jetton_wallet: bool,
    has_nft: bool,
    has_nft_item: bool,
    has_nft_collection: bool,
    has_abi: bool,
    abi_uri: ?[]const u8,
    abi_json: ?[]const u8,
    details_json: ?[]const u8,
    success: bool,
    error_message: ?[]const u8 = null,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.abi_uri) |value| allocator.free(value);
        if (self.abi_json) |value| allocator.free(value);
        if (self.details_json) |value| allocator.free(value);
        self.* = undefined;
    }
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
    wallet_workchain: i8 = 0,
    wallet_id: u32 = signing.default_wallet_id_v4,
};

pub const WalletInitResult = struct {
    raw_address: []const u8,
    user_friendly_address: []const u8,
    workchain: i8,
    wallet_id: u32,
    public_key_hex: []const u8,
    state_init_boc: []const u8,
    success: bool,
    error_message: ?[]const u8 = null,
};

pub const JettonBalanceResult = struct {
    address: []const u8,
    jetton_master: []const u8,
    balance: []const u8,
    decimals: u8,
    symbol: ?[]const u8,
    success: bool,
    error_message: ?[]const u8 = null,
};

pub const JettonInfoResult = struct {
    address: []const u8,
    total_supply: []const u8,
    mintable: bool,
    admin: ?[]const u8,
    content: ?[]const u8,
    content_uri: ?[]const u8,
    success: bool,
    error_message: ?[]const u8 = null,
};

pub const JettonWalletAddressResult = struct {
    owner_address: []const u8,
    jetton_master: []const u8,
    wallet_address: ?[]const u8,
    success: bool,
    error_message: ?[]const u8 = null,
};

pub const NFTInfoResult = struct {
    address: []const u8,
    owner: ?[]const u8,
    collection: ?[]const u8,
    index: []const u8,
    content: ?[]const u8,
    content_uri: ?[]const u8,
    success: bool,
    error_message: ?[]const u8 = null,
};

pub const NFTCollectionInfoResult = struct {
    address: []const u8,
    owner: ?[]const u8,
    next_item_index: []const u8,
    content: ?[]const u8,
    content_uri: ?[]const u8,
    success: bool,
    error_message: ?[]const u8 = null,
};

pub const ToolResponse = union(enum) {
    balance: BalanceResult,
    address: AddressResult,
    wallet_init: WalletInitResult,
    send: SendResult,
    run_method: RunMethodResult,
    decoded_body: DecodedBodyResult,
    invoice: InvoiceResult,
    verify: VerifyResult,
    transaction: TxResult,
    transaction_list: TransactionListResult,
    transaction_detail: TransactionDetailResult,
    contract_inspect: ContractInspectResult,
    jetton_balance: JettonBalanceResult,
    jetton_info: JettonInfoResult,
    jetton_wallet_address: JettonWalletAddressResult,
    nft_info: NFTInfoResult,
    nft_collection_info: NFTCollectionInfoResult,
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
