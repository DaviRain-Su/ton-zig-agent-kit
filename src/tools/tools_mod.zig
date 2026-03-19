//! Agent tools - High-level interface for AI agents
//! Unified API for balance queries, transfers, invoices, and verification

const std = @import("std");
const address_mod = @import("../core/address.zig");
const body_builder = @import("../core/body_builder.zig");
const external_message = @import("../core/external_message.zig");
const core_types = @import("../core/types.zig");
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

        fn deriveConfiguredWalletRawAddressAlloc(self: *@This()) ![]u8 {
            const private_key = self.config.wallet_private_key orelse return error.MissingWalletPrivateKey;
            var wallet_init = try signing.deriveWalletV4InitFromPrivateKeyAlloc(
                self.allocator,
                self.config.wallet_workchain,
                self.config.wallet_id,
                private_key,
            );
            defer wallet_init.deinit(self.allocator);
            return address_mod.formatRaw(self.allocator, &wallet_init.address);
        }

        fn buildWalletInitResultAlloc(self: *@This(), private_key: [32]u8) !tools_types.WalletInitResult {
            var wallet_init = try signing.deriveWalletV4InitFromPrivateKeyAlloc(
                self.allocator,
                self.config.wallet_workchain,
                self.config.wallet_id,
                private_key,
            );
            defer wallet_init.deinit(self.allocator);

            const raw_address = try address_mod.formatRaw(self.allocator, &wallet_init.address);
            errdefer self.allocator.free(raw_address);

            const user_friendly_address = try address_mod.addressToUserFriendlyAlloc(self.allocator, &wallet_init.address, true, false);
            errdefer self.allocator.free(user_friendly_address);

            const public_key_hex = try allocHexLower(self.allocator, &wallet_init.public_key);
            errdefer self.allocator.free(public_key_hex);

            const encoded_len = std.base64.standard.Encoder.calcSize(wallet_init.state_init_boc.len);
            const state_init_boc = try self.allocator.alloc(u8, encoded_len);
            errdefer self.allocator.free(state_init_boc);
            _ = std.base64.standard.Encoder.encode(state_init_boc, wallet_init.state_init_boc);

            return tools_types.WalletInitResult{
                .raw_address = raw_address,
                .user_friendly_address = user_friendly_address,
                .workchain = self.config.wallet_workchain,
                .wallet_id = self.config.wallet_id,
                .public_key_hex = public_key_hex,
                .state_init_boc = state_init_boc,
                .success = true,
                .error_message = null,
            };
        }

        fn allocHexLower(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
            const hex_chars = "0123456789abcdef";
            const out = try allocator.alloc(u8, bytes.len * 2);
            errdefer allocator.free(out);

            for (bytes, 0..) |byte, idx| {
                out[idx * 2] = hex_chars[byte >> 4];
                out[idx * 2 + 1] = hex_chars[byte & 0x0f];
            }

            return out;
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

        /// Derive the default wallet v4 address and StateInit from the configured private key.
        pub fn deriveWalletInit(self: *@This()) !tools_types.WalletInitResult {
            const private_key = self.config.wallet_private_key orelse {
                return tools_types.WalletInitResult{
                    .raw_address = "",
                    .user_friendly_address = "",
                    .workchain = self.config.wallet_workchain,
                    .wallet_id = self.config.wallet_id,
                    .public_key_hex = "",
                    .state_init_boc = "",
                    .success = false,
                    .error_message = "Wallet not configured",
                };
            };

            return self.buildWalletInitResultAlloc(private_key) catch |err| {
                return tools_types.WalletInitResult{
                    .raw_address = "",
                    .user_friendly_address = "",
                    .workchain = self.config.wallet_workchain,
                    .wallet_id = self.config.wallet_id,
                    .public_key_hex = "",
                    .state_init_boc = "",
                    .success = false,
                    .error_message = @errorName(err),
                };
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

            const function = abi_adapter.resolveFunctionByValueCount(&abi.abi, function_name, values.len) catch |err| {
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

            const prepared_values = if (function.inputs.len == values.len)
                null
            else
                abi_adapter.expandValuesForFunctionAlloc(self.allocator, function.*, values) catch |err| {
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
            defer if (prepared_values) |owned| self.allocator.free(owned);

            var args = abi_adapter.buildStackArgsFromFunctionAlloc(
                self.allocator,
                function.*,
                if (prepared_values) |owned| owned else values,
            ) catch |err| {
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

            const function = abi_adapter.resolveFunctionByValueCount(&abi.abi, function_name, values.len) catch |err| {
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

            const prepared_values = if (function.inputs.len == values.len)
                null
            else
                abi_adapter.expandValuesForFunctionAlloc(self.allocator, function.*, values) catch |err| {
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
            defer if (prepared_values) |owned| self.allocator.free(owned);

            var args = abi_adapter.buildStackArgsFromFunctionAlloc(
                self.allocator,
                function.*,
                if (prepared_values) |owned| owned else values,
            ) catch |err| {
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

        /// Deploy the configured wallet itself using its derived v4 address and StateInit.
        pub fn deployWalletSelf(self: *@This()) !tools_types.SendResult {
            const private_key = self.config.wallet_private_key orelse {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = "",
                    .amount = 0,
                    .success = false,
                    .error_message = "Wallet not configured",
                };
            };

            const derived_raw = self.deriveConfiguredWalletRawAddressAlloc() catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = "",
                    .amount = 0,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            errdefer self.allocator.free(derived_raw);

            const result = signing.deployWallet(
                self.client,
                .v4,
                private_key,
                self.config.wallet_workchain,
                self.config.wallet_id,
            ) catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = derived_raw,
                    .amount = 0,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };

            return tools_types.SendResult{
                .hash = result.hash,
                .lt = result.lt,
                .destination = derived_raw,
                .amount = 0,
                .success = true,
                .error_message = null,
            };
        }

        /// Send the first transfer from an undeployed derived wallet, including wallet StateInit.
        pub fn sendInitialTransfer(self: *@This(), destination: []const u8, amount: u64, comment: ?[]const u8) !tools_types.SendResult {
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

            const result = signing.sendInitialTransfer(
                self.client,
                .v4,
                private_key,
                self.config.wallet_workchain,
                self.config.wallet_id,
                destination,
                amount,
                comment,
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

            return tools_types.SendResult{
                .hash = result.hash,
                .lt = result.lt,
                .destination = destination,
                .amount = amount,
                .success = true,
                .error_message = null,
            };
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

        /// Send an external incoming message directly to a contract, without wallet wrapping.
        pub fn sendExternalMessage(
            self: *@This(),
            destination: []const u8,
            body_boc: []const u8,
            state_init_boc: ?[]const u8,
        ) !tools_types.SendResult {
            const ext_boc = external_message.buildExternalIncomingMessageBocAlloc(
                self.allocator,
                destination,
                body_boc,
                state_init_boc,
            ) catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = destination,
                    .amount = 0,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.allocator.free(ext_boc);

            const result = self.client.sendBoc(ext_boc) catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = destination,
                    .amount = 0,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };

            return tools_types.SendResult{
                .hash = result.hash,
                .lt = result.lt,
                .destination = destination,
                .amount = 0,
                .success = true,
                .error_message = null,
            };
        }

        /// Build and send an external incoming message body from a function schema.
        pub fn sendExternalMessageFunction(
            self: *@This(),
            destination: []const u8,
            function: abi_adapter.FunctionDef,
            values: []const abi_adapter.AbiValue,
            state_init_boc: ?[]const u8,
        ) !tools_types.SendResult {
            const body_boc = abi_adapter.buildFunctionBodyBocAlloc(self.allocator, function, values) catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = destination,
                    .amount = 0,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.allocator.free(body_boc);

            return self.sendExternalMessage(destination, body_boc, state_init_boc);
        }

        /// Build and send an external incoming message body from an ABI document.
        pub fn sendExternalMessageAbi(
            self: *@This(),
            destination: []const u8,
            abi_json: []const u8,
            function_name: []const u8,
            values: []const abi_adapter.AbiValue,
            state_init_boc: ?[]const u8,
        ) !tools_types.SendResult {
            var abi = abi_adapter.loadAbiInfoSourceAlloc(self.allocator, abi_json) catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = destination,
                    .amount = 0,
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
                    .amount = 0,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.allocator.free(body_boc);

            return self.sendExternalMessage(destination, body_boc, state_init_boc);
        }

        /// Discover ABI on-chain, build a body, and send it as an external incoming message.
        pub fn sendExternalMessageAuto(
            self: *@This(),
            destination: []const u8,
            function_name: []const u8,
            values: []const abi_adapter.AbiValue,
            state_init_boc: ?[]const u8,
        ) !tools_types.SendResult {
            var abi = abi_adapter.queryAbiDocumentAlloc(self.client, destination) catch |err| {
                return tools_types.SendResult{
                    .hash = "",
                    .lt = 0,
                    .destination = destination,
                    .amount = 0,
                    .success = false,
                    .error_message = @errorName(err),
                };
            } orelse return tools_types.SendResult{
                .hash = "",
                .lt = 0,
                .destination = destination,
                .amount = 0,
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
                    .amount = 0,
                    .success = false,
                    .error_message = @errorName(err),
                };
            };
            defer self.allocator.free(body_boc);

            return self.sendExternalMessage(destination, body_boc, state_init_boc);
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

            const result = signing.sendMessagesAuto(
                self.client,
                .v4,
                private_key,
                self.config.wallet_address,
                self.config.wallet_workchain,
                self.config.wallet_id,
                msgs,
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
pub const WalletInitResult = tools_types.WalletInitResult;
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

test "agent tools deriveWalletInit matches signing helper" {
    const allocator = std.testing.allocator;

    const FakeClient = struct {};
    const FakeTools = AgentToolsImpl(*FakeClient);

    var client = FakeClient{};
    const keypair = try signing.generateKeypair("tools-wallet-init");
    const config = tools_types.AgentToolsConfig{
        .rpc_url = "https://example.invalid",
        .wallet_private_key = keypair[0],
        .wallet_workchain = -1,
        .wallet_id = 0xA1B2C3D4,
    };

    var tools = FakeTools.init(allocator, &client, config);
    const result = try tools.deriveWalletInit();
    defer allocator.free(result.raw_address);
    defer allocator.free(result.user_friendly_address);
    defer allocator.free(result.public_key_hex);
    defer allocator.free(result.state_init_boc);

    try std.testing.expect(result.success);

    var expected = try signing.deriveWalletV4InitFromPrivateKeyAlloc(allocator, -1, 0xA1B2C3D4, keypair[0]);
    defer expected.deinit(allocator);
    const expected_raw = try address_mod.formatRaw(allocator, &expected.address);
    defer allocator.free(expected_raw);

    try std.testing.expectEqualStrings(expected_raw, result.raw_address);
    try std.testing.expectEqual(@as(i8, -1), result.workchain);
    try std.testing.expectEqual(@as(u32, 0xA1B2C3D4), result.wallet_id);
}

test "agent tools deployWalletSelf submits derived wallet deployment" {
    const allocator = std.testing.allocator;

    const FakeClient = struct {
        allocator: std.mem.Allocator,
        last_boc: ?[]u8 = null,

        pub fn sendBoc(self: *@This(), payload: []const u8) !core_types.SendBocResponse {
            self.last_boc = try self.allocator.dupe(u8, payload);
            return .{
                .hash = try self.allocator.dupe(u8, "fake"),
                .lt = 123,
            };
        }
    };
    const FakeTools = AgentToolsImpl(*FakeClient);

    var client = FakeClient{ .allocator = allocator };
    defer if (client.last_boc) |value| allocator.free(value);

    const keypair = try signing.generateKeypair("tools-wallet-deploy");
    const config = tools_types.AgentToolsConfig{
        .rpc_url = "https://example.invalid",
        .wallet_private_key = keypair[0],
    };

    var tools = FakeTools.init(allocator, &client, config);
    const result = try tools.deployWalletSelf();
    defer allocator.free(result.hash);
    defer allocator.free(result.destination);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(i64, 123), result.lt);
    try std.testing.expect(client.last_boc != null);
}

test "agent tools sendInitialTransfer submits first transfer without configured wallet address" {
    const allocator = std.testing.allocator;

    const FakeClient = struct {
        allocator: std.mem.Allocator,
        last_boc: ?[]u8 = null,

        pub fn sendBoc(self: *@This(), payload: []const u8) !core_types.SendBocResponse {
            self.last_boc = try self.allocator.dupe(u8, payload);
            return .{
                .hash = try self.allocator.dupe(u8, "fake"),
                .lt = 456,
            };
        }
    };
    const FakeTools = AgentToolsImpl(*FakeClient);

    var client = FakeClient{ .allocator = allocator };
    defer if (client.last_boc) |value| allocator.free(value);

    const keypair = try signing.generateKeypair("tools-wallet-first-send");
    const config = tools_types.AgentToolsConfig{
        .rpc_url = "https://example.invalid",
        .wallet_private_key = keypair[0],
    };

    var tools = FakeTools.init(allocator, &client, config);
    const result = try tools.sendInitialTransfer(
        "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
        999,
        null,
    );
    defer allocator.free(result.hash);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(i64, 456), result.lt);
    try std.testing.expectEqualStrings(
        "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
        result.destination,
    );
    try std.testing.expect(client.last_boc != null);
}

test "agent tools sendTransfer auto-derives wallet and falls back to initial deployment" {
    const allocator = std.testing.allocator;

    const FakeClient = struct {
        allocator: std.mem.Allocator,
        last_boc: ?[]u8 = null,

        pub fn runGetMethod(self: *@This(), wallet_address: []const u8, method: []const u8, stack: []const []const u8) !core_types.RunGetMethodResponse {
            _ = self;
            _ = wallet_address;
            _ = method;
            _ = stack;
            return error.InvalidResponse;
        }

        pub fn freeRunGetMethodResponse(self: *@This(), response: *core_types.RunGetMethodResponse) void {
            _ = self;
            _ = response;
        }

        pub fn sendBoc(self: *@This(), payload: []const u8) !core_types.SendBocResponse {
            self.last_boc = try self.allocator.dupe(u8, payload);
            return .{
                .hash = try self.allocator.dupe(u8, "fake"),
                .lt = 789,
            };
        }
    };
    const FakeTools = AgentToolsImpl(*FakeClient);

    var client = FakeClient{ .allocator = allocator };
    defer if (client.last_boc) |value| allocator.free(value);

    const keypair = try signing.generateKeypair("tools-wallet-send-auto");
    const config = tools_types.AgentToolsConfig{
        .rpc_url = "https://example.invalid",
        .wallet_private_key = keypair[0],
    };

    var tools = FakeTools.init(allocator, &client, config);
    const result = try tools.sendTransfer(
        "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
        321,
        null,
    );
    defer allocator.free(result.hash);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(i64, 789), result.lt);
    try std.testing.expect(client.last_boc != null);
}

test "agent tools sendExternalMessage wraps body without wallet" {
    const allocator = std.testing.allocator;

    const FakeClient = struct {
        allocator: std.mem.Allocator,
        last_boc: ?[]u8 = null,

        pub fn sendBoc(self: *@This(), payload: []const u8) !core_types.SendBocResponse {
            self.last_boc = try self.allocator.dupe(u8, payload);
            return .{
                .hash = try self.allocator.dupe(u8, "fake"),
                .lt = 987,
            };
        }
    };
    const FakeTools = AgentToolsImpl(*FakeClient);

    var client = FakeClient{ .allocator = allocator };
    defer if (client.last_boc) |value| allocator.free(value);

    const body_boc = try body_builder.buildBodyBocAlloc(allocator, &.{
        .{ .uint = .{ .bits = 16, .value = 0xCAFE } },
    });
    defer allocator.free(body_boc);

    var tools = FakeTools.init(allocator, &client, .{ .rpc_url = "https://example.invalid" });
    const result = try tools.sendExternalMessage(
        "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
        body_boc,
        null,
    );
    defer allocator.free(result.hash);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(i64, 987), result.lt);
    try std.testing.expect(client.last_boc != null);
}

test "agent tools generic runGetMethod result type is exported" {
    _ = AgentTools.runGetMethod;
    _ = AgentTools.runGetMethodAbi;
    _ = AgentTools.runGetMethodAuto;
    _ = AgentTools.computeStateInitAddress;
    _ = AgentTools.deriveWalletInit;
    _ = AgentTools.sendContractMessage;
    _ = AgentTools.sendContractMessageOps;
    _ = AgentTools.sendContractMessageFunction;
    _ = AgentTools.sendContractMessageAbi;
    _ = AgentTools.sendContractMessageAuto;
    _ = AgentTools.sendExternalMessage;
    _ = AgentTools.sendExternalMessageFunction;
    _ = AgentTools.sendExternalMessageAbi;
    _ = AgentTools.sendExternalMessageAuto;
    _ = AgentTools.sendContractDeploy;
    _ = AgentTools.sendContractDeployAuto;
    _ = AgentTools.deployWalletSelf;
    _ = AgentTools.sendInitialTransfer;
    _ = ProviderAgentTools.runGetMethod;
    _ = ProviderAgentTools.runGetMethodAbi;
    _ = ProviderAgentTools.runGetMethodAuto;
    _ = ProviderAgentTools.deriveWalletInit;
    _ = ProviderAgentTools.verifyPayment;
    _ = ProviderAgentTools.waitPayment;
    _ = ProviderAgentTools.getJettonBalance;
    _ = ProviderAgentTools.getJettonInfo;
    _ = ProviderAgentTools.getJettonWalletAddress;
    _ = ProviderAgentTools.getNFTInfo;
    _ = ProviderAgentTools.getNFTCollectionInfo;
    _ = ProviderAgentTools.sendTransfer;
    _ = ProviderAgentTools.sendExternalMessage;
    _ = ProviderAgentTools.sendExternalMessageAbi;
    _ = ProviderAgentTools.sendExternalMessageAuto;
    _ = ProviderAgentTools.deployWalletSelf;
    _ = ProviderAgentTools.sendInitialTransfer;
    _ = AddressResult;
    _ = RunMethodResult;
    _ = WalletInitResult;
    _ = JettonInfoResult;
    _ = JettonWalletAddressResult;
    _ = NFTCollectionInfoResult;
}
