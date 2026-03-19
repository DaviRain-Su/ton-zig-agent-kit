const std = @import("std");
const ton_zig_agent_kit = @import("ton_zig_agent_kit");

const TonHttpClient = ton_zig_agent_kit.core.TonHttpClient;
const TonError = ton_zig_agent_kit.core.TonError;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage();
        return;
    }

    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version")) {
        std.debug.print("ton-zig-agent-kit v{s}\n", .{"0.0.1"});
        return;
    }

    if (std.mem.eql(u8, command, "getBalance") or std.mem.eql(u8, command, "balance")) {
        if (args.len < 3) {
            std.debug.print("Usage: ton-zig-agent-kit getBalance <address>\n", .{});
            return;
        }
        const addr = args[2];
        var client = try TonHttpClient.init(allocator, "https://tonapi.io", null);
        defer client.deinit();

        const result = try client.getBalance(addr);
        std.debug.print("Address: {s}\n", .{addr});
        std.debug.print("Balance: {d} nanotons ({d}.{d:09} TON)\n", .{
            result.balance,
            result.balance / 1_000_000_000,
            result.balance % 1_000_000_000,
        });
        return;
    }

    if (std.mem.eql(u8, command, "runGetMethod") or std.mem.eql(u8, command, "get-method")) {
        if (args.len < 4) {
            std.debug.print("Usage: ton-zig-agent-kit runGetMethod <address> <method>\n", .{});
            return;
        }
        const addr = args[2];
        const method = args[3];
        var client = try TonHttpClient.init(allocator, "https://tonapi.io", null);
        defer client.deinit();

        const result = try client.runGetMethod(addr, method, &.{});
        std.debug.print("Address: {s}\n", .{addr});
        std.debug.print("Method: {s}\n", .{method});
        std.debug.print("Exit code: {d}\n", .{result.exit_code});
        return;
    }

    if (std.mem.eql(u8, command, "parseAddress") or std.mem.eql(u8, command, "addr")) {
        if (args.len < 3) {
            std.debug.print("Usage: ton-zig-agent-kit parseAddress <address>\n", .{});
            return;
        }
        const address_str = args[2];
        const addr = try ton_zig_agent_kit.core.address.parseAddress(address_str);
        std.debug.print("Parsed address:\n", .{});
        std.debug.print("  Workchain: {d}\n", .{addr.workchain});
        std.debug.print("  Raw hex: ", .{});
        for (addr.raw) |byte| {
            std.debug.print("{X:0>2}", .{byte});
        }
        std.debug.print("\n", .{});
        return;
    }

    if (std.mem.eql(u8, command, "createInvoice") or std.mem.eql(u8, command, "invoice")) {
        if (args.len < 4) {
            std.debug.print("Usage: ton-zig-agent-kit createInvoice <destination> <amount_tons>\n", .{});
            return;
        }
        const destination = args[2];
        const amount_str = args[3];
        const amount = try std.fmt.parseInt(u64, amount_str, 10);
        const amount_nanoton = amount * 1_000_000_000;

        const invoice = try ton_zig_agent_kit.paywatch.invoice.createInvoice(allocator, destination, amount_nanoton, "Payment");
        defer allocator.free(invoice.comment);
        defer allocator.free(invoice.payment_url);

        std.debug.print("Invoice created:\n", .{});
        std.debug.print("  Address: {s}\n", .{invoice.address});
        std.debug.print("  Amount: {d} TON ({d} nanotons)\n", .{ amount, amount_nanoton });
        std.debug.print("  Comment: {s}\n", .{invoice.comment});
        std.debug.print("  Payment URL: {s}\n", .{invoice.payment_url});
        return;
    }

    try printUsage();
}

fn printUsage() !void {
    std.debug.print("ton-zig-agent-kit v{s}\n", .{"0.0.1"});
    std.debug.print("A Zig-native TON contract toolkit for AI agents\n\n", .{});
    std.debug.print("Usage:\n", .{});
    std.debug.print("  ton-zig-agent-kit help                          Show this help\n", .{});
    std.debug.print("  ton-zig-agent-kit version                       Show version\n", .{});
    std.debug.print("  ton-zig-agent-kit getBalance <address>          Get TON balance\n", .{});
    std.debug.print("  ton-zig-agent-kit runGetMethod <addr> <method>  Call get method\n", .{});
    std.debug.print("  ton-zig-agent-kit parseAddress <address>        Parse TON address\n", .{});
    std.debug.print("  ton-zig-agent-kit createInvoice <dest> <amount>  Create payment invoice\n", .{});
}

test "basic test" {
    try std.testing.expect(true);
}
