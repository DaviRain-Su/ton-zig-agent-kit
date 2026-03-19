//! Agent tools - High-level interface for AI agents
//! Unified API for balance queries, transfers, invoices, and verification

const std = @import("std");
const address_mod = @import("../core/address.zig");
const body_builder = @import("../core/body_builder.zig");
const http_client = @import("../core/http_client.zig");
const provider_mod = @import("../core/provider.zig");
const state_init = @import("../core/state_init.zig");
const paywatch = @import("../paywatch/paywatch.zig");
const wallet = @import("../wallet/wallet.zig");
const signing = @import("../wallet/signing.zig");
const contract = @import("../contract/contract.zig");
const abi_adapter = @import("../contract/abi_adapter.zig");
const jetton = @import("../contract/jetton.zig");
const nft = @import("../contract/nft.zig");
const tools_types = @import("types.zig");

fn AgentToolsImpl(comptime ClientType: type) type {
    const JettonMasterClient = if (ClientType == *http_client.TonHttpClient) jetton.JettonMaster else jetton.ProviderJettonMaster;
    const NFTCollectionClient = if (ClientType == *http_client.TonHttpClient) nft.NFTCollection else nft.ProviderNFTCollection;

    return struct {
        allocator: std.mem.Allocator,
        client: ClientType,
        config: tools_types.AgentToolsConfig,

        pub fn init(allocator: std.mem.Allocator, client: ClientType, config: tools_types.AgentToolsConfig) @This() {
            return .{
                .allocator = allocator,
                .client = client,
                .config = config,
            };
        }

        /// Get TON balance for address
        pub fn getBalance(self: *@This(), target_address: []const u8) !tools_types.BalanceResult {
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

        /// Compute the deployed contract address for a StateInit BoC and workchain.
        pub fn computeStateInitAddress(
            self: *@This(),
            workchain: i8,
            state_init_boc: []const u8,
        ) !tools_types.AddressResult {
            const addr = state_init.computeStateInitAddressFromBoc(self.allocator, workchain, state_init_boc) catch |err| {
                return tools_types.AddressResult{
                    .raw_address = "",
                    .user_friendly_address = "",
                    .workchain = workchain,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };

            const raw_address = address_mod.formatRaw(self.allocator, &addr) catch |err| {
                return tools_types.AddressResult{
                    .raw_address = "",
                    .user_friendly_address = "",
                    .workchain = workchain,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            errdefer self.allocator.free(raw_address);

            const user_friendly_address = address_mod.addressToUserFriendlyAlloc(self.allocator, &addr, true, false) catch |err| {
                return tools_types.AddressResult{
                    .raw_address = "",
                    .user_friendly_address = "",
                    .workchain = workchain,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            errdefer self.allocator.free(user_friendly_address);

            return tools_types.AddressResult{
                .raw_address = raw_address,
                .user_friendly_address = user_friendly_address,
                .workchain = workchain,
                .success = true,
                .error_message = null,
            };
        }

        /// Run any contract get-method with typed stack arguments
        pub fn runGetMethod(self: *@This(), contract_address: []const u8, method: []const u8, args: []const contract.StackArg) !tools_types.RunMethodResult {
            const stack_input = contract.buildStackArgsJsonAlloc(self.allocator, args) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = method,
                    .exit_code = -1,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.allocator.free(stack_input);

            var result = self.client.runGetMethodJson(contract_address, method, stack_input) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = method,
                    .exit_code = -1,
                    .stack_json = "[]",
                    .decoded_json = null,
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
                    .decoded_json = null,
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
                .decoded_json = null,
                .logs = logs,
                .success = true,
                .error_message = null,
            };
        }

        /// Run a get-method using ABI input/output definitions
        pub fn runGetMethodAbi(
            self: *@This(),
            contract_address: []const u8,
            abi_json: []const u8,
            function_name: []const u8,
            values: []const abi_adapter.AbiValue,
        ) !tools_types.RunMethodResult {
            var abi = abi_adapter.loadAbiInfoSourceAlloc(self.allocator, abi_json) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = -1,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer abi.deinit(self.client.allocator);

            const function = abi_adapter.findFunction(&abi.abi, function_name) orelse {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = -1,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = "FunctionNotFound",
                };
            };

            var args = abi_adapter.buildStackArgsFromFunctionAlloc(self.allocator, function.*, values) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = -1,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer args.deinit(self.allocator);

            const stack_input = contract.buildStackArgsJsonAlloc(self.allocator, args.args) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = -1,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.allocator.free(stack_input);

            var result = self.client.runGetMethodJson(contract_address, function.name, stack_input) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = -1,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.client.freeRunGetMethodResponse(&result);

            const stack_json = contract.stackToJsonAlloc(self.allocator, result.stack) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = result.exit_code,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            errdefer self.allocator.free(stack_json);

            const logs = try self.allocator.dupe(u8, result.logs);
            errdefer self.allocator.free(logs);

            const decoded_json = abi_adapter.decodeFunctionOutputsJsonAlloc(
                self.allocator,
                function.*,
                result.stack,
            ) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = result.exit_code,
                    .stack_json = stack_json,
                    .decoded_json = null,
                    .logs = logs,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            errdefer self.allocator.free(decoded_json);

            return tools_types.RunMethodResult{
                .address = contract_address,
                .method = function_name,
                .exit_code = result.exit_code,
                .stack_json = stack_json,
                .decoded_json = decoded_json,
                .logs = logs,
                .success = true,
                .error_message = null,
            };
        }

        /// Run a get-method by discovering the contract ABI URI on-chain
        pub fn runGetMethodAuto(
            self: *@This(),
            contract_address: []const u8,
            function_name: []const u8,
            values: []const abi_adapter.AbiValue,
        ) !tools_types.RunMethodResult {
            var abi = abi_adapter.queryAbiDocumentAlloc(self.client, contract_address) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = -1,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            } orelse return tools_types.RunMethodResult{
                .address = contract_address,
                .method = function_name,
                .exit_code = -1,
                .stack_json = "[]",
                .decoded_json = null,
                .logs = "",
                .success = false,
                .error_message = "AbiNotFound",
            };
            defer abi.deinit(self.client.allocator);

            const function = abi_adapter.findFunction(&abi.abi, function_name) orelse {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = -1,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = "FunctionNotFound",
                };
            };

            var args = abi_adapter.buildStackArgsFromFunctionAlloc(self.allocator, function.*, values) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = -1,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer args.deinit(self.allocator);

            const stack_input = contract.buildStackArgsJsonAlloc(self.allocator, args.args) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = -1,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.allocator.free(stack_input);

            var result = self.client.runGetMethodJson(contract_address, function.name, stack_input) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = -1,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.client.freeRunGetMethodResponse(&result);

            const stack_json = contract.stackToJsonAlloc(self.allocator, result.stack) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = result.exit_code,
                    .stack_json = "[]",
                    .decoded_json = null,
                    .logs = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            errdefer self.allocator.free(stack_json);

            const logs = try self.allocator.dupe(u8, result.logs);
            errdefer self.allocator.free(logs);

            const decoded_json = abi_adapter.decodeFunctionOutputsJsonAlloc(
                self.allocator,
                function.*,
                result.stack,
            ) catch |err| {
                return tools_types.RunMethodResult{
                    .address = contract_address,
                    .method = function_name,
                    .exit_code = result.exit_code,
                    .stack_json = stack_json,
                    .decoded_json = null,
                    .logs = logs,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            errdefer self.allocator.free(decoded_json);

            return tools_types.RunMethodResult{
                .address = contract_address,
                .method = function_name,
                .exit_code = result.exit_code,
                .stack_json = stack_json,
                .decoded_json = decoded_json,
                .logs = logs,
                .success = true,
                .error_message = null,
            };
        }

        /// Create payment invoice
        pub fn createInvoice(self: *@This(), amount: u64, description: []const u8) !tools_types.InvoiceResult {
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
        pub fn verifyPayment(self: *@This(), comment: []const u8) !tools_types.VerifyResult {
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
        pub fn waitPayment(self: *@This(), comment: []const u8, timeout_ms: u32) !tools_types.VerifyResult {
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

            const result = paywatch.watcher.waitPaymentWithClient(
                self.client,
                &temp_invoice,
                5000, // 5s poll interval
                timeout_ms,
            ) catch |err| {
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
        pub fn getJettonBalance(self: *@This(), wallet_address: []const u8, jetton_master: []const u8) !tools_types.JettonBalanceResult {
            var result = self.client.runGetMethod(wallet_address, "get_wallet_data", &.{}) catch |err| {
                return tools_types.JettonBalanceResult{
                    .address = wallet_address,
                    .jetton_master = jetton_master,
                    .balance = "0",
                    .decimals = 9,
                    .symbol = null,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.client.freeRunGetMethodResponse(&result);

            if (result.exit_code != 0) {
                return tools_types.JettonBalanceResult{
                    .address = wallet_address,
                    .jetton_master = jetton_master,
                    .balance = "0",
                    .decimals = 9,
                    .symbol = null,
                    .success = false,
                    .error_message = "ContractError",
                };
            }

            var data = jetton.parseJettonWalletData(self.allocator, result.stack) catch |err| {
                return tools_types.JettonBalanceResult{
                    .address = wallet_address,
                    .jetton_master = jetton_master,
                    .balance = "0",
                    .decimals = 9,
                    .symbol = null,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer data.deinit(self.allocator);

            const balance = try std.fmt.allocPrint(self.allocator, "{d}", .{data.balance});

            return tools_types.JettonBalanceResult{
                .address = wallet_address,
                .jetton_master = jetton_master,
                .balance = balance,
                .decimals = 9,
                .symbol = null,
                .success = true,
                .error_message = null,
            };
        }

        /// Get Jetton master metadata
        pub fn getJettonInfo(self: *@This(), jetton_master_address: []const u8) !tools_types.JettonInfoResult {
            var master = JettonMasterClient.init(jetton_master_address, self.client);
            var data = master.getJettonData() catch |err| {
                return tools_types.JettonInfoResult{
                    .address = jetton_master_address,
                    .total_supply = "0",
                    .mintable = false,
                    .admin = null,
                    .content = null,
                    .content_uri = null,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            errdefer data.deinit(self.allocator);

            const total_supply = try std.fmt.allocPrint(self.allocator, "{d}", .{data.total_supply});
            errdefer self.allocator.free(total_supply);

            const admin = if (data.admin) |value| try address_mod.formatRaw(self.allocator, &value) else null;
            errdefer if (admin) |value| self.allocator.free(value);

            const content = data.content;
            data.content = null;
            const content_uri = data.content_uri;
            data.content_uri = null;

            return tools_types.JettonInfoResult{
                .address = jetton_master_address,
                .total_supply = total_supply,
                .mintable = data.mintable,
                .admin = admin,
                .content = content,
                .content_uri = content_uri,
                .success = true,
                .error_message = null,
            };
        }

        /// Resolve a Jetton wallet address from master + owner address.
        pub fn getJettonWalletAddress(self: *@This(), jetton_master_address: []const u8, owner_address: []const u8) !tools_types.JettonWalletAddressResult {
            var master = JettonMasterClient.init(jetton_master_address, self.client);
            const wallet_address = master.getWalletAddress(owner_address) catch |err| {
                return tools_types.JettonWalletAddressResult{
                    .owner_address = owner_address,
                    .jetton_master = jetton_master_address,
                    .wallet_address = null,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };

            return tools_types.JettonWalletAddressResult{
                .owner_address = owner_address,
                .jetton_master = jetton_master_address,
                .wallet_address = wallet_address,
                .success = true,
                .error_message = null,
            };
        }

        /// Get NFT info
        pub fn getNFTInfo(self: *@This(), nft_address: []const u8) !tools_types.NFTInfoResult {
            var result = self.client.runGetMethod(nft_address, "get_nft_data", &.{}) catch |err| {
                return tools_types.NFTInfoResult{
                    .address = nft_address,
                    .owner = null,
                    .collection = null,
                    .index = "0",
                    .content = null,
                    .content_uri = null,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.client.freeRunGetMethodResponse(&result);

            if (result.exit_code != 0) {
                return tools_types.NFTInfoResult{
                    .address = nft_address,
                    .owner = null,
                    .collection = null,
                    .index = "0",
                    .content = null,
                    .content_uri = null,
                    .success = false,
                    .error_message = "ContractError",
                };
            }

            var data = nft.parseNFTData(self.allocator, result.stack) catch |err| {
                return tools_types.NFTInfoResult{
                    .address = nft_address,
                    .owner = null,
                    .collection = null,
                    .index = "0",
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

            const index = try std.fmt.allocPrint(self.allocator, "{d}", .{data.index});
            errdefer self.allocator.free(index);

            const content = data.content;
            data.content = null;
            const content_uri = data.content_uri;
            data.content_uri = null;

            return tools_types.NFTInfoResult{
                .address = nft_address,
                .owner = owner,
                .collection = collection,
                .index = index,
                .content = content,
                .content_uri = content_uri,
                .success = true,
                .error_message = null,
            };
        }

        /// Get NFT collection metadata
        pub fn getNFTCollectionInfo(self: *@This(), collection_address: []const u8) !tools_types.NFTCollectionInfoResult {
            var collection = NFTCollectionClient.init(collection_address, self.client);
            var data = collection.getCollectionData() catch |err| {
                return tools_types.NFTCollectionInfoResult{
                    .address = collection_address,
                    .owner = null,
                    .next_item_index = "0",
                    .content = null,
                    .content_uri = null,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            errdefer data.deinit(self.allocator);

            const owner = if (data.owner) |value| try address_mod.formatRaw(self.allocator, &value) else null;
            errdefer if (owner) |value| self.allocator.free(value);

            const next_item_index = try std.fmt.allocPrint(self.allocator, "{d}", .{data.next_item_index});
            errdefer self.allocator.free(next_item_index);

            const content = data.content;
            data.content = null;
            const content_uri = data.content_uri;
            data.content_uri = null;

            return tools_types.NFTCollectionInfoResult{
                .address = collection_address,
                .owner = owner,
                .next_item_index = next_item_index,
                .content = content,
                .content_uri = content_uri,
                .success = true,
                .error_message = null,
            };
        }

        /// Send TON transfer (if wallet configured)
        pub fn sendTransfer(self: *@This(), destination: []const u8, amount: u64, comment: ?[]const u8) !tools_types.SendResult {
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
        pub fn sendContractMessage(self: *@This(), destination: []const u8, amount: u64, body_boc: []const u8) !tools_types.SendResult {
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
        pub fn sendContractMessageOps(self: *@This(), destination: []const u8, amount: u64, ops: []const body_builder.BodyOp) !tools_types.SendResult {
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
            self: *@This(),
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

        /// Build and send a contract body from a full ABI document and function name
        pub fn sendContractMessageAbi(
            self: *@This(),
            destination: []const u8,
            amount: u64,
            abi_json: []const u8,
            function_name: []const u8,
            values: []const abi_adapter.AbiValue,
        ) !tools_types.SendResult {
            var abi = abi_adapter.loadAbiInfoSourceAlloc(self.allocator, abi_json) catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = destination,
                    .amount = amount,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer abi.deinit(self.allocator);

            const body_boc = abi_adapter.buildFunctionBodyFromAbiAlloc(
                self.allocator,
                &abi.abi,
                function_name,
                values,
            ) catch |err| {
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

        /// Build and send a contract body by discovering the destination ABI URI on-chain
        pub fn sendContractMessageAuto(
            self: *@This(),
            destination: []const u8,
            amount: u64,
            function_name: []const u8,
            values: []const abi_adapter.AbiValue,
        ) !tools_types.SendResult {
            var abi = abi_adapter.queryAbiDocumentAlloc(self.client, destination) catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = destination,
                    .amount = amount,
                    .success = false,
                    .error_message = @errorName(err),
                };
            } orelse return tools_types.SendResult{
                .hash = "",
                .lt = 0,
                .destination = destination,
                .amount = amount,
                .success = false,
                .error_message = "AbiNotFound",
            };
            defer abi.deinit(self.allocator);

            const body_boc = abi_adapter.buildFunctionBodyFromAbiAlloc(
                self.allocator,
                &abi.abi,
                function_name,
                values,
            ) catch |err| {
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

        /// Deploy a contract by sending StateInit and an optional body.
        pub fn sendContractDeploy(
            self: *@This(),
            destination: []const u8,
            amount: u64,
            state_init_boc: []const u8,
            body_boc: ?[]const u8,
        ) !tools_types.SendResult {
            const msgs = &[_]wallet.signing.WalletMessage{
                .{
                    .destination = destination,
                    .amount = amount,
                    .state_init = state_init_boc,
                    .body = body_boc,
                    .bounce = false,
                },
            };

            return self.sendWalletMessages(destination, amount, msgs);
        }

        /// Derive destination from StateInit and send a deploy message there.
        pub fn sendContractDeployAuto(
            self: *@This(),
            workchain: i8,
            amount: u64,
            state_init_boc: []const u8,
            body_boc: ?[]const u8,
        ) !tools_types.SendResult {
            const addr = try self.computeStateInitAddress(workchain, state_init_boc);
            if (!addr.success) {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = "",
                    .amount = amount,
                    .success = false,
                    .error_message = addr.error_message,
                };
            }

            return self.sendContractDeploy(addr.raw_address, amount, state_init_boc, body_boc);
        }

        fn sendWalletMessages(self: *@This(), destination: []const u8, amount: u64, msgs: []const wallet.signing.WalletMessage) !tools_types.SendResult {
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
}

pub const AgentTools = AgentToolsImpl(*http_client.TonHttpClient);
pub const ProviderAgentTools = AgentToolsImpl(*provider_mod.MultiProvider);

// Re-export types
pub const BalanceResult = tools_types.BalanceResult;
pub const AddressResult = tools_types.AddressResult;
pub const SendResult = tools_types.SendResult;
pub const RunMethodResult = tools_types.RunMethodResult;
pub const InvoiceResult = tools_types.InvoiceResult;
pub const VerifyResult = tools_types.VerifyResult;
pub const TxResult = tools_types.TxResult;
pub const JettonBalanceResult = tools_types.JettonBalanceResult;
pub const JettonInfoResult = tools_types.JettonInfoResult;
pub const JettonWalletAddressResult = tools_types.JettonWalletAddressResult;
pub const NFTInfoResult = tools_types.NFTInfoResult;
pub const NFTCollectionInfoResult = tools_types.NFTCollectionInfoResult;
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
    _ = AgentTools.runGetMethodAbi;
    _ = AgentTools.runGetMethodAuto;
    _ = AgentTools.computeStateInitAddress;
    _ = AgentTools.sendContractMessage;
    _ = AgentTools.sendContractMessageOps;
    _ = AgentTools.sendContractMessageFunction;
    _ = AgentTools.sendContractMessageAbi;
    _ = AgentTools.sendContractMessageAuto;
    _ = AgentTools.sendContractDeploy;
    _ = AgentTools.sendContractDeployAuto;
    _ = ProviderAgentTools.runGetMethod;
    _ = ProviderAgentTools.runGetMethodAbi;
    _ = ProviderAgentTools.runGetMethodAuto;
    _ = ProviderAgentTools.verifyPayment;
    _ = ProviderAgentTools.waitPayment;
    _ = ProviderAgentTools.getJettonBalance;
    _ = ProviderAgentTools.getJettonInfo;
    _ = ProviderAgentTools.getJettonWalletAddress;
    _ = ProviderAgentTools.getNFTInfo;
    _ = ProviderAgentTools.getNFTCollectionInfo;
    _ = ProviderAgentTools.sendTransfer;
    _ = AddressResult;
    _ = RunMethodResult;
    _ = JettonInfoResult;
    _ = JettonWalletAddressResult;
    _ = NFTCollectionInfoResult;
}
