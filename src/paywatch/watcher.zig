//! Payment watcher for polling incoming transactions

const std = @import("std");
const types = @import("../core/types.zig");
const invoice_mod = @import("invoice.zig");
const http_client = @import("../core/http_client.zig");

pub const PaymentWatcher = struct {
    invoice: *const invoice_mod.Invoice,
    client: *http_client.TonHttpClient,
    poll_interval_ms: u32,
    timeout_ms: u32,
};

pub const PaymentResult = struct {
    found: bool,
    tx_hash: ?[]const u8,
    tx_lt: ?i64,
    amount: ?u64,
    confirmed_at: i64,
};

pub fn waitPayment(watcher: *PaymentWatcher) !PaymentResult {
    _ = watcher;
    return PaymentResult{
        .found = false,
        .tx_hash = null,
        .tx_lt = null,
        .amount = null,
        .confirmed_at = std.time.timestamp(),
    };
}

pub fn startPolling(watcher: *PaymentWatcher, callback: *const fn (PaymentResult) void) !void {
    _ = watcher;
    _ = callback;
}

test "payment watcher" {
    _ = waitPayment;
    _ = startPolling;
}
