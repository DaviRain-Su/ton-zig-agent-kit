//! Multi-provider failover support

const std = @import("std");
const http_client = @import("http_client.zig");
const types = @import("types.zig");

pub const ProviderConfig = struct {
    url: []const u8,
    api_key: ?[]const u8 = null,
};

pub const MultiProvider = struct {
    allocator: std.mem.Allocator,
    providers: []ProviderConfig,
    current_index: usize = 0,

    pub fn init(allocator: std.mem.Allocator, providers: []ProviderConfig) !MultiProvider {
        return MultiProvider{
            .allocator = allocator,
            .providers = providers,
            .current_index = 0,
        };
    }

    pub fn getClient(self: *MultiProvider) !http_client.TonHttpClient {
        const config = self.providers[self.current_index];
        return http_client.TonHttpClient.init(self.allocator, config.url, config.api_key);
    }

    pub fn failover(self: *MultiProvider) void {
        self.current_index = (self.current_index + 1) % self.providers.len;
    }
};

pub fn createDefaultProvider(allocator: std.mem.Allocator) !MultiProvider {
    return MultiProvider.init(allocator, &.{
        .{ .url = "https://tonapi.io" },
        .{ .url = "https://toncenter.com/api/v2" },
    });
}
