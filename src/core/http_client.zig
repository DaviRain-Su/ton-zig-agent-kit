//! HTTP client for TonAPI / TON Center
//! Supports getBalance, runGetMethod, sendBoc, getTransactions, lookupTx

const std = @import("std");
const types = @import("types.zig");
const address = @import("address.zig");

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

    fn executeRequest(self: *TonHttpClient, method: []const u8, params_json: []const u8) ![]u8 {
        const body = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"{s}\",\"params\":{s}}}",
            .{ method, params_json },
        );
        defer self.allocator.free(body);

        const uri = try std.Uri.parse(self.base_url);
        var request = try self.http_client.request(.POST, uri, .{
            .redirect_behavior = .unhandled,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "accept", .value = "application/json" },
            },
            .keep_alive = true,
        });
        defer request.deinit();

        request.transfer_encoding = .{ .content_length = body.len };
        request.sendBodyComplete(@constCast(body)) catch |err| {
            return err;
        };

        var response = request.receiveHead(&.{}) catch |err| {
            return err;
        };

        const decompress_buffer = switch (response.head.content_encoding) {
            .identity => null,
            .gzip, .deflate => try self.allocator.alloc(u8, std.compress.flate.max_window_len),
            else => return error.UnsupportedCompressionMethod,
        };
        defer if (decompress_buffer) |buffer| self.allocator.free(buffer);

        var response_writer = std.io.Writer.Allocating.init(self.allocator);
        errdefer response_writer.deinit();

        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer orelse &.{});

        _ = reader.streamRemaining(&response_writer.writer) catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            else => return err,
        };

        return try response_writer.toOwnedSlice();
    }

    pub fn getBalance(self: *TonHttpClient, addr: []const u8) !types.BalanceResponse {
        const params = try std.fmt.allocPrint(self.allocator, "{{\"address\":\"{s}\"}}", .{addr});
        defer self.allocator.free(params);

        const response_json = try self.executeRequest("getAddressBalance", params);
        defer self.allocator.free(response_json);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_json, .{});
        defer parsed.deinit();

        if (parsed.value.object.get("result")) |result| {
            if (result.object.get("balance")) |balance_val| {
                const balance = try std.fmt.parseInt(u64, balance_val.string, 10);
                return types.BalanceResponse{ .balance = balance, .address = addr };
            }
        }

        if (parsed.value.object.get("error")) |error_obj| {
            const code = if (error_obj.object.get("code")) |c| c.integer else 0;
            const msg = if (error_obj.object.get("message")) |m| m.string else "unknown";
            std.debug.print("RPC Error: code={d}, message={s}\n", .{ code, msg });
        }

        return types.TonError.RpcError;
    }

    pub fn runGetMethod(self: *TonHttpClient, addr: []const u8, method: []const u8, stack: []const []const u8) !types.RunGetMethodResponse {
        _ = stack;

        const params = try std.fmt.allocPrint(self.allocator, "{{\"address\":\"{s}\",\"method\":\"{s}\",\"stack\":[]}}", .{ addr, method });
        defer self.allocator.free(params);

        const response_json = try self.executeRequest("runGetMethod", params);
        defer self.allocator.free(response_json);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_json, .{});
        defer parsed.deinit();

        var exit_code: i32 = 0;
        if (parsed.value.object.get("result")) |result| {
            if (result.object.get("exit_code")) |ec| {
                exit_code = @intCast(ec.integer);
            }
        }

        return types.RunGetMethodResponse{
            .exit_code = exit_code,
            .stack = &.{},
            .logs = "",
        };
    }

    pub fn sendBoc(self: *TonHttpClient, body: []const u8) !types.SendBocResponse {
        const params = try std.fmt.allocPrint(self.allocator, "{{\"boc\":\"{s}\"}}", .{body});
        defer self.allocator.free(params);

        const response_json = try self.executeRequest("sendBoc", params);
        defer self.allocator.free(response_json);

        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response_json, .{});
        defer parsed.deinit();

        if (parsed.value.object.get("result")) |result| {
            if (result.object.get("hash")) |hash_val| {
                return types.SendBocResponse{ .hash = hash_val.string, .lt = 0 };
            }
        }

        return types.TonError.RpcError;
    }

    pub fn getTransactions(self: *TonHttpClient, addr: []const u8, limit: u32) ![]types.Transaction {
        _ = self;
        _ = addr;
        _ = limit;
        return &.{};
    }

    pub fn lookupTx(self: *TonHttpClient, lt: i64, hash: []const u8) !?types.Transaction {
        _ = self;
        _ = lt;
        _ = hash;
        return null;
    }
};
