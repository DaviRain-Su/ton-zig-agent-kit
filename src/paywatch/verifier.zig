//! Payment verification

const std = @import("std");
const types = @import("../core/types.zig");
const invoice_mod = @import("invoice.zig");
const http_client = @import("../core/http_client.zig");

pub fn verifyPayment(client: *http_client.TonHttpClient, invoice: *const invoice_mod.Invoice) !bool {
    _ = client;
    _ = invoice;
    return false;
}

pub fn checkTransactionMatches(
    tx: *const types.Transaction,
    invoice: *const invoice_mod.Invoice,
) bool {
    _ = tx;
    _ = invoice;
    return false;
}

test "payment verification" {
    _ = verifyPayment;
    _ = checkTransactionMatches;
}
