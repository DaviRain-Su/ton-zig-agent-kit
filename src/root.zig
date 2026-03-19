//! ton-zig-agent-kit
//! A Zig-native TON contract toolkit for AI agents

const telegram_bot = @import("demo/telegram_bot.zig");

pub const core = @import("core/core.zig");
pub const wallet = @import("wallet/wallet.zig");
pub const contract = @import("contract/contract.zig");
pub const paywatch = @import("paywatch/paywatch.zig");
pub const tools = @import("tools/tools.zig");

test {
    _ = core;
    _ = wallet;
    _ = contract;
    _ = paywatch;
    _ = tools;
    _ = telegram_bot;
}
