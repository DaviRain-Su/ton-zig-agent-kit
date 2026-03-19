//! Core module - Raw contract interaction layer

pub const types = @import("types.zig");
pub const address = @import("address.zig");
pub const cell = @import("cell.zig");
pub const boc = @import("boc.zig");
pub const body_builder = @import("body_builder.zig");
pub const http_client = @import("http_client.zig");
pub const provider = @import("provider.zig");

pub const TonHttpClient = http_client.TonHttpClient;
pub const MultiProvider = provider.MultiProvider;
pub const Cell = cell.Cell;
pub const Builder = cell.Builder;
pub const Slice = cell.Slice;
pub const BodyOp = body_builder.BodyOp;
pub const Address = types.Address;
pub const TonError = types.TonError;

pub const parseAddress = address.parseAddress;
pub const serializeBoc = boc.serializeBoc;
pub const deserializeBoc = boc.deserializeBoc;
pub const buildBodyBocAlloc = body_builder.buildBodyBocAlloc;

test {
    _ = types;
    _ = address;
    _ = cell;
    _ = boc;
    _ = body_builder;
    _ = http_client;
    _ = provider;
}
