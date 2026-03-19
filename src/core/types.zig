//! Common types for TON interactions

pub const Address = struct {
    raw: [32]u8,
    workchain: i8,

    pub fn parseUserFriendly(str: []const u8) !Address {
        _ = str;
        return error.InvalidAddress;
    }
    pub fn parseRaw(str: []const u8) !Address {
        _ = str;
        return error.InvalidAddress;
    }
    pub fn toUserFriendly(self: *const Address) []const u8 {
        _ = self;
        return "";
    }
    pub fn toRaw(self: *const Address) []const u8 {
        _ = self;
        return "";
    }
};

pub const Cell = struct {
    data: [128]u8,
    bit_len: u16,
    refs: [4]?*Cell,
    ref_cnt: u2,
};

pub const Builder = struct {
    data: [128]u8,
    bit_len: u16,
    refs: [4]?*Cell,
    ref_cnt: u2,

    pub fn init() Builder {
        return .{};
    }
    pub fn storeUint(self: *Builder, value: u64, bits: u16) !void {
        _ = self;
        _ = value;
        _ = bits;
        return error.InvalidCell;
    }
    pub fn storeCoins(self: *Builder, coins: u64) !void {
        _ = self;
        _ = coins;
        return error.InvalidCell;
    }
    pub fn storeAddress(self: *Builder, addr: *const Address) !void {
        _ = self;
        _ = addr;
        return error.InvalidCell;
    }
    pub fn storeSlice(self: *Builder, slice: *const Slice) !void {
        _ = self;
        _ = slice;
        return error.InvalidCell;
    }
    pub fn toCell(self: *Builder) !*Cell {
        _ = self;
        return error.InvalidCell;
    }
};

pub const Slice = struct {
    cell: *Cell,
    pos_bits: u16,
    pos_refs: u2,

    pub fn loadUint(self: *Slice, comptime bits: u16) u64 {
        _ = self;
        _ = bits;
        return 0;
    }
    pub fn loadCoins(self: *Slice) u64 {
        _ = self;
        return 0;
    }
    pub fn loadAddress(self: *Slice) !Address {
        _ = self;
        return error.InvalidAddress;
    }
    pub fn loadRef(self: *Slice) !*Cell {
        _ = self;
        return error.InvalidCell;
    }
    pub fn empty(self: *const Slice) bool {
        _ = self;
        return true;
    }
};

pub const RunGetMethodResponse = struct {
    exit_code: i32,
    stack: []StackEntry,
    logs: []const u8,
};

pub const StackEntry = union(enum) {
    number: i64,
    cell: *Cell,
    tuple: []StackEntry,
    bytes: []const u8,
};

pub const BalanceResponse = struct {
    balance: u64,
    address: []const u8,
};

pub const SendBocResponse = struct {
    hash: []const u8,
    lt: i64,
};

pub const Transaction = struct {
    hash: []const u8,
    lt: i64,
    timestamp: i64,
    in_msg: ?*Message,
    out_msgs: []*Message,
};

pub const Message = struct {
    hash: []const u8,
    source: ?Address,
    destination: ?Address,
    value: u64,
    body: ?*Cell,
    raw_body: []const u8,
};

pub const TonError = error{
    InvalidAddress,
    InvalidCell,
    InvalidBoc,
    NetworkError,
    RpcError,
    SigningError,
    SendError,
    Timeout,
    NotFound,
};
