//! Wallet signing and message creation
//! Supports wallet v4 (rwallet) with Ed25519 signing

const std = @import("std");
const types = @import("../core/types.zig");
const cell = @import("../core/cell.zig");
const boc = @import("../core/boc.zig");
const state_init = @import("../core/state_init.zig");
const generic_contract = @import("../contract/contract.zig");

const Ed25519 = std.crypto.sign.Ed25519;
const default_wallet_id_v4: u32 = 698983191;
const simple_send_opcode: u32 = 0;

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

/// Generate Ed25519 keypair from seed
pub fn generateKeypair(seed: []const u8) ![2][32]u8 {
    const seed_bytes = deriveSeed(seed);
    const keypair = try Ed25519.KeyPair.generateDeterministic(seed_bytes);

    return .{
        keypair.secret_key.seed(),
        keypair.public_key.toBytes(),
    };
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
) !*cell.Cell {
    var builder = cell.Builder.init();

    try builder.storeUint(0b10, 2); // ext_in_msg_info$10
    try builder.storeUint(0, 2); // src: addr_none (MsgAddressExt)
    try builder.storeAddress(wallet_addr);
    try builder.storeCoins(0); // import_fee
    try builder.storeUint(0, 1); // state_init absent
    try builder.storeUint(1, 1); // body in ref
    try builder.storeRef(body_cell);

    return builder.toCell(allocator);
}

fn createWalletV4ExternalMessageWithId(
    allocator: std.mem.Allocator,
    private_key_seed: [32]u8,
    wallet_addr: []const u8,
    wallet_id: u32,
    seqno: u32,
    valid_until: u32,
    messages: []const WalletMessage,
) ![]u8 {
    const signed_body = try createSignedBodyCell(allocator, private_key_seed, wallet_id, seqno, valid_until, messages);
    errdefer signed_body.deinit(allocator);

    const ext_msg = try createExternalIncomingMessageCell(allocator, wallet_addr, signed_body);
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

pub fn sendMessages(
    client: anytype,
    version: WalletVersion,
    private_key: [32]u8,
    wallet_address: []const u8,
    msgs: []const WalletMessage,
) !types.SendBocResponse {
    const allocator = std.heap.page_allocator;

    const wallet_info = try getWalletInfo(client, wallet_address);
    const key_pair = try ed25519KeyPairFromSeed(private_key);
    const public_key = key_pair.public_key.toBytes();
    if (!std.mem.eql(u8, &wallet_info.public_key, &public_key)) return error.InvalidWalletPublicKey;

    const valid_until = @as(u32, @intCast(std.time.timestamp())) + 60;
    const signed_transfer = try createSignedTransferWithWalletId(
        allocator,
        version,
        private_key,
        wallet_address,
        wallet_info.wallet_id,
        wallet_info.seqno,
        msgs,
        valid_until,
    );
    defer allocator.free(signed_transfer);

    return try client.sendBoc(signed_transfer);
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
