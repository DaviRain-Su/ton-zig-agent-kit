//! Agent tools - High-level interface for AI agents
//! Unified API for balance queries, transfers, invoices, and verification

const std = @import("std");
const address_mod = @import("../core/address.zig");
const body_builder = @import("../core/body_builder.zig");
const http_client = @import("../core/http_client.zig");
const paywatch = @import("../paywatch/paywatch.zig");
const wallet = @import("../wallet/wallet.zig");
const signing = @import("../wallet/signing.zig");
const contract = @import("../contract/contract.zig");
const abi_adapter = @import("../contract/abi_adapter.zig");
const jetton = @import("../contract/jetton.zig");
const nft = @import("../contract/nft.zig");
const tools_types = @import("types.zig");

pub const AgentTools = struct {
    allocator: std.mem.Allocator,
    client: *http_client.TonHttpClient,
    config: tools_types.AgentToolsConfig,

    pub fn init(allocator: std.mem.Allocator, client: *http_client.TonHttpClient, config: tools_types.AgentToolsConfig) AgentTools {
        return .{
            .allocator = allocator,
            .client = client,
            .config = config,
        };
    }

    /// Get TON balance for address
    pub fn getBalance(self: *AgentTools, target_address: []const u8) !tools_types.BalanceResult {
        const resp = self.client.getBalance(target_address) catch |err| {
            return tools_types.BalanceResult{
                .address = target_address,
                .balance = 0,
                .formatted = "0 TON",
                .success = false,
                .error_message = @errorName(err),
            };
        };

        const formatted = try std.fmt.allocPrint(self.allocator, "{d}.{d:09} TON", .{
            resp.balance / 1_000_000_000,
            resp.balance % 1_000_000_000,
        });

        return tools_types.BalanceResult{
            .address = target_address,
            .balance = resp.balance,
            .formatted = formatted,
            .success = true,
            .error_message = null,
        };
    }

    /// Run any contract get-method with typed stack arguments
    pub fn runGetMethod(self: *AgentTools, contract_address: []const u8, method: []const u8, args: []const contract.StackArg) !tools_types.RunMethodResult {
        var generic = contract.GenericContract.init(self.client, contract_address);
        var result = generic.callGetMethodArgs(method, args) catch |err| {
            return tools_types.RunMethodResult{
                .address = contract_address,
                .method = method,
                .exit_code = -1,
                .stack_json = "[]",
                .logs = "",
                .success = false,
                .error_message = @errorName(err),
            };
        };
        defer self.client.freeRunGetMethodResponse(&result);

        const stack_json = contract.stackToJsonAlloc(self.allocator, result.stack) catch |err| {
            return tools_types.RunMethodResult{
                .address = contract_address,
                .method = method,
                .exit_code = result.exit_code,
                .stack_json = "[]",
                .logs = "",
                .success = false,
                .error_message = @errorName(err),
            };
        };

        const logs = try self.allocator.dupe(u8, result.logs);
        return tools_types.RunMethodResult{
            .address = contract_address,
            .method = method,
            .exit_code = result.exit_code,
            .stack_json = stack_json,
            .logs = logs,
            .success = true,
            .error_message = null,
        };
    }

    /// Create payment invoice
    pub fn createInvoice(self: *AgentTools, amount: u64, description: []const u8) !tools_types.InvoiceResult {
        const dest = self.config.wallet_address orelse "";

        const invoice = paywatch.invoice.createInvoice(self.allocator, dest, amount, description) catch |err| {
            return tools_types.InvoiceResult{
                .invoice_id = "",
                .address = dest,
                .amount = amount,
                .comment = "",
                .payment_url = "",
                .expires_at = 0,
                .success = false,
                .error_message = @errorName(err),
            };
        };

        return tools_types.InvoiceResult{
            .invoice_id = invoice.id,
            .address = invoice.address,
            .amount = invoice.amount,
            .comment = invoice.comment,
            .payment_url = invoice.payment_url,
            .expires_at = invoice.expires_at.?,
            .success = true,
            .error_message = null,
        };
    }

    /// Verify payment by comment
    pub fn verifyPayment(self: *AgentTools, comment: []const u8) !tools_types.VerifyResult {
        const dest = self.config.wallet_address orelse "";

        // Create temporary invoice for verification
        const temp_invoice = paywatch.invoice.Invoice{
            .id = "verify",
            .address = dest,
            .comment = comment,
            .amount = 0,
            .description = "",
            .payment_url = "",
            .created_at = std.time.timestamp(),
            .expires_at = null,
            .status = .pending,
        };

        const result = paywatch.verifier.verifyPayment(self.client, &temp_invoice) catch |err| {
            return tools_types.VerifyResult{
                .verified = false,
                .tx_hash = null,
                .tx_lt = null,
                .amount = null,
                .sender = null,
                .timestamp = null,
                .success = false,
                .error_message = @errorName(err),
            };
        };

        return tools_types.VerifyResult{
            .verified = result.verified,
            .tx_hash = result.tx_hash,
            .tx_lt = result.tx_lt,
            .amount = result.amount,
            .sender = result.sender,
            .timestamp = result.timestamp,
            .success = true,
            .error_message = null,
        };
    }

    /// Wait for payment with timeout
    pub fn waitPayment(self: *AgentTools, comment: []const u8, timeout_ms: u32) !tools_types.VerifyResult {
        const dest = self.config.wallet_address orelse "";

        const temp_invoice = paywatch.invoice.Invoice{
            .id = "wait",
            .address = dest,
            .comment = comment,
            .amount = 0,
            .description = "",
            .payment_url = "",
            .created_at = std.time.timestamp(),
            .expires_at = std.time.timestamp() + @divTrunc(timeout_ms, 1000),
            .status = .pending,
        };

        var watcher = paywatch.watcher.PaymentWatcher.init(
            &temp_invoice,
            self.client,
            5000, // 5s poll interval
            timeout_ms,
        );

        const result = paywatch.watcher.waitPayment(&watcher) catch |err| {
            return tools_types.VerifyResult{
                .verified = false,
                .tx_hash = null,
                .tx_lt = null,
                .amount = null,
                .sender = null,
                .timestamp = null,
                .success = false,
                .error_message = @errorName(err),
            };
        };

        return tools_types.VerifyResult{
            .verified = result.found,
            .tx_hash = result.tx_hash,
            .tx_lt = result.tx_lt,
            .amount = result.amount,
            .sender = result.sender,
            .timestamp = result.confirmed_at,
            .success = true,
            .error_message = null,
        };
    }

    /// Get Jetton balance
    pub fn getJettonBalance(self: *AgentTools, wallet_address: []const u8, jetton_master: []const u8) !tools_types.JettonBalanceResult {
        var jwallet = jetton.JettonWallet.init(wallet_address, self.client);

        const data = jwallet.getWalletData() catch |err| {
            return tools_types.JettonBalanceResult{
                .address = wallet_address,
                .jetton_master = jetton_master,
                .balance = 0,
                .decimals = 9,
                .symbol = null,
                .success = false,
                .error_message = @errorName(err),
            };
        };

        return tools_types.JettonBalanceResult{
            .address = wallet_address,
            .jetton_master = jetton_master,
            .balance = data.balance,
            .decimals = 9,
            .symbol = null,
            .success = true,
            .error_message = null,
        };
    }

    /// Get NFT info
    pub fn getNFTInfo(self: *AgentTools, nft_address: []const u8) !tools_types.NFTInfoResult {
        var item = nft.NFTItem.init(nft_address, self.client);

        var data = item.getNFTData() catch |err| {
            return tools_types.NFTInfoResult{
                .address = nft_address,
                .owner = null,
                .collection = null,
                .index = 0,
                .content = null,
                .content_uri = null,
                .success = false,
                .error_message = @errorName(err),
            };
        };
        errdefer data.deinit(self.allocator);

        const owner = if (data.owner) |value| try address_mod.formatRaw(self.allocator, &value) else null;
        errdefer if (owner) |value| self.allocator.free(value);

        const collection = if (data.collection) |value| try address_mod.formatRaw(self.allocator, &value) else null;
        errdefer if (collection) |value| self.allocator.free(value);

        const content = data.content;
        data.content = null;
        const content_uri = data.content_uri;
        data.content_uri = null;

        return tools_types.NFTInfoResult{
            .address = nft_address,
            .owner = owner,
            .collection = collection,
            .index = @intCast(data.index),
            .content = content,
            .content_uri = content_uri,
            .success = true,
            .error_message = null,
        };
    }

    /// Send TON transfer (if wallet configured)
    pub fn sendTransfer(self: *AgentTools, destination: []const u8, amount: u64, comment: ?[]const u8) !tools_types.SendResult {
        const msgs = &[_]wallet.signing.WalletMessage{
            .{
                .destination = destination,
                .amount = amount,
                .comment = comment,
            },
        };
        return self.sendWalletMessages(destination, amount, msgs);
    }

    /// Send an arbitrary contract body BoC via the configured wallet
    pub fn sendContractMessage(self: *AgentTools, destination: []const u8, amount: u64, body_boc: []const u8) !tools_types.SendResult {
        const msgs = &[_]wallet.signing.WalletMessage{
            .{
                .destination = destination,
                .amount = amount,
                .body = body_boc,
            },
        };
        return self.sendWalletMessages(destination, amount, msgs);
    }

    /// Build and send an arbitrary contract body from typed operations
    pub fn sendContractMessageOps(self: *AgentTools, destination: []const u8, amount: u64, ops: []const body_builder.BodyOp) !tools_types.SendResult {
        const body_boc = body_builder.buildBodyBocAlloc(self.allocator, ops) catch |err| {
            return tools_types.SendResult{
                .hash = "",
                .lt = 0,
                .destination = destination,
                .amount = amount,
                .success = false,
                .error_message = @errorName(err),
            };
        };
        defer self.allocator.free(body_boc);

        return self.sendContractMessage(destination, amount, body_boc);
    }

    /// Build and send a contract body from a function schema and typed values
    pub fn sendContractMessageFunction(
        self: *AgentTools,
        destination: []const u8,
        amount: u64,
        function: abi_adapter.FunctionDef,
        values: []const abi_adapter.AbiValue,
    ) !tools_types.SendResult {
        const body_boc = abi_adapter.buildFunctionBodyBocAlloc(self.allocator, function, values) catch |err| {
            return tools_types.SendResult{
                .hash = "",
                .lt = 0,
                .destination = destination,
                .amount = amount,
                .success = false,
                .error_message = @errorName(err),
            };
        };
        defer self.allocator.free(body_boc);

        return self.sendContractMessage(destination, amount, body_boc);
    }

    fn sendWalletMessages(self: *AgentTools, destination: []const u8, amount: u64, msgs: []const wallet.signing.WalletMessage) !tools_types.SendResult {
        const private_key = self.config.wallet_private_key orelse {
            return tools_types.SendResult{
                .hash = "",
                .lt = 0,
                .destination = destination,
                .amount = amount,
                .success = false,
                .error_message = "Wallet not configured",
            };
        };

        const wallet_addr = self.config.wallet_address orelse "";
        const result = signing.sendMessages(self.client, .v4, private_key, wallet_addr, msgs) catch |err| {
            return tools_types.SendResult{
                .hash = "",
                .lt = 0,
                .destination = destination,
                .amount = amount,
                .success = false,
                .error_message = @errorName(err),
            };
        };

        return tools_types.SendResult{
            .hash = result.hash,
            .lt = result.lt,
            .destination = destination,
            .amount = amount,
            .success = true,
            .error_message = null,
        };
    }
};

// Re-export types
pub const BalanceResult = tools_types.BalanceResult;
pub const SendResult = tools_types.SendResult;
pub const RunMethodResult = tools_types.RunMethodResult;
pub const InvoiceResult = tools_types.InvoiceResult;
pub const VerifyResult = tools_types.VerifyResult;
pub const TxResult = tools_types.TxResult;
pub const JettonBalanceResult = tools_types.JettonBalanceResult;
pub const NFTInfoResult = tools_types.NFTInfoResult;
pub const AgentToolsConfig = tools_types.AgentToolsConfig;
pub const ToolResponse = tools_types.ToolResponse;
pub const ToolError = tools_types.ToolError;
pub const ErrorCode = tools_types.ErrorCode;

test "agent tools init" {
    const allocator = std.testing.allocator;
    var client = try http_client.TonHttpClient.init(allocator, "https://toncenter.com/api/v2/jsonRPC", null);
    defer client.deinit();

    const config = tools_types.AgentToolsConfig{
        .rpc_url = "https://toncenter.com/api/v2/jsonRPC",
    };

    const tools = AgentTools.init(allocator, &client, config);
    _ = tools;
}

test "agent tools getBalance" {
    const allocator = std.testing.allocator;
    var client = try http_client.TonHttpClient.init(allocator, "https://toncenter.com/api/v2/jsonRPC", null);
    defer client.deinit();

    const config = tools_types.AgentToolsConfig{
        .rpc_url = "https://toncenter.com/api/v2/jsonRPC",
    };

    var tools = AgentTools.init(allocator, &client, config);
    const result = try tools.getBalance("EQCD39vd5kB8FW5w6KH7HpNmP8GCvGajvLKGPMgY4sUXJyxqH");

    // Note: May fail if network unavailable, but struct should be valid
    _ = result;
}

test "agent tools generic runGetMethod result type is exported" {
    _ = AgentTools.runGetMethod;
    _ = AgentTools.sendContractMessage;
    _ = AgentTools.sendContractMessageOps;
    _ = AgentTools.sendContractMessageFunction;
    _ = RunMethodResult;
}
