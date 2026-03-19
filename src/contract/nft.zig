//! NFT standard implementation - TEP-62/64/66

const std = @import("std");
const types = @import("../core/types.zig");
const contract = @import("contract.zig");

pub const NFTItem = struct {
    contract: contract.GenericContract,
};

pub const NFTCollection = struct {
    contract: contract.GenericContract,
};

pub fn getNFTData(item: *NFTItem) !NFTData {
    _ = item;
    return NFTData{};
}

pub fn getCollectionData(collection: *NFTCollection) !CollectionData {
    _ = collection;
    return CollectionData{};
}

pub const NFTData = struct {
    index: u256,
    collection: ?types.Address,
    owner: ?types.Address,
    content: ?[]const u8,
};

pub const CollectionData = struct {
    next_item_index: u256,
    owner: ?types.Address,
    content: ?[]const u8,
};

test "nft basic" {
    _ = getNFTData;
    _ = getCollectionData;
}
