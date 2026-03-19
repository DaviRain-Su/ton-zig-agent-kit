//! Payment verification
//! Verifies payment status on-chain

const std = @import("std");
const types = @import("../core/types.zig");
const cell = @import("../core/cell.zig");
const invoice_mod = @import("invoice.zig");
const http_client = @import("../core/http_client.zig");

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
    client: *http_client.TonHttpClient,
    invoice: *const invoice_mod.Invoice,
) !VerificationResult {
    // Get transactions for invoice address
    const txs = try client.getTransactions(invoice.address, 50);

    for (txs) |tx| {
        if (try checkTransactionMatches(&tx, invoice)) {
            return VerificationResult{
                .verified = true,
                .tx_hash = tx.hash,
                .tx_lt = tx.lt,
                .amount = if (tx.in_msg) |msg| msg.value else null,
                .sender = null, // TODO: format Address properly
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
    if (msg.value < invoice.amount) {
        return false;
    }

    // Check for matching comment in body
    if (msg.body) |body_cell| {
        var slice = body_cell.*.toSlice();

        // Try to extract comment text
        // Skip op code if present
        if (slice.remainingBits() >= 32) {
            const op = try slice.loadUint(32);
            if (op == 0) { // Text comment
                // Read remaining as text
                const text_len = slice.remainingBits() / 8;
                if (text_len > 0) {
                    const text_bytes = try slice.loadBits(@intCast(text_len * 8));
                    const text = std.mem.sliceTo(text_bytes, 0);

                    // Check if invoice comment is in the text
                    if (std.mem.indexOf(u8, text, invoice.comment) != null) {
                        return true;
                    }
                }
            }
        }
    }

    return false;
}

/// Verify payment by transaction hash
pub fn verifyByTxHash(
    client: *http_client.TonHttpClient,
    tx_hash: []const u8,
    invoice: *const invoice_mod.Invoice,
) !VerificationResult {
    // Look up transaction
    const tx = try client.lookupTx(0, tx_hash) orelse return VerificationResult{
        .verified = false,
        .tx_hash = null,
        .tx_lt = null,
        .amount = null,
        .sender = null,
        .confirmations = 0,
        .timestamp = std.time.timestamp(),
    };

    const matches = try checkTransactionMatches(&tx, invoice);

    return VerificationResult{
        .verified = matches,
        .tx_hash = tx.hash,
        .tx_lt = tx.lt,
        .amount = if (tx.in_msg) |msg| msg.value else null,
        .sender = null, // TODO: format Address properly
        .confirmations = 1,
        .timestamp = tx.timestamp,
    };
}

/// Batch verify multiple invoices
pub fn batchVerifyPayments(
    allocator: std.mem.Allocator,
    client: *http_client.TonHttpClient,
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
