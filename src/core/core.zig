//! Core module - Raw contract interaction layer

pub const types = @import("types.zig");
pub const address = @import("address.zig");
pub const cell = @import("cell.zig");
pub const boc = @import("boc.zig");
pub const body_inspector = @import("body_inspector.zig");
pub const stack_inspector = @import("stack_inspector.zig");
pub const body_builder = @import("body_builder.zig");
pub const external_message = @import("external_message.zig");
pub const state_init = @import("state_init.zig");
pub const http_client = @import("http_client.zig");
pub const provider = @import("provider.zig");

pub const TonHttpClient = http_client.TonHttpClient;
pub const MultiProvider = provider.MultiProvider;
pub const Cell = cell.Cell;
pub const Builder = cell.Builder;
pub const Slice = cell.Slice;
pub const BodyOp = body_builder.BodyOp;
pub const BodyAnalysis = body_inspector.BodyAnalysis;
pub const summarizeStackJsonAlloc = stack_inspector.summarizeStackJsonAlloc;
pub const countUnsupportedStackEntries = stack_inspector.countUnsupportedStackEntries;
pub const buildExternalIncomingMessageBocAlloc = external_message.buildExternalIncomingMessageBocAlloc;
pub const buildStateInitBocAlloc = state_init.buildStateInitBocAlloc;
pub const computeStateInitAddress = state_init.computeStateInitAddress;
pub const computeStateInitAddressFromBoc = state_init.computeStateInitAddressFromBoc;
pub const Address = types.Address;
pub const TonError = types.TonError;

pub const parseAddress = address.parseAddress;
pub const serializeBoc = boc.serializeBoc;
pub const deserializeBoc = boc.deserializeBoc;
pub const buildBodyBocAlloc = body_builder.buildBodyBocAlloc;
pub const inspectBodyCellAlloc = body_inspector.inspectBodyCellAlloc;
pub const inspectBodyBocAlloc = body_inspector.inspectBodyBocAlloc;

test {
    _ = types;
    _ = address;
    _ = cell;
    _ = boc;
    _ = body_inspector;
    _ = stack_inspector;
    _ = body_builder;
    _ = external_message;
    _ = state_init;
    _ = http_client;
    _ = provider;
}
