const std = @import("std");
const types = @import("types.zig");

pub fn countUnsupportedStackEntries(stack: []const types.StackEntry) u32 {
    var total: u32 = 0;
    for (stack) |*entry| total += countUnsupportedStackEntry(entry);
    return total;
}

pub fn summarizeStackJsonAlloc(allocator: std.mem.Allocator, stack: []const types.StackEntry) ![]u8 {
    var writer = std.io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    try writer.writer.writeAll("{\"items\":");
    try writeStackEntriesSummaryJson(&writer.writer, allocator, stack);
    try writer.writer.writeAll(",\"unsupported_count\":");
    try writer.writer.print("{d}", .{countUnsupportedStackEntries(stack)});
    try writer.writer.writeByte('}');
    return try writer.toOwnedSlice();
}

fn countUnsupportedStackEntry(entry: *const types.StackEntry) u32 {
    return switch (entry.*) {
        .unsupported => 1,
        .tuple => |items| countUnsupportedStackEntries(items),
        .list => |items| countUnsupportedStackEntries(items),
        else => 0,
    };
}

fn writeStackEntriesSummaryJson(writer: anytype, allocator: std.mem.Allocator, stack: []const types.StackEntry) anyerror!void {
    try writer.writeByte('[');
    for (stack, 0..) |*entry, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writeStackEntrySummaryJson(writer, allocator, entry);
    }
    try writer.writeByte(']');
}

fn writeStackEntrySummaryJson(writer: anytype, allocator: std.mem.Allocator, entry: *const types.StackEntry) anyerror!void {
    var wrote_any = false;
    try writer.writeByte('{');

    switch (entry.*) {
        .null => {
            try writeJsonFieldPrefix(writer, &wrote_any, "kind");
            try writeJsonString(writer, "null");
        },
        .number => |value| {
            try writeJsonFieldPrefix(writer, &wrote_any, "kind");
            try writeJsonString(writer, "number");
            try writeJsonFieldPrefix(writer, &wrote_any, "value");
            try writer.print("{d}", .{value});
        },
        .big_number => |value| {
            try writeJsonFieldPrefix(writer, &wrote_any, "kind");
            try writeJsonString(writer, "big_number");
            try writeJsonFieldPrefix(writer, &wrote_any, "value");
            try writeJsonString(writer, value);
        },
        .bytes => |value| {
            try writeJsonFieldPrefix(writer, &wrote_any, "kind");
            try writeJsonString(writer, "bytes");
            try writeJsonFieldPrefix(writer, &wrote_any, "encoded_len");
            try writer.print("{d}", .{value.len});
            try writeJsonFieldPrefix(writer, &wrote_any, "preview");
            try writeJsonString(writer, truncatePreview(value));
        },
        .cell => |value| try writeCellSummaryJson(writer, &wrote_any, "cell", value),
        .slice => |value| try writeCellSummaryJson(writer, &wrote_any, "slice", value),
        .builder => |value| try writeCellSummaryJson(writer, &wrote_any, "builder", value),
        .tuple => |items| {
            try writeJsonFieldPrefix(writer, &wrote_any, "kind");
            try writeJsonString(writer, "tuple");
            try writeJsonFieldPrefix(writer, &wrote_any, "len");
            try writer.print("{d}", .{items.len});
            try writeJsonFieldPrefix(writer, &wrote_any, "items");
            try writeStackEntriesSummaryJson(writer, allocator, items);
        },
        .list => |items| {
            try writeJsonFieldPrefix(writer, &wrote_any, "kind");
            try writeJsonString(writer, "list");
            try writeJsonFieldPrefix(writer, &wrote_any, "len");
            try writer.print("{d}", .{items.len});
            try writeJsonFieldPrefix(writer, &wrote_any, "items");
            try writeStackEntriesSummaryJson(writer, allocator, items);
        },
        .unsupported => |value| {
            try writeJsonFieldPrefix(writer, &wrote_any, "kind");
            try writeJsonString(writer, "unsupported");
            try writeUnsupportedSummaryJson(writer, allocator, &wrote_any, value);
        },
    }

    try writer.writeByte('}');
}

fn writeCellSummaryJson(writer: anytype, wrote_any: *bool, kind: []const u8, value: anytype) anyerror!void {
    try writeJsonFieldPrefix(writer, wrote_any, "kind");
    try writeJsonString(writer, kind);
    try writeJsonFieldPrefix(writer, wrote_any, "bits");
    try writer.print("{d}", .{value.bit_len});
    try writeJsonFieldPrefix(writer, wrote_any, "refs");
    try writer.print("{d}", .{value.ref_cnt});
}

fn writeUnsupportedSummaryJson(writer: anytype, allocator: std.mem.Allocator, wrote_any: *bool, raw_json: []const u8) anyerror!void {
    try writeJsonFieldPrefix(writer, wrote_any, "preview");
    try writeJsonString(writer, truncatePreview(raw_json));

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{}) catch return;
    defer parsed.deinit();

    if (extractJsonTag(parsed.value)) |raw_tag| {
        try writeJsonFieldPrefix(writer, wrote_any, "raw_tag");
        try writeJsonString(writer, raw_tag);
    }

    try writeJsonFieldPrefix(writer, wrote_any, "raw_shape");
    try writeJsonString(writer, jsonShapeName(parsed.value));

    switch (parsed.value) {
        .object => |object| {
            try writeJsonFieldPrefix(writer, wrote_any, "object_keys");
            try writer.writeByte('[');
            var iter = object.iterator();
            var idx: usize = 0;
            while (iter.next()) |item| : (idx += 1) {
                if (idx != 0) try writer.writeByte(',');
                try writeJsonString(writer, item.key_ptr.*);
            }
            try writer.writeByte(']');
        },
        .array => |array| {
            try writeJsonFieldPrefix(writer, wrote_any, "array_len");
            try writer.print("{d}", .{array.items.len});
        },
        else => {},
    }
}

fn extractJsonTag(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .object => |object| {
            if (object.get("@type")) |tag_value| {
                return switch (tag_value) {
                    .string => tag_value.string,
                    else => null,
                };
            }
            if (object.get("type")) |tag_value| {
                return switch (tag_value) {
                    .string => tag_value.string,
                    else => null,
                };
            }
            return null;
        },
        .array => |array| {
            if (array.items.len == 0) return null;
            return switch (array.items[0]) {
                .string => array.items[0].string,
                else => null,
            };
        },
        else => null,
    };
}

fn jsonShapeName(value: std.json.Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => "bool",
        .integer => "integer",
        .float => "float",
        .number_string => "number_string",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

fn truncatePreview(value: []const u8) []const u8 {
    const max_len = 96;
    if (value.len <= max_len) return value;
    return value[0..max_len];
}

fn writeJsonFieldPrefix(writer: anytype, wrote_any: *bool, name: []const u8) anyerror!void {
    if (wrote_any.*) try writer.writeByte(',');
    wrote_any.* = true;
    try writeJsonString(writer, name);
    try writer.writeByte(':');
}

fn writeJsonString(writer: anytype, value: []const u8) anyerror!void {
    try writer.writeByte('"');
    for (value) |char| {
        switch (char) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0c => try writer.writeAll("\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f => try writer.print("\\u00{X:0>2}", .{char}),
            else => try writer.writeByte(char),
        }
    }
    try writer.writeByte('"');
}

test "stack inspector summarizes nested stack and unsupported payloads" {
    const allocator = std.testing.allocator;

    const tuple_items = try allocator.alloc(types.StackEntry, 2);
    defer allocator.free(tuple_items);
    tuple_items[0] = .{ .unsupported = try allocator.dupe(u8, "{\"@type\":\"tvm.stackEntryCont\",\"continuation\":{\"pc\":7}}") };
    defer allocator.free(tuple_items[0].unsupported);
    tuple_items[1] = .{ .big_number = try allocator.dupe(u8, "340282366920938463463374607431768211455") };
    defer allocator.free(tuple_items[1].big_number);

    const stack = try allocator.alloc(types.StackEntry, 2);
    defer allocator.free(stack);
    stack[0] = .{ .tuple = tuple_items };
    stack[1] = .{ .number = 9 };

    const summary_json = try summarizeStackJsonAlloc(allocator, stack);
    defer allocator.free(summary_json);

    try std.testing.expectEqual(@as(u32, 1), countUnsupportedStackEntries(stack));
    try std.testing.expect(std.mem.indexOf(u8, summary_json, "\"unsupported_count\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary_json, "\"kind\":\"tuple\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary_json, "\"raw_tag\":\"tvm.stackEntryCont\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary_json, "\"object_keys\":[\"@type\",\"continuation\"]") != null);
}
