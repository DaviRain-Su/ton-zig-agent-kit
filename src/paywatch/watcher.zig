//! Payment watcher for polling incoming transactions
//! Monitors address for payments matching invoice criteria

const std = @import("std");
const address_mod = @import("../core/address.zig");
const types = @import("../core/types.zig");
const invoice_mod = @import("invoice.zig");
const http_client = @import("../core/http_client.zig");

pub const PaymentWatcher = struct {
    invoice: *const invoice_mod.Invoice,
    client: *http_client.TonHttpClient,
    poll_interval_ms: u32,
    timeout_ms: u32,

    pub fn init(
        invoice: *const invoice_mod.Invoice,
        client: *http_client.TonHttpClient,
        poll_interval_ms: u32,
        timeout_ms: u32,
    ) PaymentWatcher {
        return .{
            .invoice = invoice,
            .client = client,
            .poll_interval_ms = poll_interval_ms,
            .timeout_ms = timeout_ms,
        };
    }
};

pub const PaymentResult = struct {
    found: bool,
    tx_hash: ?[]const u8,
    tx_lt: ?i64,
    amount: ?u64,
    sender: ?[]const u8,
    confirmed_at: i64,
    confirmations: u32,
};

/// Wait for payment with polling
pub fn waitPayment(watcher: *PaymentWatcher) !PaymentResult {
    return waitPaymentWithClient(
        watcher.client,
        watcher.invoice,
        watcher.poll_interval_ms,
        watcher.timeout_ms,
    );
}

pub fn waitPaymentWithClient(
    client: anytype,
    invoice: *const invoice_mod.Invoice,
    poll_interval_ms: u32,
    timeout_ms: u32,
) !PaymentResult {
    const start_time = std.time.milliTimestamp();

    while (std.time.milliTimestamp() - start_time < timeout_ms) {
        // Check if invoice expired
        if (invoice_mod.isExpired(invoice)) {
            return PaymentResult{
                .found = false,
                .tx_hash = null,
                .tx_lt = null,
                .amount = null,
                .sender = null,
                .confirmed_at = std.time.timestamp(),
                .confirmations = 0,
            };
        }

        // Query transactions
        const txs = try client.getTransactions(invoice.address, 10);
        defer client.freeTransactions(txs);

        // Check each transaction
        for (txs) |tx| {
            if (try checkTransactionMatchesInvoice(&tx, invoice)) {
                const tx_hash = try client.allocator.dupe(u8, tx.hash);
                errdefer client.allocator.free(tx_hash);

                const sender = try formatIncomingSenderAlloc(client.allocator, tx.in_msg);
                errdefer if (sender) |value| client.allocator.free(value);

                return PaymentResult{
                    .found = true,
                    .tx_hash = tx_hash,
                    .tx_lt = tx.lt,
                    .amount = if (tx.in_msg) |msg| msg.value else null,
                    .sender = sender,
                    .confirmed_at = std.time.timestamp(),
                    .confirmations = 1,
                };
            }
        }

        // Sleep before next poll
        std.Thread.sleep(poll_interval_ms * std.time.ns_per_ms);
    }

    // Timeout reached
    return PaymentResult{
        .found = false,
        .tx_hash = null,
        .tx_lt = null,
        .amount = null,
        .sender = null,
        .confirmed_at = std.time.timestamp(),
        .confirmations = 0,
    };
}

/// Start continuous polling with callback
pub fn startPolling(
    watcher: *PaymentWatcher,
    callback: *const fn (PaymentResult) void,
) !void {
    callback(try waitPayment(watcher));
}

/// Check if transaction matches invoice criteria
fn checkTransactionMatchesInvoice(
    tx: *const types.Transaction,
    invoice: *const invoice_mod.Invoice,
) !bool {
    // Must have incoming message
    const msg = tx.in_msg orelse return false;

    if (invoice.amount > 0 and msg.value != invoice.amount) {
        // Allow 1% tolerance for fees
        const tolerance = invoice.amount / 100;
        if (msg.value < invoice.amount - tolerance or
            msg.value > invoice.amount + tolerance)
        {
            return false;
        }
    }

    if (try extractMessageComment(msg)) |comment| {
        if (std.mem.indexOf(u8, comment, invoice.comment) != null) {
            return true;
        }
    }

    return false;
}

fn extractMessageComment(msg: *const types.Message) !?[]const u8 {
    if (msg.body) |body| {
        var slice = body.toSlice();
        if (slice.remainingBits() < 32) return null;

        const op = try slice.loadUint(32);
        if (op != 0) return null;

        const remaining_bits = slice.remainingBits();
        if (remaining_bits == 0) return "";
        if (remaining_bits % 8 != 0) return null;

        return try slice.loadBits(@intCast(remaining_bits));
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

test "payment watcher init" {
    const allocator = std.testing.allocator;
    var client = try http_client.TonHttpClient.init(allocator, "https://toncenter.com/api/v2/jsonRPC", null);
    defer client.deinit();

    const invoice = try invoice_mod.createInvoice(allocator, "EQ...", 1000, "Test");
    defer {
        allocator.free(invoice.id);
        allocator.free(invoice.comment);
        allocator.free(invoice.payment_url);
    }

    const watcher = PaymentWatcher.init(&invoice, &client, 1000, 5000);
    try std.testing.expect(watcher.poll_interval_ms == 1000);
}
