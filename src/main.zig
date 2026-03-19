const std = @import("std");
const ton_zig_agent_kit = @import("ton_zig_agent_kit");

const TonHttpClient = ton_zig_agent_kit.core.TonHttpClient;
const TonError = ton_zig_agent_kit.core.TonError;
const Cell = ton_zig_agent_kit.core.Cell;
const Builder = ton_zig_agent_kit.core.Builder;
const Slice = ton_zig_agent_kit.core.Slice;
const StackEntry = ton_zig_agent_kit.core.types.StackEntry;
const boc = ton_zig_agent_kit.core.boc;
const signing = ton_zig_agent_kit.wallet.signing;
const default_rpc_url = "https://toncenter.com/api/v2/jsonRPC";

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
        var client = try TonHttpClient.init(allocator, default_rpc_url, null);
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
            std.debug.print("Usage: ton-zig-agent-kit runGetMethod <address> <method> [stack_json]\n", .{});
            return;
        }
        const addr = args[2];
        const method = args[3];
        const stack_json = if (args.len >= 5) args[4] else "[]";
        var client = try TonHttpClient.init(allocator, default_rpc_url, null);
        defer client.deinit();

        var result = try client.runGetMethodJson(addr, method, stack_json);
        defer client.freeRunGetMethodResponse(&result);

        std.debug.print("Address: {s}\n", .{addr});
        std.debug.print("Method: {s}\n", .{method});
        std.debug.print("Stack JSON: {s}\n", .{stack_json});
        printRunGetMethodResult(result);
        return;
    }

    if (std.mem.eql(u8, command, "sendBoc") or std.mem.eql(u8, command, "send-boc")) {
        if (args.len < 3) {
            std.debug.print("Usage: ton-zig-agent-kit sendBoc <boc_base64>\n", .{});
            return;
        }

        var client = try TonHttpClient.init(allocator, default_rpc_url, null);
        defer client.deinit();

        var result = try client.sendBocBase64(args[2]);
        defer client.freeSendBocResponse(&result);

        std.debug.print("Submitted BoC:\n", .{});
        std.debug.print("  Hash: {s}\n", .{result.hash});
        std.debug.print("  LT: {d}\n", .{result.lt});
        return;
    }

    if (std.mem.eql(u8, command, "sendBocHex") or std.mem.eql(u8, command, "send-boc-hex")) {
        if (args.len < 3) {
            std.debug.print("Usage: ton-zig-agent-kit sendBocHex <boc_hex>\n", .{});
            return;
        }

        var client = try TonHttpClient.init(allocator, default_rpc_url, null);
        defer client.deinit();

        var result = try client.sendBocHex(args[2]);
        defer client.freeSendBocResponse(&result);

        std.debug.print("Submitted BoC:\n", .{});
        std.debug.print("  Hash: {s}\n", .{result.hash});
        std.debug.print("  LT: {d}\n", .{result.lt});
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
            var client = try TonHttpClient.init(allocator, default_rpc_url, null);
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

            var client = try TonHttpClient.init(allocator, default_rpc_url, null);
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

    if (std.mem.eql(u8, command, "paywatch") or std.mem.eql(u8, command, "watch")) {
        if (args.len < 3) {
            std.debug.print("Usage: ton-zig-agent-kit paywatch <invoice|verify|wait>\n", .{});
            return;
        }
        const watch_cmd = args[2];

        if (std.mem.eql(u8, watch_cmd, "invoice")) {
            if (args.len < 5) {
                std.debug.print("Usage: ton-zig-agent-kit paywatch invoice <destination> <amount_tons>\n", .{});
                return;
            }
            const destination = args[3];
            const amount = try std.fmt.parseInt(u64, args[4], 10);
            const amount_nanoton = amount * 1_000_000_000;

            const invoice = try ton_zig_agent_kit.paywatch.invoice.createInvoice(allocator, destination, amount_nanoton, "Payment");
            defer allocator.free(invoice.id);
            defer allocator.free(invoice.comment);
            defer allocator.free(invoice.payment_url);

            std.debug.print("Invoice created:\n", .{});
            std.debug.print("  ID: {s}\n", .{invoice.id});
            std.debug.print("  Address: {s}\n", .{invoice.address});
            std.debug.print("  Amount: {d} TON ({d} nanotons)\n", .{ amount, amount_nanoton });
            std.debug.print("  Comment: {s}\n", .{invoice.comment});
            std.debug.print("  Payment URL: {s}\n", .{invoice.payment_url});
            std.debug.print("  Expires: {d}\n", .{invoice.expires_at.?});
            return;
        }

        if (std.mem.eql(u8, watch_cmd, "verify")) {
            if (args.len < 5) {
                std.debug.print("Usage: ton-zig-agent-kit paywatch verify <address> <comment>\n", .{});
                return;
            }
            const address = args[3];
            const comment = args[4];

            // Create a temporary invoice for verification
            const invoice = ton_zig_agent_kit.paywatch.invoice.Invoice{
                .id = "verify",
                .address = address,
                .comment = comment,
                .amount = 0,
                .description = "",
                .payment_url = "",
                .created_at = std.time.timestamp(),
                .expires_at = null,
                .status = .pending,
            };

            var client = try TonHttpClient.init(allocator, default_rpc_url, null);
            defer client.deinit();

            const result = try ton_zig_agent_kit.paywatch.verifier.verifyPayment(&client, &invoice);

            std.debug.print("Verification result:\n", .{});
            std.debug.print("  Verified: {any}\n", .{result.verified});
            if (result.tx_hash) |hash| {
                std.debug.print("  Transaction: {s}\n", .{hash});
            }
            if (result.amount) |amt| {
                std.debug.print("  Amount: {d} nanotons\n", .{amt});
            }
            return;
        }

        if (std.mem.eql(u8, watch_cmd, "wait")) {
            if (args.len < 5) {
                std.debug.print("Usage: ton-zig-agent-kit paywatch wait <address> <comment>\n", .{});
                return;
            }
            const address = args[3];
            const comment = args[4];

            const invoice = ton_zig_agent_kit.paywatch.invoice.Invoice{
                .id = "wait",
                .address = address,
                .comment = comment,
                .amount = 0,
                .description = "",
                .payment_url = "",
                .created_at = std.time.timestamp(),
                .expires_at = std.time.timestamp() + 300, // 5 min timeout
                .status = .pending,
            };

            var client = try TonHttpClient.init(allocator, default_rpc_url, null);
            defer client.deinit();

            std.debug.print("Waiting for payment (timeout: 30s)...\n", .{});

            var watcher = ton_zig_agent_kit.paywatch.watcher.PaymentWatcher.init(
                &invoice,
                &client,
                5000, // 5s poll interval
                30000, // 30s timeout
            );

            const result = try ton_zig_agent_kit.paywatch.watcher.waitPayment(&watcher);

            if (result.found) {
                std.debug.print("Payment found!\n", .{});
                if (result.tx_hash) |hash| {
                    std.debug.print("  Transaction: {s}\n", .{hash});
                }
                if (result.amount) |amt| {
                    std.debug.print("  Amount: {d} nanotons\n", .{amt});
                }
            } else {
                std.debug.print("Payment not found (timeout or expired)\n", .{});
            }
            return;
        }

        std.debug.print("Unknown paywatch command: {s}\n", .{watch_cmd});
        return;
    }

    if (std.mem.eql(u8, command, "demo")) {
        if (args.len < 3) {
            std.debug.print("Usage: ton-zig-agent-kit demo <bot>\n", .{});
            return;
        }
        const demo_cmd = args[2];

        if (std.mem.eql(u8, demo_cmd, "bot")) {
            try runBotDemo();
            return;
        }

        std.debug.print("Unknown demo command: {s}\n", .{demo_cmd});
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

fn printRunGetMethodResult(result: ton_zig_agent_kit.core.types.RunGetMethodResponse) void {
    std.debug.print("Exit code: {d}\n", .{result.exit_code});

    if (result.logs.len > 0) {
        std.debug.print("Logs:\n{s}\n", .{result.logs});
    }

    if (result.stack.len == 0) {
        std.debug.print("Stack: []\n", .{});
        return;
    }

    std.debug.print("Stack:\n", .{});
    for (result.stack, 0..) |entry, i| {
        printIndent(2);
        std.debug.print("[{d}] ", .{i});
        printStackEntry(entry, 4);
    }
}

fn printStackEntry(entry: StackEntry, indent: usize) void {
    switch (entry) {
        .number => |value| std.debug.print("number: {d}\n", .{value}),
        .bytes => |value| std.debug.print("bytes/base64: {s}\n", .{value}),
        .cell => |value| std.debug.print("cell(bits={d}, refs={d})\n", .{ value.bit_len, value.ref_cnt }),
        .tuple => |items| {
            std.debug.print("tuple[{d}]\n", .{items.len});
            for (items, 0..) |child, i| {
                printIndent(indent);
                std.debug.print("[{d}] ", .{i});
                printStackEntry(child, indent + 2);
            }
        },
    }
}

fn printIndent(indent: usize) void {
    var i: usize = 0;
    while (i < indent) : (i += 1) {
        std.debug.print(" ", .{});
    }
}

fn printUsage() !void {
    std.debug.print("ton-zig-agent-kit v{s}\n", .{"0.0.1"});
    std.debug.print("A Zig-native TON contract toolkit for AI agents\n\n", .{});
    std.debug.print("Usage:\n", .{});
    std.debug.print("  ton-zig-agent-kit help                          Show this help\n", .{});
    std.debug.print("  ton-zig-agent-kit version                       Show version\n", .{});
    std.debug.print("  ton-zig-agent-kit getBalance <address>          Get TON balance\n", .{});
    std.debug.print("  ton-zig-agent-kit runGetMethod <addr> <method> [stack_json]  Call any get method\n", .{});
    std.debug.print("  ton-zig-agent-kit sendBoc <boc_base64>          Submit raw BoC to the network\n", .{});
    std.debug.print("  ton-zig-agent-kit sendBocHex <boc_hex>          Submit raw BoC hex to the network\n", .{});
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
    std.debug.print("\nPayment watch operations:\n", .{});
    std.debug.print("  ton-zig-agent-kit paywatch invoice <dest> <amount>  Create invoice\n", .{});
    std.debug.print("  ton-zig-agent-kit paywatch verify <addr> <comment>  Verify payment\n", .{});
    std.debug.print("  ton-zig-agent-kit paywatch wait <addr> <comment>    Wait for payment\n", .{});
    std.debug.print("\nDemo:\n", .{});
    std.debug.print("  ton-zig-agent-kit demo bot                     Run Telegram bot demo\n", .{});
}

/// Run Telegram Bot Demo
fn runBotDemo() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== TON Payment Bot Demo ===\n\n", .{});

    const merchant_address = "EQCD39vd5kB8FW5w6KH7HpNmP8GCvGajvLKGPMgY4sUXJyxqH";

    // Demo 1: Start
    std.debug.print("1. User sends /start\n", .{});
    const welcome = try std.fmt.allocPrint(allocator, "Welcome to TON Payment Bot!\n\n" ++
        "Commands:\n" ++
        "/buy <amount> - Create a new order\n" ++
        "/status <order_id> - Check order status\n" ++
        "/balance <address> - Check TON balance\n", .{});
    std.debug.print("Bot: {s}\n\n", .{welcome});

    // Demo 2: Buy
    std.debug.print("2. User sends /buy 10\n", .{});

    // Create invoice
    const amount_nanoton = 10 * 1_000_000_000;
    const timestamp = std.time.timestamp();
    const comment = try std.fmt.allocPrint(allocator, "TON-ZIG-{d}-1", .{timestamp});
    defer allocator.free(comment);

    const payment_url = try std.fmt.allocPrint(allocator, "ton://transfer/{s}?amount={d}&text={s}", .{ merchant_address, amount_nanoton, comment });
    defer allocator.free(payment_url);

    const buy_response = try std.fmt.allocPrint(allocator, "Order created!\n" ++
        "Order ID: order_1\n" ++
        "Amount: 10 TON\n" ++
        "Payment Comment: {s}\n\n" ++
        "Please send 10 TON to:\n" ++
        "{s}\n\n" ++
        "With comment: {s}\n\n" ++
        "Or use: {s}", .{ comment, merchant_address, comment, payment_url });
    defer allocator.free(buy_response);

    std.debug.print("Bot: {s}\n\n", .{buy_response});

    // Demo 3: Check status
    std.debug.print("3. User sends /status order_1\n", .{});
    const status = try std.fmt.allocPrint(allocator, "Order Status\n" ++
        "ID: order_1\n" ++
        "Status: awaiting_payment\n" ++
        "Amount: 10 TON\n", .{});
    defer allocator.free(status);
    std.debug.print("Bot: {s}\n\n", .{status});

    // Demo 4: Check balance
    std.debug.print("4. User sends /balance EQCD39vd5kB8FW5w6KH7HpNmP8GCvGajvLKGPMgY4sUXJyxqH\n", .{});

    var client = try TonHttpClient.init(allocator, default_rpc_url, null);
    defer client.deinit();

    const balance_result = client.getBalance("EQCD39vd5kB8FW5w6KH7HpNmP8GCvGajvLKGPMgY4sUXJyxqH") catch |err| {
        std.debug.print("Bot: Error checking balance: {s}\n", .{@errorName(err)});
        return;
    };

    const balance = try std.fmt.allocPrint(allocator, "Balance for EQCD39vd5kB8FW5w6KH7HpNmP8GCvGajvLKGPMgY4sUXJyxqH:\n{d}.{d:09} TON", .{
        balance_result.balance / 1_000_000_000,
        balance_result.balance % 1_000_000_000,
    });
    defer allocator.free(balance);

    std.debug.print("Bot: {s}\n\n", .{balance});

    std.debug.print("=== Demo Complete ===\n", .{});
    std.debug.print("\nThis demo shows the core payment flow:\n", .{});
    std.debug.print("1. User creates an order with /buy\n", .{});
    std.debug.print("2. Bot generates unique invoice with comment\n", .{});
    std.debug.print("3. User pays via TON wallet with the comment\n", .{});
    std.debug.print("4. Bot monitors and confirms payment\n", .{});
    std.debug.print("5. Goods/services are delivered\n", .{});
}

test "basic test" {
    try std.testing.expect(true);
}

test "hexToBytes parses mixed case input" {
    const allocator = std.testing.allocator;
    const bytes = try hexToBytes(allocator, "00A1ff");
    defer allocator.free(bytes);

    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0xA1, 0xff }, bytes);
}
