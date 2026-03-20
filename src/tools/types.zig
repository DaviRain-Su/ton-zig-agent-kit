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
    stack_summary_json: []const u8 = "{\"items\":[],\"unsupported_count\":0}",
    unsupported_count: u32 = 0,
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

pub const BodyAnalysisResult = struct {
    opcode: ?u32,
    opcode_name: ?[]const u8,
    comment: ?[]const u8,
    tail_utf8: ?[]const u8,
    decoded_json: ?[]const u8,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.opcode_name) |value| allocator.free(value);
        if (self.comment) |value| allocator.free(value);
        if (self.tail_utf8) |value| allocator.free(value);
        if (self.decoded_json) |value| allocator.free(value);
        self.* = undefined;
    }
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
    body_analysis: ?BodyAnalysisResult,
    decoded_body: ?DecodedBodyResult,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.hash.len > 0) allocator.free(self.hash);
        if (self.source) |value| allocator.free(value);
        if (self.destination) |value| allocator.free(value);
        if (self.body_boc) |value| allocator.free(value);
        if (self.raw_body_utf8) |value| allocator.free(value);
        if (self.raw_body_base64) |value| allocator.free(value);
        if (self.body_analysis) |*value| value.deinit(allocator);
        if (self.decoded_body) |*value| {
            if (value.address.len > 0) allocator.free(value.address);
            if (value.selector.len > 0) allocator.free(value.selector);
            if (value.decoded_json.len > 0) allocator.free(value.decoded_json);
        }
        self.* = undefined;
    }
};

pub const ObservedMessageDirection = enum {
    incoming,
    outgoing,
};

pub const ObservedMessageTemplateResult = struct {
    body_cli_template: ?[]const u8,
    send_cli_template: ?[]const u8,
    example_spec_json: ?[]const u8 = null,
    note: ?[]const u8,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.body_cli_template) |value| allocator.free(value);
        if (self.send_cli_template) |value| allocator.free(value);
        if (self.example_spec_json) |value| allocator.free(value);
        if (self.note) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const ObservedMessageSummaryResult = struct {
    direction: ObservedMessageDirection,
    count: u32,
    opcode: ?u32,
    opcode_name: ?[]const u8,
    comment: ?[]const u8,
    utf8_tail: ?[]const u8,
    abi_kind: ?DecodedBodyKind,
    abi_selector: ?[]const u8,
    template: ?ObservedMessageTemplateResult,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.opcode_name) |value| allocator.free(value);
        if (self.comment) |value| allocator.free(value);
        if (self.utf8_tail) |value| allocator.free(value);
        if (self.abi_selector) |value| allocator.free(value);
        if (self.template) |*value| value.deinit(allocator);
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
    abi_version: ?[]const u8,
    abi_json: ?[]const u8,
    functions: []AbiFunctionTemplateResult,
    events: []AbiEventTemplateResult,
    observed_messages: []ObservedMessageSummaryResult,
    details_json: ?[]const u8,
    success: bool,
    error_message: ?[]const u8 = null,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.abi_uri) |value| allocator.free(value);
        if (self.abi_version) |value| allocator.free(value);
        if (self.abi_json) |value| allocator.free(value);
        for (self.functions) |*item| item.deinit(allocator);
        if (self.functions.len > 0) allocator.free(self.functions);
        for (self.events) |*item| item.deinit(allocator);
        if (self.events.len > 0) allocator.free(self.events);
        for (self.observed_messages) |*item| item.deinit(allocator);
        if (self.observed_messages.len > 0) allocator.free(self.observed_messages);
        if (self.details_json) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const AbiParamTemplateResult = struct {
    name: []const u8,
    type_name: []const u8,
    cli_template: []const u8,
    json_template: []const u8,
    decoded_template: []const u8,
    components: []AbiParamTemplateResult,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.name.len > 0) allocator.free(self.name);
        if (self.type_name.len > 0) allocator.free(self.type_name);
        if (self.cli_template.len > 0) allocator.free(self.cli_template);
        if (self.json_template.len > 0) allocator.free(self.json_template);
        if (self.decoded_template.len > 0) allocator.free(self.decoded_template);
        for (self.components) |*item| item.deinit(allocator);
        if (self.components.len > 0) allocator.free(self.components);
        self.* = undefined;
    }
};

pub const AbiFunctionTemplateResult = struct {
    name: []const u8,
    selector: []const u8,
    opcode: ?u32,
    input_template: []const u8,
    named_input_template: []const u8,
    decoded_output_template: []const u8,
    inputs: []AbiParamTemplateResult,
    outputs: []AbiParamTemplateResult,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.name.len > 0) allocator.free(self.name);
        if (self.selector.len > 0) allocator.free(self.selector);
        if (self.input_template.len > 0) allocator.free(self.input_template);
        if (self.named_input_template.len > 0) allocator.free(self.named_input_template);
        if (self.decoded_output_template.len > 0) allocator.free(self.decoded_output_template);
        for (self.inputs) |*item| item.deinit(allocator);
        if (self.inputs.len > 0) allocator.free(self.inputs);
        for (self.outputs) |*item| item.deinit(allocator);
        if (self.outputs.len > 0) allocator.free(self.outputs);
        self.* = undefined;
    }
};

pub const AbiEventTemplateResult = struct {
    name: []const u8,
    selector: []const u8,
    opcode: ?u32,
    decoded_fields_template: []const u8,
    fields: []AbiParamTemplateResult,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.name.len > 0) allocator.free(self.name);
        if (self.selector.len > 0) allocator.free(self.selector);
        if (self.decoded_fields_template.len > 0) allocator.free(self.decoded_fields_template);
        for (self.fields) |*item| item.deinit(allocator);
        if (self.fields.len > 0) allocator.free(self.fields);
        self.* = undefined;
    }
};

pub const AbiDescribeResult = struct {
    source: []const u8,
    address: ?[]const u8,
    version: []const u8,
    uri: ?[]const u8,
    functions: []AbiFunctionTemplateResult,
    events: []AbiEventTemplateResult,
    success: bool,
    error_message: ?[]const u8 = null,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.source.len > 0) allocator.free(self.source);
        if (self.address) |value| allocator.free(value);
        if (self.version.len > 0) allocator.free(self.version);
        if (self.uri) |value| allocator.free(value);
        for (self.functions) |*item| item.deinit(allocator);
        if (self.functions.len > 0) allocator.free(self.functions);
        for (self.events) |*item| item.deinit(allocator);
        if (self.events.len > 0) allocator.free(self.events);
        self.* = undefined;
    }
};

pub const BuiltBodyResult = struct {
    address: ?[]const u8,
    selector: []const u8,
    body_boc: []const u8,
    body_hex: []const u8,
    success: bool,
    error_message: ?[]const u8 = null,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.address) |value| allocator.free(value);
        if (self.selector.len > 0) allocator.free(self.selector);
        if (self.body_boc.len > 0) allocator.free(self.body_boc);
        if (self.body_hex.len > 0) allocator.free(self.body_hex);
        self.* = undefined;
    }
};

pub const BuiltExternalMessageResult = struct {
    destination: []const u8,
    body_boc: []const u8,
    external_boc: []const u8,
    external_hex: []const u8,
    state_init_attached: bool,
    success: bool,
    error_message: ?[]const u8 = null,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.destination.len > 0) allocator.free(self.destination);
        if (self.body_boc.len > 0) allocator.free(self.body_boc);
        if (self.external_boc.len > 0) allocator.free(self.external_boc);
        if (self.external_hex.len > 0) allocator.free(self.external_hex);
        self.* = undefined;
    }
};

pub const BuiltWalletMessageResult = struct {
    wallet_address: []const u8,
    destination: []const u8,
    amount: u64,
    wallet_id: u32,
    seqno: u32,
    external_boc: []const u8,
    external_hex: []const u8,
    state_init_attached: bool,
    success: bool,
    error_message: ?[]const u8 = null,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.wallet_address.len > 0) allocator.free(self.wallet_address);
        if (self.destination.len > 0) allocator.free(self.destination);
        if (self.external_boc.len > 0) allocator.free(self.external_boc);
        if (self.external_hex.len > 0) allocator.free(self.external_hex);
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
    built_body: BuiltBodyResult,
    built_external: BuiltExternalMessageResult,
    built_wallet: BuiltWalletMessageResult,
    invoice: InvoiceResult,
    verify: VerifyResult,
    transaction: TxResult,
    transaction_list: TransactionListResult,
    transaction_detail: TransactionDetailResult,
    contract_inspect: ContractInspectResult,
    abi_describe: AbiDescribeResult,
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
