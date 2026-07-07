const std = @import("std");
const stdx = @import("stdx");

const conformance = @import("generate.zig");
const conformance_fixture_options = @import("conformance_fixture_options");

const format = @field(conformance.Format, conformance_fixture_options.format);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const shell = try stdx.Shell.create(gpa.allocator());
    defer shell.destroy();

    try conformance.generate(
        arena.allocator(),
        shell.project_root,
        format,
        std.io.getStdOut().writer(),
    );
}
