const std = @import("std");
const ton_zig_agent_kit = @import("ton_zig_agent_kit");

const TonHttpClient = ton_zig_agent_kit.core.TonHttpClient;
const TonError = ton_zig_agent_kit.core.TonError;
const MultiProvider = ton_zig_agent_kit.core.MultiProvider;
const Cell = ton_zig_agent_kit.core.Cell;
const Builder = ton_zig_agent_kit.core.Builder;
const Slice = ton_zig_agent_kit.core.Slice;
const StackEntry = ton_zig_agent_kit.core.types.StackEntry;
const Transaction = ton_zig_agent_kit.core.types.Transaction;
const Message = ton_zig_agent_kit.core.types.Message;
const BodyOp = ton_zig_agent_kit.core.body_builder.BodyOp;
const contract_mod = ton_zig_agent_kit.contract;
const AbiValue = contract_mod.abi_adapter.AbiValue;
const boc = ton_zig_agent_kit.core.boc;
const signing = ton_zig_agent_kit.wallet.signing;
const inspect_abi_list_limit: usize = 12;
const inspect_abi_template_limit: usize = 3;
const rpc_url_env = "TON_RPC_URL";
const rpc_urls_env = "TON_RPC_URLS";
const api_key_env = "TON_API_KEY";
const api_keys_env = "TON_API_KEYS";
const network_env = "TON_NETWORK";
const wallet_private_key_hex_env = "TON_PRIVATE_KEY_HEX";
const wallet_seed_env = "TON_SEED";
const wallet_seed_file_env = "TON_SEED_FILE";

const LoadedCliAbi = struct {
    abi: contract_mod.abi_adapter.OwnedAbiInfo,
    auto_address: ?[]const u8 = null,

    fn deinit(self: *LoadedCliAbi, allocator: std.mem.Allocator) void {
        self.abi.deinit(allocator);
    }
};

const CliDecodedMessageBody = struct {
    kind: enum {
        function,
        event,
    },
    contract_address: []u8,
    selector: []u8,
    opcode: ?u32,
    decoded_json: []u8,

    fn deinit(self: *CliDecodedMessageBody, allocator: std.mem.Allocator) void {
        allocator.free(self.contract_address);
        allocator.free(self.selector);
        allocator.free(self.decoded_json);
    }
};

fn initDefaultProvider(allocator: std.mem.Allocator) !ton_zig_agent_kit.core.MultiProvider {
    return ton_zig_agent_kit.core.provider.createProviderFromProcessEnv(allocator);
}

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
        var provider = try initDefaultProvider(allocator);
        const result = try provider.getBalance(addr);
        std.debug.print("Address: {s}\n", .{addr});
        std.debug.print("Balance: {d} nanotons ({d}.{d:09} TON)\n", .{
            result.balance,
            result.balance / 1_000_000_000,
            result.balance % 1_000_000_000,
        });
        return;
    }

    if (std.mem.eql(u8, command, "tx")) {
        if (args.len < 3) {
            std.debug.print("Usage: ton-zig-agent-kit tx <list|show>\n", .{});
            return;
        }

        const tx_cmd = args[2];
        if (std.mem.eql(u8, tx_cmd, "list")) {
            if (args.len < 4) {
                std.debug.print("Usage: ton-zig-agent-kit tx list <address> [limit]\n", .{});
                return;
            }

            const addr = args[3];
            const limit: u32 = if (args.len >= 5)
                try std.fmt.parseInt(u32, args[4], 10)
            else
                10;

            var provider = try initDefaultProvider(allocator);
            const txs = try provider.getTransactions(addr, limit);
            defer provider.freeTransactions(txs);

            std.debug.print("Transactions for {s} ({d}):\n", .{ addr, txs.len });
            for (txs, 0..) |*tx, idx| {
                std.debug.print("[{d}] hash={s} lt={d} ts={d}\n", .{ idx, tx.hash, tx.lt, tx.timestamp });
                if (tx.in_msg) |msg| {
                    std.debug.print("  in value={d}\n", .{msg.value});
                    printMessageAddressLine(allocator, "from", msg.source);
                    printMessageAddressLine(allocator, "to", msg.destination);
                }
                std.debug.print("  out messages={d}\n", .{tx.out_msgs.len});
            }
            return;
        }

        if (std.mem.eql(u8, tx_cmd, "show")) {
            if (args.len < 5) {
                std.debug.print("Usage: ton-zig-agent-kit tx show <lt> <hash>\n", .{});
                return;
            }

            const lt = try std.fmt.parseInt(i64, args[3], 10);
            const hash = args[4];

            var provider = try initDefaultProvider(allocator);
            var tx = (try provider.lookupTx(lt, hash)) orelse {
                std.debug.print("Transaction not found: lt={d} hash={s}\n", .{ lt, hash });
                return;
            };
            defer provider.freeTransaction(&tx);

            printTransactionDetails(allocator, &provider, &tx);
            return;
        }

        std.debug.print("Unknown tx command: {s}\n", .{tx_cmd});
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
        var provider = try initDefaultProvider(allocator);

        var result = try provider.runGetMethodJson(addr, method, stack_json);
        defer provider.freeRunGetMethodResponse(&result);

        std.debug.print("Address: {s}\n", .{addr});
        std.debug.print("Method: {s}\n", .{method});
        std.debug.print("Stack JSON: {s}\n", .{stack_json});
        try printRunGetMethodResult(allocator, result);
        return;
    }

    if (std.mem.eql(u8, command, "inspectContract") or std.mem.eql(u8, command, "inspect-contract")) {
        if (args.len < 3) {
            std.debug.print("Usage: ton-zig-agent-kit inspectContract <address>\n", .{});
            return;
        }

        const addr = args[2];
        var provider = try initDefaultProvider(allocator);

        const supported = try contract_mod.abi_adapter.querySupportedInterfaces(&provider, addr);
        var abi = try contract_mod.abi_adapter.queryAbiIpfs(&provider, addr);
        defer if (abi) |*info| info.deinit(allocator);
        var abi_doc = contract_mod.abi_adapter.queryAbiDocumentAlloc(&provider, addr) catch null;
        defer if (abi_doc) |*info| info.deinit(allocator);

        std.debug.print("Address: {s}\n", .{addr});
        if (supported) |value| {
            std.debug.print("Supported interfaces:\n", .{});
            std.debug.print("  wallet: {s}\n", .{if (value.has_wallet) "yes" else "no"});
            std.debug.print("  jetton: {s}\n", .{if (value.has_jetton) "yes" else "no"});
            std.debug.print("    jetton_master: {s}\n", .{if (value.has_jetton_master) "yes" else "no"});
            std.debug.print("    jetton_wallet: {s}\n", .{if (value.has_jetton_wallet) "yes" else "no"});
            std.debug.print("  nft: {s}\n", .{if (value.has_nft) "yes" else "no"});
            std.debug.print("    nft_item: {s}\n", .{if (value.has_nft_item) "yes" else "no"});
            std.debug.print("    nft_collection: {s}\n", .{if (value.has_nft_collection) "yes" else "no"});
            std.debug.print("  abi: {s}\n", .{if (value.has_abi) "yes" else "no"});
        } else {
            std.debug.print("Supported interfaces: none detected\n", .{});
        }

        if (abi) |info| {
            std.debug.print("ABI:\n", .{});
            std.debug.print("  kind: {s}\n", .{info.version});
            std.debug.print("  uri: {s}\n", .{info.uri orelse "(missing)"});
            if (abi_doc) |*loaded| {
                std.debug.print("  document_version: {s}\n", .{loaded.abi.version});
                std.debug.print("  functions: {d}\n", .{loaded.abi.functions.len});
                std.debug.print("  events: {d}\n", .{loaded.abi.events.len});
                printInspectAbiDocument(&loaded.abi);
            } else {
                std.debug.print("  document: not loaded\n", .{});
            }
        } else {
            std.debug.print("ABI: not detected\n", .{});
        }

        if (supported) |value| {
            if (value.has_wallet) {
                printInspectWalletDetails(&provider, addr);
            }
            if (value.has_jetton_master) {
                printInspectJettonMasterDetails(allocator, &provider, addr);
            }
            if (value.has_jetton_wallet) {
                printInspectJettonWalletDetails(&provider, addr);
            }
            if (value.has_nft_item) {
                printInspectNFTItemDetails(allocator, &provider, addr);
            }
            if (value.has_nft_collection) {
                printInspectNFTCollectionDetails(allocator, &provider, addr);
            }
        }

        var inspect_tools = ton_zig_agent_kit.tools.tools_mod.ProviderAgentTools.init(
            allocator,
            &provider,
            .{ .rpc_url = "" },
        );
        var inspect_summary = inspect_tools.inspectContract(addr) catch null;
        defer if (inspect_summary) |*value| value.deinit(allocator);
        if (inspect_summary) |*value| {
            printInspectObservedMessages(value.observed_messages);
        }

        printInspectCommandHints(allocator, addr, if (abi_doc) |*loaded| &loaded.abi else null);
        return;
    }

    if (std.mem.eql(u8, command, "abi")) {
        if (args.len < 3) {
            std.debug.print("Usage: ton-zig-agent-kit abi <describe|decode-function|decode-event>\n", .{});
            return;
        }

        const abi_cmd = args[2];
        if (std.mem.eql(u8, abi_cmd, "describe")) {
            if (args.len < 4) {
                std.debug.print("Usage: ton-zig-agent-kit abi describe <abi_json|@file|file://|http(s)://|ipfs://|auto:<address>> [function_name_or_signature]\n", .{});
                return;
            }

            var loaded = try loadCliAbiSourceAlloc(allocator, args[3]);
            defer loaded.deinit(allocator);

            std.debug.print("ABI description:\n", .{});
            std.debug.print("  Input source: {s}\n", .{displayAbiSource(args[3])});
            if (loaded.auto_address) |value| {
                std.debug.print("  Auto address: {s}\n", .{value});
            }
            if (loaded.abi.abi.uri) |value| {
                std.debug.print("  Resolved URI: {s}\n", .{value});
            }
            std.debug.print("  Version: {s}\n", .{loaded.abi.abi.version});
            std.debug.print("  Functions: {d}\n", .{loaded.abi.abi.functions.len});
            std.debug.print("  Events: {d}\n", .{loaded.abi.abi.events.len});

            if (args.len >= 5) {
                const function_selector = args[4];
                const function = contract_mod.abi_adapter.findFunction(&loaded.abi.abi, function_selector) orelse {
                    std.debug.print("Function not found: {s}\n", .{function_selector});
                    return;
                };

                printAbiFunctionDescribe(allocator, &loaded.abi.abi, function.*, loaded.auto_address);
            } else {
                printInspectAbiDocument(&loaded.abi.abi);
                if (loaded.auto_address) |value| {
                    std.debug.print("Next: ton-zig-agent-kit abi describe auto:{s} <function_name_or_signature>\n", .{value});
                } else {
                    std.debug.print("Next: ton-zig-agent-kit abi describe <abi_source> <function_name_or_signature>\n", .{});
                }
            }
            return;
        }

        if (std.mem.eql(u8, abi_cmd, "decode-function")) {
            if (args.len < 5) {
                std.debug.print("Usage: ton-zig-agent-kit abi decode-function <abi_json|@file|file://|http(s)://|ipfs://|auto:<address>> <body_b64> [function_name_or_signature]\n", .{});
                return;
            }

            var loaded = try loadCliAbiSourceAlloc(allocator, args[3]);
            defer loaded.deinit(allocator);

            const body_text = try loadCliTextAlloc(allocator, args[4]);
            defer allocator.free(body_text);
            const body_boc = try decodeBase64FlexibleAlloc(allocator, body_text);
            defer allocator.free(body_boc);

            const function_selector = if (args.len >= 6) args[5] else null;
            const function = try contract_mod.abi_adapter.resolveFunctionByBodyBoc(&loaded.abi.abi, function_selector, body_boc);
            const decoded = try contract_mod.abi_adapter.decodeFunctionBodyJsonAlloc(allocator, function.*, body_boc);
            defer allocator.free(decoded);
            const function_ref = try buildAbiFunctionCommandRefAlloc(allocator, &loaded.abi.abi, function.*);
            defer allocator.free(function_ref);

            std.debug.print("Decoded function body:\n", .{});
            std.debug.print("  Input source: {s}\n", .{displayAbiSource(args[3])});
            if (loaded.auto_address) |value| {
                std.debug.print("  Auto address: {s}\n", .{value});
            }
            std.debug.print("  Function: {s}\n", .{function_ref});
            if (function.opcode) |opcode| {
                std.debug.print("  Opcode: 0x{X}\n", .{opcode});
            }
            std.debug.print("  Decoded payload:\n{s}\n", .{decoded});
            return;
        }

        if (std.mem.eql(u8, abi_cmd, "decode-event")) {
            if (args.len < 5) {
                std.debug.print("Usage: ton-zig-agent-kit abi decode-event <abi_json|@file|file://|http(s)://|ipfs://|auto:<address>> <body_b64> [event_name_or_signature]\n", .{});
                return;
            }

            var loaded = try loadCliAbiSourceAlloc(allocator, args[3]);
            defer loaded.deinit(allocator);

            const body_text = try loadCliTextAlloc(allocator, args[4]);
            defer allocator.free(body_text);
            const body_boc = try decodeBase64FlexibleAlloc(allocator, body_text);
            defer allocator.free(body_boc);

            const event_selector = if (args.len >= 6) args[5] else null;
            const event = try contract_mod.abi_adapter.resolveEventByBodyBoc(&loaded.abi.abi, event_selector, body_boc);
            const decoded = try contract_mod.abi_adapter.decodeEventBodyJsonAlloc(allocator, event.*, body_boc);
            defer allocator.free(decoded);

            std.debug.print("Decoded event:\n", .{});
            std.debug.print("  Input source: {s}\n", .{displayAbiSource(args[3])});
            if (loaded.auto_address) |value| {
                std.debug.print("  Auto address: {s}\n", .{value});
            }
            std.debug.print("  Event: {s}\n", .{event.name});
            if (event.opcode) |opcode| {
                std.debug.print("  Opcode: 0x{X}\n", .{opcode});
            }
            std.debug.print("  Decoded payload:\n{s}\n", .{decoded});
            return;
        }

        std.debug.print("Unknown abi command: {s}\n", .{abi_cmd});
        return;
    }

    if (std.mem.eql(u8, command, "jetton")) {
        if (args.len < 3) {
            std.debug.print("Usage: ton-zig-agent-kit jetton <info|wallet-address|wallet-data>\n", .{});
            return;
        }

        const jetton_cmd = args[2];
        var provider = try initDefaultProvider(allocator);

        if (std.mem.eql(u8, jetton_cmd, "info")) {
            if (args.len < 4) {
                std.debug.print("Usage: ton-zig-agent-kit jetton info <master_address>\n", .{});
                return;
            }

            var master = contract_mod.jetton.ProviderJettonMaster.init(args[3], &provider);
            var data = try master.getJettonData();
            defer data.deinit(allocator);

            const total_supply = try std.fmt.allocPrint(allocator, "{d}", .{data.total_supply});
            defer allocator.free(total_supply);
            const admin = if (data.admin) |value|
                try ton_zig_agent_kit.core.address.formatRaw(allocator, &value)
            else
                null;
            defer if (admin) |value| allocator.free(value);

            std.debug.print("Jetton master:\n", .{});
            std.debug.print("  Address: {s}\n", .{args[3]});
            std.debug.print("  Total supply: {s}\n", .{total_supply});
            std.debug.print("  Mintable: {s}\n", .{if (data.mintable) "yes" else "no"});
            std.debug.print("  Admin: {s}\n", .{admin orelse "(none)"});
            std.debug.print("  Content URI: {s}\n", .{data.content_uri orelse "(none)"});
            std.debug.print("  Content BoC: {s}\n", .{if (data.content != null) "present" else "missing"});
            return;
        }

        if (std.mem.eql(u8, jetton_cmd, "wallet-address")) {
            if (args.len < 5) {
                std.debug.print("Usage: ton-zig-agent-kit jetton wallet-address <master_address> <owner_address>\n", .{});
                return;
            }

            var master = contract_mod.jetton.ProviderJettonMaster.init(args[3], &provider);
            const wallet_address = try master.getWalletAddress(args[4]);

            std.debug.print("Jetton wallet address:\n", .{});
            std.debug.print("  Master: {s}\n", .{args[3]});
            std.debug.print("  Owner: {s}\n", .{args[4]});
            std.debug.print("  Wallet: {s}\n", .{wallet_address});
            return;
        }

        if (std.mem.eql(u8, jetton_cmd, "wallet-data")) {
            if (args.len < 4) {
                std.debug.print("Usage: ton-zig-agent-kit jetton wallet-data <wallet_address>\n", .{});
                return;
            }

            var wallet_contract = contract_mod.jetton.ProviderJettonWallet.init(args[3], &provider);
            var data = try wallet_contract.getWalletData();
            defer data.deinit(allocator);

            const balance = try std.fmt.allocPrint(allocator, "{d}", .{data.balance});
            defer allocator.free(balance);

            std.debug.print("Jetton wallet data:\n", .{});
            std.debug.print("  Address: {s}\n", .{args[3]});
            std.debug.print("  Balance: {s}\n", .{balance});
            std.debug.print("  Owner: {s}\n", .{data.owner});
            std.debug.print("  Master: {s}\n", .{data.master});
            return;
        }

        std.debug.print("Unknown jetton command: {s}\n", .{jetton_cmd});
        return;
    }

    if (std.mem.eql(u8, command, "nft")) {
        if (args.len < 3) {
            std.debug.print("Usage: ton-zig-agent-kit nft <info|collection-info>\n", .{});
            return;
        }

        const nft_cmd = args[2];
        var provider = try initDefaultProvider(allocator);

        if (std.mem.eql(u8, nft_cmd, "info")) {
            if (args.len < 4) {
                std.debug.print("Usage: ton-zig-agent-kit nft info <item_address>\n", .{});
                return;
            }

            var item = contract_mod.nft.ProviderNFTItem.init(args[3], &provider);
            var data = try item.getNFTData();
            defer data.deinit(allocator);

            const index = try std.fmt.allocPrint(allocator, "{d}", .{data.index});
            defer allocator.free(index);
            const owner = if (data.owner) |value|
                try ton_zig_agent_kit.core.address.formatRaw(allocator, &value)
            else
                null;
            defer if (owner) |value| allocator.free(value);
            const collection = if (data.collection) |value|
                try ton_zig_agent_kit.core.address.formatRaw(allocator, &value)
            else
                null;
            defer if (collection) |value| allocator.free(value);

            std.debug.print("NFT item:\n", .{});
            std.debug.print("  Address: {s}\n", .{args[3]});
            std.debug.print("  Index: {s}\n", .{index});
            std.debug.print("  Owner: {s}\n", .{owner orelse "(none)"});
            std.debug.print("  Collection: {s}\n", .{collection orelse "(none)"});
            std.debug.print("  Content URI: {s}\n", .{data.content_uri orelse "(none)"});
            std.debug.print("  Content BoC: {s}\n", .{if (data.content != null) "present" else "missing"});
            return;
        }

        if (std.mem.eql(u8, nft_cmd, "collection-info")) {
            if (args.len < 4) {
                std.debug.print("Usage: ton-zig-agent-kit nft collection-info <collection_address>\n", .{});
                return;
            }

            var collection = contract_mod.nft.ProviderNFTCollection.init(args[3], &provider);
            var data = try collection.getCollectionData();
            defer data.deinit(allocator);

            const next_item_index = try std.fmt.allocPrint(allocator, "{d}", .{data.next_item_index});
            defer allocator.free(next_item_index);
            const owner = if (data.owner) |value|
                try ton_zig_agent_kit.core.address.formatRaw(allocator, &value)
            else
                null;
            defer if (owner) |value| allocator.free(value);

            std.debug.print("NFT collection:\n", .{});
            std.debug.print("  Address: {s}\n", .{args[3]});
            std.debug.print("  Owner: {s}\n", .{owner orelse "(none)"});
            std.debug.print("  Next item index: {s}\n", .{next_item_index});
            std.debug.print("  Content URI: {s}\n", .{data.content_uri orelse "(none)"});
            std.debug.print("  Content BoC: {s}\n", .{if (data.content != null) "present" else "missing"});
            return;
        }

        std.debug.print("Unknown nft command: {s}\n", .{nft_cmd});
        return;
    }

    if (std.mem.eql(u8, command, "runGetMethodTyped") or std.mem.eql(u8, command, "get-method-typed")) {
        if (args.len < 4) {
            std.debug.print("Usage: ton-zig-agent-kit runGetMethodTyped <address> <method> [null|int:<n>|addr:<addr>|cell:<b64>|slice:<b64>|builder:<b64>|cellhex:<hex>|slicehex:<hex>|builderhex:<hex> ...]\n", .{});
            return;
        }

        const addr = args[2];
        const method = args[3];
        var parsed_args = try parseCliStackArgs(allocator, args[4..]);
        defer parsed_args.deinit(allocator);

        var provider = try initDefaultProvider(allocator);
        const stack_json = try contract_mod.buildStackArgsJsonAlloc(allocator, parsed_args.args);
        defer allocator.free(stack_json);

        var result = try provider.runGetMethodJson(addr, method, stack_json);
        defer provider.freeRunGetMethodResponse(&result);

        std.debug.print("Address: {s}\n", .{addr});
        std.debug.print("Method: {s}\n", .{method});
        std.debug.print("Typed args: {d}\n", .{parsed_args.args.len});
        try printRunGetMethodResult(allocator, result);
        return;
    }

    if (std.mem.eql(u8, command, "runGetMethodAbi") or std.mem.eql(u8, command, "get-method-abi")) {
        if (args.len < 5) {
            std.debug.print("Usage: ton-zig-agent-kit runGetMethodAbi <address> <abi_json|@file|file://|http(s)://|ipfs://> <function_name_or_signature> [values...]\n", .{});
            return;
        }

        const addr = args[2];
        const function_selector = args[4];
        var abi = try contract_mod.abi_adapter.loadAbiInfoSourceAlloc(allocator, args[3]);
        defer abi.deinit(allocator);

        const function = try resolveCliAbiFunction(&abi.abi, function_selector, args[5..]);

        var parsed_values = try parseCliAbiValuesForParams(allocator, function.inputs, args[5..]);
        defer parsed_values.deinit(allocator);

        var stack_args = try contract_mod.abi_adapter.buildStackArgsFromFunctionAlloc(
            allocator,
            function.*,
            parsed_values.values,
        );
        defer stack_args.deinit(allocator);

        var provider = try initDefaultProvider(allocator);
        const stack_json = try contract_mod.buildStackArgsJsonAlloc(allocator, stack_args.args);
        defer allocator.free(stack_json);

        var result = try provider.runGetMethodJson(addr, function.name, stack_json);
        defer provider.freeRunGetMethodResponse(&result);

        std.debug.print("Address: {s}\n", .{addr});
        std.debug.print("ABI version: {s}\n", .{abi.abi.version});
        std.debug.print("Function: {s}\n", .{function_selector});
        try printRunGetMethodResult(allocator, result);

        const decoded = try contract_mod.abi_adapter.decodeFunctionOutputsJsonAlloc(
            allocator,
            function.*,
            result.stack,
        );
        defer allocator.free(decoded);
        std.debug.print("Decoded outputs:\n{s}\n", .{decoded});
        return;
    }

    if (std.mem.eql(u8, command, "runGetMethodAuto") or std.mem.eql(u8, command, "get-method-auto")) {
        if (args.len < 4) {
            std.debug.print("Usage: ton-zig-agent-kit runGetMethodAuto <address> <function_name_or_signature> [values...]\n", .{});
            return;
        }

        const addr = args[2];
        const function_selector = args[3];

        var provider = try initDefaultProvider(allocator);

        var abi = (try contract_mod.abi_adapter.queryAbiDocumentAlloc(&provider, addr)) orelse {
            std.debug.print("ABI document not found for {s}\n", .{addr});
            return;
        };
        defer abi.deinit(allocator);

        const function = try resolveCliAbiFunction(&abi.abi, function_selector, args[4..]);

        var parsed_values = try parseCliAbiValuesForParams(allocator, function.inputs, args[4..]);
        defer parsed_values.deinit(allocator);

        var stack_args = try contract_mod.abi_adapter.buildStackArgsFromFunctionAlloc(
            allocator,
            function.*,
            parsed_values.values,
        );
        defer stack_args.deinit(allocator);

        const stack_json = try contract_mod.buildStackArgsJsonAlloc(allocator, stack_args.args);
        defer allocator.free(stack_json);

        var result = try provider.runGetMethodJson(addr, function.name, stack_json);
        defer provider.freeRunGetMethodResponse(&result);

        std.debug.print("Address: {s}\n", .{addr});
        std.debug.print("ABI source: {s}\n", .{abi.abi.uri orelse "(embedded)"});
        std.debug.print("ABI version: {s}\n", .{abi.abi.version});
        std.debug.print("Function: {s}\n", .{function_selector});
        try printRunGetMethodResult(allocator, result);

        const decoded = try contract_mod.abi_adapter.decodeFunctionOutputsJsonAlloc(
            allocator,
            function.*,
            result.stack,
        );
        defer allocator.free(decoded);
        std.debug.print("Decoded outputs:\n{s}\n", .{decoded});
        return;
    }

    if (std.mem.eql(u8, command, "sendBoc") or std.mem.eql(u8, command, "send-boc")) {
        if (args.len < 3) {
            std.debug.print("Usage: ton-zig-agent-kit sendBoc <boc_base64>\n", .{});
            return;
        }

        var provider = try initDefaultProvider(allocator);

        var result = try provider.sendBocBase64(args[2]);
        defer provider.freeSendBocResponse(&result);

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

        var provider = try initDefaultProvider(allocator);

        var result = try provider.sendBocHex(args[2]);
        defer provider.freeSendBocResponse(&result);

        std.debug.print("Submitted BoC:\n", .{});
        std.debug.print("  Hash: {s}\n", .{result.hash});
        std.debug.print("  LT: {d}\n", .{result.lt});
        return;
    }

    if (std.mem.eql(u8, command, "sendExternal") or std.mem.eql(u8, command, "send-external")) {
        if (args.len < 4) {
            std.debug.print("Usage: ton-zig-agent-kit sendExternal <destination> <body_b64> [state_init_b64|none]\n", .{});
            return;
        }

        const destination = args[2];
        const body_boc = try decodeBase64FlexibleAlloc(allocator, args[3]);
        defer allocator.free(body_boc);

        const state_init_boc = if (args.len >= 5 and !std.mem.eql(u8, args[4], "none"))
            try decodeBase64FlexibleAlloc(allocator, args[4])
        else
            null;
        defer if (state_init_boc) |value| allocator.free(value);

        const ext_boc = try ton_zig_agent_kit.core.external_message.buildExternalIncomingMessageBocAlloc(
            allocator,
            destination,
            body_boc,
            state_init_boc,
        );
        defer allocator.free(ext_boc);

        var provider = try initDefaultProvider(allocator);
        var result = try provider.sendBoc(ext_boc);
        defer provider.freeSendBocResponse(&result);

        std.debug.print("Submitted external incoming message:\n", .{});
        std.debug.print("  Destination: {s}\n", .{destination});
        std.debug.print("  Hash: {s}\n", .{result.hash});
        std.debug.print("  LT: {d}\n", .{result.lt});
        return;
    }

    if (std.mem.eql(u8, command, "sendExternalHex") or std.mem.eql(u8, command, "send-external-hex")) {
        if (args.len < 4) {
            std.debug.print("Usage: ton-zig-agent-kit sendExternalHex <destination> <body_hex> [state_init_hex|none]\n", .{});
            return;
        }

        const destination = args[2];
        const body_boc = try hexToBytes(allocator, args[3]);
        defer allocator.free(body_boc);

        const state_init_boc = if (args.len >= 5 and !std.mem.eql(u8, args[4], "none"))
            try hexToBytes(allocator, args[4])
        else
            null;
        defer if (state_init_boc) |value| allocator.free(value);

        const ext_boc = try ton_zig_agent_kit.core.external_message.buildExternalIncomingMessageBocAlloc(
            allocator,
            destination,
            body_boc,
            state_init_boc,
        );
        defer allocator.free(ext_boc);

        var provider = try initDefaultProvider(allocator);
        var result = try provider.sendBoc(ext_boc);
        defer provider.freeSendBocResponse(&result);

        std.debug.print("Submitted external incoming message:\n", .{});
        std.debug.print("  Destination: {s}\n", .{destination});
        std.debug.print("  Hash: {s}\n", .{result.hash});
        std.debug.print("  LT: {d}\n", .{result.lt});
        return;
    }

    if (std.mem.eql(u8, command, "sendExternalStandard") or std.mem.eql(u8, command, "send-external-standard")) {
        if (args.len < 6) {
            std.debug.print("Usage: ton-zig-agent-kit sendExternalStandard <destination> <state_init_b64|none> <kind> <json|@file|file://|http(s)://|ipfs://>\n", .{});
            return;
        }

        const destination = args[2];
        const state_init_boc = if (!std.mem.eql(u8, args[3], "none"))
            try decodeBase64FlexibleAlloc(allocator, args[3])
        else
            null;
        defer if (state_init_boc) |value| allocator.free(value);

        const body_boc = try contract_mod.standard_body.buildBodyFromSourceAlloc(allocator, args[4], args[5]);
        defer allocator.free(body_boc);

        const ext_boc = try ton_zig_agent_kit.core.external_message.buildExternalIncomingMessageBocAlloc(
            allocator,
            destination,
            body_boc,
            state_init_boc,
        );
        defer allocator.free(ext_boc);

        var provider = try initDefaultProvider(allocator);
        var result = try provider.sendBoc(ext_boc);
        defer provider.freeSendBocResponse(&result);

        std.debug.print("Submitted standard external message:\n", .{});
        std.debug.print("  Destination: {s}\n", .{destination});
        std.debug.print("  Kind: {s}\n", .{args[4]});
        std.debug.print("  Hash: {s}\n", .{result.hash});
        std.debug.print("  LT: {d}\n", .{result.lt});
        return;
    }

    if (std.mem.eql(u8, command, "sendExternalAbi") or std.mem.eql(u8, command, "send-external-abi")) {
        if (args.len < 6) {
            std.debug.print("Usage: ton-zig-agent-kit sendExternalAbi <destination> <state_init_b64|none> <abi_json|@file|file://|http(s)://|ipfs://> <function_name_or_signature> [values...]\n", .{});
            return;
        }

        const destination = args[2];
        const state_init_boc = if (!std.mem.eql(u8, args[3], "none"))
            try decodeBase64FlexibleAlloc(allocator, args[3])
        else
            null;
        defer if (state_init_boc) |value| allocator.free(value);

        const function_selector = args[5];

        var abi = try contract_mod.abi_adapter.loadAbiInfoSourceAlloc(allocator, args[4]);
        defer abi.deinit(allocator);

        const function = try resolveCliAbiFunction(&abi.abi, function_selector, args[6..]);

        var parsed_values = try parseCliAbiValuesForParams(allocator, function.inputs, args[6..]);
        defer parsed_values.deinit(allocator);

        const body_boc = try contract_mod.abi_adapter.buildFunctionBodyBocAlloc(
            allocator,
            function.*,
            parsed_values.values,
        );
        defer allocator.free(body_boc);

        const ext_boc = try ton_zig_agent_kit.core.external_message.buildExternalIncomingMessageBocAlloc(
            allocator,
            destination,
            body_boc,
            state_init_boc,
        );
        defer allocator.free(ext_boc);

        var provider = try initDefaultProvider(allocator);
        var result = try provider.sendBoc(ext_boc);
        defer provider.freeSendBocResponse(&result);

        std.debug.print("Submitted external ABI message:\n", .{});
        std.debug.print("  Destination: {s}\n", .{destination});
        std.debug.print("  ABI version: {s}\n", .{abi.abi.version});
        std.debug.print("  Function: {s}\n", .{function_selector});
        std.debug.print("  Hash: {s}\n", .{result.hash});
        std.debug.print("  LT: {d}\n", .{result.lt});
        return;
    }

    if (std.mem.eql(u8, command, "sendExternalAutoAbi") or std.mem.eql(u8, command, "send-external-auto-abi")) {
        if (args.len < 5) {
            std.debug.print("Usage: ton-zig-agent-kit sendExternalAutoAbi <destination> <state_init_b64|none> <function_name_or_signature> [values...]\n", .{});
            return;
        }

        const destination = args[2];
        const state_init_boc = if (!std.mem.eql(u8, args[3], "none"))
            try decodeBase64FlexibleAlloc(allocator, args[3])
        else
            null;
        defer if (state_init_boc) |value| allocator.free(value);

        const function_selector = args[4];

        var provider = try initDefaultProvider(allocator);

        var abi = (try contract_mod.abi_adapter.queryAbiDocumentAlloc(&provider, destination)) orelse {
            std.debug.print("ABI document not found for {s}\n", .{destination});
            return;
        };
        defer abi.deinit(allocator);

        const function = try resolveCliAbiFunction(&abi.abi, function_selector, args[5..]);

        var parsed_values = try parseCliAbiValuesForParams(allocator, function.inputs, args[5..]);
        defer parsed_values.deinit(allocator);

        const body_boc = try contract_mod.abi_adapter.buildFunctionBodyBocAlloc(
            allocator,
            function.*,
            parsed_values.values,
        );
        defer allocator.free(body_boc);

        const ext_boc = try ton_zig_agent_kit.core.external_message.buildExternalIncomingMessageBocAlloc(
            allocator,
            destination,
            body_boc,
            state_init_boc,
        );
        defer allocator.free(ext_boc);

        var result = try provider.sendBoc(ext_boc);
        defer provider.freeSendBocResponse(&result);

        std.debug.print("Submitted external ABI message:\n", .{});
        std.debug.print("  Destination: {s}\n", .{destination});
        std.debug.print("  ABI source: {s}\n", .{abi.abi.uri orelse "(embedded)"});
        std.debug.print("  ABI version: {s}\n", .{abi.abi.version});
        std.debug.print("  Function: {s}\n", .{function_selector});
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
            std.debug.print("Usage: ton-zig-agent-kit cell <create|encode|decode|hash|inspect-body|build-typed|build-standard|build-function|build-abi|build-state-init|state-init-address>\n", .{});
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

        if (std.mem.eql(u8, cell_cmd, "inspect-body")) {
            if (args.len < 4) {
                std.debug.print("Usage: ton-zig-agent-kit cell inspect-body <body_b64>\n", .{});
                return;
            }

            const body_boc = try decodeBase64FlexibleAlloc(allocator, args[3]);
            defer allocator.free(body_boc);

            var analysis = try ton_zig_agent_kit.core.body_inspector.inspectBodyBocAlloc(allocator, body_boc);
            defer analysis.deinit(allocator);

            std.debug.print("Body analysis:\n", .{});
            if (analysis.opcode) |opcode| {
                std.debug.print("  Opcode: 0x{X}\n", .{opcode});
            } else {
                std.debug.print("  Opcode: (none)\n", .{});
            }
            if (analysis.opcode_name) |value| {
                std.debug.print("  Opcode name: {s}\n", .{value});
            }
            if (analysis.comment) |value| {
                std.debug.print("  Comment: {s}\n", .{value});
            }
            if (analysis.tail_utf8) |value| {
                std.debug.print("  UTF-8 tail: {s}\n", .{value});
            }
            if (analysis.decoded_json) |value| {
                std.debug.print("  Decoded fields:\n{s}\n", .{value});
            }
            if (analysis.empty()) {
                std.debug.print("  No obvious UTF-8/comment payload detected\n", .{});
            }
            return;
        }

        if (std.mem.eql(u8, cell_cmd, "build-typed")) {
            if (args.len < 4) {
                std.debug.print("Usage: ton-zig-agent-kit cell build-typed <ops...>\n", .{});
                return;
            }

            var parsed_ops = try parseCliBodyOps(allocator, args[3..]);
            defer parsed_ops.deinit(allocator);

            const built = try ton_zig_agent_kit.core.body_builder.buildBodyBocAlloc(allocator, parsed_ops.ops);
            defer allocator.free(built);

            const encoded_len = std.base64.standard.Encoder.calcSize(built.len);
            const encoded = try allocator.alloc(u8, encoded_len);
            defer allocator.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, built);

            std.debug.print("Built body BoC:\n", .{});
            std.debug.print("  Base64: {s}\n", .{encoded});
            std.debug.print("  Hex: ", .{});
            for (built) |byte| {
                std.debug.print("{X:0>2}", .{byte});
            }
            std.debug.print("\n", .{});
            return;
        }

        if (std.mem.eql(u8, cell_cmd, "build-standard")) {
            if (args.len < 5) {
                std.debug.print("Usage: ton-zig-agent-kit cell build-standard <kind> <json|@file|file://|http(s)://|ipfs://>\n", .{});
                return;
            }

            const built = try contract_mod.standard_body.buildBodyFromSourceAlloc(allocator, args[3], args[4]);
            defer allocator.free(built);

            const encoded_len = std.base64.standard.Encoder.calcSize(built.len);
            const encoded = try allocator.alloc(u8, encoded_len);
            defer allocator.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, built);

            std.debug.print("Built standard body BoC:\n", .{});
            std.debug.print("  Kind: {s}\n", .{args[3]});
            std.debug.print("  Base64: {s}\n", .{encoded});
            std.debug.print("  Hex: ", .{});
            for (built) |byte| {
                std.debug.print("{X:0>2}", .{byte});
            }
            std.debug.print("\n", .{});
            return;
        }

        if (std.mem.eql(u8, cell_cmd, "build-function")) {
            if (args.len < 4) {
                std.debug.print("Usage: ton-zig-agent-kit cell build-function <function_json> <values...>\n", .{});
                return;
            }

            const function_json = try loadCliTextAlloc(allocator, args[3]);
            defer allocator.free(function_json);

            var function_def = try contract_mod.abi_adapter.parseFunctionDefJsonAlloc(allocator, function_json);
            defer function_def.deinit(allocator);

            var parsed_values = try parseCliAbiValuesForParams(allocator, function_def.function.inputs, args[4..]);
            defer parsed_values.deinit(allocator);

            const built = try contract_mod.abi_adapter.buildFunctionBodyBocAlloc(
                allocator,
                function_def.function,
                parsed_values.values,
            );
            defer allocator.free(built);

            const encoded_len = std.base64.standard.Encoder.calcSize(built.len);
            const encoded = try allocator.alloc(u8, encoded_len);
            defer allocator.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, built);

            std.debug.print("Built function body BoC:\n", .{});
            std.debug.print("  Function: {s}\n", .{function_def.function.name});
            std.debug.print("  Base64: {s}\n", .{encoded});
            std.debug.print("  Hex: ", .{});
            for (built) |byte| {
                std.debug.print("{X:0>2}", .{byte});
            }
            std.debug.print("\n", .{});
            return;
        }

        if (std.mem.eql(u8, cell_cmd, "build-abi")) {
            if (args.len < 5) {
                std.debug.print("Usage: ton-zig-agent-kit cell build-abi <abi_json|@file|file://|http(s)://|ipfs://> <function_name_or_signature> <values...>\n", .{});
                return;
            }

            const function_selector = args[4];

            var abi = try contract_mod.abi_adapter.loadAbiInfoSourceAlloc(allocator, args[3]);
            defer abi.deinit(allocator);

            const function = try resolveCliAbiFunction(&abi.abi, function_selector, args[5..]);

            var parsed_values = try parseCliAbiValuesForParams(allocator, function.inputs, args[5..]);
            defer parsed_values.deinit(allocator);

            const built = try contract_mod.abi_adapter.buildFunctionBodyBocAlloc(
                allocator,
                function.*,
                parsed_values.values,
            );
            defer allocator.free(built);

            const encoded_len = std.base64.standard.Encoder.calcSize(built.len);
            const encoded = try allocator.alloc(u8, encoded_len);
            defer allocator.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, built);

            std.debug.print("Built ABI function body BoC:\n", .{});
            std.debug.print("  ABI version: {s}\n", .{abi.abi.version});
            std.debug.print("  Function: {s}\n", .{function_selector});
            std.debug.print("  Base64: {s}\n", .{encoded});
            std.debug.print("  Hex: ", .{});
            for (built) |byte| {
                std.debug.print("{X:0>2}", .{byte});
            }
            std.debug.print("\n", .{});
            return;
        }

        if (std.mem.eql(u8, cell_cmd, "build-state-init")) {
            if (args.len < 4) {
                std.debug.print("Usage: ton-zig-agent-kit cell build-state-init <code_b64|none> [data_b64|none]\n", .{});
                return;
            }

            const code_boc = if (!std.mem.eql(u8, args[3], "none"))
                try decodeBase64FlexibleAlloc(allocator, args[3])
            else
                null;
            defer if (code_boc) |value| allocator.free(value);

            const data_boc = if (args.len >= 5 and !std.mem.eql(u8, args[4], "none"))
                try decodeBase64FlexibleAlloc(allocator, args[4])
            else
                null;
            defer if (data_boc) |value| allocator.free(value);

            const built = try ton_zig_agent_kit.core.state_init.buildStateInitBocAlloc(allocator, code_boc, data_boc);
            defer allocator.free(built);

            const encoded_len = std.base64.standard.Encoder.calcSize(built.len);
            const encoded = try allocator.alloc(u8, encoded_len);
            defer allocator.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, built);

            std.debug.print("Built StateInit BoC:\n", .{});
            std.debug.print("  Base64: {s}\n", .{encoded});
            std.debug.print("  Hex: ", .{});
            for (built) |byte| {
                std.debug.print("{X:0>2}", .{byte});
            }
            std.debug.print("\n", .{});
            return;
        }

        if (std.mem.eql(u8, cell_cmd, "build-external")) {
            if (args.len < 5) {
                std.debug.print("Usage: ton-zig-agent-kit cell build-external <destination> <body_b64> [state_init_b64|none]\n", .{});
                return;
            }

            const destination = args[3];
            const body_boc = try decodeBase64FlexibleAlloc(allocator, args[4]);
            defer allocator.free(body_boc);

            const state_init_boc = if (args.len >= 6 and !std.mem.eql(u8, args[5], "none"))
                try decodeBase64FlexibleAlloc(allocator, args[5])
            else
                null;
            defer if (state_init_boc) |value| allocator.free(value);

            const built = try ton_zig_agent_kit.core.external_message.buildExternalIncomingMessageBocAlloc(
                allocator,
                destination,
                body_boc,
                state_init_boc,
            );
            defer allocator.free(built);

            const encoded_len = std.base64.standard.Encoder.calcSize(built.len);
            const encoded = try allocator.alloc(u8, encoded_len);
            defer allocator.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, built);

            std.debug.print("Built external incoming message BoC:\n", .{});
            std.debug.print("  Destination: {s}\n", .{destination});
            std.debug.print("  Base64: {s}\n", .{encoded});
            std.debug.print("  Hex: ", .{});
            for (built) |byte| {
                std.debug.print("{X:0>2}", .{byte});
            }
            std.debug.print("\n", .{});
            return;
        }

        if (std.mem.eql(u8, cell_cmd, "state-init-address")) {
            if (args.len < 5) {
                std.debug.print("Usage: ton-zig-agent-kit cell state-init-address <workchain> <state_init_b64>\n", .{});
                return;
            }

            const workchain = try std.fmt.parseInt(i8, args[3], 10);
            const state_init_boc = try decodeBase64FlexibleAlloc(allocator, args[4]);
            defer allocator.free(state_init_boc);

            const addr = try ton_zig_agent_kit.core.state_init.computeStateInitAddressFromBoc(allocator, workchain, state_init_boc);
            const raw = try ton_zig_agent_kit.core.address.formatRaw(allocator, &addr);
            defer allocator.free(raw);
            const user_friendly = try ton_zig_agent_kit.core.address.addressToUserFriendlyAlloc(allocator, &addr, true, false);
            defer allocator.free(user_friendly);

            std.debug.print("Computed StateInit address:\n", .{});
            std.debug.print("  Workchain: {d}\n", .{workchain});
            std.debug.print("  Raw: {s}\n", .{raw});
            std.debug.print("  User-friendly: {s}\n", .{user_friendly});
            return;
        }

        std.debug.print("Unknown cell command: {s}\n", .{cell_cmd});
        return;
    }

    if (std.mem.eql(u8, command, "wallet")) {
        if (args.len < 3) {
            std.debug.print("Usage: ton-zig-agent-kit wallet <genkey|address|seqno|info|build-self-deploy|build-transfer|build-body|build-body-hex|build-standard|build-function|build-abi|build-auto-abi|build-deploy|build-deploy-auto|send|send-init|deploy-self|send-body|send-body-hex|send-standard|send-ops|send-function|send-abi|send-auto-abi|send-deploy|send-deploy-auto>\n", .{});
            return;
        }
        const wallet_cmd = args[2];

        if (std.mem.eql(u8, wallet_cmd, "genkey")) {
            const wallet_keys = if (args.len >= 4)
                loadCliWalletKeyMaterialFromSpec(allocator, args[3]) catch |err| {
                    printWalletKeyLoadError(err);
                    return;
                }
            else
                loadCliWalletKeyMaterial(allocator) catch |err| {
                    printWalletKeyLoadError(err);
                    return;
                };

            std.debug.print("Keypair generated:\n", .{});
            std.debug.print("  Source: {s}\n", .{walletKeySourceLabel(wallet_keys.source)});
            std.debug.print("  Private key: ", .{});
            for (wallet_keys.private_key_seed) |byte| {
                std.debug.print("{X:0>2}", .{byte});
            }
            std.debug.print("\n", .{});
            std.debug.print("  Public key: ", .{});
            for (wallet_keys.public_key) |byte| {
                std.debug.print("{X:0>2}", .{byte});
            }
            std.debug.print("\n", .{});
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "address")) {
            const bootstrap = parseWalletBootstrapOptions(args[3..]) catch |err| {
                std.debug.print("Usage: ton-zig-agent-kit wallet address [v4|v5] [workchain] [wallet_id] [seed|@file|hex:<private_key_hex>]\n", .{});
                std.debug.print("Wallet bootstrap args invalid: {s}\n", .{@errorName(err)});
                return;
            };
            const wallet_keys = loadCliWalletKeyMaterialWithOptionalSpec(allocator, bootstrap.key_spec) catch |err| {
                printWalletKeyLoadError(err);
                return;
            };

            var init = try signing.deriveWalletInitFromPrivateKeyAlloc(
                allocator,
                bootstrap.wallet_version,
                bootstrap.workchain,
                bootstrap.wallet_id,
                wallet_keys.private_key_seed,
            );
            defer init.deinit(allocator);

            const raw = try init.address.toRawAlloc(allocator);
            defer allocator.free(raw);
            const user_friendly = try init.address.toUserFriendlyAlloc(allocator, true, false);
            defer allocator.free(user_friendly);
            const encoded_len = std.base64.standard.Encoder.calcSize(init.state_init_boc.len);
            const encoded = try allocator.alloc(u8, encoded_len);
            defer allocator.free(encoded);
            _ = std.base64.standard.Encoder.encode(encoded, init.state_init_boc);

            std.debug.print("Derived wallet {s} address:\n", .{signing.walletVersionName(init.version)});
            std.debug.print("  Source: {s}\n", .{walletKeySourceLabel(wallet_keys.source)});
            std.debug.print("  Version: {s}\n", .{signing.walletVersionName(init.version)});
            std.debug.print("  Workchain: {d}\n", .{bootstrap.workchain});
            std.debug.print("  Wallet ID: {d} (0x{X:0>8})\n", .{ bootstrap.wallet_id, bootstrap.wallet_id });
            std.debug.print("  Raw: {s}\n", .{raw});
            std.debug.print("  User-friendly: {s}\n", .{user_friendly});
            std.debug.print("  Public key: ", .{});
            for (wallet_keys.public_key) |byte| {
                std.debug.print("{X:0>2}", .{byte});
            }
            std.debug.print("\n", .{});
            std.debug.print("  StateInit BoC: {s}\n", .{encoded});
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "seqno")) {
            if (args.len < 4) {
                std.debug.print("Usage: ton-zig-agent-kit wallet seqno <wallet_address>\n", .{});
                return;
            }
            const wallet_addr = args[3];
            var provider = try initDefaultProvider(allocator);

            const seqno = try signing.getSeqno(&provider, wallet_addr);
            std.debug.print("Wallet seqno: {d}\n", .{seqno});
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "info")) {
            if (args.len < 4) {
                std.debug.print("Usage: ton-zig-agent-kit wallet info <wallet_address>\n", .{});
                return;
            }
            const wallet_addr = args[3];
            var provider = try initDefaultProvider(allocator);

            const info = try signing.getWalletInfo(&provider, wallet_addr);
            std.debug.print("Wallet info:\n", .{});
            std.debug.print("  Address: {s}\n", .{wallet_addr});
            std.debug.print("  Version: {s}\n", .{signing.walletVersionName(info.version)});
            std.debug.print("  Seqno: {d}\n", .{info.seqno});
            std.debug.print("  Wallet ID: {d} (0x{X:0>8})\n", .{ info.wallet_id, info.wallet_id });
            std.debug.print("  Public key: ", .{});
            for (info.public_key) |byte| {
                std.debug.print("{X:0>2}", .{byte});
            }
            std.debug.print("\n", .{});

            const maybe_local_keys = loadCliWalletKeyMaterial(allocator) catch |err| switch (err) {
                error.MissingWalletKeyMaterial => null,
                else => blk: {
                    std.debug.print("  Local key: load failed ({s})\n", .{@errorName(err)});
                    break :blk null;
                },
            };
            if (maybe_local_keys) |local_keys| {
                std.debug.print("  Local key source: {s}\n", .{walletKeySourceLabel(local_keys.source)});
                std.debug.print("  Local public key: ", .{});
                for (local_keys.public_key) |byte| {
                    std.debug.print("{X:0>2}", .{byte});
                }
                std.debug.print("\n", .{});
                std.debug.print("  Public key match: {s}\n", .{
                    if (std.mem.eql(u8, &local_keys.public_key, &info.public_key)) "yes" else "no",
                });
            }
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "build-self-deploy")) {
            const bootstrap = parseWalletBootstrapOptions(args[3..]) catch |err| {
                std.debug.print("Usage: ton-zig-agent-kit wallet build-self-deploy [v4|v5] [workchain] [wallet_id] [seed|@file|hex:<private_key_hex>]\n", .{});
                std.debug.print("Wallet bootstrap args invalid: {s}\n", .{@errorName(err)});
                return;
            };
            const wallet_keys = loadCliWalletKeyMaterialWithOptionalSpec(allocator, bootstrap.key_spec) catch |err| {
                printWalletKeyLoadError(err);
                return;
            };

            var init = try signing.deriveWalletInitFromPrivateKeyAlloc(
                allocator,
                bootstrap.wallet_version,
                bootstrap.workchain,
                bootstrap.wallet_id,
                wallet_keys.private_key_seed,
            );
            defer init.deinit(allocator);

            const raw = try init.address.toRawAlloc(allocator);
            defer allocator.free(raw);
            const user_friendly = try init.address.toUserFriendlyAlloc(allocator, true, false);
            defer allocator.free(user_friendly);

            var built = try signing.buildWalletDeploymentAlloc(
                allocator,
                bootstrap.wallet_version,
                wallet_keys.private_key_seed,
                bootstrap.workchain,
                bootstrap.wallet_id,
            );
            defer built.deinit(allocator);

            try printBuiltWalletExternalMessage(allocator, raw, 0, &built);
            std.debug.print("  User-friendly: {s}\n", .{user_friendly});
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "send-init")) {
            if (args.len < 5) {
                std.debug.print("Usage: ton-zig-agent-kit wallet send-init <dest> <amount_nanoton> [v4|v5] [workchain] [wallet_id] [seed|@file|hex:<private_key_hex>]\n", .{});
                return;
            }
            const dest = args[3];
            const amount = try std.fmt.parseInt(u64, args[4], 10);
            const bootstrap = parseWalletBootstrapOptions(args[5..]) catch |err| {
                std.debug.print("Usage: ton-zig-agent-kit wallet send-init <dest> <amount_nanoton> [v4|v5] [workchain] [wallet_id] [seed|@file|hex:<private_key_hex>]\n", .{});
                std.debug.print("Wallet bootstrap args invalid: {s}\n", .{@errorName(err)});
                return;
            };
            const wallet_keys = loadCliWalletKeyMaterialWithOptionalSpec(allocator, bootstrap.key_spec) catch |err| {
                printWalletKeyLoadError(err);
                return;
            };

            var init = try signing.deriveWalletInitFromPrivateKeyAlloc(
                allocator,
                bootstrap.wallet_version,
                bootstrap.workchain,
                bootstrap.wallet_id,
                wallet_keys.private_key_seed,
            );
            defer init.deinit(allocator);

            const raw = try init.address.toRawAlloc(allocator);
            defer allocator.free(raw);
            const user_friendly = try init.address.toUserFriendlyAlloc(allocator, true, false);
            defer allocator.free(user_friendly);

            var provider = try initDefaultProvider(allocator);
            var result = try signing.sendInitialTransfer(
                &provider,
                bootstrap.wallet_version,
                wallet_keys.private_key_seed,
                bootstrap.workchain,
                bootstrap.wallet_id,
                dest,
                amount,
                null,
            );
            defer provider.freeSendBocResponse(&result);

            std.debug.print("Initial wallet transfer submitted:\n", .{});
            std.debug.print("  Wallet: {s}\n", .{raw});
            std.debug.print("  User-friendly: {s}\n", .{user_friendly});
            std.debug.print("  Hash: {s}\n", .{result.hash});
            std.debug.print("  LT: {d}\n", .{result.lt});
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "deploy-self")) {
            const bootstrap = parseWalletBootstrapOptions(args[3..]) catch |err| {
                std.debug.print("Usage: ton-zig-agent-kit wallet deploy-self [v4|v5] [workchain] [wallet_id] [seed|@file|hex:<private_key_hex>]\n", .{});
                std.debug.print("Wallet bootstrap args invalid: {s}\n", .{@errorName(err)});
                return;
            };
            const wallet_keys = loadCliWalletKeyMaterialWithOptionalSpec(allocator, bootstrap.key_spec) catch |err| {
                printWalletKeyLoadError(err);
                return;
            };

            var init = try signing.deriveWalletInitFromPrivateKeyAlloc(
                allocator,
                bootstrap.wallet_version,
                bootstrap.workchain,
                bootstrap.wallet_id,
                wallet_keys.private_key_seed,
            );
            defer init.deinit(allocator);

            const raw = try init.address.toRawAlloc(allocator);
            defer allocator.free(raw);
            const user_friendly = try init.address.toUserFriendlyAlloc(allocator, true, false);
            defer allocator.free(user_friendly);

            var provider = try initDefaultProvider(allocator);
            var result = try signing.deployWallet(
                &provider,
                bootstrap.wallet_version,
                wallet_keys.private_key_seed,
                bootstrap.workchain,
                bootstrap.wallet_id,
            );
            defer provider.freeSendBocResponse(&result);

            std.debug.print("Wallet deployment submitted:\n", .{});
            std.debug.print("  Wallet: {s}\n", .{raw});
            std.debug.print("  User-friendly: {s}\n", .{user_friendly});
            std.debug.print("  Hash: {s}\n", .{result.hash});
            std.debug.print("  LT: {d}\n", .{result.lt});
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "build-transfer")) {
            if (args.len < 5) {
                std.debug.print("Usage: ton-zig-agent-kit wallet build-transfer <dest> <amount_nanoton> [comment]\n", .{});
                return;
            }
            const dest = args[3];
            const amount = try std.fmt.parseInt(u64, args[4], 10);
            const comment = if (args.len >= 6) args[5] else null;

            var provider = try initDefaultProvider(allocator);

            const wallet_keys = loadCliWalletKeyMaterial(allocator) catch |err| {
                printWalletKeyLoadError(err);
                return;
            };

            var built = try buildCliWalletSignedMessageAuto(
                allocator,
                &provider,
                wallet_keys.private_key_seed,
                .{
                    .destination = dest,
                    .amount = amount,
                    .comment = comment,
                },
            );
            defer built.deinit(allocator);

            try printBuiltWalletExternalMessage(allocator, dest, amount, &built);
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "build-body")) {
            if (args.len < 6) {
                std.debug.print("Usage: ton-zig-agent-kit wallet build-body <dest> <amount_nanoton> <body_b64>\n", .{});
                return;
            }
            const dest = args[3];
            const amount = try std.fmt.parseInt(u64, args[4], 10);
            const body = try decodeBase64FlexibleAlloc(allocator, args[5]);
            defer allocator.free(body);

            var provider = try initDefaultProvider(allocator);

            const wallet_keys = loadCliWalletKeyMaterial(allocator) catch |err| {
                printWalletKeyLoadError(err);
                return;
            };

            var built = try buildCliWalletSignedMessageAuto(
                allocator,
                &provider,
                wallet_keys.private_key_seed,
                .{
                    .destination = dest,
                    .amount = amount,
                    .body = body,
                },
            );
            defer built.deinit(allocator);

            try printBuiltWalletExternalMessage(allocator, dest, amount, &built);
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "build-body-hex")) {
            if (args.len < 6) {
                std.debug.print("Usage: ton-zig-agent-kit wallet build-body-hex <dest> <amount_nanoton> <body_hex>\n", .{});
                return;
            }
            const dest = args[3];
            const amount = try std.fmt.parseInt(u64, args[4], 10);
            const body = try hexToBytes(allocator, args[5]);
            defer allocator.free(body);

            var provider = try initDefaultProvider(allocator);

            const wallet_keys = loadCliWalletKeyMaterial(allocator) catch |err| {
                printWalletKeyLoadError(err);
                return;
            };

            var built = try buildCliWalletSignedMessageAuto(
                allocator,
                &provider,
                wallet_keys.private_key_seed,
                .{
                    .destination = dest,
                    .amount = amount,
                    .body = body,
                },
            );
            defer built.deinit(allocator);

            try printBuiltWalletExternalMessage(allocator, dest, amount, &built);
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "build-standard")) {
            if (args.len < 7) {
                std.debug.print("Usage: ton-zig-agent-kit wallet build-standard <dest> <amount_nanoton> <kind> <json|@file|file://|http(s)://|ipfs://>\n", .{});
                return;
            }
            const dest = args[3];
            const amount = try std.fmt.parseInt(u64, args[4], 10);
            const body = try contract_mod.standard_body.buildBodyFromSourceAlloc(allocator, args[5], args[6]);
            defer allocator.free(body);

            var provider = try initDefaultProvider(allocator);

            const wallet_keys = loadCliWalletKeyMaterial(allocator) catch |err| {
                printWalletKeyLoadError(err);
                return;
            };

            var built = try buildCliWalletSignedMessageAuto(
                allocator,
                &provider,
                wallet_keys.private_key_seed,
                .{
                    .destination = dest,
                    .amount = amount,
                    .body = body,
                },
            );
            defer built.deinit(allocator);

            try printBuiltWalletExternalMessage(allocator, dest, amount, &built);
            std.debug.print("  Kind: {s}\n", .{args[5]});
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "build-function")) {
            if (args.len < 6) {
                std.debug.print("Usage: ton-zig-agent-kit wallet build-function <dest> <amount_nanoton> <function_json> <values...>\n", .{});
                return;
            }
            const dest = args[3];
            const amount = try std.fmt.parseInt(u64, args[4], 10);
            const function_json = try loadCliTextAlloc(allocator, args[5]);
            defer allocator.free(function_json);

            var function_def = try contract_mod.abi_adapter.parseFunctionDefJsonAlloc(allocator, function_json);
            defer function_def.deinit(allocator);

            var parsed_values = try parseCliAbiValuesForParams(allocator, function_def.function.inputs, args[6..]);
            defer parsed_values.deinit(allocator);

            const body = try contract_mod.abi_adapter.buildFunctionBodyBocAlloc(
                allocator,
                function_def.function,
                parsed_values.values,
            );
            defer allocator.free(body);

            var provider = try initDefaultProvider(allocator);

            const wallet_keys = loadCliWalletKeyMaterial(allocator) catch |err| {
                printWalletKeyLoadError(err);
                return;
            };

            var built = try buildCliWalletSignedMessageAuto(
                allocator,
                &provider,
                wallet_keys.private_key_seed,
                .{
                    .destination = dest,
                    .amount = amount,
                    .body = body,
                },
            );
            defer built.deinit(allocator);

            try printBuiltWalletExternalMessage(allocator, dest, amount, &built);
            std.debug.print("  Function: {s}\n", .{function_def.function.name});
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "build-abi")) {
            if (args.len < 7) {
                std.debug.print("Usage: ton-zig-agent-kit wallet build-abi <dest> <amount_nanoton> <abi_json|@file|file://|http(s)://|ipfs://> <function_name_or_signature> <values...>\n", .{});
                return;
            }
            const dest = args[3];
            const amount = try std.fmt.parseInt(u64, args[4], 10);
            const function_selector = args[6];

            var abi = try contract_mod.abi_adapter.loadAbiInfoSourceAlloc(allocator, args[5]);
            defer abi.deinit(allocator);

            const function = try resolveCliAbiFunction(&abi.abi, function_selector, args[7..]);
            var parsed_values = try parseCliAbiValuesForParams(allocator, function.inputs, args[7..]);
            defer parsed_values.deinit(allocator);

            const body = try contract_mod.abi_adapter.buildFunctionBodyBocAlloc(
                allocator,
                function.*,
                parsed_values.values,
            );
            defer allocator.free(body);

            var provider = try initDefaultProvider(allocator);

            const wallet_keys = loadCliWalletKeyMaterial(allocator) catch |err| {
                printWalletKeyLoadError(err);
                return;
            };

            var built = try buildCliWalletSignedMessageAuto(
                allocator,
                &provider,
                wallet_keys.private_key_seed,
                .{
                    .destination = dest,
                    .amount = amount,
                    .body = body,
                },
            );
            defer built.deinit(allocator);

            try printBuiltWalletExternalMessage(allocator, dest, amount, &built);
            std.debug.print("  ABI version: {s}\n", .{abi.abi.version});
            std.debug.print("  Function: {s}\n", .{function_selector});
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "build-auto-abi")) {
            if (args.len < 6) {
                std.debug.print("Usage: ton-zig-agent-kit wallet build-auto-abi <dest> <amount_nanoton> <function_name_or_signature> <values...>\n", .{});
                return;
            }
            const dest = args[3];
            const amount = try std.fmt.parseInt(u64, args[4], 10);
            const function_selector = args[5];

            var provider = try initDefaultProvider(allocator);

            var abi = (try contract_mod.abi_adapter.queryAbiDocumentAlloc(&provider, dest)) orelse {
                std.debug.print("ABI document not found for {s}\n", .{dest});
                return;
            };
            defer abi.deinit(allocator);

            const function = try resolveCliAbiFunction(&abi.abi, function_selector, args[6..]);
            var parsed_values = try parseCliAbiValuesForParams(allocator, function.inputs, args[6..]);
            defer parsed_values.deinit(allocator);

            const body = try contract_mod.abi_adapter.buildFunctionBodyBocAlloc(
                allocator,
                function.*,
                parsed_values.values,
            );
            defer allocator.free(body);

            const wallet_keys = loadCliWalletKeyMaterial(allocator) catch |err| {
                printWalletKeyLoadError(err);
                return;
            };

            var built = try buildCliWalletSignedMessageAuto(
                allocator,
                &provider,
                wallet_keys.private_key_seed,
                .{
                    .destination = dest,
                    .amount = amount,
                    .body = body,
                },
            );
            defer built.deinit(allocator);

            try printBuiltWalletExternalMessage(allocator, dest, amount, &built);
            std.debug.print("  ABI source: {s}\n", .{abi.abi.uri orelse "(embedded)"});
            std.debug.print("  ABI version: {s}\n", .{abi.abi.version});
            std.debug.print("  Function: {s}\n", .{function_selector});
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "build-deploy")) {
            if (args.len < 6) {
                std.debug.print("Usage: ton-zig-agent-kit wallet build-deploy <dest> <amount_nanoton> <state_init_b64> [body_b64]\n", .{});
                return;
            }
            const dest = args[3];
            const amount = try std.fmt.parseInt(u64, args[4], 10);
            const state_init_boc = try decodeBase64FlexibleAlloc(allocator, args[5]);
            defer allocator.free(state_init_boc);
            const body_boc = if (args.len >= 7)
                try decodeBase64FlexibleAlloc(allocator, args[6])
            else
                null;
            defer if (body_boc) |value| allocator.free(value);

            var provider = try initDefaultProvider(allocator);

            const wallet_keys = loadCliWalletKeyMaterial(allocator) catch |err| {
                printWalletKeyLoadError(err);
                return;
            };

            var built = try buildCliWalletSignedMessageAuto(
                allocator,
                &provider,
                wallet_keys.private_key_seed,
                .{
                    .destination = dest,
                    .amount = amount,
                    .state_init = state_init_boc,
                    .body = body_boc,
                    .bounce = false,
                },
            );
            defer built.deinit(allocator);

            try printBuiltWalletExternalMessage(allocator, dest, amount, &built);
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "build-deploy-auto")) {
            if (args.len < 6) {
                std.debug.print("Usage: ton-zig-agent-kit wallet build-deploy-auto <workchain> <amount_nanoton> <state_init_b64> [body_b64]\n", .{});
                return;
            }
            const workchain = try std.fmt.parseInt(i8, args[3], 10);
            const amount = try std.fmt.parseInt(u64, args[4], 10);
            const state_init_boc = try decodeBase64FlexibleAlloc(allocator, args[5]);
            defer allocator.free(state_init_boc);
            const body_boc = if (args.len >= 7)
                try decodeBase64FlexibleAlloc(allocator, args[6])
            else
                null;
            defer if (body_boc) |value| allocator.free(value);

            const dest_addr = try ton_zig_agent_kit.core.state_init.computeStateInitAddressFromBoc(allocator, workchain, state_init_boc);
            const dest_raw = try ton_zig_agent_kit.core.address.formatRaw(allocator, &dest_addr);
            defer allocator.free(dest_raw);
            const dest_user_friendly = try ton_zig_agent_kit.core.address.addressToUserFriendlyAlloc(allocator, &dest_addr, true, false);
            defer allocator.free(dest_user_friendly);

            var provider = try initDefaultProvider(allocator);

            const wallet_keys = loadCliWalletKeyMaterial(allocator) catch |err| {
                printWalletKeyLoadError(err);
                return;
            };

            var built = try buildCliWalletSignedMessageAuto(
                allocator,
                &provider,
                wallet_keys.private_key_seed,
                .{
                    .destination = dest_raw,
                    .amount = amount,
                    .state_init = state_init_boc,
                    .body = body_boc,
                    .bounce = false,
                },
            );
            defer built.deinit(allocator);

            try printBuiltWalletExternalMessage(allocator, dest_raw, amount, &built);
            std.debug.print("  Derived destination (user-friendly): {s}\n", .{dest_user_friendly});
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

            var provider = try initDefaultProvider(allocator);

            const wallet_keys = loadCliWalletKeyMaterial(allocator) catch |err| {
                printWalletKeyLoadError(err);
                return;
            };
            const private_key = wallet_keys.private_key_seed;

            var result = try signing.sendTransfer(&provider, .auto, private_key, wallet_addr, dest, amount, null);
            defer provider.freeSendBocResponse(&result);

            std.debug.print("Transfer submitted:\n", .{});
            std.debug.print("  Hash: {s}\n", .{result.hash});
            std.debug.print("  LT: {d}\n", .{result.lt});
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "send-body")) {
            if (args.len < 7) {
                std.debug.print("Usage: ton-zig-agent-kit wallet send-body <wallet_addr> <dest> <amount_nanoton> <body_b64>\n", .{});
                return;
            }
            const wallet_addr = args[3];
            const dest = args[4];
            const amount = try std.fmt.parseInt(u64, args[5], 10);
            const body = try decodeBase64FlexibleAlloc(allocator, args[6]);
            defer allocator.free(body);

            var provider = try initDefaultProvider(allocator);

            const wallet_keys = loadCliWalletKeyMaterial(allocator) catch |err| {
                printWalletKeyLoadError(err);
                return;
            };
            const private_key = wallet_keys.private_key_seed;

            var result = try signing.sendBody(&provider, .auto, private_key, wallet_addr, dest, amount, body);
            defer provider.freeSendBocResponse(&result);

            std.debug.print("Contract message submitted:\n", .{});
            std.debug.print("  Hash: {s}\n", .{result.hash});
            std.debug.print("  LT: {d}\n", .{result.lt});
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "send-body-hex")) {
            if (args.len < 7) {
                std.debug.print("Usage: ton-zig-agent-kit wallet send-body-hex <wallet_addr> <dest> <amount_nanoton> <body_hex>\n", .{});
                return;
            }
            const wallet_addr = args[3];
            const dest = args[4];
            const amount = try std.fmt.parseInt(u64, args[5], 10);
            const body = try hexToBytes(allocator, args[6]);
            defer allocator.free(body);

            var provider = try initDefaultProvider(allocator);

            const wallet_keys = loadCliWalletKeyMaterial(allocator) catch |err| {
                printWalletKeyLoadError(err);
                return;
            };
            const private_key = wallet_keys.private_key_seed;

            var result = try signing.sendBody(&provider, .auto, private_key, wallet_addr, dest, amount, body);
            defer provider.freeSendBocResponse(&result);

            std.debug.print("Contract message submitted:\n", .{});
            std.debug.print("  Hash: {s}\n", .{result.hash});
            std.debug.print("  LT: {d}\n", .{result.lt});
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "send-standard")) {
            if (args.len < 8) {
                std.debug.print("Usage: ton-zig-agent-kit wallet send-standard <wallet_addr> <dest> <amount_nanoton> <kind> <json|@file|file://|http(s)://|ipfs://>\n", .{});
                return;
            }
            const wallet_addr = args[3];
            const dest = args[4];
            const amount = try std.fmt.parseInt(u64, args[5], 10);
            const body = try contract_mod.standard_body.buildBodyFromSourceAlloc(allocator, args[6], args[7]);
            defer allocator.free(body);

            var provider = try initDefaultProvider(allocator);

            const wallet_keys = loadCliWalletKeyMaterial(allocator) catch |err| {
                printWalletKeyLoadError(err);
                return;
            };
            const private_key = wallet_keys.private_key_seed;

            var result = try signing.sendBody(&provider, .auto, private_key, wallet_addr, dest, amount, body);
            defer provider.freeSendBocResponse(&result);

            std.debug.print("Standard contract message submitted:\n", .{});
            std.debug.print("  Kind: {s}\n", .{args[6]});
            std.debug.print("  Hash: {s}\n", .{result.hash});
            std.debug.print("  LT: {d}\n", .{result.lt});
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "send-ops")) {
            if (args.len < 7) {
                std.debug.print("Usage: ton-zig-agent-kit wallet send-ops <wallet_addr> <dest> <amount_nanoton> <ops...>\n", .{});
                return;
            }
            const wallet_addr = args[3];
            const dest = args[4];
            const amount = try std.fmt.parseInt(u64, args[5], 10);

            var parsed_ops = try parseCliBodyOps(allocator, args[6..]);
            defer parsed_ops.deinit(allocator);

            const body = try ton_zig_agent_kit.core.body_builder.buildBodyBocAlloc(allocator, parsed_ops.ops);
            defer allocator.free(body);

            var provider = try initDefaultProvider(allocator);

            const wallet_keys = loadCliWalletKeyMaterial(allocator) catch |err| {
                printWalletKeyLoadError(err);
                return;
            };
            const private_key = wallet_keys.private_key_seed;

            var result = try signing.sendBody(&provider, .auto, private_key, wallet_addr, dest, amount, body);
            defer provider.freeSendBocResponse(&result);

            std.debug.print("Typed contract message submitted:\n", .{});
            std.debug.print("  Hash: {s}\n", .{result.hash});
            std.debug.print("  LT: {d}\n", .{result.lt});
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "send-function")) {
            if (args.len < 8) {
                std.debug.print("Usage: ton-zig-agent-kit wallet send-function <wallet_addr> <dest> <amount_nanoton> <function_json> <values...>\n", .{});
                return;
            }
            const wallet_addr = args[3];
            const dest = args[4];
            const amount = try std.fmt.parseInt(u64, args[5], 10);

            const function_json = try loadCliTextAlloc(allocator, args[6]);
            defer allocator.free(function_json);

            var function_def = try contract_mod.abi_adapter.parseFunctionDefJsonAlloc(allocator, function_json);
            defer function_def.deinit(allocator);

            var parsed_values = try parseCliAbiValuesForParams(allocator, function_def.function.inputs, args[7..]);
            defer parsed_values.deinit(allocator);

            const body = try contract_mod.abi_adapter.buildFunctionBodyBocAlloc(
                allocator,
                function_def.function,
                parsed_values.values,
            );
            defer allocator.free(body);

            var provider = try initDefaultProvider(allocator);

            const wallet_keys = loadCliWalletKeyMaterial(allocator) catch |err| {
                printWalletKeyLoadError(err);
                return;
            };
            const private_key = wallet_keys.private_key_seed;

            var result = try signing.sendBody(&provider, .auto, private_key, wallet_addr, dest, amount, body);
            defer provider.freeSendBocResponse(&result);

            std.debug.print("Function contract message submitted:\n", .{});
            std.debug.print("  Function: {s}\n", .{function_def.function.name});
            std.debug.print("  Hash: {s}\n", .{result.hash});
            std.debug.print("  LT: {d}\n", .{result.lt});
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "send-abi")) {
            if (args.len < 9) {
                std.debug.print("Usage: ton-zig-agent-kit wallet send-abi <wallet_addr> <dest> <amount_nanoton> <abi_json|@file|file://|http(s)://|ipfs://> <function_name_or_signature> <values...>\n", .{});
                return;
            }
            const wallet_addr = args[3];
            const dest = args[4];
            const amount = try std.fmt.parseInt(u64, args[5], 10);
            const function_selector = args[7];

            var abi = try contract_mod.abi_adapter.loadAbiInfoSourceAlloc(allocator, args[6]);
            defer abi.deinit(allocator);

            const function = try resolveCliAbiFunction(&abi.abi, function_selector, args[8..]);

            var parsed_values = try parseCliAbiValuesForParams(allocator, function.inputs, args[8..]);
            defer parsed_values.deinit(allocator);

            const body = try contract_mod.abi_adapter.buildFunctionBodyBocAlloc(
                allocator,
                function.*,
                parsed_values.values,
            );
            defer allocator.free(body);

            var provider = try initDefaultProvider(allocator);

            const wallet_keys = loadCliWalletKeyMaterial(allocator) catch |err| {
                printWalletKeyLoadError(err);
                return;
            };
            const private_key = wallet_keys.private_key_seed;

            var result = try signing.sendBody(&provider, .auto, private_key, wallet_addr, dest, amount, body);
            defer provider.freeSendBocResponse(&result);

            std.debug.print("ABI contract message submitted:\n", .{});
            std.debug.print("  ABI version: {s}\n", .{abi.abi.version});
            std.debug.print("  Function: {s}\n", .{function_selector});
            std.debug.print("  Hash: {s}\n", .{result.hash});
            std.debug.print("  LT: {d}\n", .{result.lt});
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "send-auto-abi")) {
            if (args.len < 8) {
                std.debug.print("Usage: ton-zig-agent-kit wallet send-auto-abi <wallet_addr> <dest> <amount_nanoton> <function_name_or_signature> <values...>\n", .{});
                return;
            }
            const wallet_addr = args[3];
            const dest = args[4];
            const amount = try std.fmt.parseInt(u64, args[5], 10);
            const function_selector = args[6];

            var provider = try initDefaultProvider(allocator);

            var abi = (try contract_mod.abi_adapter.queryAbiDocumentAlloc(&provider, dest)) orelse {
                std.debug.print("ABI document not found for {s}\n", .{dest});
                return;
            };
            defer abi.deinit(allocator);

            const function = try resolveCliAbiFunction(&abi.abi, function_selector, args[7..]);

            var parsed_values = try parseCliAbiValuesForParams(allocator, function.inputs, args[7..]);
            defer parsed_values.deinit(allocator);

            const body = try contract_mod.abi_adapter.buildFunctionBodyBocAlloc(
                allocator,
                function.*,
                parsed_values.values,
            );
            defer allocator.free(body);

            const wallet_keys = loadCliWalletKeyMaterial(allocator) catch |err| {
                printWalletKeyLoadError(err);
                return;
            };
            const private_key = wallet_keys.private_key_seed;

            var result = try signing.sendBody(&provider, .auto, private_key, wallet_addr, dest, amount, body);
            defer provider.freeSendBocResponse(&result);

            std.debug.print("Auto ABI contract message submitted:\n", .{});
            std.debug.print("  ABI source: {s}\n", .{abi.abi.uri orelse "(embedded)"});
            std.debug.print("  ABI version: {s}\n", .{abi.abi.version});
            std.debug.print("  Function: {s}\n", .{function_selector});
            std.debug.print("  Hash: {s}\n", .{result.hash});
            std.debug.print("  LT: {d}\n", .{result.lt});
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "send-deploy")) {
            if (args.len < 7) {
                std.debug.print("Usage: ton-zig-agent-kit wallet send-deploy <wallet_addr> <dest> <amount_nanoton> <state_init_b64> [body_b64]\n", .{});
                return;
            }
            const wallet_addr = args[3];
            const dest = args[4];
            const amount = try std.fmt.parseInt(u64, args[5], 10);
            const state_init_boc = try decodeBase64FlexibleAlloc(allocator, args[6]);
            defer allocator.free(state_init_boc);
            const body_boc = if (args.len >= 8)
                try decodeBase64FlexibleAlloc(allocator, args[7])
            else
                null;
            defer if (body_boc) |value| allocator.free(value);

            var provider = try initDefaultProvider(allocator);

            const wallet_keys = loadCliWalletKeyMaterial(allocator) catch |err| {
                printWalletKeyLoadError(err);
                return;
            };
            const private_key = wallet_keys.private_key_seed;

            var result = try signing.sendDeploy(&provider, .auto, private_key, wallet_addr, dest, amount, state_init_boc, body_boc);
            defer provider.freeSendBocResponse(&result);

            std.debug.print("Deploy message submitted:\n", .{});
            std.debug.print("  Hash: {s}\n", .{result.hash});
            std.debug.print("  LT: {d}\n", .{result.lt});
            return;
        }

        if (std.mem.eql(u8, wallet_cmd, "send-deploy-auto")) {
            if (args.len < 7) {
                std.debug.print("Usage: ton-zig-agent-kit wallet send-deploy-auto <wallet_addr> <workchain> <amount_nanoton> <state_init_b64> [body_b64]\n", .{});
                return;
            }
            const wallet_addr = args[3];
            const workchain = try std.fmt.parseInt(i8, args[4], 10);
            const amount = try std.fmt.parseInt(u64, args[5], 10);
            const state_init_boc = try decodeBase64FlexibleAlloc(allocator, args[6]);
            defer allocator.free(state_init_boc);
            const body_boc = if (args.len >= 8)
                try decodeBase64FlexibleAlloc(allocator, args[7])
            else
                null;
            defer if (body_boc) |value| allocator.free(value);

            const dest_addr = try ton_zig_agent_kit.core.state_init.computeStateInitAddressFromBoc(allocator, workchain, state_init_boc);
            const dest_raw = try ton_zig_agent_kit.core.address.formatRaw(allocator, &dest_addr);
            defer allocator.free(dest_raw);
            const dest_user_friendly = try ton_zig_agent_kit.core.address.addressToUserFriendlyAlloc(allocator, &dest_addr, true, false);
            defer allocator.free(dest_user_friendly);

            var provider = try initDefaultProvider(allocator);

            const wallet_keys = loadCliWalletKeyMaterial(allocator) catch |err| {
                printWalletKeyLoadError(err);
                return;
            };
            const private_key = wallet_keys.private_key_seed;

            var result = try signing.sendDeploy(&provider, .auto, private_key, wallet_addr, dest_raw, amount, state_init_boc, body_boc);
            defer provider.freeSendBocResponse(&result);

            std.debug.print("Deploy message submitted:\n", .{});
            std.debug.print("  Destination: {s}\n", .{dest_raw});
            std.debug.print("  User-friendly: {s}\n", .{dest_user_friendly});
            std.debug.print("  Hash: {s}\n", .{result.hash});
            std.debug.print("  LT: {d}\n", .{result.lt});
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

            var provider = try initDefaultProvider(allocator);

            const result = try ton_zig_agent_kit.paywatch.verifier.verifyPayment(&provider, &invoice);

            std.debug.print("Verification result:\n", .{});
            std.debug.print("  Verified: {any}\n", .{result.verified});
            if (result.tx_hash) |hash| {
                std.debug.print("  Transaction: {s}\n", .{hash});
            }
            if (result.amount) |amt| {
                std.debug.print("  Amount: {d} nanotons\n", .{amt});
            }
            if (result.sender) |sender| {
                std.debug.print("  Sender: {s}\n", .{sender});
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

            var provider = try initDefaultProvider(allocator);

            std.debug.print("Waiting for payment (timeout: 30s)...\n", .{});

            const result = try ton_zig_agent_kit.paywatch.watcher.waitPaymentWithClient(
                &provider,
                &invoice,
                5000, // 5s poll interval
                30000, // 30s timeout
            );

            if (result.found) {
                std.debug.print("Payment found!\n", .{});
                if (result.tx_hash) |hash| {
                    std.debug.print("  Transaction: {s}\n", .{hash});
                }
                if (result.amount) |amt| {
                    std.debug.print("  Amount: {d} nanotons\n", .{amt});
                }
                if (result.sender) |sender| {
                    std.debug.print("  Sender: {s}\n", .{sender});
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

const ParsedCliStackArgs = struct {
    args: []contract_mod.StackArg,
    owned_buffers: []?[]u8,

    fn deinit(self: *ParsedCliStackArgs, allocator: std.mem.Allocator) void {
        for (self.owned_buffers) |buffer| {
            if (buffer) |value| allocator.free(value);
        }
        allocator.free(self.owned_buffers);
        allocator.free(self.args);
        self.args = &.{};
        self.owned_buffers = &.{};
    }
};

const ParsedCliBodyOps = struct {
    ops: []BodyOp,
    owned_buffers: []?[]u8,

    fn deinit(self: *ParsedCliBodyOps, allocator: std.mem.Allocator) void {
        for (self.owned_buffers) |buffer| {
            if (buffer) |value| allocator.free(value);
        }
        allocator.free(self.owned_buffers);
        allocator.free(self.ops);
        self.ops = &.{};
        self.owned_buffers = &.{};
    }
};

const ParsedUintBodyOp = struct {
    bits: u16,
    value: u64,
};

const ParsedIntBodyOp = struct {
    bits: u16,
    value: i64,
};

const ParsedCliAbiValues = struct {
    values: []AbiValue,
    owned_buffers: []?[]u8,

    fn deinit(self: *ParsedCliAbiValues, allocator: std.mem.Allocator) void {
        for (self.owned_buffers) |buffer| {
            if (buffer) |value| allocator.free(value);
        }
        allocator.free(self.owned_buffers);
        allocator.free(self.values);
        self.values = &.{};
        self.owned_buffers = &.{};
    }
};

const ParsedCliAbiValue = struct {
    value: AbiValue,
    owned_buffer: ?[]u8 = null,
};

const CliNamedAbiSpec = struct {
    name: []const u8,
    value_spec: []const u8,
};

const CliWalletKeySource = enum {
    private_key_hex,
    seed_text,
    seed_file,
    explicit_seed_arg,
    explicit_private_key_hex_arg,
};

const CliWalletKeyMaterial = struct {
    private_key_seed: [32]u8,
    public_key: [32]u8,
    source: CliWalletKeySource,
};

fn parseCliBodyOps(allocator: std.mem.Allocator, specs: []const []const u8) !ParsedCliBodyOps {
    const parsed_ops = try allocator.alloc(BodyOp, specs.len);
    errdefer allocator.free(parsed_ops);

    const owned_buffers = try allocator.alloc(?[]u8, specs.len);
    for (owned_buffers) |*buffer| buffer.* = null;
    errdefer {
        for (owned_buffers) |buffer| {
            if (buffer) |value| allocator.free(value);
        }
        allocator.free(owned_buffers);
    }

    for (specs, 0..) |spec, i| {
        if (try parseCliUintOp(spec)) |value| {
            parsed_ops[i] = .{ .uint = .{
                .bits = value.bits,
                .value = value.value,
            } };
            continue;
        }

        if (try parseCliIntOp(spec)) |value| {
            parsed_ops[i] = .{ .int = .{
                .bits = value.bits,
                .value = value.value,
            } };
            continue;
        }

        if (std.mem.startsWith(u8, spec, "coins:")) {
            parsed_ops[i] = .{ .coins = try std.fmt.parseInt(u64, spec["coins:".len..], 10) };
            continue;
        }

        if (std.mem.startsWith(u8, spec, "addr:")) {
            parsed_ops[i] = .{ .address = spec["addr:".len..] };
            continue;
        }

        if (std.mem.startsWith(u8, spec, "bytes:")) {
            parsed_ops[i] = .{ .bytes = spec["bytes:".len..] };
            continue;
        }

        if (std.mem.startsWith(u8, spec, "hex:")) {
            const decoded = try hexToBytes(allocator, spec["hex:".len..]);
            owned_buffers[i] = decoded;
            parsed_ops[i] = .{ .bytes = decoded };
            continue;
        }

        if (std.mem.startsWith(u8, spec, "ref:")) {
            const decoded = try decodeBase64FlexibleAlloc(allocator, spec["ref:".len..]);
            owned_buffers[i] = decoded;
            parsed_ops[i] = .{ .ref_boc = decoded };
            continue;
        }

        if (std.mem.startsWith(u8, spec, "refhex:")) {
            const decoded = try hexToBytes(allocator, spec["refhex:".len..]);
            owned_buffers[i] = decoded;
            parsed_ops[i] = .{ .ref_boc = decoded };
            continue;
        }

        return error.InvalidBodyOpSpec;
    }

    return .{
        .ops = parsed_ops,
        .owned_buffers = owned_buffers,
    };
}

fn parseCliAbiValues(allocator: std.mem.Allocator, specs: []const []const u8) !ParsedCliAbiValues {
    const values = try allocator.alloc(AbiValue, specs.len);
    errdefer allocator.free(values);

    const owned_buffers = try allocator.alloc(?[]u8, specs.len);
    for (owned_buffers) |*buffer| buffer.* = null;
    errdefer {
        for (owned_buffers) |buffer| {
            if (buffer) |value| allocator.free(value);
        }
        allocator.free(owned_buffers);
    }

    for (specs, 0..) |spec, i| {
        if (std.mem.eql(u8, spec, "null")) {
            values[i] = .{ .null = {} };
            continue;
        }

        if (std.mem.startsWith(u8, spec, "u:")) {
            values[i] = .{ .uint = try parseStackUint(spec["u:".len..]) };
            continue;
        }

        if (std.mem.startsWith(u8, spec, "i:")) {
            values[i] = .{ .int = try parseStackInt(spec["i:".len..]) };
            continue;
        }

        if (std.mem.startsWith(u8, spec, "num:")) {
            values[i] = .{ .numeric_text = spec["num:".len..] };
            continue;
        }

        if (std.mem.startsWith(u8, spec, "str:")) {
            values[i] = .{ .text = spec["str:".len..] };
            continue;
        }

        if (std.mem.startsWith(u8, spec, "addr:")) {
            values[i] = .{ .text = spec["addr:".len..] };
            continue;
        }

        if (std.mem.startsWith(u8, spec, "json:")) {
            const json_text = try loadCliTextAlloc(allocator, spec["json:".len..]);
            owned_buffers[i] = json_text;
            values[i] = .{ .json = json_text };
            continue;
        }

        if (std.mem.startsWith(u8, spec, "hex:")) {
            const decoded = try hexToBytes(allocator, spec["hex:".len..]);
            owned_buffers[i] = decoded;
            values[i] = .{ .bytes = decoded };
            continue;
        }

        if (std.mem.startsWith(u8, spec, "boc:")) {
            const decoded = try decodeBase64FlexibleAlloc(allocator, spec["boc:".len..]);
            owned_buffers[i] = decoded;
            values[i] = .{ .boc = decoded };
            continue;
        }

        if (std.mem.startsWith(u8, spec, "bochex:")) {
            const decoded = try hexToBytes(allocator, spec["bochex:".len..]);
            owned_buffers[i] = decoded;
            values[i] = .{ .boc = decoded };
            continue;
        }

        return error.InvalidAbiValueSpec;
    }

    return .{
        .values = values,
        .owned_buffers = owned_buffers,
    };
}

fn parseCliAbiValuesForParams(
    allocator: std.mem.Allocator,
    params: []const contract_mod.abi_adapter.ParamDef,
    specs: []const []const u8,
) !ParsedCliAbiValues {
    if (cliAbiSpecsUseNamedSyntax(specs)) {
        return parseCliAbiValuesNamedForParams(allocator, params, specs);
    }
    return parseCliAbiValuesPositionalForParams(allocator, params, specs);
}

const CliAbiFunctionMatch = enum {
    exact,
    optional_missing,
};

fn resolveCliAbiFunction(
    abi: *const contract_mod.abi_adapter.AbiInfo,
    function_selector: []const u8,
    specs: []const []const u8,
) !*const contract_mod.abi_adapter.FunctionDef {
    if (!cliAbiSpecsUseNamedSyntax(specs)) {
        return contract_mod.abi_adapter.resolveFunctionByValueCount(abi, function_selector, specs.len);
    }

    const direct = contract_mod.abi_adapter.findFunction(abi, function_selector);
    if (std.mem.indexOfScalar(u8, std.mem.trim(u8, function_selector, " \t\r\n"), '(') != null) {
        return direct orelse error.FunctionNotFound;
    }

    var exact_match: ?*const contract_mod.abi_adapter.FunctionDef = null;
    var exact_count: usize = 0;
    var optional_match: ?*const contract_mod.abi_adapter.FunctionDef = null;
    var optional_count: usize = 0;

    for (abi.functions) |*function| {
        if (!std.mem.eql(u8, function.name, function_selector)) continue;

        const match = cliNamedSpecsMatchFunction(function.inputs, specs) orelse continue;
        switch (match) {
            .exact => {
                exact_count += 1;
                if (exact_match == null) exact_match = function;
            },
            .optional_missing => {
                optional_count += 1;
                if (optional_match == null) optional_match = function;
            },
        }
    }

    if (exact_match) |function| {
        if (exact_count > 1) return error.AmbiguousFunctionOverload;
        return function;
    }

    if (optional_match) |function| {
        if (optional_count > 1) return error.AmbiguousFunctionOverload;
        return function;
    }

    return error.FunctionNotFound;
}

fn cliNamedSpecsMatchFunction(
    params: []const contract_mod.abi_adapter.ParamDef,
    specs: []const []const u8,
) ?CliAbiFunctionMatch {
    if (specs.len > params.len) return null;

    for (specs, 0..) |spec, spec_idx| {
        const named = splitCliNamedAbiSpec(spec) orelse return null;
        const idx = findCliAbiParamIndex(params, named.name) orelse return null;

        for (specs[0..spec_idx]) |prev_spec| {
            const prev_named = splitCliNamedAbiSpec(prev_spec) orelse return null;
            const prev_idx = findCliAbiParamIndex(params, prev_named.name) orelse return null;
            if (prev_idx == idx) return null;
        }
    }

    if (specs.len == params.len) return .exact;

    for (params, 0..) |param, idx| {
        var seen = false;
        for (specs) |spec| {
            const named = splitCliNamedAbiSpec(spec) orelse return null;
            const spec_idx = findCliAbiParamIndex(params, named.name) orelse return null;
            if (spec_idx == idx) {
                seen = true;
                break;
            }
        }

        if (!seen and inspectOptionalInnerType(param.type_name) == null) return null;
    }

    return .optional_missing;
}

fn parseCliAbiValuesPositionalForParams(
    allocator: std.mem.Allocator,
    params: []const contract_mod.abi_adapter.ParamDef,
    specs: []const []const u8,
) !ParsedCliAbiValues {
    if (specs.len > params.len) return error.InvalidAbiArguments;

    const values = try allocator.alloc(AbiValue, params.len);
    errdefer allocator.free(values);

    const owned_buffers = try allocator.alloc(?[]u8, params.len);
    for (owned_buffers) |*buffer| buffer.* = null;
    errdefer {
        for (owned_buffers) |buffer| {
            if (buffer) |value| allocator.free(value);
        }
        allocator.free(owned_buffers);
    }

    for (specs, 0..) |spec, idx| {
        const parsed = try parseCliAbiValueSpec(allocator, spec);
        values[idx] = parsed.value;
        owned_buffers[idx] = parsed.owned_buffer;
    }

    for (params[specs.len..], specs.len..) |param, idx| {
        if (inspectOptionalInnerType(param.type_name) == null) return error.MissingAbiArgument;
        values[idx] = .{ .null = {} };
        owned_buffers[idx] = null;
    }

    return .{
        .values = values,
        .owned_buffers = owned_buffers,
    };
}

fn parseCliAbiValuesNamedForParams(
    allocator: std.mem.Allocator,
    params: []const contract_mod.abi_adapter.ParamDef,
    specs: []const []const u8,
) !ParsedCliAbiValues {
    const values = try allocator.alloc(AbiValue, params.len);
    errdefer allocator.free(values);

    const owned_buffers = try allocator.alloc(?[]u8, params.len);
    for (owned_buffers) |*buffer| buffer.* = null;
    errdefer {
        for (owned_buffers) |buffer| {
            if (buffer) |value| allocator.free(value);
        }
        allocator.free(owned_buffers);
    }

    const seen = try allocator.alloc(bool, params.len);
    defer allocator.free(seen);
    @memset(seen, false);

    for (specs) |spec| {
        const named = splitCliNamedAbiSpec(spec) orelse return error.MixedAbiArgumentStyles;
        const idx = findCliAbiParamIndex(params, named.name) orelse return error.UnknownAbiParameter;
        if (seen[idx]) return error.DuplicateAbiParameter;

        const parsed = try parseCliAbiValueSpec(allocator, named.value_spec);
        values[idx] = parsed.value;
        owned_buffers[idx] = parsed.owned_buffer;
        seen[idx] = true;
    }

    for (params, 0..) |param, idx| {
        if (seen[idx]) continue;
        if (inspectOptionalInnerType(param.type_name) == null) return error.MissingAbiArgument;
        values[idx] = .{ .null = {} };
        owned_buffers[idx] = null;
    }

    return .{
        .values = values,
        .owned_buffers = owned_buffers,
    };
}

fn parseCliAbiValueSpec(allocator: std.mem.Allocator, spec: []const u8) !ParsedCliAbiValue {
    if (std.mem.eql(u8, spec, "null")) {
        return .{ .value = .{ .null = {} } };
    }

    if (std.mem.startsWith(u8, spec, "u:")) {
        return .{ .value = .{ .uint = try parseStackUint(spec["u:".len..]) } };
    }

    if (std.mem.startsWith(u8, spec, "i:")) {
        return .{ .value = .{ .int = try parseStackInt(spec["i:".len..]) } };
    }

    if (std.mem.startsWith(u8, spec, "num:")) {
        return .{ .value = .{ .numeric_text = spec["num:".len..] } };
    }

    if (std.mem.startsWith(u8, spec, "str:")) {
        return .{ .value = .{ .text = spec["str:".len..] } };
    }

    if (std.mem.startsWith(u8, spec, "addr:")) {
        return .{ .value = .{ .text = spec["addr:".len..] } };
    }

    if (std.mem.startsWith(u8, spec, "json:")) {
        const json_text = try loadCliTextAlloc(allocator, spec["json:".len..]);
        return .{
            .value = .{ .json = json_text },
            .owned_buffer = json_text,
        };
    }

    if (std.mem.startsWith(u8, spec, "hex:")) {
        const decoded = try hexToBytes(allocator, spec["hex:".len..]);
        return .{
            .value = .{ .bytes = decoded },
            .owned_buffer = decoded,
        };
    }

    if (std.mem.startsWith(u8, spec, "boc:")) {
        const decoded = try decodeBase64FlexibleAlloc(allocator, spec["boc:".len..]);
        return .{
            .value = .{ .boc = decoded },
            .owned_buffer = decoded,
        };
    }

    if (std.mem.startsWith(u8, spec, "bochex:")) {
        const decoded = try hexToBytes(allocator, spec["bochex:".len..]);
        return .{
            .value = .{ .boc = decoded },
            .owned_buffer = decoded,
        };
    }

    return error.InvalidAbiValueSpec;
}

fn cliAbiSpecsUseNamedSyntax(specs: []const []const u8) bool {
    for (specs) |spec| {
        if (splitCliNamedAbiSpec(spec) != null) return true;
    }
    return false;
}

fn splitCliNamedAbiSpec(spec: []const u8) ?CliNamedAbiSpec {
    const eq_idx = std.mem.indexOfScalar(u8, spec, '=') orelse return null;
    if (eq_idx == 0 or eq_idx + 1 > spec.len) return null;

    const name = spec[0..eq_idx];
    if (std.mem.indexOfScalar(u8, name, ':') != null) return null;
    if (std.mem.indexOfAny(u8, name, " \t\r\n") != null) return null;

    return .{
        .name = name,
        .value_spec = spec[eq_idx + 1 ..],
    };
}

fn findCliAbiParamIndex(params: []const contract_mod.abi_adapter.ParamDef, name: []const u8) ?usize {
    for (params, 0..) |param, idx| {
        if (param.name.len > 0 and std.mem.eql(u8, param.name, name)) return idx;

        var fallback_buf: [32]u8 = undefined;
        const fallback_name = std.fmt.bufPrint(&fallback_buf, "arg{d}", .{idx}) catch continue;
        if (std.mem.eql(u8, fallback_name, name)) return idx;
    }
    return null;
}

fn loadCliTextAlloc(allocator: std.mem.Allocator, spec: []const u8) ![]u8 {
    if (spec.len > 1 and spec[0] == '@') {
        return std.fs.cwd().readFileAlloc(allocator, spec[1..], 1 << 20);
    }
    return allocator.dupe(u8, spec);
}

fn loadCliWalletKeyMaterial(allocator: std.mem.Allocator) !CliWalletKeyMaterial {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    return loadCliWalletKeyMaterialFromEnvMap(allocator, &env_map);
}

const WalletBootstrapOptions = struct {
    wallet_version: signing.WalletVersion = .v4,
    workchain: i8 = 0,
    wallet_id: u32 = signing.default_wallet_id_v4,
    key_spec: ?[]const u8 = null,
};

fn maybeParseWalletVersionArg(value: []const u8) ?signing.WalletVersion {
    if (std.mem.eql(u8, value, "v4")) return .v4;
    if (std.mem.eql(u8, value, "v5")) return .v5;
    return null;
}

fn maybeParseCliInt(comptime T: type, value: []const u8) !?T {
    return std.fmt.parseInt(T, value, 10) catch |err| switch (err) {
        error.InvalidCharacter => null,
        else => err,
    };
}

fn parseWalletBootstrapOptions(args: []const []const u8) !WalletBootstrapOptions {
    var out = WalletBootstrapOptions{};
    var idx: usize = 0;
    var explicit_version = false;
    var explicit_wallet_id = false;

    if (idx < args.len) {
        if (maybeParseWalletVersionArg(args[idx])) |wallet_version| {
            out.wallet_version = wallet_version;
            explicit_version = true;
            idx += 1;
        }
    }

    if (idx < args.len) {
        if (try maybeParseCliInt(i8, args[idx])) |workchain| {
            out.workchain = workchain;
            idx += 1;
        }
    }

    if (idx < args.len) {
        if (try maybeParseCliInt(u32, args[idx])) |wallet_id| {
            out.wallet_id = wallet_id;
            explicit_wallet_id = true;
            idx += 1;
        }
    }

    if (idx < args.len) {
        out.key_spec = args[idx];
        idx += 1;
    }

    if (idx != args.len) return error.InvalidWalletBootstrapArguments;

    if (explicit_version) {
        if (!explicit_wallet_id) {
            out.wallet_id = try signing.defaultWalletIdForVersion(out.wallet_version);
        }
    } else {
        out.wallet_version = signing.inferWalletVersionFromWalletId(out.wallet_id);
    }

    return out;
}

fn loadCliWalletKeyMaterialWithOptionalSpec(
    allocator: std.mem.Allocator,
    key_spec: ?[]const u8,
) !CliWalletKeyMaterial {
    if (key_spec) |value| return loadCliWalletKeyMaterialFromSpec(allocator, value);
    return loadCliWalletKeyMaterial(allocator);
}

fn loadCliWalletKeyMaterialFromEnvMap(
    allocator: std.mem.Allocator,
    env_map: *const std.process.EnvMap,
) !CliWalletKeyMaterial {
    if (env_map.get(wallet_private_key_hex_env)) |value| {
        return cliWalletKeyMaterialFromPrivateKeyHexAlloc(allocator, value, .private_key_hex);
    }

    if (env_map.get(wallet_seed_file_env)) |value| {
        const seed_text = try std.fs.cwd().readFileAlloc(allocator, value, 1 << 20);
        defer allocator.free(seed_text);
        return cliWalletKeyMaterialFromSeedText(seed_text, .seed_file);
    }

    if (env_map.get(wallet_seed_env)) |value| {
        return cliWalletKeyMaterialFromSeedText(value, .seed_text);
    }

    return error.MissingWalletKeyMaterial;
}

fn loadCliWalletKeyMaterialFromSpec(allocator: std.mem.Allocator, spec: []const u8) !CliWalletKeyMaterial {
    if (std.mem.startsWith(u8, spec, "hex:")) {
        return cliWalletKeyMaterialFromPrivateKeyHexAlloc(allocator, spec["hex:".len..], .explicit_private_key_hex_arg);
    }

    const seed_text = try loadCliTextAlloc(allocator, spec);
    defer allocator.free(seed_text);
    return cliWalletKeyMaterialFromSeedText(seed_text, .explicit_seed_arg);
}

fn cliWalletKeyMaterialFromSeedText(
    seed_text: []const u8,
    source: CliWalletKeySource,
) !CliWalletKeyMaterial {
    const trimmed = std.mem.trim(u8, seed_text, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidWalletSeed;

    const keypair = try signing.generateKeypair(trimmed);
    return .{
        .private_key_seed = keypair[0],
        .public_key = keypair[1],
        .source = source,
    };
}

fn cliWalletKeyMaterialFromPrivateKeyHexAlloc(
    allocator: std.mem.Allocator,
    private_key_hex: []const u8,
    source: CliWalletKeySource,
) !CliWalletKeyMaterial {
    const private_key_seed = try parseCliWalletPrivateKeyHexAlloc(allocator, private_key_hex);
    return .{
        .private_key_seed = private_key_seed,
        .public_key = try signing.derivePublicKey(private_key_seed),
        .source = source,
    };
}

fn parseCliWalletPrivateKeyHexAlloc(
    allocator: std.mem.Allocator,
    private_key_hex: []const u8,
) ![32]u8 {
    const trimmed = std.mem.trim(u8, private_key_hex, " \t\r\n");
    const body = if (std.mem.startsWith(u8, trimmed, "0x") or std.mem.startsWith(u8, trimmed, "0X"))
        trimmed[2..]
    else
        trimmed;

    const decoded = try hexToBytes(allocator, body);
    defer allocator.free(decoded);

    if (decoded.len != 32) return error.InvalidWalletPrivateKey;

    var out: [32]u8 = undefined;
    @memcpy(&out, decoded[0..32]);
    return out;
}

fn printWalletKeyLoadError(err: anyerror) void {
    std.debug.print("Wallet key load failed: {s}\n", .{@errorName(err)});
    std.debug.print("Set {s}=<64 hex>, or {s}=<seed text>, or {s}=<path-to-seed-file>\n", .{
        wallet_private_key_hex_env,
        wallet_seed_env,
        wallet_seed_file_env,
    });
}

fn walletKeySourceLabel(source: CliWalletKeySource) []const u8 {
    return switch (source) {
        .private_key_hex => wallet_private_key_hex_env,
        .seed_text => wallet_seed_env,
        .seed_file => wallet_seed_file_env,
        .explicit_seed_arg => "cli-seed",
        .explicit_private_key_hex_arg => "cli-private-key-hex",
    };
}

fn buildCliWalletSignedMessageAuto(
    allocator: std.mem.Allocator,
    provider: *MultiProvider,
    private_key: [32]u8,
    message: signing.WalletMessage,
) !signing.BuiltWalletExternalMessage {
    var messages = [_]signing.WalletMessage{message};
    return signing.buildSignedMessagesAutoAlloc(
        provider,
        allocator,
        .auto,
        private_key,
        null,
        0,
        signing.default_wallet_id_v4,
        messages[0..],
    );
}

fn printBuiltWalletExternalMessage(
    allocator: std.mem.Allocator,
    destination: []const u8,
    amount: u64,
    built: *const signing.BuiltWalletExternalMessage,
) !void {
    const encoded_len = std.base64.standard.Encoder.calcSize(built.boc.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, built.boc);

    std.debug.print("Built signed wallet external message:\n", .{});
    std.debug.print("  Wallet: {s}\n", .{built.wallet_address});
    std.debug.print("  Version: {s}\n", .{signing.walletVersionName(built.version)});
    std.debug.print("  Destination: {s}\n", .{destination});
    std.debug.print("  Amount: {d}\n", .{amount});
    std.debug.print("  Wallet ID: {d} (0x{X:0>8})\n", .{ built.wallet_id, built.wallet_id });
    std.debug.print("  Seqno: {d}\n", .{built.seqno});
    std.debug.print("  StateInit attached: {s}\n", .{if (built.state_init_attached) "yes" else "no"});
    std.debug.print("  External BoC: {s}\n", .{encoded});
    std.debug.print("  External Hex: ", .{});
    for (built.boc) |byte| {
        std.debug.print("{X:0>2}", .{byte});
    }
    std.debug.print("\n", .{});
}

fn parseCliStackArgs(allocator: std.mem.Allocator, specs: []const []const u8) !ParsedCliStackArgs {
    const parsed_args = try allocator.alloc(contract_mod.StackArg, specs.len);
    errdefer allocator.free(parsed_args);

    const owned_buffers = try allocator.alloc(?[]u8, specs.len);
    for (owned_buffers) |*buffer| buffer.* = null;
    errdefer {
        for (owned_buffers) |buffer| {
            if (buffer) |value| allocator.free(value);
        }
        allocator.free(owned_buffers);
    }

    for (specs, 0..) |spec, i| {
        if (std.mem.eql(u8, spec, "null")) {
            parsed_args[i] = .{ .null = {} };
            continue;
        }

        if (std.mem.startsWith(u8, spec, "int:")) {
            parsed_args[i] = .{ .int = try parseStackInt(spec["int:".len..]) };
            continue;
        }

        if (std.mem.startsWith(u8, spec, "addr:")) {
            parsed_args[i] = .{ .address = spec["addr:".len..] };
            continue;
        }

        if (std.mem.startsWith(u8, spec, "cell:")) {
            const decoded = try decodeBase64FlexibleAlloc(allocator, spec["cell:".len..]);
            owned_buffers[i] = decoded;
            parsed_args[i] = .{ .cell = decoded };
            continue;
        }

        if (std.mem.startsWith(u8, spec, "slice:")) {
            const decoded = try decodeBase64FlexibleAlloc(allocator, spec["slice:".len..]);
            owned_buffers[i] = decoded;
            parsed_args[i] = .{ .slice = decoded };
            continue;
        }

        if (std.mem.startsWith(u8, spec, "builder:")) {
            const decoded = try decodeBase64FlexibleAlloc(allocator, spec["builder:".len..]);
            owned_buffers[i] = decoded;
            parsed_args[i] = .{ .builder = decoded };
            continue;
        }

        if (std.mem.startsWith(u8, spec, "cellhex:")) {
            const decoded = try hexToBytes(allocator, spec["cellhex:".len..]);
            owned_buffers[i] = decoded;
            parsed_args[i] = .{ .cell = decoded };
            continue;
        }

        if (std.mem.startsWith(u8, spec, "slicehex:")) {
            const decoded = try hexToBytes(allocator, spec["slicehex:".len..]);
            owned_buffers[i] = decoded;
            parsed_args[i] = .{ .slice = decoded };
            continue;
        }

        if (std.mem.startsWith(u8, spec, "builderhex:")) {
            const decoded = try hexToBytes(allocator, spec["builderhex:".len..]);
            owned_buffers[i] = decoded;
            parsed_args[i] = .{ .builder = decoded };
            continue;
        }

        return error.InvalidStackArgSpec;
    }

    return .{
        .args = parsed_args,
        .owned_buffers = owned_buffers,
    };
}

fn parseStackInt(text: []const u8) !i64 {
    if (std.mem.startsWith(u8, text, "-0x")) {
        const magnitude = try std.fmt.parseInt(u64, text[3..], 16);
        if (magnitude > @as(u64, @intCast(std.math.maxInt(i64))) + 1) return error.Overflow;
        return -@as(i64, @intCast(magnitude));
    }
    if (std.mem.startsWith(u8, text, "0x")) {
        return @intCast(try std.fmt.parseInt(u64, text[2..], 16));
    }
    return std.fmt.parseInt(i64, text, 10);
}

fn parseCliUintOp(spec: []const u8) !?ParsedUintBodyOp {
    if (spec.len < 3 or spec[0] != 'u') return null;

    const sep = std.mem.indexOfScalar(u8, spec, ':') orelse return null;
    if (sep == 1) return error.InvalidBodyOpSpec;

    const bits = try std.fmt.parseInt(u16, spec[1..sep], 10);
    const value = try parseStackUint(spec[sep + 1 ..]);
    return .{
        .bits = bits,
        .value = value,
    };
}

fn parseCliIntOp(spec: []const u8) !?ParsedIntBodyOp {
    if (spec.len < 3 or spec[0] != 'i') return null;

    const sep = std.mem.indexOfScalar(u8, spec, ':') orelse return null;
    if (sep == 1) return error.InvalidBodyOpSpec;

    const bits = try std.fmt.parseInt(u16, spec[1..sep], 10);
    const value = try parseStackInt(spec[sep + 1 ..]);
    return .{
        .bits = bits,
        .value = value,
    };
}

fn parseStackUint(text: []const u8) !u64 {
    if (std.mem.startsWith(u8, text, "0x")) {
        return std.fmt.parseInt(u64, text[2..], 16);
    }
    return std.fmt.parseInt(u64, text, 10);
}

fn decodeBase64FlexibleAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return decodeBase64WithDecoder(allocator, input, std.base64.standard.Decoder) catch
        decodeBase64WithDecoder(allocator, input, std.base64.url_safe.Decoder);
}

fn decodeBase64WithDecoder(allocator: std.mem.Allocator, input: []const u8, comptime decoder: anytype) ![]u8 {
    const decoded_len = try decoder.calcSizeForSlice(input);
    const output = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(output);
    try decoder.decode(output, input);
    return output;
}

fn printMessageAddressLine(
    allocator: std.mem.Allocator,
    label: []const u8,
    maybe_addr: ?ton_zig_agent_kit.core.types.Address,
) void {
    if (maybe_addr) |addr| {
        const raw = addr.toRawAlloc(allocator) catch {
            std.debug.print("  {s}: (format failed)\n", .{label});
            return;
        };
        defer allocator.free(raw);
        std.debug.print("  {s}: {s}\n", .{ label, raw });
        return;
    }

    std.debug.print("  {s}: (none)\n", .{label});
}

fn tryDecodeMessageFunctionAtAlloc(
    allocator: std.mem.Allocator,
    provider: anytype,
    owned_contract_address: []u8,
    body_boc: []const u8,
) ?CliDecodedMessageBody {
    var abi = contract_mod.abi_adapter.queryAbiDocumentAlloc(provider, owned_contract_address) catch {
        allocator.free(owned_contract_address);
        return null;
    } orelse {
        allocator.free(owned_contract_address);
        return null;
    };
    defer abi.deinit(allocator);

    const function = contract_mod.abi_adapter.resolveFunctionByBodyBoc(&abi.abi, null, body_boc) catch {
        allocator.free(owned_contract_address);
        return null;
    };

    const selector = contract_mod.abi_adapter.buildFunctionSelectorAlloc(allocator, function.*) catch {
        allocator.free(owned_contract_address);
        return null;
    };

    const decoded_json = contract_mod.abi_adapter.decodeFunctionBodyJsonAlloc(allocator, function.*, body_boc) catch {
        allocator.free(selector);
        allocator.free(owned_contract_address);
        return null;
    };

    return .{
        .kind = .function,
        .contract_address = owned_contract_address,
        .selector = selector,
        .opcode = function.opcode,
        .decoded_json = decoded_json,
    };
}

fn tryDecodeMessageEventAtAlloc(
    allocator: std.mem.Allocator,
    provider: anytype,
    owned_contract_address: []u8,
    body_boc: []const u8,
) ?CliDecodedMessageBody {
    var abi = contract_mod.abi_adapter.queryAbiDocumentAlloc(provider, owned_contract_address) catch {
        allocator.free(owned_contract_address);
        return null;
    } orelse {
        allocator.free(owned_contract_address);
        return null;
    };
    defer abi.deinit(allocator);

    const event = contract_mod.abi_adapter.resolveEventByBodyBoc(&abi.abi, null, body_boc) catch {
        allocator.free(owned_contract_address);
        return null;
    };

    const selector = contract_mod.abi_adapter.buildEventSelectorAlloc(allocator, event.*) catch {
        allocator.free(owned_contract_address);
        return null;
    };

    const decoded_json = contract_mod.abi_adapter.decodeEventBodyJsonAlloc(allocator, event.*, body_boc) catch {
        allocator.free(selector);
        allocator.free(owned_contract_address);
        return null;
    };

    return .{
        .kind = .event,
        .contract_address = owned_contract_address,
        .selector = selector,
        .opcode = event.opcode,
        .decoded_json = decoded_json,
    };
}

fn tryDecodeMessageBodyAutoAlloc(
    allocator: std.mem.Allocator,
    provider: anytype,
    msg: *const Message,
) ?CliDecodedMessageBody {
    const body = msg.body orelse return null;
    const body_boc = boc.serializeBoc(allocator, body) catch return null;
    defer allocator.free(body_boc);

    if (msg.destination) |addr| {
        const raw = addr.toRawAlloc(allocator) catch return null;
        if (tryDecodeMessageFunctionAtAlloc(allocator, provider, raw, body_boc)) |decoded| {
            return decoded;
        }
    }

    if (msg.source) |addr| {
        const raw = addr.toRawAlloc(allocator) catch return null;
        if (tryDecodeMessageEventAtAlloc(allocator, provider, raw, body_boc)) |decoded| {
            return decoded;
        }
    }

    return null;
}

fn printMessageDetails(
    allocator: std.mem.Allocator,
    provider: anytype,
    label: []const u8,
    msg_opt: ?*const Message,
) void {
    std.debug.print("{s}:\n", .{label});

    const msg = msg_opt orelse {
        std.debug.print("  (none)\n", .{});
        return;
    };

    if (msg.hash.len > 0) {
        std.debug.print("  Hash: {s}\n", .{msg.hash});
    }
    printMessageAddressLine(allocator, "Source", msg.source);
    printMessageAddressLine(allocator, "Destination", msg.destination);
    std.debug.print("  Value: {d}\n", .{msg.value});
    if (msg.body) |body| {
        std.debug.print("  Body: {d} bits, {d} refs\n", .{ body.bit_len, body.ref_cnt });
    } else {
        std.debug.print("  Body: (none)\n", .{});
    }
    if (msg.raw_body.len > 0) {
        std.debug.print("  Raw body bytes: {d}\n", .{msg.raw_body.len});
        if (std.unicode.utf8ValidateSlice(msg.raw_body)) {
            std.debug.print("  Raw body text: {s}\n", .{msg.raw_body});
        }
    }
    if (msg.body) |body| {
        printBodyAnalysis(allocator, body);
    }

    if (tryDecodeMessageBodyAutoAlloc(allocator, provider, msg)) |decoded| {
        defer {
            var owned = decoded;
            owned.deinit(allocator);
        }
        std.debug.print("  ABI decoded as {s} on {s}\n", .{
            switch (decoded.kind) {
                .function => "function",
                .event => "event",
            },
            decoded.contract_address,
        });
        std.debug.print("  ABI selector: {s}\n", .{decoded.selector});
        if (decoded.opcode) |opcode| {
            std.debug.print("  ABI opcode: 0x{X}\n", .{opcode});
        }
        std.debug.print("  ABI json:\n{s}\n", .{decoded.decoded_json});
    }
}

fn printBodyAnalysis(allocator: std.mem.Allocator, body: *const Cell) void {
    var analysis = ton_zig_agent_kit.core.body_inspector.inspectBodyCellAlloc(allocator, body) catch return;
    defer analysis.deinit(allocator);

    if (analysis.opcode) |opcode| {
        std.debug.print("  Body opcode: 0x{X}\n", .{opcode});
    }
    if (analysis.opcode_name) |value| {
        std.debug.print("  Body opcode name: {s}\n", .{value});
    }
    if (analysis.comment) |value| {
        std.debug.print("  Body comment: {s}\n", .{value});
    }
    if (analysis.tail_utf8) |value| {
        std.debug.print("  Body UTF-8 tail: {s}\n", .{value});
    }
    if (analysis.decoded_json) |value| {
        std.debug.print("  Body decoded:\n{s}\n", .{value});
        if (analysis.opcode_name) |opcode_name| {
            if (standardBodyBuildTemplate(opcode_name)) |template| {
                std.debug.print("  Body reusable spec:\n{s}\n", .{value});
                std.debug.print("  Build standard: {s}\n", .{template});
            }
        }
    }
}

fn standardBodyBuildTemplate(opcode_name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, opcode_name, "comment")) return "ton-zig-agent-kit cell build-standard comment @spec.json";
    if (std.mem.eql(u8, opcode_name, "jetton_transfer")) return "ton-zig-agent-kit cell build-standard jetton_transfer @spec.json";
    if (std.mem.eql(u8, opcode_name, "jetton_internal_transfer")) return "ton-zig-agent-kit cell build-standard jetton_internal_transfer @spec.json";
    if (std.mem.eql(u8, opcode_name, "jetton_transfer_notification")) return "ton-zig-agent-kit cell build-standard jetton_transfer_notification @spec.json";
    if (std.mem.eql(u8, opcode_name, "jetton_burn")) return "ton-zig-agent-kit cell build-standard jetton_burn @spec.json";
    if (std.mem.eql(u8, opcode_name, "nft_transfer")) return "ton-zig-agent-kit cell build-standard nft_transfer @spec.json";
    return null;
}

fn printTransactionDetails(
    allocator: std.mem.Allocator,
    provider: anytype,
    tx: *const Transaction,
) void {
    std.debug.print("Transaction:\n", .{});
    std.debug.print("  Hash: {s}\n", .{tx.hash});
    std.debug.print("  LT: {d}\n", .{tx.lt});
    std.debug.print("  Timestamp: {d}\n", .{tx.timestamp});

    printMessageDetails(allocator, provider, "In message", tx.in_msg);

    std.debug.print("Out messages: {d}\n", .{tx.out_msgs.len});
    for (tx.out_msgs, 0..) |msg, idx| {
        var label_buf: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "Out message #{d}", .{idx}) catch "Out message";
        printMessageDetails(allocator, provider, label, msg);
    }
}

fn printRunGetMethodResult(allocator: std.mem.Allocator, result: ton_zig_agent_kit.core.types.RunGetMethodResponse) !void {
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

    const unsupported_count = ton_zig_agent_kit.core.countUnsupportedStackEntries(result.stack);
    if (unsupported_count > 0) {
        const summary_json = try ton_zig_agent_kit.core.summarizeStackJsonAlloc(allocator, result.stack);
        defer allocator.free(summary_json);

        std.debug.print("Stack analysis ({d} unsupported entries):\n{s}\n", .{ unsupported_count, summary_json });
    }
}

fn printStackEntry(entry: StackEntry, indent: usize) void {
    switch (entry) {
        .null => std.debug.print("null\n", .{}),
        .number => |value| std.debug.print("number: {d}\n", .{value}),
        .big_number => |value| std.debug.print("number: {s}\n", .{value}),
        .unsupported => |value| std.debug.print("unsupported/raw: {s}\n", .{value}),
        .bytes => |value| std.debug.print("bytes/base64: {s}\n", .{value}),
        .cell => |value| std.debug.print("cell(bits={d}, refs={d})\n", .{ value.bit_len, value.ref_cnt }),
        .slice => |value| std.debug.print("slice(bits={d}, refs={d})\n", .{ value.bit_len, value.ref_cnt }),
        .builder => |value| std.debug.print("builder(bits={d}, refs={d})\n", .{ value.bit_len, value.ref_cnt }),
        .tuple => |items| {
            std.debug.print("tuple[{d}]\n", .{items.len});
            for (items, 0..) |child, i| {
                printIndent(indent);
                std.debug.print("[{d}] ", .{i});
                printStackEntry(child, indent + 2);
            }
        },
        .list => |items| {
            std.debug.print("list[{d}]\n", .{items.len});
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

fn printInspectWalletDetails(provider: *ton_zig_agent_kit.core.MultiProvider, addr: []const u8) void {
    const info = signing.getWalletInfo(provider, addr) catch |err| {
        std.debug.print("Wallet details: read failed ({s})\n", .{@errorName(err)});
        return;
    };

    std.debug.print("Wallet details:\n", .{});
    std.debug.print("  Seqno: {d}\n", .{info.seqno});
    std.debug.print("  Subwallet ID: {d} (0x{X:0>8})\n", .{ info.wallet_id, info.wallet_id });
    std.debug.print("  Public key: ", .{});
    for (info.public_key) |byte| {
        std.debug.print("{X:0>2}", .{byte});
    }
    std.debug.print("\n", .{});
}

fn printInspectJettonMasterDetails(allocator: std.mem.Allocator, provider: *ton_zig_agent_kit.core.MultiProvider, addr: []const u8) void {
    var master = contract_mod.jetton.ProviderJettonMaster.init(addr, provider);
    var data = master.getJettonData() catch |err| {
        std.debug.print("Jetton master details: read failed ({s})\n", .{@errorName(err)});
        return;
    };
    defer data.deinit(allocator);

    const total_supply = std.fmt.allocPrint(allocator, "{d}", .{data.total_supply}) catch |err| {
        std.debug.print("Jetton master details: format failed ({s})\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(total_supply);

    const admin = if (data.admin) |value|
        ton_zig_agent_kit.core.address.formatRaw(allocator, &value) catch |err| {
            std.debug.print("Jetton master details: admin format failed ({s})\n", .{@errorName(err)});
            return;
        }
    else
        null;
    defer if (admin) |value| allocator.free(value);

    std.debug.print("Jetton master details:\n", .{});
    std.debug.print("  Total supply: {s}\n", .{total_supply});
    std.debug.print("  Mintable: {s}\n", .{if (data.mintable) "yes" else "no"});
    std.debug.print("  Admin: {s}\n", .{admin orelse "(none)"});
    std.debug.print("  Content URI: {s}\n", .{data.content_uri orelse "(none)"});
}

fn printInspectJettonWalletDetails(provider: *ton_zig_agent_kit.core.MultiProvider, addr: []const u8) void {
    var wallet_contract = contract_mod.jetton.ProviderJettonWallet.init(addr, provider);
    var data = wallet_contract.getWalletData() catch |err| {
        std.debug.print("Jetton wallet details: read failed ({s})\n", .{@errorName(err)});
        return;
    };
    defer data.deinit(provider.allocator);

    std.debug.print("Jetton wallet details:\n", .{});
    std.debug.print("  Balance: {d}\n", .{data.balance});
    std.debug.print("  Owner: {s}\n", .{data.owner});
    std.debug.print("  Master: {s}\n", .{data.master});
}

fn printInspectNFTItemDetails(allocator: std.mem.Allocator, provider: *ton_zig_agent_kit.core.MultiProvider, addr: []const u8) void {
    var item = contract_mod.nft.ProviderNFTItem.init(addr, provider);
    var data = item.getNFTData() catch |err| {
        std.debug.print("NFT item details: read failed ({s})\n", .{@errorName(err)});
        return;
    };
    defer data.deinit(allocator);

    const owner = if (data.owner) |value|
        ton_zig_agent_kit.core.address.formatRaw(allocator, &value) catch |err| {
            std.debug.print("NFT item details: owner format failed ({s})\n", .{@errorName(err)});
            return;
        }
    else
        null;
    defer if (owner) |value| allocator.free(value);

    const collection = if (data.collection) |value|
        ton_zig_agent_kit.core.address.formatRaw(allocator, &value) catch |err| {
            std.debug.print("NFT item details: collection format failed ({s})\n", .{@errorName(err)});
            return;
        }
    else
        null;
    defer if (collection) |value| allocator.free(value);

    std.debug.print("NFT item details:\n", .{});
    std.debug.print("  Index: {d}\n", .{data.index});
    std.debug.print("  Owner: {s}\n", .{owner orelse "(none)"});
    std.debug.print("  Collection: {s}\n", .{collection orelse "(none)"});
    std.debug.print("  Content URI: {s}\n", .{data.content_uri orelse "(none)"});
}

fn printInspectNFTCollectionDetails(allocator: std.mem.Allocator, provider: *ton_zig_agent_kit.core.MultiProvider, addr: []const u8) void {
    var collection = contract_mod.nft.ProviderNFTCollection.init(addr, provider);
    var data = collection.getCollectionData() catch |err| {
        std.debug.print("NFT collection details: read failed ({s})\n", .{@errorName(err)});
        return;
    };
    defer data.deinit(allocator);

    const owner = if (data.owner) |value|
        ton_zig_agent_kit.core.address.formatRaw(allocator, &value) catch |err| {
            std.debug.print("NFT collection details: owner format failed ({s})\n", .{@errorName(err)});
            return;
        }
    else
        null;
    defer if (owner) |value| allocator.free(value);

    std.debug.print("NFT collection details:\n", .{});
    std.debug.print("  Owner: {s}\n", .{owner orelse "(none)"});
    std.debug.print("  Next item index: {d}\n", .{data.next_item_index});
    std.debug.print("  Content URI: {s}\n", .{data.content_uri orelse "(none)"});
}

fn printInspectObservedMessages(items: []const ton_zig_agent_kit.tools.tools_mod.ObservedMessageSummaryResult) void {
    if (items.len == 0) return;

    std.debug.print("Observed messages:\n", .{});
    for (items) |item| {
        std.debug.print("  - {s}", .{switch (item.direction) {
            .incoming => "incoming",
            .outgoing => "outgoing",
        }});
        if (item.count > 1) {
            std.debug.print(" x{d}", .{item.count});
        }
        if (item.opcode) |opcode| {
            std.debug.print(" op=0x{X}", .{opcode});
        }
        if (item.opcode_name) |value| {
            std.debug.print(" {s}", .{value});
        }
        if (item.abi_kind) |kind| {
            std.debug.print(" {s}", .{switch (kind) {
                .function => "function",
                .event => "event",
            }});
        }
        if (item.abi_selector) |value| {
            std.debug.print(" {s}", .{value});
        }
        if (item.comment) |value| {
            std.debug.print(" comment={s}", .{value});
        } else if (item.utf8_tail) |value| {
            std.debug.print(" text={s}", .{value});
        }
        std.debug.print("\n", .{});
        if (item.template) |value| {
            if (value.body_cli_template) |template| {
                std.debug.print("      body: {s}\n", .{template});
            }
            if (value.send_cli_template) |template| {
                std.debug.print("      send: {s}\n", .{template});
            }
            if (value.example_spec_json) |spec| {
                std.debug.print("      spec: {s}\n", .{spec});
            }
            if (value.note) |note| {
                std.debug.print("      note: {s}\n", .{note});
            }
        }
    }
}

fn printInspectAbiDocument(abi: *const contract_mod.abi_adapter.AbiInfo) void {
    if (abi.functions.len > 0) {
        const shown = @min(abi.functions.len, inspect_abi_list_limit);
        std.debug.print("ABI functions:\n", .{});
        for (abi.functions[0..shown]) |function| {
            printAbiFunctionSignature(function);
        }
        if (abi.functions.len > shown) {
            std.debug.print("  ... {d} more functions omitted\n", .{abi.functions.len - shown});
        }
    }

    if (abi.events.len > 0) {
        const shown = @min(abi.events.len, inspect_abi_list_limit);
        std.debug.print("ABI events:\n", .{});
        for (abi.events[0..shown]) |event| {
            printAbiEventSignature(event);
        }
        if (abi.events.len > shown) {
            std.debug.print("  ... {d} more events omitted\n", .{abi.events.len - shown});
        }
    }
}

fn printAbiFunctionSignature(function: contract_mod.abi_adapter.FunctionDef) void {
    std.debug.print("  - {s}(", .{function.name});
    printAbiParamList(function.inputs);
    std.debug.print(")", .{});
    if (function.outputs.len > 0) {
        std.debug.print(" -> (", .{});
        printAbiParamList(function.outputs);
        std.debug.print(")", .{});
    }
    if (function.opcode) |opcode| {
        std.debug.print(" [op=0x{X}]", .{opcode});
    }
    std.debug.print("\n", .{});
}

fn printAbiEventSignature(event: contract_mod.abi_adapter.EventDef) void {
    std.debug.print("  - {s}(", .{event.name});
    printAbiParamList(event.inputs);
    std.debug.print(")", .{});
    if (event.opcode) |opcode| {
        std.debug.print(" [op=0x{X}]", .{opcode});
    }
    std.debug.print("\n", .{});
}

fn printAbiParamList(params: []const contract_mod.abi_adapter.ParamDef) void {
    for (params, 0..) |param, idx| {
        if (idx != 0) std.debug.print(", ", .{});
        if (param.name.len > 0) {
            std.debug.print("{s}:", .{param.name});
        }
        std.debug.print("{s}", .{param.type_name});
    }
}

fn printInspectCommandHints(
    allocator: std.mem.Allocator,
    addr: []const u8,
    abi: ?*const contract_mod.abi_adapter.AbiInfo,
) void {
    std.debug.print("Command hints:\n", .{});
    std.debug.print("  Raw read: ton-zig-agent-kit runGetMethod {s} <method> [stack_json]\n", .{addr});
    std.debug.print("  Typed read: ton-zig-agent-kit runGetMethodTyped {s} <method> [typed_args...]\n", .{addr});
    std.debug.print("  ABI describe: ton-zig-agent-kit abi describe auto:{s} [function_name_or_signature]\n", .{addr});

    if (abi) |value| {
        std.debug.print("  ABI read: ton-zig-agent-kit runGetMethodAuto {s} <function_name_or_signature> [values...]\n", .{addr});
        std.debug.print("  ABI build: ton-zig-agent-kit wallet build-auto-abi {s} <amount_nanoton> <function_name_or_signature> [values...]\n", .{addr});
        std.debug.print("  ABI write: ton-zig-agent-kit wallet send-auto-abi <wallet_addr> {s} <amount_nanoton> <function_name_or_signature> [values...]\n", .{addr});

        if (value.functions.len > 0) {
            const shown = @min(value.functions.len, inspect_abi_template_limit);
            std.debug.print("  ABI function names:", .{});
            for (value.functions[0..shown], 0..) |function, idx| {
                std.debug.print("{s}{s}", .{ if (idx == 0) " " else ", ", function.name });
            }
            if (value.functions.len > shown) {
                std.debug.print(", ...", .{});
            }
            std.debug.print("\n", .{});

            std.debug.print("  ABI templates:\n", .{});
            for (value.functions[0..shown]) |function| {
                const function_ref = buildAbiFunctionCommandRefAlloc(allocator, value, function) catch |err| {
                    std.debug.print("    {s}: selector build failed ({s})\n", .{ function.name, @errorName(err) });
                    continue;
                };
                defer allocator.free(function_ref);

                const template_args = buildInspectCliArgsTemplateAlloc(allocator, function.inputs) catch |err| {
                    std.debug.print("    {s}: template build failed ({s})\n", .{ function.name, @errorName(err) });
                    continue;
                };
                defer allocator.free(template_args);

                std.debug.print("    {s} args: {s}\n", .{
                    function.name,
                    if (template_args.len == 0) "(no args)" else template_args,
                });
                const output_template = buildInspectDecodedOutputsTemplateAlloc(allocator, function.outputs) catch |err| {
                    std.debug.print("      outputs: template build failed ({s})\n", .{@errorName(err)});
                    std.debug.print("      read: ton-zig-agent-kit runGetMethodAuto {s} {s}{s}{s}\n", .{
                        addr,
                        function_ref,
                        if (template_args.len == 0) "" else " ",
                        template_args,
                    });
                    std.debug.print("      build: ton-zig-agent-kit wallet build-auto-abi {s} <amount_nanoton> {s}{s}{s}\n", .{
                        addr,
                        function_ref,
                        if (template_args.len == 0) "" else " ",
                        template_args,
                    });
                    std.debug.print("      write: ton-zig-agent-kit wallet send-auto-abi <wallet_addr> {s} <amount_nanoton> {s}{s}{s}\n", .{
                        addr,
                        function_ref,
                        if (template_args.len == 0) "" else " ",
                        template_args,
                    });
                    continue;
                };
                defer allocator.free(output_template);

                std.debug.print("      outputs: {s}\n", .{
                    if (function.outputs.len == 0) "(no outputs)" else output_template,
                });
                std.debug.print("      read: ton-zig-agent-kit runGetMethodAuto {s} {s}{s}{s}\n", .{
                    addr,
                    function_ref,
                    if (template_args.len == 0) "" else " ",
                    template_args,
                });
                std.debug.print("      build: ton-zig-agent-kit wallet build-auto-abi {s} <amount_nanoton> {s}{s}{s}\n", .{
                    addr,
                    function_ref,
                    if (template_args.len == 0) "" else " ",
                    template_args,
                });
                std.debug.print("      write: ton-zig-agent-kit wallet send-auto-abi <wallet_addr> {s} <amount_nanoton> {s}{s}{s}\n", .{
                    addr,
                    function_ref,
                    if (template_args.len == 0) "" else " ",
                    template_args,
                });
            }
        }
    }
}

fn loadCliAbiSourceAlloc(allocator: std.mem.Allocator, source: []const u8) !LoadedCliAbi {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidAbiDefinition;

    if (std.mem.startsWith(u8, trimmed, "auto:")) {
        const addr = std.mem.trim(u8, trimmed["auto:".len..], " \t\r\n");
        if (addr.len == 0) return error.InvalidAbiDefinition;

        var provider = try initDefaultProvider(allocator);
        var abi = (try contract_mod.abi_adapter.queryAbiDocumentAlloc(&provider, addr)) orelse {
            return error.AbiDocumentNotFound;
        };
        errdefer abi.deinit(allocator);

        return .{
            .abi = abi,
            .auto_address = addr,
        };
    }

    return .{
        .abi = try contract_mod.abi_adapter.loadAbiInfoSourceAlloc(allocator, trimmed),
    };
}

fn displayAbiSource(source: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0) return "(empty)";
    if (trimmed[0] == '{' or trimmed[0] == '[') return "(inline json)";
    return trimmed;
}

fn printAbiFunctionDescribe(
    allocator: std.mem.Allocator,
    abi: *const contract_mod.abi_adapter.AbiInfo,
    function: contract_mod.abi_adapter.FunctionDef,
    auto_address: ?[]const u8,
) void {
    std.debug.print("Function detail:\n", .{});
    printAbiFunctionSignature(function);

    const function_ref = buildAbiFunctionCommandRefAlloc(allocator, abi, function) catch |err| {
        std.debug.print("  Selector: build failed ({s})\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(function_ref);
    std.debug.print("  Selector: {s}\n", .{function_ref});

    const input_template = buildInspectCliArgsTemplateAlloc(allocator, function.inputs) catch |err| {
        std.debug.print("  Input args: template build failed ({s})\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(input_template);

    const named_input_template = buildInspectNamedCliArgsTemplateAlloc(allocator, function.inputs) catch |err| {
        std.debug.print("  Named args: template build failed ({s})\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(named_input_template);

    const output_template = buildInspectDecodedOutputsTemplateAlloc(allocator, function.outputs) catch |err| {
        std.debug.print("  Decoded outputs: template build failed ({s})\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(output_template);

    std.debug.print("  Input args: {s}\n", .{
        if (input_template.len == 0) "(no args)" else input_template,
    });
    std.debug.print("  Named args: {s}\n", .{
        if (named_input_template.len == 0) "(no args)" else named_input_template,
    });
    std.debug.print("  Decoded outputs: {s}\n", .{
        if (function.outputs.len == 0) "(no outputs)" else output_template,
    });

    if (auto_address) |addr| {
        std.debug.print("  Auto read: ton-zig-agent-kit runGetMethodAuto {s} {s}{s}{s}\n", .{
            addr,
            function_ref,
            if (input_template.len == 0) "" else " ",
            input_template,
        });
        std.debug.print("  Auto build: ton-zig-agent-kit wallet build-auto-abi {s} <amount_nanoton> {s}{s}{s}\n", .{
            addr,
            function_ref,
            if (input_template.len == 0) "" else " ",
            input_template,
        });
        std.debug.print("  Auto write: ton-zig-agent-kit wallet send-auto-abi <wallet_addr> {s} <amount_nanoton> {s}{s}{s}\n", .{
            addr,
            function_ref,
            if (input_template.len == 0) "" else " ",
            input_template,
        });
        return;
    }

    std.debug.print("  Build body: ton-zig-agent-kit cell build-abi <abi_source> {s}{s}{s}\n", .{
        function_ref,
        if (input_template.len == 0) "" else " ",
        input_template,
    });
    std.debug.print("  ABI read: ton-zig-agent-kit runGetMethodAbi <address> <abi_source> {s}{s}{s}\n", .{
        function_ref,
        if (input_template.len == 0) "" else " ",
        input_template,
    });
    std.debug.print("  Build wallet message: ton-zig-agent-kit wallet build-abi <dest> <amount_nanoton> <abi_source> {s}{s}{s}\n", .{
        function_ref,
        if (input_template.len == 0) "" else " ",
        input_template,
    });
    std.debug.print("  ABI write: ton-zig-agent-kit wallet send-abi <wallet_addr> <dest> <amount_nanoton> <abi_source> {s}{s}{s}\n", .{
        function_ref,
        if (input_template.len == 0) "" else " ",
        input_template,
    });
}

fn buildAbiFunctionCommandRefAlloc(
    allocator: std.mem.Allocator,
    abi: *const contract_mod.abi_adapter.AbiInfo,
    function: contract_mod.abi_adapter.FunctionDef,
) ![]u8 {
    if (abiFunctionIsOverloaded(abi, function.name)) {
        return contract_mod.abi_adapter.buildFunctionSelectorAlloc(allocator, function);
    }
    return allocator.dupe(u8, function.name);
}

fn abiFunctionIsOverloaded(abi: *const contract_mod.abi_adapter.AbiInfo, function_name: []const u8) bool {
    var matches: usize = 0;
    for (abi.functions) |function| {
        if (!std.mem.eql(u8, function.name, function_name)) continue;
        matches += 1;
        if (matches > 1) return true;
    }
    return false;
}

fn buildInspectCliArgsTemplateAlloc(
    allocator: std.mem.Allocator,
    params: []const contract_mod.abi_adapter.ParamDef,
) ![]u8 {
    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    for (params, 0..) |param, idx| {
        if (idx != 0) try writer.writer.writeByte(' ');
        const value = try buildInspectCliValueTemplateAlloc(allocator, param);
        defer allocator.free(value);
        try writer.writer.writeAll(value);
    }

    return try writer.toOwnedSlice();
}

fn buildInspectNamedCliArgsTemplateAlloc(
    allocator: std.mem.Allocator,
    params: []const contract_mod.abi_adapter.ParamDef,
) anyerror![]u8 {
    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    for (params, 0..) |param, idx| {
        if (idx != 0) try writer.writer.writeByte(' ');

        var fallback_name_buf: [32]u8 = undefined;
        const name = if (param.name.len > 0)
            param.name
        else
            try std.fmt.bufPrint(&fallback_name_buf, "arg{d}", .{idx});

        try writer.writer.print("{s}=", .{name});

        const value = try buildInspectCliValueTemplateAlloc(allocator, param);
        defer allocator.free(value);
        try writer.writer.writeAll(value);
    }

    return try writer.toOwnedSlice();
}

fn buildInspectDecodedOutputsTemplateAlloc(
    allocator: std.mem.Allocator,
    params: []const contract_mod.abi_adapter.ParamDef,
) anyerror![]u8 {
    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    try writer.writer.writeByte('{');
    for (params, 0..) |param, idx| {
        if (idx != 0) try writer.writer.writeByte(',');

        var fallback_name_buf: [32]u8 = undefined;
        const name = if (param.name.len > 0)
            param.name
        else
            try std.fmt.bufPrint(&fallback_name_buf, "value{d}", .{idx});

        try writeInspectJsonString(&writer.writer, name);
        try writer.writer.writeByte(':');

        const value = try buildInspectOutputValueTemplateAlloc(allocator, param);
        defer allocator.free(value);
        try writer.writer.writeAll(value);
    }
    try writer.writer.writeByte('}');

    return try writer.toOwnedSlice();
}

fn buildInspectCliValueTemplateAlloc(
    allocator: std.mem.Allocator,
    param: contract_mod.abi_adapter.ParamDef,
) anyerror![]u8 {
    if (inspectOptionalInnerType(param.type_name) != null) {
        return allocator.dupe(u8, "null");
    }

    if (inspectArrayInnerType(param.type_name)) |inner_type| {
        const value = try buildInspectJsonValueTemplateAlloc(allocator, inspectParamWithType(param, inner_type));
        defer allocator.free(value);
        return std.fmt.allocPrint(allocator, "json:[{s}]", .{value});
    }

    if (inspectIsCompositeParam(param)) {
        const value = try buildInspectJsonValueTemplateAlloc(allocator, param);
        defer allocator.free(value);
        return std.fmt.allocPrint(allocator, "json:{s}", .{value});
    }

    if (std.mem.eql(u8, param.type_name, "bool")) {
        return allocator.dupe(u8, "num:1");
    }

    if (std.mem.eql(u8, param.type_name, "address")) {
        return allocator.dupe(u8, "addr:EQ...");
    }

    if (std.mem.eql(u8, param.type_name, "string")) {
        return allocator.dupe(u8, "str:text");
    }

    if (std.mem.eql(u8, param.type_name, "bytes") or inspectFixedBytesLength(param.type_name) != null) {
        return allocator.dupe(u8, "hex:CAFE");
    }

    if (inspectIsCellLikeType(param.type_name)) {
        return allocator.dupe(u8, "boc:<base64_boc>");
    }

    if (inspectIsNumericType(param.type_name)) {
        return allocator.dupe(u8, "num:0");
    }

    return allocator.dupe(u8, "json:null");
}

fn buildInspectJsonValueTemplateAlloc(
    allocator: std.mem.Allocator,
    param: contract_mod.abi_adapter.ParamDef,
) anyerror![]u8 {
    if (inspectOptionalInnerType(param.type_name) != null) {
        return allocator.dupe(u8, "null");
    }

    if (inspectArrayInnerType(param.type_name)) |inner_type| {
        const value = try buildInspectJsonValueTemplateAlloc(allocator, inspectParamWithType(param, inner_type));
        defer allocator.free(value);
        return std.fmt.allocPrint(allocator, "[{s}]", .{value});
    }

    if (inspectIsCompositeParam(param)) {
        return buildInspectCompositeJsonTemplateAlloc(allocator, param.components);
    }

    if (inspectIsNumericType(param.type_name)) {
        return allocator.dupe(u8, if (std.mem.eql(u8, param.type_name, "bool")) "true" else "0");
    }

    if (std.mem.eql(u8, param.type_name, "address")) {
        return allocator.dupe(u8, "\"EQ...\"");
    }

    if (std.mem.eql(u8, param.type_name, "string")) {
        return allocator.dupe(u8, "\"text\"");
    }

    if (std.mem.eql(u8, param.type_name, "bytes") or inspectFixedBytesLength(param.type_name) != null) {
        return allocator.dupe(u8, "{\"hex\":\"CAFE\"}");
    }

    if (inspectIsCellLikeType(param.type_name)) {
        return allocator.dupe(u8, "{\"boc\":\"<base64_boc>\"}");
    }

    return allocator.dupe(u8, "null");
}

fn buildInspectOutputValueTemplateAlloc(
    allocator: std.mem.Allocator,
    param: contract_mod.abi_adapter.ParamDef,
) anyerror![]u8 {
    if (inspectOptionalInnerType(param.type_name) != null) {
        return allocator.dupe(u8, "null");
    }

    if (inspectArrayInnerType(param.type_name)) |inner_type| {
        const value = try buildInspectOutputValueTemplateAlloc(allocator, inspectParamWithType(param, inner_type));
        defer allocator.free(value);
        return std.fmt.allocPrint(allocator, "[{s}]", .{value});
    }

    if (inspectIsCompositeParam(param)) {
        return buildInspectCompositeOutputTemplateAlloc(allocator, param.components);
    }

    if (inspectIsNumericType(param.type_name)) {
        return allocator.dupe(u8, if (std.mem.eql(u8, param.type_name, "bool")) "true" else "0");
    }

    if (std.mem.eql(u8, param.type_name, "address")) {
        return allocator.dupe(u8, "\"0:...\"");
    }

    if (std.mem.eql(u8, param.type_name, "string")) {
        return allocator.dupe(u8, "\"text\"");
    }

    if (std.mem.eql(u8, param.type_name, "bytes") or inspectFixedBytesLength(param.type_name) != null) {
        return allocator.dupe(u8, "\"<base64_bytes>\"");
    }

    if (inspectIsCellLikeType(param.type_name)) {
        return allocator.dupe(u8, "\"<base64_boc>\"");
    }

    return allocator.dupe(u8, "null");
}

fn buildInspectCompositeJsonTemplateAlloc(
    allocator: std.mem.Allocator,
    components: []const contract_mod.abi_adapter.ParamDef,
) anyerror![]u8 {
    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    var has_named_components = true;
    for (components) |component| {
        if (component.name.len == 0) {
            has_named_components = false;
            break;
        }
    }

    if (has_named_components) {
        try writer.writer.writeByte('{');
        for (components, 0..) |component, idx| {
            if (idx != 0) try writer.writer.writeByte(',');
            try writeInspectJsonString(&writer.writer, component.name);
            try writer.writer.writeByte(':');
            const value = try buildInspectJsonValueTemplateAlloc(allocator, component);
            defer allocator.free(value);
            try writer.writer.writeAll(value);
        }
        try writer.writer.writeByte('}');
    } else {
        try writer.writer.writeByte('[');
        for (components, 0..) |component, idx| {
            if (idx != 0) try writer.writer.writeByte(',');
            const value = try buildInspectJsonValueTemplateAlloc(allocator, component);
            defer allocator.free(value);
            try writer.writer.writeAll(value);
        }
        try writer.writer.writeByte(']');
    }

    return try writer.toOwnedSlice();
}

fn buildInspectCompositeOutputTemplateAlloc(
    allocator: std.mem.Allocator,
    components: []const contract_mod.abi_adapter.ParamDef,
) anyerror![]u8 {
    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    var has_named_components = true;
    for (components) |component| {
        if (component.name.len == 0) {
            has_named_components = false;
            break;
        }
    }

    if (has_named_components) {
        try writer.writer.writeByte('{');
        for (components, 0..) |component, idx| {
            if (idx != 0) try writer.writer.writeByte(',');
            try writeInspectJsonString(&writer.writer, component.name);
            try writer.writer.writeByte(':');
            const value = try buildInspectOutputValueTemplateAlloc(allocator, component);
            defer allocator.free(value);
            try writer.writer.writeAll(value);
        }
        try writer.writer.writeByte('}');
    } else {
        try writer.writer.writeByte('[');
        for (components, 0..) |component, idx| {
            if (idx != 0) try writer.writer.writeByte(',');
            const value = try buildInspectOutputValueTemplateAlloc(allocator, component);
            defer allocator.free(value);
            try writer.writer.writeAll(value);
        }
        try writer.writer.writeByte(']');
    }

    return try writer.toOwnedSlice();
}

fn inspectParamWithType(
    param: contract_mod.abi_adapter.ParamDef,
    type_name: []const u8,
) contract_mod.abi_adapter.ParamDef {
    return .{
        .name = param.name,
        .type_name = type_name,
        .components = param.components,
    };
}

fn inspectIsCompositeParam(param: contract_mod.abi_adapter.ParamDef) bool {
    return param.components.len > 0 or
        std.mem.eql(u8, param.type_name, "tuple") or
        std.mem.eql(u8, param.type_name, "struct");
}

fn inspectIsNumericType(type_name: []const u8) bool {
    return std.mem.eql(u8, type_name, "bool") or
        std.mem.eql(u8, type_name, "coins") or
        std.mem.startsWith(u8, type_name, "uint") or
        std.mem.startsWith(u8, type_name, "int");
}

fn inspectIsCellLikeType(type_name: []const u8) bool {
    return inspectMatchesAbiTypeBase(type_name, "cell") or
        inspectMatchesAbiTypeBase(type_name, "slice") or
        inspectMatchesAbiTypeBase(type_name, "builder") or
        inspectMatchesAbiTypeBase(type_name, "ref") or
        inspectMatchesAbiTypeBase(type_name, "boc") or
        inspectMatchesAbiTypeBase(type_name, "ref_boc") or
        inspectMatchesAbiTypeBase(type_name, "cell_ref") or
        inspectMatchesAbiTypeBase(type_name, "dict") or
        inspectMatchesAbiTypeBase(type_name, "map") or
        inspectMatchesAbiTypeBase(type_name, "hashmap") or
        inspectMatchesAbiTypeBase(type_name, "hashmape") or
        inspectMatchesAbiTypeBase(type_name, "dict_ref") or
        inspectMatchesAbiTypeBase(type_name, "map_ref") or
        inspectMatchesAbiTypeBase(type_name, "hashmap_ref") or
        inspectMatchesAbiTypeBase(type_name, "hashmape_ref");
}

fn inspectFixedBytesLength(type_name: []const u8) ?usize {
    const trimmed = std.mem.trim(u8, type_name, " \t\r\n");

    if (inspectParseFixedBytesSuffix(trimmed, "bytes")) |value| return value;
    if (inspectParseFixedBytesSuffix(trimmed, "fixedbytes")) |value| return value;
    if (inspectParseFixedBytesSuffix(trimmed, "fixed_bytes")) |value| return value;

    if (inspectParseFixedBytesGeneric(trimmed, "fixedbytes<")) |value| return value;
    if (inspectParseFixedBytesGeneric(trimmed, "fixed_bytes<")) |value| return value;

    return null;
}

fn inspectParseFixedBytesSuffix(trimmed: []const u8, comptime prefix: []const u8) ?usize {
    if (trimmed.len <= prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(trimmed[0..prefix.len], prefix)) return null;

    const digits = trimmed[prefix.len..];
    if (digits.len == 0) return null;
    for (digits) |char| {
        if (!std.ascii.isDigit(char)) return null;
    }

    return std.fmt.parseInt(usize, digits, 10) catch null;
}

fn inspectParseFixedBytesGeneric(trimmed: []const u8, comptime prefix: []const u8) ?usize {
    if (!std.ascii.startsWithIgnoreCase(trimmed, prefix)) return null;
    if (trimmed.len <= prefix.len or trimmed[trimmed.len - 1] != '>') return null;
    return std.fmt.parseInt(usize, trimmed[prefix.len .. trimmed.len - 1], 10) catch null;
}

fn inspectMatchesAbiTypeBase(type_name: []const u8, base: []const u8) bool {
    const trimmed = std.mem.trim(u8, type_name, " \t\r\n");
    if (trimmed.len < base.len) return false;
    if (!std.ascii.eqlIgnoreCase(trimmed[0..base.len], base)) return false;
    return trimmed.len == base.len or trimmed[base.len] == '<' or trimmed[base.len] == ' ';
}

fn inspectOptionalInnerType(type_name: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, type_name, " \t\r\n");

    if (std.mem.startsWith(u8, trimmed, "maybe<") and trimmed.len > "maybe<>".len and trimmed[trimmed.len - 1] == '>') {
        return std.mem.trim(u8, trimmed["maybe<".len .. trimmed.len - 1], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "optional<") and trimmed.len > "optional<>".len and trimmed[trimmed.len - 1] == '>') {
        return std.mem.trim(u8, trimmed["optional<".len .. trimmed.len - 1], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "maybe ")) {
        return std.mem.trim(u8, trimmed["maybe ".len..], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "optional ")) {
        return std.mem.trim(u8, trimmed["optional ".len..], " \t\r\n");
    }

    return null;
}

fn inspectArrayInnerType(type_name: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, type_name, " \t\r\n");

    if (trimmed.len > 2 and std.mem.endsWith(u8, trimmed, "[]")) {
        return std.mem.trim(u8, trimmed[0 .. trimmed.len - 2], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "array<") and trimmed.len > "array<>".len and trimmed[trimmed.len - 1] == '>') {
        return std.mem.trim(u8, trimmed["array<".len .. trimmed.len - 1], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "list<") and trimmed.len > "list<>".len and trimmed[trimmed.len - 1] == '>') {
        return std.mem.trim(u8, trimmed["list<".len .. trimmed.len - 1], " \t\r\n");
    }

    if (std.mem.startsWith(u8, trimmed, "array ")) {
        return std.mem.trim(u8, trimmed["array ".len..], " \t\r\n");
    }

    return null;
}

fn writeInspectJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |char| {
        switch (char) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f => try writer.print("\\u00{X:0>2}", .{char}),
            else => try writer.writeByte(char),
        }
    }
    try writer.writeByte('"');
}

fn printUsage() !void {
    std.debug.print("ton-zig-agent-kit v{s}\n", .{"0.0.1"});
    std.debug.print("A Zig-native TON contract toolkit for AI agents\n\n", .{});
    std.debug.print("Usage:\n", .{});
    std.debug.print("  ton-zig-agent-kit help                          Show this help\n", .{});
    std.debug.print("  ton-zig-agent-kit version                       Show version\n", .{});
    std.debug.print("  ton-zig-agent-kit abi describe <source|auto:addr> [function]  Describe ABI and show call templates\n", .{});
    std.debug.print("  ton-zig-agent-kit abi decode-function <source|auto:addr> <body_b64> [function]  Decode an ABI function body\n", .{});
    std.debug.print("  ton-zig-agent-kit abi decode-event <source|auto:addr> <body_b64> [event]  Decode an ABI event body\n", .{});
    std.debug.print("  ton-zig-agent-kit getBalance <address>          Get TON balance\n", .{});
    std.debug.print("  ton-zig-agent-kit tx list <address> [limit]     List recent transactions\n", .{});
    std.debug.print("  ton-zig-agent-kit tx show <lt> <hash>           Show one transaction and best-effort ABI decode its messages\n", .{});
    std.debug.print("  ton-zig-agent-kit runGetMethod <addr> <method> [stack_json]  Call any get method\n", .{});
    std.debug.print("  ton-zig-agent-kit inspectContract <addr>        Detect standard interfaces and ABI URI\n", .{});
    std.debug.print("  ton-zig-agent-kit runGetMethodTyped <addr> <method> [typed_args...]  Call get method with typed args\n", .{});
    std.debug.print("  ton-zig-agent-kit runGetMethodAbi <addr> <abi_json|@file|file://|http(s)://|ipfs://> <function_or_signature> [values...]  Call get method with ABI decode\n", .{});
    std.debug.print("  ton-zig-agent-kit runGetMethodAuto <addr> <function_or_signature> [values...]  Discover ABI and call get method\n", .{});
    std.debug.print("    ABI values: positional specs or name=spec; omitted trailing optional args default to null\n", .{});
    std.debug.print("  ton-zig-agent-kit jetton info <master>          Read Jetton master metadata\n", .{});
    std.debug.print("  ton-zig-agent-kit jetton wallet-address <master> <owner>  Resolve Jetton wallet address\n", .{});
    std.debug.print("  ton-zig-agent-kit jetton wallet-data <wallet>   Read Jetton wallet balance/owner/master\n", .{});
    std.debug.print("  ton-zig-agent-kit nft info <item>               Read NFT item metadata\n", .{});
    std.debug.print("  ton-zig-agent-kit nft collection-info <collection>  Read NFT collection metadata\n", .{});
    std.debug.print("    typed args: null, int:<n>, addr:<addr>, cell:<b64>, slice:<b64>, builder:<b64>, cellhex:<hex>, slicehex:<hex>, builderhex:<hex>\n", .{});
    std.debug.print("  ton-zig-agent-kit sendBoc <boc_base64>          Submit raw BoC to the network\n", .{});
    std.debug.print("  ton-zig-agent-kit sendBocHex <boc_hex>          Submit raw BoC hex to the network\n", .{});
    std.debug.print("  ton-zig-agent-kit sendExternal <dest> <body_b64> [state_init_b64|none]  Wrap a body in ext_in and submit it\n", .{});
    std.debug.print("  ton-zig-agent-kit sendExternalHex <dest> <body_hex> [state_init_hex|none]  Wrap a hex body in ext_in and submit it\n", .{});
    std.debug.print("  ton-zig-agent-kit sendExternalStandard <dest> <state_init_b64|none> <kind> <json|@file|file://|http(s)://|ipfs://>  Build a standard body and submit external message\n", .{});
    std.debug.print("  ton-zig-agent-kit sendExternalAbi <dest> <state_init_b64|none> <abi_source> <function_or_signature> [values...]  Build ABI body and submit external message\n", .{});
    std.debug.print("  ton-zig-agent-kit sendExternalAutoAbi <dest> <state_init_b64|none> <function_or_signature> [values...]  Discover ABI, build body, and submit external message\n", .{});
    std.debug.print("  ton-zig-agent-kit parseAddress <address>        Parse TON address\n", .{});
    std.debug.print("  ton-zig-agent-kit createInvoice <dest> <amount>  Create payment invoice\n", .{});
    std.debug.print("\nCell/Builder/Slice operations:\n", .{});
    std.debug.print("  ton-zig-agent-kit cell create                  Create test cell\n", .{});
    std.debug.print("  ton-zig-agent-kit cell encode <hex>            Encode data to BoC\n", .{});
    std.debug.print("  ton-zig-agent-kit cell hash <hex>              Get cell hash\n", .{});
    std.debug.print("  ton-zig-agent-kit cell inspect-body <body_b64> Best-effort inspect an unknown message body\n", .{});
    std.debug.print("  ton-zig-agent-kit cell build-typed <ops...>    Build body BoC from typed ops\n", .{});
    std.debug.print("  ton-zig-agent-kit cell build-standard <kind> <json|@file|file://|http(s)://|ipfs://>  Build a standard non-ABI body\n", .{});
    std.debug.print("  ton-zig-agent-kit cell build-function <function_json> <values...>  Build body from function schema\n", .{});
    std.debug.print("  ton-zig-agent-kit cell build-abi <abi_json|@file|file://|http(s)://|ipfs://> <function_or_signature> <values...>  Build body from ABI doc\n", .{});
    std.debug.print("  ton-zig-agent-kit cell build-state-init <code_b64|none> [data_b64|none]  Build StateInit BoC\n", .{});
    std.debug.print("  ton-zig-agent-kit cell build-external <dest> <body_b64> [state_init_b64|none]  Build external incoming message BoC\n", .{});
    std.debug.print("  ton-zig-agent-kit cell state-init-address <workchain> <state_init_b64>  Compute contract address from StateInit\n", .{});
    std.debug.print("    body ops: u<bits>:<v>, i<bits>:<v>, coins:<v>, addr:<addr>, bytes:<utf8>, hex:<hex>, ref:<b64 boc>, refhex:<hex boc>\n", .{});
    std.debug.print("    function values: null, u:<v>, i:<v>, num:<dec|0xhex>, str:<utf8>, addr:<addr>, json:<json|@file>, hex:<hex>, boc:<b64 boc>, bochex:<hex boc>\n", .{});
    std.debug.print("\nWallet operations:\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet genkey [seed|@file|hex:<private_key_hex>]  Generate or inspect keypair\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet address [v4|v5] [workchain] [wallet_id] [seed|@file|hex:<private_key_hex>]  Derive wallet address and StateInit\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet seqno <addr>          Get wallet seqno\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet info <addr>           Get wallet seqno, subwallet ID, public key, and local key match if configured\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet build-self-deploy [v4|v5] [workchain] [wallet_id] [seed|@file|hex:<private_key_hex>]  Build signed wallet self-deployment message\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet build-transfer <dst> <amount> [comment]  Build signed transfer without sending\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet build-body <dst> <amount> <body_b64>  Build signed wallet message from raw body\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet build-body-hex <dst> <amount> <body_hex>  Build signed wallet message from raw body hex\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet build-standard <dst> <amount> <kind> <json|@file|file://|http(s)://|ipfs://>  Build signed wallet message from a standard body spec\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet build-function <dst> <amount> <function_json> <values...>  Build signed wallet message from function schema\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet build-abi <dst> <amount> <abi_json|@file|file://|http(s)://|ipfs://> <function_or_signature> <values...>  Build signed wallet message from ABI doc\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet build-auto-abi <dst> <amount> <function_or_signature> <values...>  Discover ABI and build signed wallet message\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet build-deploy <dst> <amount> <state_init_b64> [body_b64]  Build signed deploy message\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet build-deploy-auto <workchain> <amount> <state_init_b64> [body_b64]  Derive destination from StateInit and build signed deploy message\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet send <src> <dst> <amount>  Send TON\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet send-init <dst> <amount> [v4|v5] [workchain] [wallet_id] [seed|@file|hex:<private_key_hex>]  Deploy wallet if needed and send first transfer\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet deploy-self [v4|v5] [workchain] [wallet_id] [seed|@file|hex:<private_key_hex>]  Submit external wallet deployment message\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet send-body <src> <dst> <amount> <body_b64>  Send raw contract body\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet send-body-hex <src> <dst> <amount> <body_hex>  Send raw contract body hex\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet send-standard <src> <dst> <amount> <kind> <json|@file|file://|http(s)://|ipfs://>  Build and send a standard non-ABI body\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet send-ops <src> <dst> <amount> <ops...>  Build and send typed contract body\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet send-function <src> <dst> <amount> <function_json> <values...>  Build and send function body\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet send-abi <src> <dst> <amount> <abi_json|@file|file://|http(s)://|ipfs://> <function_or_signature> <values...>  Build and send ABI function body\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet send-auto-abi <src> <dst> <amount> <function_or_signature> <values...>  Discover ABI and send function body\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet send-deploy <src> <dst> <amount> <state_init_b64> [body_b64]  Deploy contract with StateInit\n", .{});
    std.debug.print("  ton-zig-agent-kit wallet send-deploy-auto <src> <workchain> <amount> <state_init_b64> [body_b64]  Derive destination from StateInit and deploy\n", .{});
    std.debug.print("    provider env: {s}, {s}, {s}, {s}, {s}\n", .{
        rpc_url_env,
        rpc_urls_env,
        api_key_env,
        api_keys_env,
        network_env,
    });
    std.debug.print("    wallet key env: {s}, {s}, {s}\n", .{
        wallet_private_key_hex_env,
        wallet_seed_env,
        wallet_seed_file_env,
    });
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

    var provider = try initDefaultProvider(allocator);

    const balance_result = provider.getBalance("EQCD39vd5kB8FW5w6KH7HpNmP8GCvGajvLKGPMgY4sUXJyxqH") catch |err| {
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

test "parse cli stack args" {
    const allocator = std.testing.allocator;
    var parsed = try parseCliStackArgs(allocator, &.{
        "null",
        "int:-1",
        "addr:0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
        "cellhex:b5ee9c72410101010005000002cafe6c44e11d",
        "builderhex:b5ee9c72410101010005000002cafe6c44e11d",
    });
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), parsed.args.len);
    try std.testing.expect(std.meta.activeTag(parsed.args[0]) == .null);
    try std.testing.expectEqual(@as(i64, -1), parsed.args[1].int);
    try std.testing.expectEqualStrings("0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8", parsed.args[2].address);
    try std.testing.expectEqualSlices(u8, &.{ 0xB5, 0xEE, 0x9C, 0x72 }, parsed.args[3].cell[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0xB5, 0xEE, 0x9C, 0x72 }, parsed.args[4].builder[0..4]);
}

test "parse cli body ops" {
    const allocator = std.testing.allocator;
    var parsed = try parseCliBodyOps(allocator, &.{
        "u32:0x12345678",
        "i8:-1",
        "coins:10",
        "addr:0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
        "bytes:OK",
        "hex:CAFE",
        "refhex:b5ee9c72410101010003000001ab8958a94a",
    });
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 7), parsed.ops.len);
    try std.testing.expectEqual(@as(u16, 32), parsed.ops[0].uint.bits);
    try std.testing.expectEqual(@as(u64, 0x12345678), parsed.ops[0].uint.value);
    try std.testing.expectEqual(@as(i64, -1), parsed.ops[1].int.value);
    try std.testing.expectEqual(@as(u64, 10), parsed.ops[2].coins);
    try std.testing.expectEqualStrings("OK", parsed.ops[4].bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0xCA, 0xFE }, parsed.ops[5].bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0xB5, 0xEE, 0x9C, 0x72 }, parsed.ops[6].ref_boc[0..4]);
}

test "parse cli abi values" {
    const allocator = std.testing.allocator;
    var parsed = try parseCliAbiValues(allocator, &.{
        "null",
        "u:0x12345678",
        "i:-1",
        "num:0x123456789abcdef0123456789abcdef0",
        "str:hello",
        "addr:0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
        "json:{\"enabled\":true}",
        "hex:CAFE",
        "bochex:b5ee9c72410101010003000001ab8958a94a",
    });
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 9), parsed.values.len);
    try std.testing.expect(std.meta.activeTag(parsed.values[0]) == .null);
    try std.testing.expectEqual(@as(u64, 0x12345678), parsed.values[1].uint);
    try std.testing.expectEqual(@as(i64, -1), parsed.values[2].int);
    try std.testing.expectEqualStrings("0x123456789abcdef0123456789abcdef0", parsed.values[3].numeric_text);
    try std.testing.expectEqualStrings("hello", parsed.values[4].text);
    try std.testing.expectEqualStrings("{\"enabled\":true}", parsed.values[6].json);
    try std.testing.expectEqualSlices(u8, &.{ 0xCA, 0xFE }, parsed.values[7].bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0xB5, 0xEE, 0x9C, 0x72 }, parsed.values[8].boc[0..4]);
}

test "parse cli abi values for params supports named args and optional defaults" {
    const allocator = std.testing.allocator;

    const params = [_]contract_mod.abi_adapter.ParamDef{
        .{ .name = "owner", .type_name = "address" },
        .{ .name = "amount", .type_name = "uint128" },
        .{ .name = "note", .type_name = "optional<string>" },
    };

    var parsed = try parseCliAbiValuesForParams(allocator, params[0..], &.{
        "amount=num:0x1234",
        "owner=addr:0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
    });
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), parsed.values.len);
    try std.testing.expectEqualStrings(
        "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
        parsed.values[0].text,
    );
    try std.testing.expectEqualStrings("0x1234", parsed.values[1].numeric_text);
    try std.testing.expect(std.meta.activeTag(parsed.values[2]) == .null);
}

test "parse cli abi values for params supports positional optional omission" {
    const allocator = std.testing.allocator;

    const params = [_]contract_mod.abi_adapter.ParamDef{
        .{ .name = "flag", .type_name = "bool" },
        .{ .name = "memo", .type_name = "maybe<string>" },
    };

    var parsed = try parseCliAbiValuesForParams(allocator, params[0..], &.{
        "num:1",
    });
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("1", parsed.values[0].numeric_text);
    try std.testing.expect(std.meta.activeTag(parsed.values[1]) == .null);
}

test "resolve cli abi function selects overloads for positional and named specs" {
    const functions = [_]contract_mod.abi_adapter.FunctionDef{
        .{
            .name = "set_user",
            .opcode = 1,
            .inputs = &.{
                .{ .name = "owner", .type_name = "address" },
            },
            .outputs = &.{},
        },
        .{
            .name = "set_user",
            .opcode = 2,
            .inputs = &.{
                .{ .name = "owner", .type_name = "address" },
                .{ .name = "memo", .type_name = "optional<string>" },
            },
            .outputs = &.{},
        },
        .{
            .name = "set_admin",
            .opcode = 3,
            .inputs = &.{
                .{ .name = "admin", .type_name = "address" },
            },
            .outputs = &.{},
        },
        .{
            .name = "set_admin",
            .opcode = 4,
            .inputs = &.{
                .{ .name = "owner", .type_name = "address" },
            },
            .outputs = &.{},
        },
    };

    const abi = contract_mod.abi_adapter.AbiInfo{
        .version = "1.0",
        .functions = functions[0..],
        .events = &.{},
    };

    try std.testing.expectEqual(
        @as(u32, 1),
        (try resolveCliAbiFunction(&abi, "set_user", &.{"addr:EQ..."})).opcode.?,
    );
    try std.testing.expectEqual(
        @as(u32, 2),
        (try resolveCliAbiFunction(&abi, "set_user", &.{ "owner=addr:EQ...", "memo=null" })).opcode.?,
    );
    try std.testing.expectEqual(
        @as(u32, 3),
        (try resolveCliAbiFunction(&abi, "set_admin", &.{"admin=addr:EQ..."})).opcode.?,
    );
    try std.testing.expectError(
        error.AmbiguousFunctionOverload,
        resolveCliAbiFunction(&abi, "set_admin", &.{"arg0=addr:EQ..."}),
    );
}

test "load cli text alloc supports inline and file specs" {
    const allocator = std.testing.allocator;

    const inline_text = try loadCliTextAlloc(allocator, "{\"name\":\"x\"}");
    defer allocator.free(inline_text);
    try std.testing.expectEqualStrings("{\"name\":\"x\"}", inline_text);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "abi.json", .data = "{\"version\":\"1.0\"}" });

    const abs_path = try tmp.dir.realpathAlloc(allocator, "abi.json");
    defer allocator.free(abs_path);
    const path_spec = try std.fmt.allocPrint(allocator, "@{s}", .{abs_path});
    defer allocator.free(path_spec);

    const file_text = try loadCliTextAlloc(allocator, path_spec);
    defer allocator.free(file_text);
    try std.testing.expectEqualStrings("{\"version\":\"1.0\"}", file_text);
}

test "parse cli wallet private key hex supports 0x prefix" {
    const allocator = std.testing.allocator;
    const private_key = try parseCliWalletPrivateKeyHexAlloc(
        allocator,
        "  0x00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF  ",
    );

    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF },
        &private_key,
    );
}

test "wallet key material env prefers private key hex" {
    const allocator = std.testing.allocator;

    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();
    try env_map.put(wallet_seed_env, "ignored-seed");
    try env_map.put(wallet_private_key_hex_env, "00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF");

    const wallet_keys = try loadCliWalletKeyMaterialFromEnvMap(allocator, &env_map);
    try std.testing.expectEqual(CliWalletKeySource.private_key_hex, wallet_keys.source);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF },
        &wallet_keys.private_key_seed,
    );
    const derived_public_key = try signing.derivePublicKey(wallet_keys.private_key_seed);
    try std.testing.expectEqualSlices(u8, &derived_public_key, &wallet_keys.public_key);
}

test "wallet key material env reads seed file" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "seed.txt", .data = "  file-seed-value\n" });

    const abs_path = try tmp.dir.realpathAlloc(allocator, "seed.txt");
    defer allocator.free(abs_path);

    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();
    try env_map.put(wallet_seed_file_env, abs_path);

    const wallet_keys = try loadCliWalletKeyMaterialFromEnvMap(allocator, &env_map);
    const expected = try signing.generateKeypair("file-seed-value");

    try std.testing.expectEqual(CliWalletKeySource.seed_file, wallet_keys.source);
    try std.testing.expectEqualSlices(u8, &expected[0], &wallet_keys.private_key_seed);
    try std.testing.expectEqualSlices(u8, &expected[1], &wallet_keys.public_key);
}

test "parse wallet bootstrap options supports defaults and overrides" {
    const defaults = try parseWalletBootstrapOptions(&.{});
    try std.testing.expectEqual(signing.WalletVersion.v4, defaults.wallet_version);
    try std.testing.expectEqual(@as(i8, 0), defaults.workchain);
    try std.testing.expectEqual(signing.default_wallet_id_v4, defaults.wallet_id);
    try std.testing.expect(defaults.key_spec == null);

    const custom = try parseWalletBootstrapOptions(&.{ "-1", "12345", "hex:0011" });
    try std.testing.expectEqual(signing.WalletVersion.v4, custom.wallet_version);
    try std.testing.expectEqual(@as(i8, -1), custom.workchain);
    try std.testing.expectEqual(@as(u32, 12345), custom.wallet_id);
    try std.testing.expectEqualStrings("hex:0011", custom.key_spec.?);

    const v5 = try parseWalletBootstrapOptions(&.{ "v5", "-1", "hex:0011" });
    try std.testing.expectEqual(signing.WalletVersion.v5, v5.wallet_version);
    try std.testing.expectEqual(@as(i8, -1), v5.workchain);
    try std.testing.expectEqual(signing.default_wallet_id_v5_mainnet, v5.wallet_id);
    try std.testing.expectEqualStrings("hex:0011", v5.key_spec.?);
}

test "parse wallet bootstrap options accepts key spec without numeric prefix" {
    const parsed = try parseWalletBootstrapOptions(&.{"@seed.txt"});
    try std.testing.expectEqual(signing.WalletVersion.v4, parsed.wallet_version);
    try std.testing.expectEqual(@as(i8, 0), parsed.workchain);
    try std.testing.expectEqual(signing.default_wallet_id_v4, parsed.wallet_id);
    try std.testing.expectEqualStrings("@seed.txt", parsed.key_spec.?);
}

test "inspect cli template builds composite json args" {
    const allocator = std.testing.allocator;

    const param = contract_mod.abi_adapter.ParamDef{
        .name = "payload",
        .type_name = "tuple",
        .components = &.{
            .{ .name = "owner", .type_name = "address" },
            .{ .name = "amount", .type_name = "uint128" },
            .{ .name = "note", .type_name = "optional<string>" },
            .{ .name = "meta", .type_name = "bytes" },
        },
    };

    const template = try buildInspectCliValueTemplateAlloc(allocator, param);
    defer allocator.free(template);

    try std.testing.expectEqualStrings(
        "json:{\"owner\":\"EQ...\",\"amount\":0,\"note\":null,\"meta\":{\"hex\":\"CAFE\"}}",
        template,
    );
}

test "inspect cli template joins scalars and arrays" {
    const allocator = std.testing.allocator;

    const params = [_]contract_mod.abi_adapter.ParamDef{
        .{ .name = "enabled", .type_name = "bool" },
        .{ .name = "recipient", .type_name = "address" },
        .{ .name = "items", .type_name = "uint16[]" },
    };

    const template = try buildInspectCliArgsTemplateAlloc(allocator, params[0..]);
    defer allocator.free(template);

    try std.testing.expectEqualStrings("num:1 addr:EQ... json:[0]", template);
}

test "inspect named cli template labels arguments" {
    const allocator = std.testing.allocator;

    const params = [_]contract_mod.abi_adapter.ParamDef{
        .{ .name = "recipient", .type_name = "address" },
        .{ .name = "amount", .type_name = "uint64" },
        .{ .name = "memo", .type_name = "optional<string>" },
    };

    const template = try buildInspectNamedCliArgsTemplateAlloc(allocator, params[0..]);
    defer allocator.free(template);

    try std.testing.expectEqualStrings(
        "recipient=addr:EQ... amount=num:0 memo=null",
        template,
    );
}

test "inspect cli template treats fixed bytes like hex input" {
    const allocator = std.testing.allocator;

    const param = contract_mod.abi_adapter.ParamDef{
        .name = "hash",
        .type_name = "bytes32",
    };

    const template = try buildInspectCliValueTemplateAlloc(allocator, param);
    defer allocator.free(template);

    try std.testing.expectEqualStrings("hex:CAFE", template);
}

test "inspect decoded outputs template builds nested json" {
    const allocator = std.testing.allocator;

    const params = [_]contract_mod.abi_adapter.ParamDef{
        .{ .name = "ok", .type_name = "bool" },
        .{
            .name = "payload",
            .type_name = "tuple",
            .components = &.{
                .{ .name = "owner", .type_name = "address" },
                .{ .name = "tags", .type_name = "string[]" },
                .{ .name = "hash", .type_name = "bytes32" },
                .{ .name = "code", .type_name = "cell" },
            },
        },
    };

    const template = try buildInspectDecodedOutputsTemplateAlloc(allocator, params[0..]);
    defer allocator.free(template);

    try std.testing.expectEqualStrings(
        "{\"ok\":true,\"payload\":{\"owner\":\"0:...\",\"tags\":[\"text\"],\"hash\":\"<base64_bytes>\",\"code\":\"<base64_boc>\"}}",
        template,
    );
}

test "display abi source collapses inline json" {
    try std.testing.expectEqualStrings("(inline json)", displayAbiSource("{\"version\":\"1.0\"}"));
    try std.testing.expectEqualStrings("auto:EQABC", displayAbiSource(" auto:EQABC "));
}

test "message auto decode resolves destination abi as function" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abi_json =
        \\{
        \\  "version": "1.0",
        \\  "functions": [
        \\    {
        \\      "name": "transfer",
        \\      "opcode": "0x11223344",
        \\      "inputs": [
        \\        {"name": "amount", "type": "coins"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "abi.json", .data = abi_json });
    const abi_path = try tmp.dir.realpathAlloc(allocator, "abi.json");
    defer allocator.free(abi_path);
    const abi_uri = try std.fmt.allocPrint(allocator, "file://{s}", .{abi_path});
    defer allocator.free(abi_uri);

    const FakeProvider = struct {
        allocator: std.mem.Allocator,
        abi_uri: []const u8,

        pub fn runGetMethod(self: *@This(), addr: []const u8, method_name: []const u8, stack: []const []const u8) anyerror!ton_zig_agent_kit.core.types.RunGetMethodResponse {
            _ = addr;
            _ = method_name;
            _ = stack;

            var builder = Builder.init();
            try builder.storeUint(0x01, 8);
            try builder.storeBits(self.abi_uri, @intCast(self.abi_uri.len * 8));
            const uri_cell = try builder.toCell(self.allocator);

            const entries = try self.allocator.alloc(StackEntry, 1);
            entries[0] = .{ .cell = uri_cell };
            return .{
                .exit_code = 0,
                .stack = entries,
                .logs = "",
            };
        }

        pub fn freeRunGetMethodResponse(self: *@This(), response: *ton_zig_agent_kit.core.types.RunGetMethodResponse) void {
            for (response.stack) |*entry| {
                switch (entry.*) {
                    .cell => |value| value.deinit(self.allocator),
                    .slice => |value| value.deinit(self.allocator),
                    .builder => |value| value.deinit(self.allocator),
                    else => {},
                }
            }
            if (response.stack.len > 0) self.allocator.free(response.stack);
        }
    };

    var parsed_abi = try contract_mod.abi_adapter.parseAbiInfoJsonAlloc(allocator, abi_json);
    defer parsed_abi.deinit(allocator);

    const body_boc = try contract_mod.abi_adapter.buildFunctionBodyFromAbiAlloc(
        allocator,
        &parsed_abi.abi,
        "transfer",
        &.{.{ .uint = 77 }},
    );
    defer allocator.free(body_boc);

    const body_cell = try boc.deserializeBoc(allocator, body_boc);
    defer body_cell.deinit(allocator);

    const msg = Message{
        .hash = "",
        .source = null,
        .destination = .{
            .raw = [_]u8{0x11} ** 32,
            .workchain = 0,
        },
        .value = 0,
        .body = body_cell,
        .raw_body = &.{},
    };

    var provider = FakeProvider{ .allocator = allocator, .abi_uri = abi_uri };
    var decoded = (tryDecodeMessageBodyAutoAlloc(allocator, &provider, &msg)).?;
    defer decoded.deinit(allocator);

    try std.testing.expectEqualStrings("transfer(coins)", decoded.selector);
    try std.testing.expectEqualStrings("{\"amount\":77}", decoded.decoded_json);
    try std.testing.expect(decoded.kind == .function);
}

test "message auto decode resolves source abi as event" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abi_json =
        \\{
        \\  "version": "1.0",
        \\  "events": [
        \\    {
        \\      "name": "Transfer",
        \\      "opcode": "0x01020304",
        \\      "inputs": [
        \\        {"name": "amount", "type": "coins"}
        \\      ]
        \\    }
        \\  ]
        \\}
    ;
    try tmp.dir.writeFile(.{ .sub_path = "abi.json", .data = abi_json });
    const abi_path = try tmp.dir.realpathAlloc(allocator, "abi.json");
    defer allocator.free(abi_path);
    const abi_uri = try std.fmt.allocPrint(allocator, "file://{s}", .{abi_path});
    defer allocator.free(abi_uri);

    const FakeProvider = struct {
        allocator: std.mem.Allocator,
        abi_uri: []const u8,

        pub fn runGetMethod(self: *@This(), addr: []const u8, method_name: []const u8, stack: []const []const u8) anyerror!ton_zig_agent_kit.core.types.RunGetMethodResponse {
            _ = addr;
            _ = method_name;
            _ = stack;

            var builder = Builder.init();
            try builder.storeUint(0x01, 8);
            try builder.storeBits(self.abi_uri, @intCast(self.abi_uri.len * 8));
            const uri_cell = try builder.toCell(self.allocator);

            const entries = try self.allocator.alloc(StackEntry, 1);
            entries[0] = .{ .cell = uri_cell };
            return .{
                .exit_code = 0,
                .stack = entries,
                .logs = "",
            };
        }

        pub fn freeRunGetMethodResponse(self: *@This(), response: *ton_zig_agent_kit.core.types.RunGetMethodResponse) void {
            for (response.stack) |*entry| {
                switch (entry.*) {
                    .cell => |value| value.deinit(self.allocator),
                    .slice => |value| value.deinit(self.allocator),
                    .builder => |value| value.deinit(self.allocator),
                    else => {},
                }
            }
            if (response.stack.len > 0) self.allocator.free(response.stack);
        }
    };

    var builder = Builder.init();
    try builder.storeUint(0x01020304, 32);
    try builder.storeCoins(88);
    const body_cell = try builder.toCell(allocator);
    defer body_cell.deinit(allocator);

    const msg = Message{
        .hash = "",
        .source = .{
            .raw = [_]u8{0x22} ** 32,
            .workchain = 0,
        },
        .destination = null,
        .value = 0,
        .body = body_cell,
        .raw_body = &.{},
    };

    var provider = FakeProvider{ .allocator = allocator, .abi_uri = abi_uri };
    var decoded = (tryDecodeMessageBodyAutoAlloc(allocator, &provider, &msg)).?;
    defer decoded.deinit(allocator);

    try std.testing.expectEqualStrings("Transfer(coins)", decoded.selector);
    try std.testing.expectEqualStrings("{\"amount\":88}", decoded.decoded_json);
    try std.testing.expect(decoded.kind == .event);
}
