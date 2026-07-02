const std = @import("std");
const stdx = @import("stdx");

const conformance = @import("generate.zig");
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const shell = try stdx.Shell.create(gpa.allocator());
    defer shell.destroy();

    try conformance.generate(arena.allocator(), shell.project_root, std.io.getStdOut().writer());
}
