//! HTTP client for TON Center API v2/v3.
//! - v2 JSON-RPC: balance, get-method, sendBoc
//! - v3 REST: transactions lookup

const std = @import("std");
const types = @import("types.zig");
const address = @import("address.zig");
const boc = @import("boc.zig");

pub const TonHttpClient = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    api_key: ?[]const u8,
    http_client: std.http.Client,

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8, api_key: ?[]const u8) !TonHttpClient {
        return TonHttpClient{
            .allocator = allocator,
            .base_url = base_url,
            .api_key = api_key,
            .http_client = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *TonHttpClient) void {
        self.http_client.deinit();
    }

    fn executeJsonRpc(self: *TonHttpClient, method_name: []const u8, params_json: []const u8) ![]u8 {
        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}",
            .{ method_name, params_json },
        );
        defer self.allocator.free(body);

        return self.executeHttp(.POST, self.base_url, body, true);
    }

    fn executeHttp(
        self: *TonHttpClient,
        method: std.http.Method,
        url: []const u8,
        body: ?[]const u8,
        json_body: bool,
    ) ![]u8 {
        const uri = try std.Uri.parse(url);

        var headers = [_]std.http.Header{
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "content-type", .value = if (json_body) "application/json" else "application/octet-stream" },
            .{ .name = "X-API-Key", .value = "" },
        };
        const header_len: usize = if (self.api_key != null) 3 else if (body != null) 2 else 1;
        if (self.api_key) |api_key| headers[2].value = api_key;

        var request = try self.http_client.request(method, uri, .{
            .redirect_behavior = .unhandled,
            .extra_headers = headers[0..header_len],
            .keep_alive = true,
        });
        defer request.deinit();

        if (body) |payload| {
            request.transfer_encoding = .{ .content_length = payload.len };
            try request.sendBodyComplete(@constCast(payload));
        } else {
            try request.sendBodiless();
        }

        var response = try request.receiveHead(&.{});

        const decompress_buffer = switch (response.head.content_encoding) {
            .identity => null,
            .gzip, .deflate => try self.allocator.alloc(u8, std.compress.flate.max_window_len),
            else => return error.UnsupportedCompressionMethod,
        };
        defer if (decompress_buffer) |buffer| self.allocator.free(buffer);

        var response_writer = std.io.Writer.Allocating.init(self.allocator);
        errdefer response_writer.deinit();

        var transfer_buffer: [512]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer orelse &.{});
        _ = try reader.streamRemaining(&response_writer.writer);

        return try response_writer.toOwnedSlice();
    }

    fn apiV2Base(self: *TonHttpClient) ![]u8 {
        if (std.mem.endsWith(u8, self.base_url, "/jsonRPC")) {
            return self.allocator.dupe(u8, self.base_url[0 .. self.base_url.len - "/jsonRPC".len]);
        }
        return self.allocator.dupe(u8, self.base_url);
    }

    fn apiV3Base(self: *TonHttpClient) ![]u8 {
        if (std.mem.indexOf(u8, self.base_url, "/api/v2")) |idx| {
            return std.fmt.allocPrint(self.allocator, "{s}/api/v3", .{self.base_url[0..idx]});
        }
        if (std.mem.indexOf(u8, self.base_url, "/api/v3")) |idx| {
            return std.fmt.allocPrint(self.allocator, "{s}/api/v3", .{self.base_url[0..idx]});
        }
        return error.InvalidApiBaseUrl;
    }

    pub fn getBalance(self: *TonHttpClient, addr: []const u8) !types.BalanceResponse {
        const params = try std.fmt.allocPrint(self.allocator, "{{\"address\":\"{s}\"}}", .{addr});
        defer self.allocator.free(params);

        const response_json = try self.executeJsonRpc("getAddressBalance", params);
        defer self.allocator.free(response_json);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_json, .{});
        defer parsed.deinit();

        const result = parsed.value.object.get("result") orelse return types.TonError.RpcError;
        const balance = switch (result) {
            .string => try std.fmt.parseInt(u64, result.string, 10),
            .integer => @as(u64, @intCast(result.integer)),
            .object => if (result.object.get("balance")) |balance_val|
                try std.fmt.parseInt(u64, balance_val.string, 10)
            else
                return types.TonError.RpcError,
            else => return types.TonError.RpcError,
        };

        return types.BalanceResponse{ .balance = balance, .address = addr };
    }

    pub fn runGetMethod(self: *TonHttpClient, addr: []const u8, method_name: []const u8, stack: []const []const u8) !types.RunGetMethodResponse {
        const stack_json = try buildStackJson(self.allocator, stack);
        defer self.allocator.free(stack_json);

        return self.runGetMethodJson(addr, method_name, stack_json);
    }

    pub fn runGetMethodJson(
        self: *TonHttpClient,
        addr: []const u8,
        method_name: []const u8,
        stack_json: []const u8,
    ) !types.RunGetMethodResponse {
        var parsed_stack = try std.json.parseFromSlice(std.json.Value, self.allocator, stack_json, .{});
        defer parsed_stack.deinit();

        if (parsed_stack.value != .array) return error.InvalidResponse;

        const params = try std.fmt.allocPrint(
            self.allocator,
            "{{\"address\":\"{s}\",\"method\":\"{s}\",\"stack\":{s}}}",
            .{ addr, method_name, stack_json },
        );
        defer self.allocator.free(params);

        const response_json = try self.executeJsonRpc("runGetMethod", params);
        defer self.allocator.free(response_json);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_json, .{});
        defer parsed.deinit();

        const result = parsed.value.object.get("result") orelse return types.TonError.RpcError;

        const exit_code = if (result.object.get("exit_code")) |ec|
            switch (ec) {
                .integer => @as(i32, @intCast(ec.integer)),
                .string => try std.fmt.parseInt(i32, ec.string, 10),
                else => 0,
            }
        else
            0;

        var stack_entries: []types.StackEntry = &.{};
        if (result.object.get("stack")) |stack_val| {
            stack_entries = try parseStack(self.allocator, stack_val);
        }

        const logs = if (result.object.get("logs")) |logs_val|
            try self.allocator.dupe(u8, logs_val.string)
        else
            try self.allocator.dupe(u8, "");

        return types.RunGetMethodResponse{
            .exit_code = exit_code,
            .stack = stack_entries,
            .logs = logs,
        };
    }

    pub fn freeRunGetMethodResponse(self: *TonHttpClient, response: *types.RunGetMethodResponse) void {
        for (response.stack) |*entry| {
            freeStackEntry(self.allocator, entry);
        }
        if (response.stack.len > 0) self.allocator.free(response.stack);
        if (response.logs.len > 0) self.allocator.free(response.logs);

        response.stack = &.{};
        response.logs = "";
    }

    pub fn freeSendBocResponse(self: *TonHttpClient, response: *types.SendBocResponse) void {
        if (response.hash.len > 0) self.allocator.free(response.hash);
        response.hash = "";
        response.lt = 0;
    }

    pub fn sendBoc(self: *TonHttpClient, body: []const u8) !types.SendBocResponse {
        const encoded_len = std.base64.standard.Encoder.calcSize(body.len);
        const encoded = try self.allocator.alloc(u8, encoded_len);
        defer self.allocator.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, body);

        const params = try std.fmt.allocPrint(self.allocator, "{{\"boc\":\"{s}\"}}", .{encoded});
        defer self.allocator.free(params);

        const response_json = try self.executeJsonRpc("sendBoc", params);
        defer self.allocator.free(response_json);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_json, .{});
        defer parsed.deinit();

        const result = parsed.value.object.get("result") orelse return types.TonError.RpcError;
        return switch (result) {
            .string => types.SendBocResponse{
                .hash = try self.allocator.dupe(u8, result.string),
                .lt = 0,
            },
            .object => types.SendBocResponse{
                .hash = if (result.object.get("hash")) |hash_val|
                    try self.allocator.dupe(u8, hash_val.string)
                else
                    return types.TonError.RpcError,
                .lt = if (result.object.get("lt")) |lt_val|
                    try parseInt64Value(lt_val)
                else
                    0,
            },
            else => return types.TonError.RpcError,
        };
    }

    pub fn sendBocBase64(self: *TonHttpClient, body_base64: []const u8) !types.SendBocResponse {
        const decoded = try decodeBase64Flexible(self.allocator, body_base64);
        defer self.allocator.free(decoded);

        return self.sendBoc(decoded);
    }

    pub fn sendBocHex(self: *TonHttpClient, body_hex: []const u8) !types.SendBocResponse {
        const decoded = try decodeHex(self.allocator, body_hex);
        defer self.allocator.free(decoded);

        return self.sendBoc(decoded);
    }

    pub fn getTransactions(self: *TonHttpClient, addr: []const u8, limit: u32) ![]types.Transaction {
        const url = try buildTransactionsUrl(self, addr, null, limit);
        defer self.allocator.free(url);

        const response_json = try self.executeHttp(.GET, url, null, false);
        defer self.allocator.free(response_json);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_json, .{});
        defer parsed.deinit();

        const txs = parsed.value.object.get("transactions") orelse return types.TonError.RpcError;
        return parseTransactions(self.allocator, txs);
    }

    pub fn lookupTx(self: *TonHttpClient, lt: i64, hash: []const u8) !?types.Transaction {
        _ = lt;

        const url = try buildTransactionsUrl(self, null, hash, 1);
        defer self.allocator.free(url);

        const response_json = try self.executeHttp(.GET, url, null, false);
        defer self.allocator.free(response_json);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_json, .{});
        defer parsed.deinit();

        const txs = parsed.value.object.get("transactions") orelse return null;
        const transactions = try parseTransactions(self.allocator, txs);
        defer if (transactions.len == 0) self.allocator.free(transactions);

        if (transactions.len == 0) return null;

        const tx = transactions[0];
        self.allocator.free(transactions);
        return tx;
    }

    pub fn freeTransaction(self: *TonHttpClient, tx: *types.Transaction) void {
        if (tx.hash.len > 0) self.allocator.free(tx.hash);
        if (tx.in_msg) |msg| self.freeMessage(msg);
        for (tx.out_msgs) |msg| self.freeMessage(msg);
        if (tx.out_msgs.len > 0) self.allocator.free(tx.out_msgs);
        tx.* = undefined;
    }

    pub fn freeTransactions(self: *TonHttpClient, txs: []types.Transaction) void {
        for (txs) |*tx| self.freeTransaction(tx);
        if (txs.len > 0) self.allocator.free(txs);
    }

    fn freeMessage(self: *TonHttpClient, msg: *types.Message) void {
        if (msg.hash.len > 0) self.allocator.free(msg.hash);
        if (msg.raw_body.len > 0) self.allocator.free(msg.raw_body);
        if (msg.body) |body| body.deinit(self.allocator);
        self.allocator.destroy(msg);
    }
};

fn buildStackJson(allocator: std.mem.Allocator, stack: []const []const u8) ![]u8 {
    if (stack.len == 0) return allocator.dupe(u8, "[]");

    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    try writer.writer.writeByte('[');
    for (stack, 0..) |item, i| {
        if (i != 0) try writer.writer.writeByte(',');
        try writer.writer.writeAll(item);
    }
    try writer.writer.writeByte(']');

    return try writer.toOwnedSlice();
}

fn parseStack(allocator: std.mem.Allocator, value: std.json.Value) anyerror![]types.StackEntry {
    const items = try extractStackItems(value);

    const entries = try allocator.alloc(types.StackEntry, items.len);
    errdefer allocator.free(entries);

    for (items, 0..) |item, i| {
        entries[i] = try parseStackEntry(allocator, item);
    }

    return entries;
}

fn parseStackEntry(allocator: std.mem.Allocator, value: std.json.Value) anyerror!types.StackEntry {
    const normalized = try normalizeStackEntry(allocator, value);
    defer if (normalized.owned_tag) |tag| allocator.free(tag);

    if (std.mem.eql(u8, normalized.tag, "null")) {
        return .{ .null = {} };
    }

    if (normalized.payload == null) return error.InvalidResponse;
    const raw_value = normalized.payload.?;

    if (std.mem.eql(u8, normalized.tag, "num") or std.mem.eql(u8, normalized.tag, "int")) {
        return try parseTonNumber(allocator, raw_value);
    }

    if (std.mem.eql(u8, normalized.tag, "tuple")) {
        const items = try parseStack(allocator, raw_value);
        return .{ .tuple = items };
    }

    if (std.mem.eql(u8, normalized.tag, "list")) {
        const items = try parseStack(allocator, raw_value);
        return .{ .list = items };
    }

    if (std.mem.eql(u8, normalized.tag, "bytes")) {
        return .{ .bytes = try dupStackString(allocator, raw_value) };
    }

    if (std.mem.eql(u8, normalized.tag, "cell") or std.mem.eql(u8, normalized.tag, "slice") or std.mem.eql(u8, normalized.tag, "builder")) {
        const boc_base64 = try extractStackBytes(raw_value);
        const boc_bytes = try decodeBase64Flexible(allocator, boc_base64);
        defer allocator.free(boc_bytes);

        const parsed_cell = try boc.deserializeBoc(allocator, boc_bytes);
        if (std.mem.eql(u8, normalized.tag, "cell")) {
            return .{ .cell = parsed_cell };
        }
        if (std.mem.eql(u8, normalized.tag, "slice")) {
            return .{ .slice = parsed_cell };
        }
        return .{ .builder = parsed_cell };
    }

    return error.UnsupportedStackEntry;
}

const NormalizedStackEntry = struct {
    tag: []const u8,
    payload: ?std.json.Value,
    owned_tag: ?[]u8 = null,
};

fn normalizeStackEntry(allocator: std.mem.Allocator, value: std.json.Value) !NormalizedStackEntry {
    return switch (value) {
        .array => {
            if (value.array.items.len == 0) return error.InvalidResponse;
            if (value.array.items[0] != .string) return error.InvalidResponse;
            const normalized_tag = try normalizeStackTagAlloc(allocator, value.array.items[0].string);

            return .{
                .tag = normalized_tag,
                .payload = if (value.array.items.len >= 2) value.array.items[1] else null,
                .owned_tag = normalized_tag,
            };
        },
        .object => {
            const raw_tag = if (value.object.get("type")) |tag_val|
                try dupJsonString(allocator, tag_val)
            else if (value.object.get("@type")) |tag_val|
                try dupJsonString(allocator, tag_val)
            else
                return error.InvalidResponse;
            errdefer allocator.free(raw_tag);
            const normalized_tag = try normalizeStackTagAlloc(allocator, raw_tag);
            allocator.free(raw_tag);

            return .{
                .tag = normalized_tag,
                .payload = stackEntryObjectPayload(value.object),
                .owned_tag = normalized_tag,
            };
        },
        else => error.InvalidResponse,
    };
}

fn normalizeStackTagAlloc(allocator: std.mem.Allocator, raw_tag: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw_tag, " \t\r\n");
    var normalized = try allocator.alloc(u8, trimmed.len);
    errdefer allocator.free(normalized);

    for (trimmed, 0..) |char, idx| {
        normalized[idx] = std.ascii.toLower(char);
    }

    if (std.mem.startsWith(u8, normalized, "tvm.")) {
        const out = try allocator.dupe(u8, normalized["tvm.".len..]);
        allocator.free(normalized);
        normalized = out;
    }

    if (std.mem.eql(u8, normalized, "vm_stk_null") or std.mem.eql(u8, normalized, "none")) {
        const out = try allocator.dupe(u8, "null");
        allocator.free(normalized);
        return out;
    }

    if (std.mem.eql(u8, normalized, "number")) {
        const out = try allocator.dupe(u8, "num");
        allocator.free(normalized);
        return out;
    }

    if (std.mem.eql(u8, normalized, "integer")) {
        const out = try allocator.dupe(u8, "int");
        allocator.free(normalized);
        return out;
    }

    if (std.mem.eql(u8, normalized, "stackentrynumber")) {
        const out = try allocator.dupe(u8, "num");
        allocator.free(normalized);
        return out;
    }

    if (std.mem.eql(u8, normalized, "stackentrycell")) {
        const out = try allocator.dupe(u8, "cell");
        allocator.free(normalized);
        return out;
    }

    if (std.mem.eql(u8, normalized, "stackentryslice")) {
        const out = try allocator.dupe(u8, "slice");
        allocator.free(normalized);
        return out;
    }

    if (std.mem.eql(u8, normalized, "stackentrybuilder")) {
        const out = try allocator.dupe(u8, "builder");
        allocator.free(normalized);
        return out;
    }

    if (std.mem.eql(u8, normalized, "stackentrytuple")) {
        const out = try allocator.dupe(u8, "tuple");
        allocator.free(normalized);
        return out;
    }

    if (std.mem.eql(u8, normalized, "stackentrylist")) {
        const out = try allocator.dupe(u8, "list");
        allocator.free(normalized);
        return out;
    }

    if (std.mem.eql(u8, normalized, "stackentryunsupported")) {
        const out = try allocator.dupe(u8, "unsupported");
        allocator.free(normalized);
        return out;
    }

    return normalized;
}

fn stackEntryObjectPayload(object: std.json.ObjectMap) ?std.json.Value {
    return object.get("value") orelse
        object.get("val") orelse
        object.get("bytes") orelse
        object.get("number") orelse
        object.get("cell") orelse
        object.get("slice") orelse
        object.get("builder") orelse
        object.get("elements") orelse
        object.get("items") orelse
        object.get("list") orelse
        object.get("tuple");
}

fn extractStackItems(value: std.json.Value) ![]const std.json.Value {
    return switch (value) {
        .array => value.array.items,
        .object => if (stackEntryObjectPayload(value.object)) |payload|
            extractStackItems(payload)
        else
            error.InvalidResponse,
        else => error.InvalidResponse,
    };
}

fn freeStackEntry(allocator: std.mem.Allocator, entry: *types.StackEntry) void {
    switch (entry.*) {
        .tuple => |items| {
            for (items) |*child| freeStackEntry(allocator, child);
            allocator.free(items);
        },
        .list => |items| {
            for (items) |*child| freeStackEntry(allocator, child);
            allocator.free(items);
        },
        .big_number => |value| if (value.len > 0) allocator.free(value),
        .cell => |value| value.deinit(allocator),
        .slice => |value| value.deinit(allocator),
        .builder => |value| value.deinit(allocator),
        .bytes => |bytes| if (bytes.len > 0) allocator.free(bytes),
        else => {},
    }
}

fn extractStackBytes(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => value.string,
        .object => if (value.object.get("bytes")) |bytes_value|
            switch (bytes_value) {
                .string => bytes_value.string,
                else => error.InvalidResponse,
            }
        else if (value.object.get("boc")) |boc_value|
            switch (boc_value) {
                .string => boc_value.string,
                else => error.InvalidResponse,
            }
        else if (value.object.get("value")) |nested_value|
            try extractStackBytes(nested_value)
        else
            error.InvalidResponse,
        else => error.UnsupportedStackEntry,
    };
}

fn dupStackString(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return switch (value) {
        .string => allocator.dupe(u8, value.string),
        .object => if (value.object.get("value")) |nested|
            dupStackString(allocator, nested)
        else if (value.object.get("bytes")) |nested|
            dupStackString(allocator, nested)
        else
            error.InvalidResponse,
        else => error.InvalidResponse,
    };
}

fn parseTonNumber(allocator: std.mem.Allocator, value: std.json.Value) !types.StackEntry {
    return switch (value) {
        .integer => .{ .number = @as(i64, @intCast(value.integer)) },
        .string => {
            if (parseTonIntText(value.string)) |small_value| {
                return .{ .number = small_value };
            } else |err| switch (err) {
                error.Overflow => {
                    if (!isValidTonNumberText(value.string)) return error.InvalidResponse;
                    return .{ .big_number = try allocator.dupe(u8, value.string) };
                },
                else => return error.InvalidResponse,
            }
        },
        .object => if (value.object.get("value")) |nested|
            parseTonNumber(allocator, nested)
        else if (value.object.get("number")) |nested|
            parseTonNumber(allocator, nested)
        else
            error.InvalidResponse,
        else => error.InvalidResponse,
    };
}

fn parseTonIntText(value: []const u8) !i64 {
    if (std.mem.startsWith(u8, value, "-0x")) {
        const magnitude = try std.fmt.parseInt(u64, value[3..], 16);
        if (magnitude > @as(u64, @intCast(std.math.maxInt(i64))) + 1) return error.Overflow;
        if (magnitude == @as(u64, @intCast(std.math.maxInt(i64))) + 1) return std.math.minInt(i64);
        return -@as(i64, @intCast(magnitude));
    }
    if (std.mem.startsWith(u8, value, "0x")) {
        return @intCast(try std.fmt.parseInt(u64, value[2..], 16));
    }
    return try std.fmt.parseInt(i64, value, 10);
}

fn isValidTonNumberText(value: []const u8) bool {
    if (value.len == 0) return false;

    var text = value;
    if (text[0] == '-') {
        if (text.len == 1) return false;
        text = text[1..];
    }

    if (std.mem.startsWith(u8, text, "0x")) {
        const hex = text[2..];
        if (hex.len == 0) return false;
        for (hex) |char| {
            if (!std.ascii.isHex(char)) return false;
        }
        return true;
    }

    for (text) |char| {
        if (!std.ascii.isDigit(char)) return false;
    }
    return true;
}

fn buildTransactionsUrl(
    client: *TonHttpClient,
    account: ?[]const u8,
    hash: ?[]const u8,
    limit: u32,
) ![]u8 {
    var writer = std.io.Writer.Allocating.init(client.allocator);
    errdefer writer.deinit();

    const base = try client.apiV3Base();
    defer client.allocator.free(base);

    try writer.writer.print("{s}/transactions?", .{base});

    var needs_amp = false;
    if (account) |address_value| {
        try writer.writer.writeAll("account=");
        try (std.Uri.Component{ .raw = address_value }).formatQuery(&writer.writer);
        needs_amp = true;
    }

    if (hash) |hash_value| {
        if (needs_amp) try writer.writer.writeByte('&');
        try writer.writer.writeAll("hash=");
        try (std.Uri.Component{ .raw = hash_value }).formatQuery(&writer.writer);
        needs_amp = true;
    }

    if (needs_amp) try writer.writer.writeByte('&');
    try writer.writer.print("limit={d}&sort=desc", .{limit});

    return try writer.toOwnedSlice();
}

fn parseTransactions(allocator: std.mem.Allocator, value: std.json.Value) ![]types.Transaction {
    if (value != .array) return error.InvalidResponse;

    const txs = try allocator.alloc(types.Transaction, value.array.items.len);
    errdefer allocator.free(txs);

    for (value.array.items, 0..) |item, i| {
        txs[i] = try parseTransaction(allocator, item);
    }

    return txs;
}

fn parseTransaction(allocator: std.mem.Allocator, value: std.json.Value) !types.Transaction {
    const object = value.object;

    var out_msgs: []*types.Message = &.{};
    if (object.get("out_msgs")) |out_msgs_value| {
        if (out_msgs_value == .array) {
            out_msgs = try allocator.alloc(*types.Message, out_msgs_value.array.items.len);
            for (out_msgs_value.array.items, 0..) |out_msg, i| {
                out_msgs[i] = try parseMessage(allocator, out_msg);
            }
        }
    }

    return types.Transaction{
        .hash = try dupJsonString(allocator, object.get("hash") orelse return error.InvalidResponse),
        .lt = try parseInt64Value(object.get("lt") orelse return error.InvalidResponse),
        .timestamp = try parseInt64Value((object.get("now") orelse object.get("utime") orelse return error.InvalidResponse)),
        .in_msg = if (object.get("in_msg")) |in_msg| try parseMessage(allocator, in_msg) else null,
        .out_msgs = out_msgs,
    };
}

fn parseMessage(allocator: std.mem.Allocator, value: std.json.Value) !*types.Message {
    const object = value.object;
    const msg = try allocator.create(types.Message);
    errdefer allocator.destroy(msg);

    var raw_body: []u8 = &.{};
    var body_cell: ?*boc.Cell = null;

    if (object.get("message_content")) |content| {
        if (content == .object) {
            if (content.object.get("body")) |body_value| {
                if (body_value == .string and body_value.string.len > 0) {
                    raw_body = try decodeBase64Standard(allocator, body_value.string);
                    body_cell = boc.deserializeBoc(allocator, raw_body) catch null;
                }
            } else if (content.object.get("decoded")) |decoded_value| {
                if (decoded_value == .string) {
                    raw_body = try allocator.dupe(u8, decoded_value.string);
                } else if (decoded_value == .object) {
                    if (decoded_value.object.get("comment")) |comment_value| {
                        raw_body = try dupJsonString(allocator, comment_value);
                    }
                }
            }
        }
    }

    msg.* = .{
        .hash = try dupJsonString(allocator, object.get("hash") orelse return error.InvalidResponse),
        .source = try parseOptionalAddress(object.get("source")),
        .destination = try parseOptionalAddress(object.get("destination")),
        .value = if (object.get("value")) |value_field| try parseUint64Value(value_field) else 0,
        .body = body_cell,
        .raw_body = raw_body,
    };

    return msg;
}

fn parseOptionalAddress(value: ?std.json.Value) !?types.Address {
    const address_value = value orelse return null;
    return switch (address_value) {
        .null => null,
        .string => if (address_value.string.len == 0)
            null
        else
            try address.parseAddress(address_value.string),
        else => error.InvalidResponse,
    };
}

fn dupJsonString(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return switch (value) {
        .string => allocator.dupe(u8, value.string),
        else => error.InvalidResponse,
    };
}

fn decodeBase64Standard(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return decodeBase64WithDecoder(allocator, input, std.base64.standard.Decoder);
}

fn decodeBase64Flexible(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return decodeBase64WithDecoder(allocator, input, std.base64.standard.Decoder) catch
        decodeBase64WithDecoder(allocator, input, std.base64.url_safe.Decoder);
}

fn decodeBase64WithDecoder(
    allocator: std.mem.Allocator,
    input: []const u8,
    comptime decoder: anytype,
) ![]u8 {
    const decoded_len = try decoder.calcSizeForSlice(input);
    const output = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(output);
    try decoder.decode(output, input);
    return output;
}

fn decodeHex(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (input.len % 2 != 0) return error.InvalidHex;

    const output = try allocator.alloc(u8, input.len / 2);
    errdefer allocator.free(output);

    var i: usize = 0;
    while (i < output.len) : (i += 1) {
        output[i] = (try hexCharValue(input[i * 2]) << 4) | try hexCharValue(input[i * 2 + 1]);
    }

    return output;
}

fn hexCharValue(char: u8) !u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => error.InvalidHex,
    };
}

fn parseInt64Value(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => @as(i64, @intCast(value.integer)),
        .string => try std.fmt.parseInt(i64, value.string, 10),
        else => error.InvalidResponse,
    };
}

fn parseUint64Value(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => @as(u64, @intCast(value.integer)),
        .string => try std.fmt.parseInt(u64, value.string, 10),
        else => error.InvalidResponse,
    };
}

test "parse runGetMethod stack number" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "result": {
        \\    "exit_code": 0,
        \\    "stack": [["num", "0x2a"]],
        \\    "logs": ""
        \\  }
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const stack = try parseStack(allocator, parsed.value.object.get("result").?.object.get("stack").?);
    defer {
        var client = TonHttpClient{
            .allocator = allocator,
            .base_url = "",
            .api_key = null,
            .http_client = .{ .allocator = allocator },
        };
        var response = types.RunGetMethodResponse{
            .exit_code = 0,
            .stack = stack,
            .logs = "",
        };
        client.freeRunGetMethodResponse(&response);
    }

    try std.testing.expectEqual(@as(i64, 42), stack[0].number);
}

test "parse runGetMethod stack big number" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "result": {
        \\    "exit_code": 0,
        \\    "stack": [["num", "0x1234567890abcdef1234567890abcdef"]],
        \\    "logs": ""
        \\  }
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const stack = try parseStack(allocator, parsed.value.object.get("result").?.object.get("stack").?);
    defer {
        var client = TonHttpClient{
            .allocator = allocator,
            .base_url = "",
            .api_key = null,
            .http_client = .{ .allocator = allocator },
        };
        var response = types.RunGetMethodResponse{
            .exit_code = 0,
            .stack = stack,
            .logs = "",
        };
        client.freeRunGetMethodResponse(&response);
    }

    try std.testing.expectEqualStrings("0x1234567890abcdef1234567890abcdef", stack[0].big_number);
}

test "build stack json from raw items" {
    const allocator = std.testing.allocator;
    const stack = try buildStackJson(allocator, &.{
        "[\"num\",\"0x2a\"]",
        "[\"tuple\",[]]",
    });
    defer allocator.free(stack);

    try std.testing.expectEqualStrings("[[\"num\",\"0x2a\"],[\"tuple\",[]]]", stack);
}

test "parse runGetMethod stack cell" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "result": {
        \\    "exit_code": 0,
        \\    "stack": [["cell", "te6cckEBAQEABgAACP/////btDe4"]],
        \\    "logs": ""
        \\  }
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const stack = try parseStack(allocator, parsed.value.object.get("result").?.object.get("stack").?);
    defer {
        var client = TonHttpClient{
            .allocator = allocator,
            .base_url = "",
            .api_key = null,
            .http_client = .{ .allocator = allocator },
        };
        var response = types.RunGetMethodResponse{
            .exit_code = 0,
            .stack = stack,
            .logs = "",
        };
        client.freeRunGetMethodResponse(&response);
    }

    try std.testing.expectEqual(@as(u16, 32), stack[0].cell.bit_len);
}

test "parse runGetMethod stack supports null list builder and bytes" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "result": {
        \\    "exit_code": 0,
        \\    "stack": [
        \\      ["null"],
        \\      ["builder", "te6cckEBAQEABgAACP/////btDe4"],
        \\      ["list", [["num", "0x2a"], ["bytes", "https://example.com/abi.json"]]]
        \\    ],
        \\    "logs": ""
        \\  }
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const stack = try parseStack(allocator, parsed.value.object.get("result").?.object.get("stack").?);
    defer {
        var client = TonHttpClient{
            .allocator = allocator,
            .base_url = "",
            .api_key = null,
            .http_client = .{ .allocator = allocator },
        };
        var response = types.RunGetMethodResponse{
            .exit_code = 0,
            .stack = stack,
            .logs = "",
        };
        client.freeRunGetMethodResponse(&response);
    }

    try std.testing.expect(std.meta.activeTag(stack[0]) == .null);
    try std.testing.expectEqual(@as(u16, 32), stack[1].builder.bit_len);
    try std.testing.expectEqual(@as(usize, 2), stack[2].list.len);
    try std.testing.expectEqual(@as(i64, 42), stack[2].list[0].number);
    try std.testing.expectEqualStrings("https://example.com/abi.json", stack[2].list[1].bytes);
}

test "parse runGetMethod stack supports object entries and tvm tags" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "result": {
        \\    "exit_code": 0,
        \\    "stack": [
        \\      {"type":"tvm.Number","value":"0x2a"},
        \\      {"type":"tvm.Slice","value":{"bytes":"te6cckEBAQEABgAACP/////btDe4"}},
        \\      {"type":"bytes","value":"hello"},
        \\      {"type":"tvm.Tuple","items":[
        \\        {"type":"int","value":{"number":"-1"}},
        \\        {"type":"null"}
        \\      ]}
        \\    ],
        \\    "logs": ""
        \\  }
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const stack = try parseStack(allocator, parsed.value.object.get("result").?.object.get("stack").?);
    defer {
        var client = TonHttpClient{
            .allocator = allocator,
            .base_url = "",
            .api_key = null,
            .http_client = .{ .allocator = allocator },
        };
        var response = types.RunGetMethodResponse{
            .exit_code = 0,
            .stack = stack,
            .logs = "",
        };
        client.freeRunGetMethodResponse(&response);
    }

    try std.testing.expectEqual(@as(i64, 42), stack[0].number);
    try std.testing.expectEqual(@as(u16, 32), stack[1].slice.bit_len);
    try std.testing.expectEqualStrings("hello", stack[2].bytes);
    try std.testing.expectEqual(@as(usize, 2), stack[3].tuple.len);
    try std.testing.expectEqual(@as(i64, -1), stack[3].tuple[0].number);
    try std.testing.expect(std.meta.activeTag(stack[3].tuple[1]) == .null);
}

test "parse runGetMethod stack supports object wrapped list payload" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "result": {
        \\    "exit_code": 0,
        \\    "stack": {
        \\      "items": [
        \\        {"type":"list","value":{"items":[{"type":"num","value":"0x2"}]}}
        \\      ]
        \\    },
        \\    "logs": ""
        \\  }
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const stack = try parseStack(allocator, parsed.value.object.get("result").?.object.get("stack").?);
    defer {
        var client = TonHttpClient{
            .allocator = allocator,
            .base_url = "",
            .api_key = null,
            .http_client = .{ .allocator = allocator },
        };
        var response = types.RunGetMethodResponse{
            .exit_code = 0,
            .stack = stack,
            .logs = "",
        };
        client.freeRunGetMethodResponse(&response);
    }

    try std.testing.expectEqual(@as(usize, 1), stack.len);
    try std.testing.expectEqual(@as(usize, 1), stack[0].list.len);
    try std.testing.expectEqual(@as(i64, 2), stack[0].list[0].number);
}

test "parse runGetMethod stack supports tonlib stackentry objects" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "result": {
        \\    "exit_code": 0,
        \\    "stack": {
        \\      "elements": [
        \\        {
        \\          "@type": "tvm.stackEntryNumber",
        \\          "number": {
        \\            "@type": "tvm.numberDecimal",
        \\            "number": "42"
        \\          }
        \\        },
        \\        {
        \\          "@type": "tvm.stackEntryCell",
        \\          "cell": {
        \\            "bytes": "te6cckEBAQEABgAACP/////btDe4"
        \\          }
        \\        },
        \\        {
        \\          "@type": "tvm.stackEntryTuple",
        \\          "tuple": {
        \\            "@type": "tvm.tuple",
        \\            "elements": [
        \\              {
        \\                "@type": "tvm.stackEntryList",
        \\                "list": {
        \\                  "@type": "tvm.list",
        \\                  "elements": [
        \\                    {
        \\                      "@type": "tvm.stackEntryNumber",
        \\                      "number": "0x2"
        \\                    }
        \\                  ]
        \\                }
        \\              }
        \\            ]
        \\          }
        \\        }
        \\      ]
        \\    },
        \\    "logs": ""
        \\  }
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const stack = try parseStack(allocator, parsed.value.object.get("result").?.object.get("stack").?);
    defer {
        var client = TonHttpClient{
            .allocator = allocator,
            .base_url = "",
            .api_key = null,
            .http_client = .{ .allocator = allocator },
        };
        var response = types.RunGetMethodResponse{
            .exit_code = 0,
            .stack = stack,
            .logs = "",
        };
        client.freeRunGetMethodResponse(&response);
    }

    try std.testing.expectEqual(@as(usize, 3), stack.len);
    try std.testing.expectEqual(@as(i64, 42), stack[0].number);
    try std.testing.expectEqual(@as(u16, 32), stack[1].cell.bit_len);
    try std.testing.expectEqual(@as(usize, 1), stack[2].tuple.len);
    try std.testing.expectEqual(@as(usize, 1), stack[2].tuple[0].list.len);
    try std.testing.expectEqual(@as(i64, 2), stack[2].tuple[0].list[0].number);
}

test "decode base64 flexible accepts standard and url safe" {
    const allocator = std.testing.allocator;

    const standard = try decodeBase64Flexible(allocator, "+/8=");
    defer allocator.free(standard);
    try std.testing.expectEqualSlices(u8, &.{ 0xfb, 0xff }, standard);

    const url_safe = try decodeBase64Flexible(allocator, "-_8=");
    defer allocator.free(url_safe);
    try std.testing.expectEqualSlices(u8, &.{ 0xfb, 0xff }, url_safe);
}

test "decode hex payload" {
    const allocator = std.testing.allocator;
    const bytes = try decodeHex(allocator, "00A1ff");
    defer allocator.free(bytes);

    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0xA1, 0xff }, bytes);
}

test "parse v3 transaction payload" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "transactions": [
        \\    {
        \\      "hash": "tx_hash",
        \\      "lt": "123",
        \\      "now": 456,
        \\      "in_msg": {
        \\        "hash": "msg_hash",
        \\        "source": "0:83DFD552E63729B472FCBCC8C45EBCC6691702558B68EC7527E1BA403A0F31A8",
        \\        "destination": "EQCD39VS5jcptHL8vMjEXrzGaRcCVYto7HUn4bpAOg8xqB2N",
        \\        "value": "1000",
        \\        "message_content": {
        \\          "body": "te6cckEBAQEABgAACP/////btDe4",
        \\          "decoded": null,
        \\          "hash": "body_hash"
        \\        }
        \\      },
        \\      "out_msgs": []
        \\    }
        \\  ]
        \\}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const txs = try parseTransactions(allocator, parsed.value.object.get("transactions").?);
    defer {
        var client = TonHttpClient{
            .allocator = allocator,
            .base_url = "",
            .api_key = null,
            .http_client = .{ .allocator = allocator },
        };
        client.freeTransactions(txs);
    }

    try std.testing.expectEqual(@as(usize, 1), txs.len);
    try std.testing.expectEqual(@as(i64, 123), txs[0].lt);
    try std.testing.expect(txs[0].in_msg != null);
    try std.testing.expectEqual(@as(u16, 32), txs[0].in_msg.?.body.?.bit_len);
}
