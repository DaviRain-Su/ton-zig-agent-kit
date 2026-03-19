const std = @import("std");
const ton_zig_agent_kit = @import("ton_zig_agent_kit");

const TonHttpClient = ton_zig_agent_kit.core.TonHttpClient;
const TonError = ton_zig_agent_kit.core.TonError;
const Cell = ton_zig_agent_kit.core.Cell;
const Builder = ton_zig_agent_kit.core.Builder;
const Slice = ton_zig_agent_kit.core.Slice;
const boc = ton_zig_agent_kit.core.boc;
const signing = ton_zig_agent_kit.wallet.signing;

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

    if (std.mem.eql(u8, command, "cell")) {
        if (args.len < 3) {
            std.debug.print("Usage: ton-zig-agent-kit cell <create|encode|decode|hash>\n", .{});
            return;
        }
        const cell_cmd = args[2];

        if (std.mem.eql(u8, cell_cmd, "create")) {
            var builder = Builder.init();
            try builder.storeUint(42, 8);
            try builder.storeUint(1000, 16);

            const cell = try builder.toCell(allocator);
            defer allocator.destroy(cell);

            const encoded = try boc.serializeBoc(allocator, cell);
            defer allocator.free(encoded);

            std.debug.print("Cell created:\n", .{});
            std.debug.print("  Bit length: {d}\n", .{cell.bit_len});
            std.debug.print("  Refs: {d}\n", .{cell.ref_cnt});
            std.debug.print("  Hash: ", .{});
            for (cell.hash()) |byte| {
                std.debug.print("{X:0>2}", .{byte});
            }
            std.debug.print("\n", .{});
            std.debug.print("  BoC size: {d} bytes\n", .{encoded.len});
            return;
        }

        if (std.mem.eql(u8, cell_cmd, "encode")) {
            if (args.len < 4) {
                std.debug.print("Usage: ton-zig-agent-kit cell encode <hex_data>\n", .{});
                return;
            }
            const hex_data = args[3];
            const bytes = try hexToBytes(allocator, hex_data);
            defer allocator.free(bytes);

            var builder = Builder.init();
            try builder.storeBits(bytes, @intCast(bytes.len * 8));

            const cell = try builder.toCell(allocator);
            defer allocator.destroy(cell);

            const encoded = try boc.serializeBoc(allocator, cell);
            defer allocator.free(encoded);

            std.debug.print("Encoded BoC (hex): ", .{});
            for (encoded) |byte| {
                std.debug.print("{X:0>2}", .{byte});
            }
            std.debug.print("\n", .{});
            return;
        }

        if (std.mem.eql(u8, cell_cmd, "hash")) {
            if (args.len < 4) {
                std.debug.print("Usage: ton-zig-agent-kit cell hash <hex_data>\n", .{});
                return;
            }
            const hex_data = args[3];
            const bytes = try hexToBytes(allocator, hex_data);
            defer allocator.free(bytes);

            var builder = Builder.init();
            try builder.storeBits(bytes, @intCast(bytes.len * 8));

            const cell = try builder.toCell(allocator);
            defer allocator.destroy(cell);

            std.debug.print("Cell hash: ", .{});
            for (cell.hash()) |byte| {
                std.debug.print("{X:0>2}", .{byte});
            }
            std.debug.print("\n", .{});
            return;
        }

        std.debug.print("Unknown cell command: {s}\n", .{cell_cmd});
        return;
    }

    if (std.mem.eql(u8, command, "wallet")) {
        if (args.len < 3) {
            std.debug.print("Usage: ton-zig-agent-kit wallet <genkey|seqno|send>\n", .{});
            return;
        }
        const wallet_cmd = args[2];

        if (std.mem.eql(u8, wallet_cmd, "genkey")) {
            const keypair = try signing.generateKeypair("my_seed_phrase");
            std.debug.print("Keypair generated:\n", .{});
            std.debug.print("  Private key: ", .{});
            for (keypair[0]) |byte| {
                std.debug.print("{X:0>2}", .{byte});
            }
            std.debug.print("\n", .{});
            std.debug.print("  Public key: ", .{});
            for (keypair[1]) |byte| {
                std.debug.print("{X:0>2}", .{byte});
            }
            std.debug.print("\n", .{});
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "seqno")) {
            if (args.len < 4) {
                std.debug.print("Usage: ton-zig-agent-kit wallet seqno <wallet_address>\n", .{});
                return;
            }
            const wallet_addr = args[3];
            var client = try TonHttpClient.init(allocator, "https://tonapi.io", null);
            defer client.deinit();

            const seqno = try signing.getSeqno(&client, wallet_addr);
            std.debug.print("Wallet seqno: {d}\n", .{seqno});
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "send")) {
            if (args.len < 6) {
                std.debug.print("Usage: ton-zig-agent-kit wallet send <wallet_addr> <dest> <amount_nanoton>\n", .{});
                return;
            }
            const wallet_addr = args[3];
            const dest = args[4];
            const amount = try std.fmt.parseInt(u64, args[5], 10);

            var client = try TonHttpClient.init(allocator, "https://tonapi.io", null);
            defer client.deinit();

            // Generate keypair (in real usage, load from secure storage)
            const keypair = try signing.generateKeypair("my_seed_phrase");
            const private_key = keypair[0];

            // Create message
            const msgs = &[_]signing.WalletMessage{
                .{
                    .destination = dest,
                    .amount = amount,
                },
            };

            // Get seqno
            const seqno = try signing.getSeqno(&client, wallet_addr);

            // Create signed transfer
            const signed_transfer = try signing.createSignedTransfer(allocator, .v4, private_key, seqno, @constCast(msgs));
            defer allocator.free(signed_transfer);

            std.debug.print("Signed transfer created ({d} bytes)\n", .{signed_transfer.len});
            std.debug.print("First 64 bytes (signature): ", .{});
            for (signed_transfer[0..@min(64, signed_transfer.len)]) |byte| {
                std.debug.print("{X:0>2}", .{byte});
            }
            std.debug.print("...\n", .{});

            // Send (would be: try client.sendBoc(signed_transfer);)
            std.debug.print("Transfer ready to send (seqno: {d})\n", .{seqno});
            return;
        }

        std.debug.print("Unknown wallet command: {s}\n", .{wallet_cmd});
        return;
    }

    try printUsage();
}

fn hexToBytes(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidHex;
    const out = try allocator.alloc(u8, hex.len / 2);
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const hi = try hexCharValue(hex[i * 2]);
        const lo = try hexCharValue(hex[i * 2 + 1]);
        out[i] = (hi << 4) | lo;
    }
    return out;
}

fn hexCharValue(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
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
    std.debug.print("\nCell/Builder/Slice operations:\n", .{});
    std.debug.print("  ton-zig-agent-kit cell create                  Create test cell\n", .{});
    std.debug.print("  ton-zig-agent-kit cell encode <hex>            Encode data to BoC\n", .{});
    std.debug.print("  ton-zig-agent-kit cell hash <hex>              Get cell hash\n", .{});
    std.debug.print("\nWallet operations:\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet genkey                Generate keypair\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet seqno <addr>          Get wallet seqno\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet send <src> <dst> <amount>  Send TON\n", .{});
}

test "basic test" {
    try std.testing.expect(true);
}
