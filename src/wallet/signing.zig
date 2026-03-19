//! Wallet signing and message creation
//! Supports wallet v4 (rwallet) with Ed25519 signing

const std = @import("std");
const types = @import("../core/types.zig");
const cell = @import("../core/cell.zig");
const boc = @import("../core/boc.zig");
const external_message = @import("../core/external_message.zig");
const state_init = @import("../core/state_init.zig");
const generic_contract = @import("../contract/contract.zig");

const Ed25519 = std.crypto.sign.Ed25519;
pub const default_wallet_id_v4: u32 = 698983191;
const simple_send_opcode: u32 = 0;
const wallet_v4r2_code_boc_hex =
    "B5EE9C72410214010002D4000114FF00F4A413F4BCF2C80B010201200203020148040504F8F28308D71820D31FD31FD31F02F823BBF264ED44D0D31FD31FD3FFF404D15143BAF2A15151BAF2A205F901541064F910F2A3F80024A4C8CB1F5240CB1F5230CBFF5210F400C9ED54F80F01D30721C0009F6C519320D74A96D307D402FB00E830E021C001E30021C002E30001C0039130E30D03A4C8CB1F12CB1FCBFF1011121302E6D001D0D3032171B0925F04E022D749C120925F04E002D31F218210706C7567BD22821064737472BDB0925F05E003FA403020FA4401C8CA07CBFFC9D0ED44D0810140D721F404305C810108F40A6FA131B3925F07E005D33FC8258210706C7567BA923830E30D03821064737472BA925F06E30D06070201200809007801FA00F40430F8276F2230500AA121BEF2E0508210706C7567831EB17080185004CB0526CF1658FA0219F400CB6917CB1F5260CB3F20C98040FB0006008A5004810108F45930ED44D0810140D720C801CF16F400C9ED540172B08E23821064737472831EB17080185005CB055003CF1623FA0213CB6ACB1FCB3FC98040FB00925F03E20201200A0B0059BD242B6F6A2684080A06B90FA0218470D4080847A4937D29910CE6903E9FF9837812801B7810148987159F31840201580C0D0011B8C97ED44D0D70B1F8003DB29DFB513420405035C87D010C00B23281F2FFF274006040423D029BE84C600201200E0F0019ADCE76A26840206B90EB85FFC00019AF1DF6A26840106B90EB858FC0006ED207FA00D4D422F90005C8CA0715CBFFC9D077748018C8CB05CB0222CF165005FA0214CB6B12CCCCC973FB00C84014810108F451F2A7020070810108D718FA00D33FC8542047810108F451F2A782106E6F746570748018C8CB05CB025006CF165004FA0214CB6A12CB1FCB3FC973FB0002006C810108D718FA00D33F305224810108F459F2A782106473747270748018C8CB05CB025005CF165003FA0213CB6ACB1F12CB3FC973FB00000AF400C9ED54696225E5";
const wallet_v4r2_code_hash_base64 = "/rX/aCDi/w2Ug+fg1iyBfYRniftK5YDIeIZtlZ2r1cA=";

pub const WalletVersion = enum {
    v2,
    v3,
    v4,
};

pub const WalletMessage = struct {
    destination: []const u8,
    amount: u64,
    state_init: ?[]const u8 = null, // Raw StateInit BoC
    body: ?[]const u8 = null, // Raw body BoC
    comment: ?[]const u8 = null,
    mode: u8 = 3, // 3 = pay separately
    bounce: bool = true,
};

pub const WalletInfo = struct {
    seqno: u32,
    wallet_id: u32,
    public_key: [32]u8,
};

pub const WalletV4Init = struct {
    workchain: i8,
    wallet_id: u32,
    public_key: [32]u8,
    state_init_boc: []u8,
    address: types.Address,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.state_init_boc.len > 0) allocator.free(self.state_init_boc);
    }
};

pub const BuiltWalletExternalMessage = struct {
    wallet_address: []u8,
    boc: []u8,
    state_init_attached: bool,
    wallet_id: u32,
    seqno: u32,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.wallet_address.len > 0) allocator.free(self.wallet_address);
        if (self.boc.len > 0) allocator.free(self.boc);
        self.* = undefined;
    }
};

/// Generate Ed25519 keypair from seed
pub fn generateKeypair(seed: []const u8) ![2][32]u8 {
    const seed_bytes = deriveSeed(seed);
    return keypairFromPrivateKeySeed(seed_bytes);
}

pub fn keypairFromPrivateKeySeed(seed: [32]u8) ![2][32]u8 {
    const keypair = try Ed25519.KeyPair.generateDeterministic(seed);

    return .{
        keypair.secret_key.seed(),
        keypair.public_key.toBytes(),
    };
}

pub fn derivePublicKey(private_key_seed: [32]u8) ![32]u8 {
    const keypair = try ed25519KeyPairFromSeed(private_key_seed);
    return keypair.public_key.toBytes();
}

fn decodeHexAlloc(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, hex, " \t\r\n");
    if (trimmed.len % 2 != 0) return error.InvalidHex;

    const out = try allocator.alloc(u8, trimmed.len / 2);
    errdefer allocator.free(out);
    _ = try std.fmt.hexToBytes(out, trimmed);
    return out;
}

pub fn walletV4CodeBocAlloc(allocator: std.mem.Allocator) ![]u8 {
    return decodeHexAlloc(allocator, wallet_v4r2_code_boc_hex);
}

fn encodeHexPrefixedLowerAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const hex_chars = "0123456789abcdef";
    const out = try allocator.alloc(u8, 2 + bytes.len * 2);
    errdefer allocator.free(out);

    out[0] = '0';
    out[1] = 'x';
    for (bytes, 0..) |byte, idx| {
        out[2 + idx * 2] = hex_chars[byte >> 4];
        out[2 + idx * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return out;
}

pub fn buildWalletV4DataCellAlloc(
    allocator: std.mem.Allocator,
    public_key: [32]u8,
    wallet_id: u32,
    seqno: u32,
) !*cell.Cell {
    var builder = cell.Builder.init();
    try builder.storeUint(seqno, 32);
    try builder.storeUint(wallet_id, 32);
    try builder.storeBits(&public_key, 256);
    try builder.storeUint(0, 1); // plugins:(HashmapE 256 int1) empty
    return builder.toCell(allocator);
}

pub fn buildWalletV4DataBocAlloc(
    allocator: std.mem.Allocator,
    public_key: [32]u8,
    wallet_id: u32,
    seqno: u32,
) ![]u8 {
    const data_cell = try buildWalletV4DataCellAlloc(allocator, public_key, wallet_id, seqno);
    defer data_cell.deinit(allocator);
    return boc.serializeBoc(allocator, data_cell);
}

pub fn buildWalletV4StateInitBocAlloc(
    allocator: std.mem.Allocator,
    public_key: [32]u8,
    wallet_id: u32,
    seqno: u32,
) ![]u8 {
    const code_boc = try walletV4CodeBocAlloc(allocator);
    defer allocator.free(code_boc);

    const data_boc = try buildWalletV4DataBocAlloc(allocator, public_key, wallet_id, seqno);
    defer allocator.free(data_boc);

    return state_init.buildStateInitBocAlloc(allocator, code_boc, data_boc);
}

pub fn deriveWalletV4InitFromPublicKeyAlloc(
    allocator: std.mem.Allocator,
    workchain: i8,
    wallet_id: u32,
    public_key: [32]u8,
) !WalletV4Init {
    const state_init_boc = try buildWalletV4StateInitBocAlloc(allocator, public_key, wallet_id, 0);
    errdefer allocator.free(state_init_boc);

    return .{
        .workchain = workchain,
        .wallet_id = wallet_id,
        .public_key = public_key,
        .address = try state_init.computeStateInitAddressFromBoc(allocator, workchain, state_init_boc),
        .state_init_boc = state_init_boc,
    };
}

pub fn deriveWalletV4InitFromPrivateKeyAlloc(
    allocator: std.mem.Allocator,
    workchain: i8,
    wallet_id: u32,
    private_key_seed: [32]u8,
) !WalletV4Init {
    return deriveWalletV4InitFromPublicKeyAlloc(
        allocator,
        workchain,
        wallet_id,
        try derivePublicKey(private_key_seed),
    );
}

fn deriveSeed(seed: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(seed);
    return hasher.finalResult();
}

fn ed25519KeyPairFromSeed(seed: [32]u8) !Ed25519.KeyPair {
    return Ed25519.KeyPair.generateDeterministic(seed);
}

fn destroyCellShallow(allocator: std.mem.Allocator, value: *cell.Cell) void {
    value.ref_cnt = 0;
    allocator.destroy(value);
}

fn deinitBuilderRefs(allocator: std.mem.Allocator, builder: *cell.Builder) void {
    for (builder.refs[0..builder.ref_cnt]) |ref| {
        if (ref) |child| child.deinit(allocator);
    }
}

fn createCommentBodyCell(allocator: std.mem.Allocator, comment: []const u8) !*cell.Cell {
    var builder = cell.Builder.init();
    try builder.storeUint(0, 32);
    try builder.storeBits(comment, @intCast(comment.len * 8));
    return builder.toCell(allocator);
}

fn decodeBodyCellFromBoc(allocator: std.mem.Allocator, body_boc: []const u8) !*cell.Cell {
    return boc.deserializeBoc(allocator, body_boc);
}

fn createInternalTransferMessageCell(
    allocator: std.mem.Allocator,
    msg: WalletMessage,
) !*cell.Cell {
    var msg_builder = cell.Builder.init();
    errdefer deinitBuilderRefs(allocator, &msg_builder);

    try msg_builder.storeUint(0, 1); // int_msg_info$0
    try msg_builder.storeUint(1, 1); // ihr_disabled
    try msg_builder.storeUint(if (msg.bounce) 1 else 0, 1); // bounce
    try msg_builder.storeUint(0, 1); // bounced

    try msg_builder.storeUint(0, 2); // src: addr_none
    try msg_builder.storeAddress(msg.destination);

    try msg_builder.storeCoins(msg.amount);
    try msg_builder.storeUint(0, 1); // no extra currencies
    try msg_builder.storeCoins(0); // ihr_fee
    try msg_builder.storeCoins(0); // fwd_fee
    try msg_builder.storeUint(0, 64); // created_lt
    try msg_builder.storeUint(0, 32); // created_at

    if (msg.state_init) |state_init_boc| {
        const state_init_cell = try boc.deserializeBoc(allocator, state_init_boc);
        try msg_builder.storeUint(1, 1); // state_init present
        try msg_builder.storeUint(1, 1); // state_init in ref
        try msg_builder.storeRef(state_init_cell);
    } else {
        try msg_builder.storeUint(0, 1); // state_init absent
    }

    if (msg.body) |body_boc| {
        const body_cell = try decodeBodyCellFromBoc(allocator, body_boc);
        try msg_builder.storeUint(1, 1); // body in ref
        try msg_builder.storeRef(body_cell);
    } else if (msg.comment) |comment| {
        const comment_cell = try createCommentBodyCell(allocator, comment);
        try msg_builder.storeUint(1, 1); // body in ref
        try msg_builder.storeRef(comment_cell);
    } else {
        try msg_builder.storeUint(0, 1); // empty inline body
    }

    return msg_builder.toCell(allocator);
}

fn createWalletV4SigningPayloadCell(
    allocator: std.mem.Allocator,
    wallet_id: u32,
    seqno: u32,
    valid_until: u32,
    messages: []const WalletMessage,
) !*cell.Cell {
    var builder = cell.Builder.init();

    try builder.storeUint(wallet_id, 32);
    try builder.storeUint(valid_until, 32);
    try builder.storeUint(seqno, 32);
    try builder.storeUint(simple_send_opcode, 32);

    for (messages) |msg| {
        const out_msg = try createInternalTransferMessageCell(allocator, msg);
        try builder.storeUint(msg.mode, 8);
        try builder.storeRef(out_msg);
    }

    return builder.toCell(allocator);
}

fn createSignedBodyCell(
    allocator: std.mem.Allocator,
    private_key_seed: [32]u8,
    wallet_id: u32,
    seqno: u32,
    valid_until: u32,
    messages: []const WalletMessage,
) !*cell.Cell {
    const payload_cell = try createWalletV4SigningPayloadCell(allocator, wallet_id, seqno, valid_until, messages);
    defer destroyCellShallow(allocator, payload_cell);

    const signature = try signMessage(private_key_seed, &payload_cell.hash());

    var builder = cell.Builder.init();
    try builder.storeBits(&signature, signature.len * 8);

    var payload_slice = payload_cell.toSlice();
    try builder.storeSlice(&payload_slice);

    return builder.toCell(allocator);
}

fn createExternalIncomingMessageCell(
    allocator: std.mem.Allocator,
    wallet_addr: []const u8,
    body_cell: *cell.Cell,
    state_init_boc: ?[]const u8,
) !*cell.Cell {
    return external_message.buildExternalIncomingMessageCellAlloc(
        allocator,
        wallet_addr,
        body_cell,
        state_init_boc,
    );
}

fn createWalletV4ExternalMessageWithId(
    allocator: std.mem.Allocator,
    private_key_seed: [32]u8,
    wallet_addr: []const u8,
    wallet_id: u32,
    seqno: u32,
    valid_until: u32,
    messages: []const WalletMessage,
    state_init_boc: ?[]const u8,
) ![]u8 {
    const signed_body = try createSignedBodyCell(allocator, private_key_seed, wallet_id, seqno, valid_until, messages);
    errdefer signed_body.deinit(allocator);

    const ext_msg = try createExternalIncomingMessageCell(allocator, wallet_addr, signed_body, state_init_boc);
    defer ext_msg.deinit(allocator);

    return boc.serializeBoc(allocator, ext_msg);
}

/// Create wallet v4 external message
pub fn createWalletV4ExternalMessage(
    allocator: std.mem.Allocator,
    private_key_seed: [32]u8,
    wallet_addr: []const u8,
    seqno: u32,
    valid_until: u32,
    messages: []const WalletMessage,
) ![]u8 {
    return createWalletV4ExternalMessageWithId(
        allocator,
        private_key_seed,
        wallet_addr,
        default_wallet_id_v4,
        seqno,
        valid_until,
        messages,
        null,
    );
}

/// Sign message with Ed25519
pub fn signMessage(private_key: [32]u8, message: []const u8) ![64]u8 {
    const key_pair = try ed25519KeyPairFromSeed(private_key);
    const signature = try key_pair.sign(message, null);
    return signature.toBytes();
}

/// Create signed transfer (wallet v4)
pub fn createSignedTransfer(
    allocator: std.mem.Allocator,
    version: WalletVersion,
    private_key: [32]u8,
    wallet_address: []const u8,
    seqno: u32,
    msgs: []const WalletMessage,
) ![]u8 {
    if (version != .v4) return error.UnsupportedWalletVersion;

    const valid_until = @as(u32, @intCast(std.time.timestamp())) + 60;

    return createSignedTransferWithWalletId(
        allocator,
        version,
        private_key,
        wallet_address,
        default_wallet_id_v4,
        seqno,
        msgs,
        valid_until,
    );
}

pub fn createSignedTransferWithWalletId(
    allocator: std.mem.Allocator,
    version: WalletVersion,
    private_key: [32]u8,
    wallet_address: []const u8,
    wallet_id: u32,
    seqno: u32,
    msgs: []const WalletMessage,
    valid_until: u32,
) ![]u8 {
    if (version != .v4) return error.UnsupportedWalletVersion;

    return createWalletV4ExternalMessageWithId(
        allocator,
        private_key,
        wallet_address,
        wallet_id,
        seqno,
        valid_until,
        msgs,
        null,
    );
}

/// Get seqno from wallet
pub fn getSeqno(client: anytype, wallet_address: []const u8) !u32 {
    var result = try client.runGetMethod(wallet_address, "seqno", &.{});
    defer client.freeRunGetMethodResponse(&result);

    // Parse seqno from stack
    if (result.stack.len > 0) {
        // First stack entry should be the seqno number
        switch (result.stack[0]) {
            .number => |n| return @intCast(n),
            .big_number => |n| return try std.fmt.parseInt(u32, if (std.mem.startsWith(u8, n, "0x")) n[2..] else n, if (std.mem.startsWith(u8, n, "0x")) 16 else 10),
            else => return error.InvalidResponse,
        }
    }

    return 0;
}

pub fn getSubwalletId(client: anytype, wallet_address: []const u8) !u32 {
    var result = try client.runGetMethod(wallet_address, "get_subwallet_id", &.{});
    defer client.freeRunGetMethodResponse(&result);

    if (result.stack.len == 0) return error.InvalidResponse;
    return generic_contract.stackEntryAsUnsigned(u32, &result.stack[0]);
}

pub fn getPublicKey(client: anytype, wallet_address: []const u8) ![32]u8 {
    var result = try client.runGetMethod(wallet_address, "get_public_key", &.{});
    defer client.freeRunGetMethodResponse(&result);

    if (result.stack.len == 0) return error.InvalidResponse;
    return stackEntryAsPublicKeyBytes(&result.stack[0]);
}

pub fn getWalletInfo(client: anytype, wallet_address: []const u8) !WalletInfo {
    return .{
        .seqno = try getSeqno(client, wallet_address),
        .wallet_id = try getSubwalletId(client, wallet_address),
        .public_key = try getPublicKey(client, wallet_address),
    };
}

fn stackEntryAsPublicKeyBytes(entry: *const types.StackEntry) ![32]u8 {
    const value = try generic_contract.stackEntryAsUnsigned(u256, entry);
    return u256ToBytes(value);
}

fn u256ToBytes(value: u256) [32]u8 {
    var out: [32]u8 = undefined;
    var remaining = value;
    var idx: usize = out.len;
    while (idx > 0) {
        idx -= 1;
        out[idx] = @intCast(remaining & 0xff);
        remaining >>= 8;
    }
    return out;
}

/// Send transfer
pub fn sendTransfer(
    client: anytype,
    version: WalletVersion,
    private_key: [32]u8,
    wallet_address: []const u8,
    destination: []const u8,
    amount: u64,
    comment: ?[]const u8,
) !types.SendBocResponse {
    const msgs = &[_]WalletMessage{
        .{
            .destination = destination,
            .amount = amount,
            .comment = comment,
        },
    };

    return sendMessages(client, version, private_key, wallet_address, msgs);
}

pub fn sendInitialTransfer(
    client: anytype,
    version: WalletVersion,
    private_key: [32]u8,
    workchain: i8,
    wallet_id: u32,
    destination: []const u8,
    amount: u64,
    comment: ?[]const u8,
) !types.SendBocResponse {
    const msgs = &[_]WalletMessage{
        .{
            .destination = destination,
            .amount = amount,
            .comment = comment,
        },
    };

    return sendInitialMessages(client, version, private_key, workchain, wallet_id, msgs);
}

pub fn sendBody(
    client: anytype,
    version: WalletVersion,
    private_key: [32]u8,
    wallet_address: []const u8,
    destination: []const u8,
    amount: u64,
    body_boc: []const u8,
) !types.SendBocResponse {
    const msgs = &[_]WalletMessage{
        .{
            .destination = destination,
            .amount = amount,
            .body = body_boc,
        },
    };

    return sendMessages(client, version, private_key, wallet_address, msgs);
}

pub fn sendDeploy(
    client: anytype,
    version: WalletVersion,
    private_key: [32]u8,
    wallet_address: []const u8,
    destination: []const u8,
    amount: u64,
    state_init_boc: []const u8,
    body_boc: ?[]const u8,
) !types.SendBocResponse {
    const msgs = &[_]WalletMessage{
        .{
            .destination = destination,
            .amount = amount,
            .state_init = state_init_boc,
            .body = body_boc,
            .bounce = false,
        },
    };

    return sendMessages(client, version, private_key, wallet_address, msgs);
}

pub fn deployWallet(
    client: anytype,
    version: WalletVersion,
    private_key: [32]u8,
    workchain: i8,
    wallet_id: u32,
) !types.SendBocResponse {
    return sendInitialMessages(client, version, private_key, workchain, wallet_id, &.{});
}

pub fn buildInitialMessagesAlloc(
    allocator: std.mem.Allocator,
    version: WalletVersion,
    private_key: [32]u8,
    workchain: i8,
    wallet_id: u32,
    msgs: []const WalletMessage,
) !BuiltWalletExternalMessage {
    if (version != .v4) return error.UnsupportedWalletVersion;

    var init = try deriveWalletV4InitFromPrivateKeyAlloc(allocator, workchain, wallet_id, private_key);
    defer init.deinit(allocator);

    const raw_address = try init.address.toRawAlloc(allocator);
    errdefer allocator.free(raw_address);

    const valid_until = @as(u32, @intCast(std.time.timestamp())) + 60;

    return .{
        .wallet_address = raw_address,
        .boc = try createWalletV4ExternalMessageWithId(
            allocator,
            private_key,
            raw_address,
            wallet_id,
            0,
            valid_until,
            msgs,
            init.state_init_boc,
        ),
        .state_init_attached = true,
        .wallet_id = wallet_id,
        .seqno = 0,
    };
}

pub fn buildWalletDeploymentAlloc(
    allocator: std.mem.Allocator,
    version: WalletVersion,
    private_key: [32]u8,
    workchain: i8,
    wallet_id: u32,
) !BuiltWalletExternalMessage {
    return buildInitialMessagesAlloc(allocator, version, private_key, workchain, wallet_id, &.{});
}

pub fn sendInitialMessages(
    client: anytype,
    version: WalletVersion,
    private_key: [32]u8,
    workchain: i8,
    wallet_id: u32,
    msgs: []const WalletMessage,
) !types.SendBocResponse {
    if (version != .v4) return error.UnsupportedWalletVersion;

    const allocator = std.heap.page_allocator;
    var init = try deriveWalletV4InitFromPrivateKeyAlloc(allocator, workchain, wallet_id, private_key);
    defer init.deinit(allocator);

    const raw_address = try init.address.toRawAlloc(allocator);
    defer allocator.free(raw_address);

    const valid_until = @as(u32, @intCast(std.time.timestamp())) + 60;
    const signed_transfer = try createWalletV4ExternalMessageWithId(
        allocator,
        private_key,
        raw_address,
        wallet_id,
        0,
        valid_until,
        msgs,
        init.state_init_boc,
    );
    defer allocator.free(signed_transfer);

    return try client.sendBoc(signed_transfer);
}

fn verifyWalletPublicKey(private_key: [32]u8, wallet_public_key: [32]u8) !void {
    const key_pair = try ed25519KeyPairFromSeed(private_key);
    const public_key = key_pair.public_key.toBytes();
    if (!std.mem.eql(u8, &wallet_public_key, &public_key)) return error.InvalidWalletPublicKey;
}

fn sendPreparedMessages(
    client: anytype,
    version: WalletVersion,
    private_key: [32]u8,
    wallet_address: []const u8,
    wallet_id: u32,
    seqno: u32,
    msgs: []const WalletMessage,
) !types.SendBocResponse {
    const allocator = std.heap.page_allocator;
    const valid_until = @as(u32, @intCast(std.time.timestamp())) + 60;
    const signed_transfer = try createSignedTransferWithWalletId(
        allocator,
        version,
        private_key,
        wallet_address,
        wallet_id,
        seqno,
        msgs,
        valid_until,
    );
    defer allocator.free(signed_transfer);

    return try client.sendBoc(signed_transfer);
}

pub fn sendMessages(
    client: anytype,
    version: WalletVersion,
    private_key: [32]u8,
    wallet_address: []const u8,
    msgs: []const WalletMessage,
) !types.SendBocResponse {
    const wallet_info = try getWalletInfo(client, wallet_address);
    try verifyWalletPublicKey(private_key, wallet_info.public_key);
    return sendPreparedMessages(client, version, private_key, wallet_address, wallet_info.wallet_id, wallet_info.seqno, msgs);
}

pub fn sendMessagesAuto(
    client: anytype,
    version: WalletVersion,
    private_key: [32]u8,
    wallet_address: ?[]const u8,
    workchain: i8,
    wallet_id: u32,
    msgs: []const WalletMessage,
) !types.SendBocResponse {
    if (wallet_address) |addr| {
        return sendMessages(client, version, private_key, addr, msgs);
    }

    const allocator = std.heap.page_allocator;
    var init = try deriveWalletV4InitFromPrivateKeyAlloc(allocator, workchain, wallet_id, private_key);
    defer init.deinit(allocator);

    const raw_address = try init.address.toRawAlloc(allocator);
    defer allocator.free(raw_address);

    const wallet_info = getWalletInfo(client, raw_address) catch |err| {
        if (err == error.InvalidResponse) {
            return sendInitialMessages(client, version, private_key, workchain, wallet_id, msgs);
        }
        return err;
    };

    try verifyWalletPublicKey(private_key, wallet_info.public_key);
    return sendPreparedMessages(client, version, private_key, raw_address, wallet_info.wallet_id, wallet_info.seqno, msgs);
}

pub fn buildSignedMessagesAutoAlloc(
    client: anytype,
    allocator: std.mem.Allocator,
    version: WalletVersion,
    private_key: [32]u8,
    wallet_address: ?[]const u8,
    workchain: i8,
    wallet_id: u32,
    msgs: []const WalletMessage,
) !BuiltWalletExternalMessage {
    if (version != .v4) return error.UnsupportedWalletVersion;

    const valid_until = @as(u32, @intCast(std.time.timestamp())) + 60;

    if (wallet_address) |addr| {
        const wallet_info = try getWalletInfo(client, addr);
        try verifyWalletPublicKey(private_key, wallet_info.public_key);

        return .{
            .wallet_address = try allocator.dupe(u8, addr),
            .boc = try createSignedTransferWithWalletId(
                allocator,
                version,
                private_key,
                addr,
                wallet_info.wallet_id,
                wallet_info.seqno,
                msgs,
                valid_until,
            ),
            .state_init_attached = false,
            .wallet_id = wallet_info.wallet_id,
            .seqno = wallet_info.seqno,
        };
    }

    var init = try deriveWalletV4InitFromPrivateKeyAlloc(allocator, workchain, wallet_id, private_key);
    defer init.deinit(allocator);

    const raw_address = try init.address.toRawAlloc(allocator);
    errdefer allocator.free(raw_address);

    const wallet_info = getWalletInfo(client, raw_address) catch |err| {
        if (err == error.InvalidResponse) {
            allocator.free(raw_address);
            return buildInitialMessagesAlloc(allocator, version, private_key, workchain, wallet_id, msgs);
        }
        return err;
    };

    try verifyWalletPublicKey(private_key, wallet_info.public_key);
    return .{
        .wallet_address = raw_address,
        .boc = try createSignedTransferWithWalletId(
            allocator,
            version,
            private_key,
            raw_address,
            wallet_info.wallet_id,
            wallet_info.seqno,
            msgs,
            valid_until,
        ),
        .state_init_attached = false,
        .wallet_id = wallet_info.wallet_id,
        .seqno = wallet_info.seqno,
    };
}

test "wallet keypair generation" {
    const keypair = try generateKeypair("test_seed");
    _ = keypair;
}

test "wallet signing verifies with ed25519" {
    const allocator = std.testing.allocator;

    const keypair = try generateKeypair("test_seed");
    const private_key = keypair[0];
    const public_key = try Ed25519.PublicKey.fromBytes(keypair[1]);

    var msgs = [_]WalletMessage{
        .{
            .destination = "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
            .amount = 1_000_000_000,
        },
    };

    const signed = try createSignedTransfer(
        allocator,
        .v4,
        private_key,
        "0:0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
        0,
        msgs[0..],
    );
    defer allocator.free(signed);

    const ext_msg = try boc.deserializeBoc(allocator, signed);
    defer ext_msg.deinit(allocator);

    var ext_slice = ext_msg.toSlice();
    try std.testing.expectEqual(@as(u64, 0b10), try ext_slice.loadUint(2));
    try std.testing.expectEqual(@as(u64, 0), try ext_slice.loadUint(2));
    _ = try ext_slice.loadAddress();
    try std.testing.expectEqual(@as(u64, 0), try ext_slice.loadCoins());
    try std.testing.expectEqual(@as(u64, 0), try ext_slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 1), try ext_slice.loadUint(1));

    const body_cell = try ext_slice.loadRef();
    var body_slice = body_cell.toSlice();
    const signature_bytes = try body_slice.loadBits(512);

    var payload_builder = cell.Builder.init();
    try payload_builder.storeSlice(&body_slice);
    const payload_cell = try payload_builder.toCell(allocator);
    defer destroyCellShallow(allocator, payload_cell);

    const signature = Ed25519.Signature.fromBytes(signature_bytes[0..64].*);
    try signature.verify(&payload_cell.hash(), public_key);
}

test "wallet signing preserves raw body boc in internal message" {
    const allocator = std.testing.allocator;

    var body_builder = cell.Builder.init();
    try body_builder.storeUint(0x12345678, 32);
    try body_builder.storeUint(0xAB, 8);
    const raw_body_cell = try body_builder.toCell(allocator);
    defer raw_body_cell.deinit(allocator);

    const raw_body_boc = try boc.serializeBoc(allocator, raw_body_cell);
    defer allocator.free(raw_body_boc);

    const keypair = try generateKeypair("test_seed");
    var msgs = [_]WalletMessage{
        .{
            .destination = "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
            .amount = 1_000_000_000,
            .body = raw_body_boc,
        },
    };

    const signed = try createSignedTransfer(
        allocator,
        .v4,
        keypair[0],
        "0:0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
        3,
        msgs[0..],
    );
    defer allocator.free(signed);

    const ext_msg = try boc.deserializeBoc(allocator, signed);
    defer ext_msg.deinit(allocator);

    var ext_slice = ext_msg.toSlice();
    _ = try ext_slice.loadUint(2);
    _ = try ext_slice.loadUint(2);
    _ = try ext_slice.loadAddress();
    _ = try ext_slice.loadCoins();
    _ = try ext_slice.loadUint(1);
    _ = try ext_slice.loadUint(1);

    const signed_body = try ext_slice.loadRef();
    var signed_slice = signed_body.toSlice();
    _ = try signed_slice.loadBits(512);
    try std.testing.expectEqual(default_wallet_id_v4, try signed_slice.loadUint32());
    _ = try signed_slice.loadUint32();
    try std.testing.expectEqual(@as(u32, 3), try signed_slice.loadUint32());
    try std.testing.expectEqual(simple_send_opcode, try signed_slice.loadUint32());
    try std.testing.expectEqual(@as(u8, 3), try signed_slice.loadUint8());

    const out_msg = try signed_slice.loadRef();
    var out_slice = out_msg.toSlice();
    try std.testing.expectEqual(@as(u64, 0), try out_slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 1), try out_slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 1), try out_slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 0), try out_slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 0), try out_slice.loadUint(2));
    _ = try out_slice.loadAddress();
    try std.testing.expectEqual(@as(u64, 1_000_000_000), try out_slice.loadCoins());
    try std.testing.expectEqual(@as(u64, 0), try out_slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 0), try out_slice.loadCoins());
    try std.testing.expectEqual(@as(u64, 0), try out_slice.loadCoins());
    try std.testing.expectEqual(@as(u64, 0), try out_slice.loadUint(64));
    try std.testing.expectEqual(@as(u64, 0), try out_slice.loadUint(32));
    try std.testing.expectEqual(@as(u64, 0), try out_slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 1), try out_slice.loadUint(1));

    const decoded_body = try out_slice.loadRef();
    try std.testing.expectEqualSlices(u8, &raw_body_cell.hash(), &decoded_body.hash());
}

test "wallet signing includes referenced state init and disables bounce for deploy" {
    const allocator = std.testing.allocator;

    var code_builder = cell.Builder.init();
    try code_builder.storeUint(0xCAFE, 16);
    const code_cell = try code_builder.toCell(allocator);
    defer code_cell.deinit(allocator);
    const code_boc = try boc.serializeBoc(allocator, code_cell);
    defer allocator.free(code_boc);

    var data_builder = cell.Builder.init();
    try data_builder.storeUint(0xBEEF, 16);
    const data_cell = try data_builder.toCell(allocator);
    defer data_cell.deinit(allocator);
    const data_boc = try boc.serializeBoc(allocator, data_cell);
    defer allocator.free(data_boc);

    const state_init_boc = try state_init.buildStateInitBocAlloc(allocator, code_boc, data_boc);
    defer allocator.free(state_init_boc);
    const expected_state_init = try boc.deserializeBoc(allocator, state_init_boc);
    defer expected_state_init.deinit(allocator);

    const keypair = try generateKeypair("test_seed");
    var msgs = [_]WalletMessage{
        .{
            .destination = "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
            .amount = 1_000_000_000,
            .state_init = state_init_boc,
            .bounce = false,
        },
    };

    const signed = try createSignedTransferWithWalletId(
        allocator,
        .v4,
        keypair[0],
        "0:0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
        default_wallet_id_v4,
        0,
        msgs[0..],
        1234567890,
    );
    defer allocator.free(signed);

    const ext_msg = try boc.deserializeBoc(allocator, signed);
    defer ext_msg.deinit(allocator);

    var ext_slice = ext_msg.toSlice();
    _ = try ext_slice.loadUint(2);
    _ = try ext_slice.loadUint(2);
    _ = try ext_slice.loadAddress();
    _ = try ext_slice.loadCoins();
    _ = try ext_slice.loadUint(1);
    _ = try ext_slice.loadUint(1);

    const signed_body = try ext_slice.loadRef();
    var signed_slice = signed_body.toSlice();
    _ = try signed_slice.loadBits(512);
    _ = try signed_slice.loadUint32();
    _ = try signed_slice.loadUint32();
    _ = try signed_slice.loadUint32();
    _ = try signed_slice.loadUint32();
    _ = try signed_slice.loadUint8();

    const out_msg = try signed_slice.loadRef();
    var out_slice = out_msg.toSlice();
    try std.testing.expectEqual(@as(u64, 0), try out_slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 1), try out_slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 0), try out_slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 0), try out_slice.loadUint(1));
    _ = try out_slice.loadUint(2);
    _ = try out_slice.loadAddress();
    try std.testing.expectEqual(@as(u64, 1_000_000_000), try out_slice.loadCoins());
    try std.testing.expectEqual(@as(u64, 0), try out_slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 0), try out_slice.loadCoins());
    try std.testing.expectEqual(@as(u64, 0), try out_slice.loadCoins());
    try std.testing.expectEqual(@as(u64, 0), try out_slice.loadUint(64));
    try std.testing.expectEqual(@as(u64, 0), try out_slice.loadUint(32));
    try std.testing.expectEqual(@as(u64, 1), try out_slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 1), try out_slice.loadUint(1));

    const state_init_ref = try out_slice.loadRef();
    try std.testing.expectEqualSlices(u8, &state_init_ref.hash(), &expected_state_init.hash());
    try std.testing.expectEqual(@as(u64, 0), try out_slice.loadUint(1));
}

test "wallet signing supports custom wallet id" {
    const allocator = std.testing.allocator;
    const keypair = try generateKeypair("test_seed");

    var msgs = [_]WalletMessage{
        .{
            .destination = "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
            .amount = 1,
        },
    };

    const signed = try createSignedTransferWithWalletId(
        allocator,
        .v4,
        keypair[0],
        "0:0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
        0xA1B2C3D4,
        5,
        msgs[0..],
        1234567890,
    );
    defer allocator.free(signed);

    const ext_msg = try boc.deserializeBoc(allocator, signed);
    defer ext_msg.deinit(allocator);

    var ext_slice = ext_msg.toSlice();
    _ = try ext_slice.loadUint(2);
    _ = try ext_slice.loadUint(2);
    _ = try ext_slice.loadAddress();
    _ = try ext_slice.loadCoins();
    _ = try ext_slice.loadUint(1);
    _ = try ext_slice.loadUint(1);

    const signed_body = try ext_slice.loadRef();
    var signed_slice = signed_body.toSlice();
    _ = try signed_slice.loadBits(512);
    try std.testing.expectEqual(@as(u32, 0xA1B2C3D4), try signed_slice.loadUint32());
    try std.testing.expectEqual(@as(u32, 1234567890), try signed_slice.loadUint32());
    try std.testing.expectEqual(@as(u32, 5), try signed_slice.loadUint32());
}

test "wallet v4 code hash matches known v4r2 hash" {
    const allocator = std.testing.allocator;

    const code_boc = try walletV4CodeBocAlloc(allocator);
    defer allocator.free(code_boc);

    const code_cell = try boc.deserializeBoc(allocator, code_boc);
    defer code_cell.deinit(allocator);

    const hash = code_cell.hash();
    var encoded: [std.base64.standard.Encoder.calcSize(hash.len)]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&encoded, &hash);

    try std.testing.expectEqualStrings(wallet_v4r2_code_hash_base64, &encoded);
}

test "wallet v4 data cell stores seqno wallet id public key and empty plugins" {
    const allocator = std.testing.allocator;
    const public_key = [_]u8{
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        0x10, 0x21, 0x32, 0x43, 0x54, 0x65, 0x76, 0x87,
        0x98, 0xA9, 0xBA, 0xCB, 0xDC, 0xED, 0xFE, 0x0F,
    };

    const data_cell = try buildWalletV4DataCellAlloc(allocator, public_key, 0x1234ABCD, 7);
    defer data_cell.deinit(allocator);

    var slice = data_cell.toSlice();
    try std.testing.expectEqual(@as(u32, 7), try slice.loadUint32());
    try std.testing.expectEqual(@as(u32, 0x1234ABCD), try slice.loadUint32());
    try std.testing.expectEqualSlices(u8, &public_key, try slice.loadBits(256));
    try std.testing.expectEqual(@as(u64, 0), try slice.loadUint(1));
    try std.testing.expect(slice.empty());
}

test "wallet initial transfer includes wallet state init in external message" {
    const allocator = std.testing.allocator;
    const keypair = try generateKeypair("wallet-init-seed");

    var init = try deriveWalletV4InitFromPrivateKeyAlloc(allocator, 0, default_wallet_id_v4, keypair[0]);
    defer init.deinit(allocator);

    const raw_address = try init.address.toRawAlloc(allocator);
    defer allocator.free(raw_address);

    const expected_state_init = try boc.deserializeBoc(allocator, init.state_init_boc);
    defer expected_state_init.deinit(allocator);

    var msgs = [_]WalletMessage{
        .{
            .destination = "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
            .amount = 12345,
        },
    };

    const external = try createWalletV4ExternalMessageWithId(
        allocator,
        keypair[0],
        raw_address,
        default_wallet_id_v4,
        0,
        1234567890,
        msgs[0..],
        init.state_init_boc,
    );
    defer allocator.free(external);

    const ext_msg = try boc.deserializeBoc(allocator, external);
    defer ext_msg.deinit(allocator);

    var ext_slice = ext_msg.toSlice();
    try std.testing.expectEqual(@as(u64, 0b10), try ext_slice.loadUint(2));
    try std.testing.expectEqual(@as(u64, 0), try ext_slice.loadUint(2));
    const destination = try ext_slice.loadAddress();
    try std.testing.expectEqualSlices(u8, &init.address.raw, &destination.raw);
    try std.testing.expectEqual(init.address.workchain, destination.workchain);
    try std.testing.expectEqual(@as(u64, 0), try ext_slice.loadCoins());
    try std.testing.expectEqual(@as(u64, 1), try ext_slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 1), try ext_slice.loadUint(1));

    const state_init_ref = try ext_slice.loadRef();
    try std.testing.expectEqualSlices(u8, &expected_state_init.hash(), &state_init_ref.hash());
    try std.testing.expectEqual(@as(u64, 1), try ext_slice.loadUint(1));
    _ = try ext_slice.loadRef();
}

test "sendInitialTransfer sends deployment message with seqno zero" {
    const allocator = std.testing.allocator;

    const FakeClient = struct {
        allocator: std.mem.Allocator,
        last_boc: ?[]u8 = null,

        fn sendBoc(self: *@This(), payload: []const u8) !types.SendBocResponse {
            self.last_boc = try self.allocator.dupe(u8, payload);
            return .{
                .hash = try self.allocator.dupe(u8, "fake"),
                .lt = 0,
            };
        }
    };

    var client = FakeClient{ .allocator = allocator };
    defer if (client.last_boc) |value| allocator.free(value);

    const keypair = try generateKeypair("wallet-init-send");
    const result = try sendInitialTransfer(
        &client,
        .v4,
        keypair[0],
        0,
        default_wallet_id_v4,
        "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
        777,
        null,
    );
    defer allocator.free(result.hash);

    try std.testing.expect(client.last_boc != null);
    const sent = client.last_boc.?;
    const ext_msg = try boc.deserializeBoc(allocator, sent);
    defer ext_msg.deinit(allocator);

    var ext_slice = ext_msg.toSlice();
    _ = try ext_slice.loadUint(2);
    _ = try ext_slice.loadUint(2);
    _ = try ext_slice.loadAddress();
    _ = try ext_slice.loadCoins();
    try std.testing.expectEqual(@as(u64, 1), try ext_slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 1), try ext_slice.loadUint(1));
    _ = try ext_slice.loadRef();
    try std.testing.expectEqual(@as(u64, 1), try ext_slice.loadUint(1));

    const signed_body = try ext_slice.loadRef();
    var signed_slice = signed_body.toSlice();
    _ = try signed_slice.loadBits(512);
    try std.testing.expectEqual(default_wallet_id_v4, try signed_slice.loadUint32());
    _ = try signed_slice.loadUint32();
    try std.testing.expectEqual(@as(u32, 0), try signed_slice.loadUint32());
    try std.testing.expectEqual(simple_send_opcode, try signed_slice.loadUint32());
}

test "buildWalletDeploymentAlloc builds undeployed wallet external with state init" {
    const allocator = std.testing.allocator;

    const keypair = try generateKeypair("wallet-build-deploy");
    var built = try buildWalletDeploymentAlloc(
        allocator,
        .v4,
        keypair[0],
        0,
        default_wallet_id_v4,
    );
    defer built.deinit(allocator);

    try std.testing.expect(built.state_init_attached);
    try std.testing.expectEqual(default_wallet_id_v4, built.wallet_id);
    try std.testing.expectEqual(@as(u32, 0), built.seqno);

    var init = try deriveWalletV4InitFromPrivateKeyAlloc(allocator, 0, default_wallet_id_v4, keypair[0]);
    defer init.deinit(allocator);
    const expected_state_init = try boc.deserializeBoc(allocator, init.state_init_boc);
    defer expected_state_init.deinit(allocator);

    const ext_msg = try boc.deserializeBoc(allocator, built.boc);
    defer ext_msg.deinit(allocator);

    var ext_slice = ext_msg.toSlice();
    try std.testing.expectEqual(@as(u64, 0b10), try ext_slice.loadUint(2));
    try std.testing.expectEqual(@as(u64, 0), try ext_slice.loadUint(2));
    const destination = try ext_slice.loadAddress();
    try std.testing.expectEqualSlices(u8, &init.address.raw, &destination.raw);
    try std.testing.expectEqual(init.address.workchain, destination.workchain);
    try std.testing.expectEqual(@as(u64, 0), try ext_slice.loadCoins());
    try std.testing.expectEqual(@as(u64, 1), try ext_slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 1), try ext_slice.loadUint(1));

    const state_init_ref = try ext_slice.loadRef();
    try std.testing.expectEqualSlices(u8, &expected_state_init.hash(), &state_init_ref.hash());
    try std.testing.expectEqual(@as(u64, 1), try ext_slice.loadUint(1));

    const signed_body = try ext_slice.loadRef();
    var signed_slice = signed_body.toSlice();
    _ = try signed_slice.loadBits(512);
    try std.testing.expectEqual(default_wallet_id_v4, try signed_slice.loadUint32());
    _ = try signed_slice.loadUint32();
    try std.testing.expectEqual(@as(u32, 0), try signed_slice.loadUint32());
    try std.testing.expectEqual(simple_send_opcode, try signed_slice.loadUint32());
}

test "sendMessagesAuto falls back to initial deployment when wallet info is unavailable" {
    const allocator = std.testing.allocator;

    const FakeClient = struct {
        allocator: std.mem.Allocator,
        last_boc: ?[]u8 = null,

        pub fn runGetMethod(self: *@This(), wallet_address: []const u8, method: []const u8, stack: []const []const u8) !types.RunGetMethodResponse {
            _ = self;
            _ = wallet_address;
            _ = method;
            _ = stack;
            return error.InvalidResponse;
        }

        pub fn freeRunGetMethodResponse(self: *@This(), response: *types.RunGetMethodResponse) void {
            _ = self;
            _ = response;
        }

        pub fn sendBoc(self: *@This(), payload: []const u8) !types.SendBocResponse {
            self.last_boc = try self.allocator.dupe(u8, payload);
            return .{
                .hash = try self.allocator.dupe(u8, "fake"),
                .lt = 1,
            };
        }
    };

    var client = FakeClient{ .allocator = allocator };
    defer if (client.last_boc) |value| allocator.free(value);

    const keypair = try generateKeypair("wallet-auto-fallback");
    const result = try sendMessagesAuto(
        &client,
        .v4,
        keypair[0],
        null,
        0,
        default_wallet_id_v4,
        &[_]WalletMessage{
            .{
                .destination = "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
                .amount = 888,
            },
        },
    );
    defer allocator.free(result.hash);

    try std.testing.expect(client.last_boc != null);
    const ext_msg = try boc.deserializeBoc(allocator, client.last_boc.?);
    defer ext_msg.deinit(allocator);

    var ext_slice = ext_msg.toSlice();
    _ = try ext_slice.loadUint(2);
    _ = try ext_slice.loadUint(2);
    _ = try ext_slice.loadAddress();
    _ = try ext_slice.loadCoins();
    try std.testing.expectEqual(@as(u64, 1), try ext_slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 1), try ext_slice.loadUint(1));
}

test "sendMessagesAuto uses deployed wallet when address is provided" {
    const allocator = std.testing.allocator;
    const keypair = try generateKeypair("wallet-auto-deployed");

    const FakeClient = struct {
        allocator: std.mem.Allocator,
        public_key_hex: []const u8,
        last_boc: ?[]u8 = null,

        pub fn runGetMethod(self: *@This(), wallet_address: []const u8, method: []const u8, stack: []const []const u8) !types.RunGetMethodResponse {
            _ = wallet_address;
            _ = stack;

            const entry = if (std.mem.eql(u8, method, "seqno"))
                types.StackEntry{ .number = 7 }
            else if (std.mem.eql(u8, method, "get_subwallet_id"))
                types.StackEntry{ .number = default_wallet_id_v4 }
            else if (std.mem.eql(u8, method, "get_public_key"))
                types.StackEntry{ .big_number = try self.allocator.dupe(u8, self.public_key_hex) }
            else
                return error.InvalidResponse;

            const entries = try self.allocator.alloc(types.StackEntry, 1);
            entries[0] = entry;
            return .{
                .exit_code = 0,
                .stack = entries,
                .logs = "",
            };
        }

        pub fn freeRunGetMethodResponse(self: *@This(), response: *types.RunGetMethodResponse) void {
            for (response.stack) |*entry| {
                switch (entry.*) {
                    .big_number => |value| self.allocator.free(value),
                    else => {},
                }
            }
            self.allocator.free(response.stack);
        }

        pub fn sendBoc(self: *@This(), payload: []const u8) !types.SendBocResponse {
            self.last_boc = try self.allocator.dupe(u8, payload);
            return .{
                .hash = try self.allocator.dupe(u8, "fake"),
                .lt = 2,
            };
        }
    };

    const public_key_hex = try encodeHexPrefixedLowerAlloc(allocator, &keypair[1]);
    defer allocator.free(public_key_hex);

    var client = FakeClient{
        .allocator = allocator,
        .public_key_hex = public_key_hex,
    };
    defer if (client.last_boc) |value| allocator.free(value);

    const result = try sendMessagesAuto(
        &client,
        .v4,
        keypair[0],
        "0:0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
        0,
        default_wallet_id_v4,
        &[_]WalletMessage{
            .{
                .destination = "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
                .amount = 1,
            },
        },
    );
    defer allocator.free(result.hash);

    try std.testing.expect(client.last_boc != null);
    const ext_msg = try boc.deserializeBoc(allocator, client.last_boc.?);
    defer ext_msg.deinit(allocator);

    var ext_slice = ext_msg.toSlice();
    _ = try ext_slice.loadUint(2);
    _ = try ext_slice.loadUint(2);
    _ = try ext_slice.loadAddress();
    _ = try ext_slice.loadCoins();
    try std.testing.expectEqual(@as(u64, 0), try ext_slice.loadUint(1));
    try std.testing.expectEqual(@as(u64, 1), try ext_slice.loadUint(1));

    const signed_body = try ext_slice.loadRef();
    var signed_slice = signed_body.toSlice();
    _ = try signed_slice.loadBits(512);
    _ = try signed_slice.loadUint32();
    _ = try signed_slice.loadUint32();
    try std.testing.expectEqual(@as(u32, 7), try signed_slice.loadUint32());
}

test "wallet public key helper parses stack entry" {
    const entry = types.StackEntry{
        .big_number = "0x0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF",
    };

    const public_key = try stackEntryAsPublicKeyBytes(&entry);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF },
        &public_key,
    );
}
