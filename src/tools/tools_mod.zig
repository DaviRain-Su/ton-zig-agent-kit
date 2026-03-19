//! Agent tools - High-level interface for AI agents

const std = @import("std");
const http_client = @import("../core/http_client.zig");
const paywatch = @import("../paywatch/paywatch.zig");
const wallet = @import("../wallet/wallet.zig");
const tools_types = @import("types.zig");

pub const AgentTools = struct {
    client: *http_client.TonHttpClient,
};

pub fn getBalance(tools: *AgentTools, address: []const u8) !tools_types.BalanceResult {
    const resp = try tools.client.getBalance(address);
    return tools_types.BalanceResult{
        .address = address,
        .balance = resp.balance,
        .formatted = try std.fmt.allocPrint(std.heap.page_allocator, "{d}.{d:09} TON", .{
            resp.balance / 1_000_000_000,
            resp.balance % 1_000_000_000,
        }),
    };
}

pub fn createInvoice(tools: *AgentTools, amount: u64, description: []const u8) !tools_types.InvoiceResult {
    _ = tools;
    const invoice = try paywatch.invoice.createInvoice(std.heap.page_allocator, "", amount, description);
    return tools_types.InvoiceResult{
        .invoice_id = invoice.comment,
        .address = invoice.address,
        .amount = invoice.amount,
        .comment = invoice.comment,
        .payment_url = invoice.payment_url,
    };
}

test "agent tools" {
    _ = getBalance;
    _ = createInvoice;
}
