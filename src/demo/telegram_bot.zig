//! Telegram Bot Demo
//! Example bot showing payment flow integration

const std = @import("std");
const core = @import("../core/core.zig");
const tools = @import("../tools/tools_mod.zig");
const paywatch = @import("../paywatch/paywatch.zig");

const AgentTools = tools.ProviderAgentTools;
const AgentToolsConfig = tools.AgentToolsConfig;

/// Bot state for tracking orders
pub const BotState = struct {
    allocator: std.mem.Allocator,
    orders: std.StringHashMap(Order),
    next_order_id: u64,

    pub const Order = struct {
        id: []const u8,
        user_id: i64,
        amount: u64,
        status: OrderStatus,
        invoice_comment: ?[]const u8,
        tx_hash: ?[]const u8,
    };

    pub const OrderStatus = enum {
        pending,
        awaiting_payment,
        paid,
        completed,
        expired,
    };

    pub fn init(allocator: std.mem.Allocator) BotState {
        return .{
            .allocator = allocator,
            .orders = std.StringHashMap(Order).init(allocator),
            .next_order_id = 1,
        };
    }

    pub fn deinit(self: *BotState) void {
        var iter = self.orders.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.id);
            if (entry.value_ptr.invoice_comment) |c| self.allocator.free(c);
            if (entry.value_ptr.tx_hash) |h| self.allocator.free(h);
        }
        self.orders.deinit();
    }

    pub fn createOrder(self: *BotState, user_id: i64, amount: u64) ![]const u8 {
        const id = try std.fmt.allocPrint(self.allocator, "order_{d}", .{self.next_order_id});
        self.next_order_id += 1;

        const order = Order{
            .id = id,
            .user_id = user_id,
            .amount = amount,
            .status = .pending,
            .invoice_comment = null,
            .tx_hash = null,
        };

        try self.orders.put(id, order);
        return id;
    }

    pub fn updateOrderStatus(self: *BotState, order_id: []const u8, status: OrderStatus) !void {
        var order = self.orders.getPtr(order_id) orelse return error.OrderNotFound;
        order.status = status;
    }

    pub fn setInvoiceComment(self: *BotState, order_id: []const u8, comment: []const u8) !void {
        var order = self.orders.getPtr(order_id) orelse return error.OrderNotFound;
        order.invoice_comment = try self.allocator.dupe(u8, comment);
    }

    pub fn setTxHash(self: *BotState, order_id: []const u8, tx_hash: []const u8) !void {
        var order = self.orders.getPtr(order_id) orelse return error.OrderNotFound;
        order.tx_hash = try self.allocator.dupe(u8, tx_hash);
    }
};

/// Demo bot showing the flow
pub const DemoBot = struct {
    allocator: std.mem.Allocator,
    state: BotState,
    client: core.provider.MultiProvider,
    tools: AgentTools,
    merchant_address: []const u8,

    pub fn init(allocator: std.mem.Allocator, merchant_address: []const u8) !DemoBot {
        const config = AgentToolsConfig{
            .rpc_url = "https://toncenter.com/api/v2/jsonRPC",
            .wallet_address = merchant_address,
        };

        var bot = DemoBot{
            .allocator = allocator,
            .state = BotState.init(allocator),
            .client = try core.provider.MultiProvider.init(allocator, &.{
                .{ .url = "https://toncenter.com/api/v2/jsonRPC" },
            }),
            .tools = undefined,
            .merchant_address = merchant_address,
        };

        bot.tools = AgentTools.init(allocator, &bot.client, config);
        return bot;
    }

    pub fn deinit(self: *DemoBot) void {
        self.state.deinit();
    }

    /// Handle /start command
    pub fn handleStart(self: *DemoBot, user_id: i64) ![]const u8 {
        _ = user_id;
        return try std.fmt.allocPrint(self.allocator, "Welcome to TON Payment Bot!\n\n" ++
            "Commands:\n" ++
            "/buy <amount> - Create a new order\n" ++
            "/status <order_id> - Check order status\n" ++
            "/balance <address> - Check TON balance\n", .{});
    }

    /// Handle /buy command
    pub fn handleBuy(self: *DemoBot, user_id: i64, amount_tons: u64) ![]const u8 {
        // Create order
        const order_id = try self.state.createOrder(user_id, amount_tons * 1_000_000_000);

        // Create invoice
        const invoice_result = try self.tools.createInvoice(amount_tons * 1_000_000_000, "Bot Order");

        if (!invoice_result.success) {
            return try std.fmt.allocPrint(self.allocator, "Error creating invoice: {s}", .{invoice_result.error_message orelse "unknown"});
        }

        // Store invoice comment
        try self.state.setInvoiceComment(order_id, invoice_result.comment);
        try self.state.updateOrderStatus(order_id, .awaiting_payment);

        return try std.fmt.allocPrint(self.allocator, "Order created!\n" ++
            "Order ID: {s}\n" ++
            "Amount: {d} TON\n" ++
            "Payment Comment: {s}\n\n" ++
            "Please send {d} TON to:\n" ++
            "{s}\n\n" ++
            "With comment: {s}\n\n" ++
            "Or use: {s}", .{
            order_id,
            amount_tons,
            invoice_result.comment,
            amount_tons,
            self.merchant_address,
            invoice_result.comment,
            invoice_result.payment_url,
        });
    }

    /// Handle /status command
    pub fn handleStatus(self: *DemoBot, order_id: []const u8) ![]const u8 {
        const order = self.state.orders.get(order_id) orelse {
            return try std.fmt.allocPrint(self.allocator, "Order not found: {s}", .{order_id});
        };

        // If awaiting payment, check if paid
        if (order.status == .awaiting_payment) {
            if (order.invoice_comment) |comment| {
                const verify_result = try self.tools.verifyPayment(comment);

                if (verify_result.verified) {
                    try self.state.updateOrderStatus(order_id, .paid);
                    if (verify_result.tx_hash) |hash| {
                        try self.state.setTxHash(order_id, hash);
                    }
                }
            }
        }

        // Get updated status
        const updated_order = self.state.orders.get(order_id).?;
        const tx_line = if (updated_order.tx_hash) |hash|
            try std.fmt.allocPrint(self.allocator, "Transaction: {s}\n", .{hash})
        else
            null;
        defer if (tx_line) |line| self.allocator.free(line);

        return try std.fmt.allocPrint(self.allocator, "Order Status\n" ++
            "ID: {s}\n" ++
            "Status: {s}\n" ++
            "Amount: {d} TON\n" ++
            "{s}", .{
            order_id,
            @tagName(updated_order.status),
            updated_order.amount / 1_000_000_000,
            tx_line orelse "",
        });
    }

    /// Handle /balance command
    pub fn handleBalance(self: *DemoBot, address: []const u8) ![]const u8 {
        const result = try self.tools.getBalance(address);

        if (!result.success) {
            return try std.fmt.allocPrint(self.allocator, "Error: {s}", .{result.error_message orelse "unknown"});
        }

        return try std.fmt.allocPrint(self.allocator, "Balance for {s}:\n{s}", .{ address, result.formatted });
    }
};

/// Run demo scenario
pub fn runDemo() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== TON Payment Bot Demo ===\n\n", .{});

    var bot = try DemoBot.init(allocator, "EQCD39vd5kB8FW5w6KH7HpNmP8GCvGajvLKGPMgY4sUXJyxqH");
    defer bot.deinit();

    const user_id: i64 = 12345;

    // Demo 1: Start
    std.debug.print("1. User sends /start\n", .{});
    const welcome = try bot.handleStart(user_id);
    std.debug.print("Bot: {s}\n\n", .{welcome});

    // Demo 2: Buy
    std.debug.print("2. User sends /buy 10\n", .{});
    const buy_response = try bot.handleBuy(user_id, 10);
    std.debug.print("Bot: {s}\n\n", .{buy_response});

    // Extract order ID from response (simplified)
    const order_id = "order_1";

    // Demo 3: Check status
    std.debug.print("3. User sends /status {s}\n", .{order_id});
    const status = try bot.handleStatus(order_id);
    std.debug.print("Bot: {s}\n\n", .{status});

    // Demo 4: Check balance
    std.debug.print("4. User sends /balance EQCD39vd5kB8FW5w6KH7HpNmP8GCvGajvLKGPMgY4sUXJyxqH\n", .{});
    const balance = try bot.handleBalance("EQCD39vd5kB8FW5w6KH7HpNmP8GCvGajvLKGPMgY4sUXJyxqH");
    std.debug.print("Bot: {s}\n\n", .{balance});

    std.debug.print("=== Demo Complete ===\n", .{});
}

test "bot state" {
    const allocator = std.testing.allocator;
    var state = BotState.init(allocator);
    defer state.deinit();

    const order_id = try state.createOrder(12345, 1000000000);
    try std.testing.expect(state.orders.contains(order_id));
}

test "demo bot init" {
    const allocator = std.testing.allocator;
    var bot = try DemoBot.init(allocator, "EQCD39vd5kB8FW5w6KH7HpNmP8GCvGajvLKGPMgY4sUXJyxqH");
    defer bot.deinit();
}
