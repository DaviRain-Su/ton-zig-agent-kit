//! Invoice generation for payment flows

const std = @import("std");
const types = @import("../core/types.zig");

pub const Invoice = struct {
    address: []const u8,
    comment: []const u8,
    amount: u64,
    description: []const u8,
    payment_url: []const u8,
    created_at: i64,
};

var invoice_counter: u64 = 0;

pub fn createInvoice(
    allocator: std.mem.Allocator,
    destination: []const u8,
    amount: u64,
    description: []const u8,
) !Invoice {
    invoice_counter += 1;
    const timestamp = std.time.timestamp();
    const comment = try std.fmt.allocPrint(allocator, "TON-ZIG-{d}-{d}", .{ timestamp, invoice_counter });

    return Invoice{
        .address = destination,
        .comment = comment,
        .amount = amount,
        .description = description,
        .payment_url = try std.fmt.allocPrint(allocator, "ton://transfer/{s}?amount={d}", .{ destination, amount }),
        .created_at = timestamp,
    };
}

pub fn createPaymentURL(invoice: *const Invoice) []const u8 {
    _ = invoice;
    return "";
}

test "invoice creation" {
    _ = createInvoice;
}
