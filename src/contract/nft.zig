//! NFT standard implementation - TEP-62/64/66

const std = @import("std");
const types = @import("../core/types.zig");
const cell = @import("../core/cell.zig");
const http_client = @import("../core/http_client.zig");
const generic_contract = @import("contract.zig");

pub const NFTItem = struct {
    contract: generic_contract.GenericContract,

    pub fn init(address: []const u8, client: *http_client.TonHttpClient) NFTItem {
        return .{
            .contract = generic_contract.GenericContract.init(client, address),
        };
    }

    pub fn getNFTData(self: *NFTItem) !NFTData {
        var result = try self.contract.callGetMethod("get_nft_data", &.{});
        defer self.contract.client.freeRunGetMethodResponse(&result);

        if (result.exit_code != 0) return error.ContractError;
        return parseNFTData(self.contract.client.allocator, result.stack);
    }
};

pub const NFTCollection = struct {
    contract: generic_contract.GenericContract,

    pub fn init(address: []const u8, client: *http_client.TonHttpClient) NFTCollection {
        return .{
            .contract = generic_contract.GenericContract.init(client, address),
        };
    }

    pub fn getCollectionData(self: *NFTCollection) !CollectionData {
        var result = try self.contract.callGetMethod("get_collection_data", &.{});
        defer self.contract.client.freeRunGetMethodResponse(&result);

        if (result.exit_code != 0) return error.ContractError;
        return parseCollectionData(self.contract.client.allocator, result.stack);
    }
};

pub fn getNFTData(item: *NFTItem) !NFTData {
    return item.getNFTData();
}

pub fn getCollectionData(collection: *NFTCollection) !CollectionData {
    return collection.getCollectionData();
}

pub const NFTData = struct {
    index: u256,
    collection: ?types.Address,
    owner: ?types.Address,
    content: ?[]const u8,

    pub fn deinit(self: *NFTData, allocator: std.mem.Allocator) void {
        if (self.content) |content| allocator.free(content);
        self.content = null;
    }
};

pub const CollectionData = struct {
    next_item_index: u256,
    owner: ?types.Address,
    content: ?[]const u8,

    pub fn deinit(self: *CollectionData, allocator: std.mem.Allocator) void {
        if (self.content) |content| allocator.free(content);
        self.content = null;
    }
};

test "nft basic" {
    _ = getNFTData;
    _ = getCollectionData;
}

fn parseNFTData(allocator: std.mem.Allocator, stack: []const types.StackEntry) !NFTData {
    if (stack.len < 5) return error.InvalidResponse;

    const index_raw = try generic_contract.stackEntryAsInt(&stack[1]);
    if (index_raw < 0) return error.InvalidResponse;

    return NFTData{
        .index = @intCast(index_raw),
        .collection = try generic_contract.stackEntryAsOptionalAddress(&stack[2]),
        .owner = try generic_contract.stackEntryAsOptionalAddress(&stack[3]),
        .content = try generic_contract.stackEntryToBocAlloc(allocator, &stack[4]),
    };
}

fn parseCollectionData(allocator: std.mem.Allocator, stack: []const types.StackEntry) !CollectionData {
    if (stack.len < 3) return error.InvalidResponse;

    const next_item_index_raw = try generic_contract.stackEntryAsInt(&stack[0]);
    if (next_item_index_raw < 0) return error.InvalidResponse;

    return CollectionData{
        .next_item_index = @intCast(next_item_index_raw),
        .owner = try generic_contract.stackEntryAsOptionalAddress(&stack[2]),
        .content = try generic_contract.stackEntryToBocAlloc(allocator, &stack[1]),
    };
}

test "parse nft data stack" {
    const allocator = std.testing.allocator;

    var collection_builder = cell.Builder.init();
    try collection_builder.storeAddress(@as([]const u8, "0:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"));
    const collection_cell = try collection_builder.toCell(allocator);
    defer collection_cell.deinit(allocator);

    var owner_builder = cell.Builder.init();
    try owner_builder.storeAddress(@as([]const u8, "0:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"));
    const owner_cell = try owner_builder.toCell(allocator);
    defer owner_cell.deinit(allocator);

    var content_builder = cell.Builder.init();
    try content_builder.storeUint(0x1234, 16);
    const content_cell = try content_builder.toCell(allocator);
    defer content_cell.deinit(allocator);

    const stack = [_]types.StackEntry{
        .{ .number = -1 },
        .{ .number = 9 },
        .{ .slice = collection_cell },
        .{ .slice = owner_cell },
        .{ .cell = content_cell },
    };

    var data = try parseNFTData(allocator, stack[0..]);
    defer data.deinit(allocator);

    try std.testing.expectEqual(@as(u256, 9), data.index);
    try std.testing.expect(data.collection != null);
    try std.testing.expect(data.owner != null);
    try std.testing.expect(data.content != null);
}

test "parse collection data stack" {
    const allocator = std.testing.allocator;

    var owner_builder = cell.Builder.init();
    try owner_builder.storeAddress(@as([]const u8, "0:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"));
    const owner_cell = try owner_builder.toCell(allocator);
    defer owner_cell.deinit(allocator);

    var content_builder = cell.Builder.init();
    try content_builder.storeUint(0x4321, 16);
    const content_cell = try content_builder.toCell(allocator);
    defer content_cell.deinit(allocator);

    const stack = [_]types.StackEntry{
        .{ .number = 17 },
        .{ .cell = content_cell },
        .{ .slice = owner_cell },
    };

    var data = try parseCollectionData(allocator, stack[0..]);
    defer data.deinit(allocator);

    try std.testing.expectEqual(@as(u256, 17), data.next_item_index);
    try std.testing.expect(data.owner != null);
    try std.testing.expect(data.content != null);
}
