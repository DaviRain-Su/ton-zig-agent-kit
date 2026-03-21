//! Payment verification
//! Verifies payment status on-chain

const std = @import("std");
const address_mod = @import("../core/address.zig");
const types = @import("../core/types.zig");
const cell = @import("../core/cell.zig");
const invoice_mod = @import("invoice.zig");

pub const VerificationResult = struct {
    verified: bool,
    tx_hash: ?[]const u8,
    tx_lt: ?i64,
    amount: ?u64,
    sender: ?[]const u8,
    confirmations: u32,
    timestamp: i64,
};

/// Verify payment by checking invoice against blockchain
pub fn verifyPayment(
    client: anytype,
    invoice: *const invoice_mod.Invoice,
) !VerificationResult {
    // Get transactions for invoice address
    const txs = try client.getTransactions(invoice.address, 50);
    defer client.freeTransactions(txs);

    for (txs) |tx| {
        if (try checkTransactionMatches(&tx, invoice)) {
            const tx_hash = try client.allocator.dupe(u8, tx.hash);
            errdefer client.allocator.free(tx_hash);

            const sender = try formatIncomingSenderAlloc(client.allocator, tx.in_msg);
            errdefer if (sender) |value| client.allocator.free(value);

            return VerificationResult{
                .verified = true,
                .tx_hash = tx_hash,
                .tx_lt = tx.lt,
                .amount = if (tx.in_msg) |msg| msg.value else null,
                .sender = sender,
                .confirmations = 1, // Would check block depth
                .timestamp = tx.timestamp,
            };
        }
    }

    return VerificationResult{
        .verified = false,
        .tx_hash = null,
        .tx_lt = null,
        .amount = null,
        .sender = null,
        .confirmations = 0,
        .timestamp = std.time.timestamp(),
    };
}

/// Check if transaction matches invoice criteria
pub fn checkTransactionMatches(
    tx: *const types.Transaction,
    invoice: *const invoice_mod.Invoice,
) !bool {
    // Must have incoming message to invoice address
    const msg = tx.in_msg orelse return false;

    // Check amount matches
    if (invoice.amount > 0 and msg.value < invoice.amount) {
        return false;
    }

    if (try extractMessageComment(msg)) |comment| {
        if (std.mem.indexOf(u8, comment, invoice.comment) != null) {
            return true;
        }
    }

    return false;
}

/// Verify payment by transaction hash
pub fn verifyByTxHash(
    client: anytype,
    tx_hash: []const u8,
    invoice: *const invoice_mod.Invoice,
) !VerificationResult {
    // Look up transaction
    var tx = try client.lookupTx(0, tx_hash) orelse return VerificationResult{
        .verified = false,
        .tx_hash = null,
        .tx_lt = null,
        .amount = null,
        .sender = null,
        .confirmations = 0,
        .timestamp = std.time.timestamp(),
    };
    defer client.freeTransaction(&tx);

    const matches = try checkTransactionMatches(&tx, invoice);
    const resolved_tx_hash = try client.allocator.dupe(u8, tx.hash);
    errdefer client.allocator.free(resolved_tx_hash);

    const sender = try formatIncomingSenderAlloc(client.allocator, tx.in_msg);
    errdefer if (sender) |value| client.allocator.free(value);

    return VerificationResult{
        .verified = matches,
        .tx_hash = resolved_tx_hash,
        .tx_lt = tx.lt,
        .amount = if (tx.in_msg) |msg| msg.value else null,
        .sender = sender,
        .confirmations = 1,
        .timestamp = tx.timestamp,
    };
}

/// Batch verify multiple invoices
pub fn batchVerifyPayments(
    allocator: std.mem.Allocator,
    client: anytype,
    invoices: []const invoice_mod.Invoice,
) ![]VerificationResult {
    var results = try allocator.alloc(VerificationResult, invoices.len);
    errdefer allocator.free(results);

    for (invoices, 0..) |invoice, i| {
        results[i] = try verifyPayment(client, &invoice);
    }

    return results;
}

/// Check if payment is confirmed (has enough confirmations)
pub fn isConfirmed(result: *const VerificationResult, required_confirmations: u32) bool {
    return result.verified and result.confirmations >= required_confirmations;
}

fn extractMessageComment(msg: *const types.Message) !?[]const u8 {
    if (msg.body) |body_cell| {
        var slice = body_cell.toSlice();
        if (slice.remainingBits() < 32) return null;

        const op = try slice.loadUint(32);
        if (op != 0) return null;

        const text_bits = slice.remainingBits();
        if (text_bits == 0) return "";
        if (text_bits % 8 != 0) return null;

        return try slice.loadBits(@intCast(text_bits));
    }

    if (msg.raw_body.len > 0) {
        return msg.raw_body;
    }

    return null;
}

fn formatIncomingSenderAlloc(allocator: std.mem.Allocator, msg: ?*types.Message) !?[]u8 {
    const value = msg orelse return null;
    const source = value.source orelse return null;
    const formatted = try address_mod.formatRaw(allocator, &source);
    return formatted;
}

test "verification result" {
    const result = VerificationResult{
        .verified = true,
        .tx_hash = "abc123",
        .tx_lt = 12345,
        .amount = 1000000000,
        .sender = "EQ...",
        .confirmations = 3,
        .timestamp = std.time.timestamp(),
    };

    try std.testing.expect(isConfirmed(&result, 1));
    try std.testing.expect(isConfirmed(&result, 3));
    try std.testing.expect(!isConfirmed(&result, 5));
}

test "unconfirmed payment" {
    const result = VerificationResult{
        .verified = false,
        .tx_hash = null,
        .tx_lt = null,
        .amount = null,
        .sender = null,
        .confirmations = 0,
        .timestamp = std.time.timestamp(),
    };

    try std.testing.expect(!isConfirmed(&result, 1));
}
