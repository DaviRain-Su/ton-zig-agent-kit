//! Payment watcher for polling incoming transactions
//! Monitors address for payments matching invoice criteria

const std = @import("std");
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
    const start_time = std.time.milliTimestamp();

    while (std.time.milliTimestamp() - start_time < watcher.timeout_ms) {
        // Check if invoice expired
        if (invoice_mod.isExpired(watcher.invoice)) {
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
        const txs = try watcher.client.getTransactions(watcher.invoice.address, 10);

        // Check each transaction
        for (txs) |tx| {
            if (try checkTransactionMatchesInvoice(&tx, watcher.invoice)) {
                return PaymentResult{
                    .found = true,
                    .tx_hash = tx.hash,
                    .tx_lt = tx.lt,
                    .amount = if (tx.in_msg) |msg| msg.value else null,
                    .sender = null, // TODO: format Address properly
                    .confirmed_at = std.time.timestamp(),
                    .confirmations = 1,
                };
            }
        }

        // Sleep before next poll
        std.Thread.sleep(watcher.poll_interval_ms * std.time.ns_per_ms);
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
    const start_time = std.time.milliTimestamp();

    while (std.time.milliTimestamp() - start_time < watcher.timeout_ms) {
        const result = try waitPayment(watcher);

        if (result.found) {
            callback(result);
            return;
        }

        if (invoice_mod.isExpired(watcher.invoice)) {
            callback(PaymentResult{
                .found = false,
                .tx_hash = null,
                .tx_lt = null,
                .amount = null,
                .sender = null,
                .confirmed_at = std.time.timestamp(),
                .confirmations = 0,
            });
            return;
        }
    }

    // Timeout
    callback(PaymentResult{
        .found = false,
        .tx_hash = null,
        .tx_lt = null,
        .amount = null,
        .sender = null,
        .confirmed_at = std.time.timestamp(),
        .confirmations = 0,
    });
}

/// Check if transaction matches invoice criteria
fn checkTransactionMatchesInvoice(
    tx: *const types.Transaction,
    invoice: *const invoice_mod.Invoice,
) !bool {
    // Must have incoming message
    const msg = tx.in_msg orelse return false;

    // Check amount matches (with some tolerance)
    if (msg.value != invoice.amount) {
        // Allow 1% tolerance for fees
        const tolerance = invoice.amount / 100;
        if (msg.value < invoice.amount - tolerance or
            msg.value > invoice.amount + tolerance)
        {
            return false;
        }
    }

    // Check comment in body
    if (msg.body) |body| {
        // Parse body to find comment
        var slice = body.toSlice();

        // Skip op code (32 bits) and query_id (64 bits) if present
        // For simple transfers, comment is in the body directly

        // Read comment as string
        const comment_bytes = try slice.loadBits(1024); // Max comment size
        const comment = std.mem.sliceTo(comment_bytes, 0);

        if (std.mem.indexOf(u8, comment, invoice.comment) != null) {
            return true;
        }
    }

    return false;
}

test "payment watcher init" {
    const allocator = std.testing.allocator;
    var client = try http_client.TonHttpClient.init(allocator, "https://tonapi.io", null);
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
