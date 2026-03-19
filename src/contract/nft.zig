//! NFT standard implementation - TEP-62/64/66

const std = @import("std");
const types = @import("../core/types.zig");
const cell = @import("../core/cell.zig");
const http_client = @import("../core/http_client.zig");
const provider_mod = @import("../core/provider.zig");
const generic_contract = @import("contract.zig");

pub fn NFTItemType(comptime ClientType: type) type {
    return struct {
        contract: generic_contract.GenericContractType(ClientType),

        pub fn init(address: []const u8, client: ClientType) @This() {
            return .{
                .contract = generic_contract.GenericContractType(ClientType).init(client, address),
            };
        }

        pub fn getNFTData(self: *@This()) !NFTData {
            var result = try self.contract.callGetMethod("get_nft_data", &.{});
            defer self.contract.client.freeRunGetMethodResponse(&result);

            if (result.exit_code != 0) return error.ContractError;
            return parseNFTData(self.contract.client.allocator, result.stack);
        }
    };
}

pub fn NFTCollectionType(comptime ClientType: type) type {
    return struct {
        contract: generic_contract.GenericContractType(ClientType),

        pub fn init(address: []const u8, client: ClientType) @This() {
            return .{
                .contract = generic_contract.GenericContractType(ClientType).init(client, address),
            };
        }

        pub fn getCollectionData(self: *@This()) !CollectionData {
            var result = try self.contract.callGetMethod("get_collection_data", &.{});
            defer self.contract.client.freeRunGetMethodResponse(&result);

            if (result.exit_code != 0) return error.ContractError;
            return parseCollectionData(self.contract.client.allocator, result.stack);
        }
    };
}

pub const NFTItem = NFTItemType(*http_client.TonHttpClient);
pub const ProviderNFTItem = NFTItemType(*provider_mod.MultiProvider);
pub const NFTCollection = NFTCollectionType(*http_client.TonHttpClient);
pub const ProviderNFTCollection = NFTCollectionType(*provider_mod.MultiProvider);

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
    content_uri: ?[]const u8,

    pub fn deinit(self: *NFTData, allocator: std.mem.Allocator) void {
        if (self.content) |content| allocator.free(content);
        if (self.content_uri) |content_uri| allocator.free(content_uri);
        self.content = null;
        self.content_uri = null;
    }
};

pub const CollectionData = struct {
    next_item_index: u256,
    owner: ?types.Address,
    content: ?[]const u8,
    content_uri: ?[]const u8,

    pub fn deinit(self: *CollectionData, allocator: std.mem.Allocator) void {
        if (self.content) |content| allocator.free(content);
        if (self.content_uri) |content_uri| allocator.free(content_uri);
        self.content = null;
        self.content_uri = null;
    }
};

test "nft basic" {
    _ = getNFTData;
    _ = getCollectionData;
    _ = ProviderNFTItem;
    _ = ProviderNFTCollection;
}

test "provider nft wrappers init" {
    const allocator = std.testing.allocator;
    var provider = try provider_mod.MultiProvider.init(allocator, &.{
        .{ .url = "https://toncenter.com/api/v2/jsonRPC" },
    });

    const item = ProviderNFTItem.init("EQ...", &provider);
    const collection = ProviderNFTCollection.init("EQ...", &provider);
    _ = item;
    _ = collection;
}

pub fn parseNFTData(allocator: std.mem.Allocator, stack: []const types.StackEntry) !NFTData {
    if (stack.len < 5) return error.InvalidResponse;

    return NFTData{
        .index = try generic_contract.stackEntryAsUnsigned(u256, &stack[1]),
        .collection = try generic_contract.stackEntryAsOptionalAddress(&stack[2]),
        .owner = try generic_contract.stackEntryAsOptionalAddress(&stack[3]),
        .content = try generic_contract.stackEntryToBocAlloc(allocator, &stack[4]),
        .content_uri = try generic_contract.stackEntryAsOffchainContentUriAlloc(allocator, &stack[4]),
    };
}

pub fn parseCollectionData(allocator: std.mem.Allocator, stack: []const types.StackEntry) !CollectionData {
    if (stack.len < 3) return error.InvalidResponse;

    return CollectionData{
        .next_item_index = try generic_contract.stackEntryAsUnsigned(u256, &stack[0]),
        .owner = try generic_contract.stackEntryAsOptionalAddress(&stack[2]),
        .content = try generic_contract.stackEntryToBocAlloc(allocator, &stack[1]),
        .content_uri = try generic_contract.stackEntryAsOffchainContentUriAlloc(allocator, &stack[1]),
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

    var content_tail_builder = cell.Builder.init();
    try content_tail_builder.storeBits("nft.json", "nft.json".len * 8);
    const content_tail = try content_tail_builder.toCell(allocator);

    var content_builder = cell.Builder.init();
    try content_builder.storeUint(1, 8);
    try content_builder.storeBits("https://example.com/", "https://example.com/".len * 8);
    try content_builder.storeRef(content_tail);
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
    try std.testing.expectEqualStrings("https://example.com/nft.json", data.content_uri.?);
}

test "parse collection data stack" {
    const allocator = std.testing.allocator;

    var owner_builder = cell.Builder.init();
    try owner_builder.storeAddress(@as([]const u8, "0:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"));
    const owner_cell = try owner_builder.toCell(allocator);
    defer owner_cell.deinit(allocator);

    var content_tail_builder = cell.Builder.init();
    try content_tail_builder.storeBits("collection.json", "collection.json".len * 8);
    const content_tail = try content_tail_builder.toCell(allocator);

    var content_builder = cell.Builder.init();
    try content_builder.storeUint(1, 8);
    try content_builder.storeBits("https://example.com/", "https://example.com/".len * 8);
    try content_builder.storeRef(content_tail);
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
    try std.testing.expectEqualStrings("https://example.com/collection.json", data.content_uri.?);
}

test "parse collection data stack big index" {
    const allocator = std.testing.allocator;

    var owner_builder = cell.Builder.init();
    try owner_builder.storeAddress(@as([]const u8, "0:CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"));
    const owner_cell = try owner_builder.toCell(allocator);
    defer owner_cell.deinit(allocator);

    var content_builder = cell.Builder.init();
    try content_builder.storeUint(1, 8);
    try content_builder.storeBits("https://example.com/collection.json", "https://example.com/collection.json".len * 8);
    const content_cell = try content_builder.toCell(allocator);
    defer content_cell.deinit(allocator);

    const stack = [_]types.StackEntry{
        .{ .big_number = "0x1234567890ABCDEF1234567890ABCDEF" },
        .{ .cell = content_cell },
        .{ .slice = owner_cell },
    };

    var data = try parseCollectionData(allocator, stack[0..]);
    defer data.deinit(allocator);

    try std.testing.expectEqual(
        @as(u256, 0x1234567890ABCDEF1234567890ABCDEF),
        data.next_item_index,
    );
}
