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
    if (value != .array) return error.InvalidResponse;

    const entries = try allocator.alloc(types.StackEntry, value.array.items.len);
    errdefer allocator.free(entries);

    for (value.array.items, 0..) |item, i| {
        entries[i] = try parseStackEntry(allocator, item);
    }

    return entries;
}

fn parseStackEntry(allocator: std.mem.Allocator, value: std.json.Value) anyerror!types.StackEntry {
    if (value != .array or value.array.items.len < 2) return error.InvalidResponse;

    const tag = value.array.items[0].string;
    const raw_value = value.array.items[1];

    if (std.mem.eql(u8, tag, "num") or std.mem.eql(u8, tag, "int")) {
        return .{ .number = try parseTonInt(raw_value) };
    }

    if (std.mem.eql(u8, tag, "tuple")) {
        const items = try parseStack(allocator, raw_value);
        return .{ .tuple = items };
    }

    if (std.mem.eql(u8, tag, "cell") or std.mem.eql(u8, tag, "slice")) {
        const bytes = switch (raw_value) {
            .string => try allocator.dupe(u8, raw_value.string),
            else => return error.UnsupportedStackEntry,
        };
        return .{ .bytes = bytes };
    }

    return error.UnsupportedStackEntry;
}

fn freeStackEntry(allocator: std.mem.Allocator, entry: *types.StackEntry) void {
    switch (entry.*) {
        .tuple => |items| {
            for (items) |*child| freeStackEntry(allocator, child);
            allocator.free(items);
        },
        .bytes => |bytes| if (bytes.len > 0) allocator.free(bytes),
        else => {},
    }
}

fn parseTonInt(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => @as(i64, @intCast(value.integer)),
        .string => {
            if (std.mem.startsWith(u8, value.string, "-0x")) {
                const magnitude = try std.fmt.parseInt(u64, value.string[3..], 16);
                if (magnitude > @as(u64, @intCast(std.math.maxInt(i64))) + 1) return error.Overflow;
                return -@as(i64, @intCast(magnitude));
            }
            if (std.mem.startsWith(u8, value.string, "0x")) {
                return @intCast(try std.fmt.parseInt(u64, value.string[2..], 16));
            }
            return try std.fmt.parseInt(i64, value.string, 10);
        },
        else => error.InvalidResponse,
    };
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

    var client = try TonHttpClient.init(allocator, "https://toncenter.com/api/v2/jsonRPC", null);
    defer client.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const stack = try parseStack(allocator, parsed.value.object.get("result").?.object.get("stack").?);
    defer allocator.free(stack);

    try std.testing.expectEqual(@as(i64, 42), stack[0].number);
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
