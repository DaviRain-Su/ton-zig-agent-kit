//! Invoice generation for payment flows
//! Creates unique payment references with comment matching

const std = @import("std");
const types = @import("../core/types.zig");

pub const Invoice = struct {
    id: []const u8,
    address: []const u8,
    comment: []const u8,
    amount: u64,
    description: []const u8,
    payment_url: []const u8,
    created_at: i64,
    expires_at: ?i64,
    status: InvoiceStatus,
};

pub const InvoiceStatus = enum {
    pending,
    paid,
    expired,
    cancelled,
};

var invoice_counter: u64 = 0;

/// Create a new invoice with unique comment for payment matching
pub fn createInvoice(
    allocator: std.mem.Allocator,
    destination: []const u8,
    amount: u64,
    description: []const u8,
) !Invoice {
    invoice_counter += 1;
    const timestamp = std.time.timestamp();
    const id = try std.fmt.allocPrint(allocator, "inv-{d}-{d}", .{ timestamp, invoice_counter });
    const comment = try std.fmt.allocPrint(allocator, "TON-ZIG-{d}-{d}", .{ timestamp, invoice_counter });

    return Invoice{
        .id = id,
        .address = destination,
        .comment = comment,
        .amount = amount,
        .description = description,
        .payment_url = try std.fmt.allocPrint(allocator, "ton://transfer/{s}?amount={d}&text={s}", .{ destination, amount, comment }),
        .created_at = timestamp,
        .expires_at = timestamp + 3600, // 1 hour expiry
        .status = .pending,
    };
}

/// Create invoice with custom expiry
pub fn createInvoiceWithExpiry(
    allocator: std.mem.Allocator,
    destination: []const u8,
    amount: u64,
    description: []const u8,
    expiry_seconds: i64,
) !Invoice {
    var invoice = try createInvoice(allocator, destination, amount, description);
    invoice.expires_at = invoice.created_at + expiry_seconds;
    return invoice;
}

/// Create TON keeper/Wallet payment URL
pub fn createPaymentURL(invoice: *const Invoice, format: PaymentURLFormat) []const u8 {
    return switch (format) {
        .ton => invoice.payment_url,
        .tonkeeper => std.fmt.comptimePrint("https://app.tonkeeper.com/transfer/{s}?amount={d}&text={s}", .{ invoice.address, invoice.amount, invoice.comment }),
        .tonhub => std.fmt.comptimePrint("https://tonhub.com/transfer/{s}?amount={d}&text={s}", .{ invoice.address, invoice.amount, invoice.comment }),
    };
}

pub const PaymentURLFormat = enum {
    ton,
    tonkeeper,
    tonhub,
};

/// Check if invoice is expired
pub fn isExpired(invoice: *const Invoice) bool {
    if (invoice.expires_at) |expiry| {
        return std.time.timestamp() > expiry;
    }
    return false;
}

/// Parse comment from invoice ID
pub fn parseInvoiceId(comment: []const u8) ?struct { timestamp: i64, counter: u64 } {
    // Expected format: TON-ZIG-<timestamp>-<counter>
    const prefix = "TON-ZIG-";
    if (!std.mem.startsWith(u8, comment, prefix)) return null;

    const rest = comment[prefix.len..];
    var iter = std.mem.splitScalar(u8, rest, '-');

    const timestamp_str = iter.next() orelse return null;
    const counter_str = iter.next() orelse return null;

    const timestamp = std.fmt.parseInt(i64, timestamp_str, 10) catch return null;
    const counter = std.fmt.parseInt(u64, counter_str, 10) catch return null;

    return .{ .timestamp = timestamp, .counter = counter };
}

/// Generate QR code data (just the payment URL for now)
pub fn generateQRData(invoice: *const Invoice) []const u8 {
    return invoice.payment_url;
}

test "invoice creation" {
    const allocator = std.testing.allocator;

    const invoice = try createInvoice(allocator, "EQCD39vd5kB8FW5w6KH7HpNmP8GCvGajvLKGPMgY4sUXJyxqH", 1000000000, "Test payment");
    defer {
        allocator.free(invoice.id);
        allocator.free(invoice.comment);
        allocator.free(invoice.payment_url);
    }

    try std.testing.expect(invoice.amount == 1000000000);
    try std.testing.expect(std.mem.startsWith(u8, invoice.comment, "TON-ZIG-"));
    try std.testing.expect(invoice.status == .pending);
}

test "invoice expiry" {
    const allocator = std.testing.allocator;

    const invoice = try createInvoiceWithExpiry(allocator, "EQ...", 1000, "Test", 60);
    defer {
        allocator.free(invoice.id);
        allocator.free(invoice.comment);
        allocator.free(invoice.payment_url);
    }

    try std.testing.expect(!isExpired(&invoice));
}

test "parse invoice id" {
    const parsed = parseInvoiceId("TON-ZIG-1234567890-1");
    try std.testing.expect(parsed != null);
    try std.testing.expect(parsed.?.timestamp == 1234567890);
    try std.testing.expect(parsed.?.counter == 1);

    const invalid = parseInvoiceId("INVALID");
    try std.testing.expect(invalid == null);
}
