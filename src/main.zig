const std = @import("std");
const ton_zig_agent_kit = @import("ton_zig_agent_kit");

pub fn main() !void {
    std.debug.print("ton-zig-agent-kit v{s}\n", .{"0.0.1"});
    std.debug.print("Run `zig build test` to run tests.\n", .{});
}

test "basic test" {
    try std.testing.expect(true);
}
