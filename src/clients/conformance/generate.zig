const std = @import("std");
const stdx = @import("stdx");

const cases_path = "src/clients/conformance/cases";

/// Untagged integers must fit in an i54, whose maximum is JavaScript's
/// Number.MAX_SAFE_INTEGER (2^53 - 1): integers beyond it are not exactly
/// representable as IEEE 754 doubles, so JSON consumers that parse numbers
/// as float64 would silently corrupt them. Larger values must use a tagged
/// value such as `.u128`, which is converted to decimal string.
const UntaggedInteger = i54;

pub fn generate(
    arena: std.mem.Allocator,
    project_root: std.fs.Dir,
    output_writer: std.fs.File.Writer,
) !void {
    var cases_dir = try project_root.openDir(cases_path, .{ .iterate = true });
    defer cases_dir.close();

    var json = std.ArrayList(u8).init(arena);
    var writer = std.json.writeStream(json.writer(), .{ .whitespace = .indent_2 });
    defer writer.deinit();

    try writer.beginObject();
    try writer.objectField("suites");
    try writer.beginArray();

    var case_names = std.ArrayList([]const u8).init(arena);
    var iterator = cases_dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zon")) {
            std.log.err("unexpected entry in {s}: {s}", .{ cases_path, entry.name });
            return error.InvalidConformanceCases;
        }
        try case_names.append(try arena.dupe(u8, entry.name));
    }
    std.mem.sort(
        []const u8,
        case_names.items,
        {},
        struct {
            fn filename_asc(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.filename_asc,
    );

    for (case_names.items) |case_name| {
        const zoir = try parse_case(arena, cases_dir, case_name);
        try write_json_node(&zoir, .root, &writer);
    }

    try writer.endArray();
    try writer.endObject();
    try json.append('\n');

    try output_writer.writeAll(json.items);
}

fn parse_case(arena: std.mem.Allocator, cases_dir: std.fs.Dir, name: []const u8) !std.zig.Zoir {
    const source = try cases_dir.readFileAllocOptions(
        arena,
        name,
        stdx.MiB,
        null,
        @alignOf(u8),
        0,
    );

    const tree = try std.zig.Ast.parse(arena, source, .zon);
    if (tree.errors.len != 0) return error.InvalidZon;

    const zoir = try std.zig.ZonGen.generate(arena, tree, .{});
    if (zoir.hasCompileErrors()) return error.InvalidZon;

    return zoir;
}

const JsonWriter = std.json.WriteStream(
    std.ArrayList(u8).Writer,
    .{ .checked_to_fixed_depth = 256 },
);

fn write_json_node(
    zoir: *const std.zig.Zoir,
    index: std.zig.Zoir.Node.Index,
    writer: *JsonWriter,
) anyerror!void {
    switch (index.get(zoir.*)) {
        .true => try writer.write(true),
        .false => try writer.write(false),
        .null => try writer.write(null),
        .int_literal => |integer| switch (integer) {
            .small => |value| try writer.print("{}", .{value}),
            .big => |value| {
                const number = value.to(UntaggedInteger) catch {
                    std.log.err("untagged integer exceeds 2^53 - 1: {}", .{value});
                    return error.InvalidZon;
                };
                try writer.print("{}", .{number});
            },
        },
        .float_literal => |value| try writer.write(value),
        .char_literal => |value| try writer.write(value),
        .string_literal => |value| try writer.write(value),
        .enum_literal => |value| try writer.write(value.get(zoir.*)),
        .array_literal => |item_range| {
            try writer.beginArray();
            for (0..item_range.len) |i| {
                try write_json_node(zoir, item_range.at(@intCast(i)), writer);
            }
            try writer.endArray();
        },
        .struct_literal => |object| {
            if (object.names.len == 1 and std.mem.eql(u8, object.names[0].get(zoir.*), "u128")) {
                try writer.beginObject();
                try writer.objectField("u128");
                try write_json_u128(zoir, object.vals.at(0), writer);
                try writer.endObject();
                return;
            }

            try writer.beginObject();
            for (object.names, 0..) |name, i| {
                const field_name = name.get(zoir.*);
                try writer.objectField(field_name);
                const value = object.vals.at(@intCast(i));
                try write_json_node(zoir, value, writer);
            }
            try writer.endObject();
        },
        .empty_literal, .pos_inf, .neg_inf, .nan => return error.InvalidZon,
    }
}

fn write_json_u128(
    zoir: *const std.zig.Zoir,
    index: std.zig.Zoir.Node.Index,
    writer: *JsonWriter,
) anyerror!void {
    switch (index.get(zoir.*)) {
        .int_literal => |integer| switch (integer) {
            inline else => |value| try writer.print("\"{}\"", .{value}),
        },
        else => return error.InvalidZon,
    }
}
