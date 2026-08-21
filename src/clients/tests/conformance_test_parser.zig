//! Parses the pseudo-Zig suite files into the typed model in `conformance_test_ast.zig`.
const std = @import("std");
const stdx = @import("stdx");

const api = @import("conformance_test_api.zig");
const ast = @import("conformance_test_ast.zig");

const log = std.log;

pub fn parse(
    arena: std.mem.Allocator,
    comptime suites: []const struct { []const u8, []const u8 },
) !ast.ConformanceTests {
    const suites_parsed = try arena.alloc(ast.Suite, suites.len);
    inline for (suites, 0..) |suite, index| {
        const file, const name = suite;
        const path = "suites/" ++ file ++ ".zig";
        var parser = try Parser.init(arena, path, @embedFile(path));
        suites_parsed[index] = try parse_suite(&parser, name);
    }
    return .{ .suites = suites_parsed };
}

const Parser = struct {
    arena: std.mem.Allocator,
    path: []const u8,
    tree: std.zig.Ast,
    bindings: std.StringArrayHashMap(ast.Expression),

    fn init(arena: std.mem.Allocator, path: []const u8, source: [:0]const u8) !Parser {
        const tree = try std.zig.Ast.parse(arena, source, .zig);
        if (tree.errors.len > 0) {
            for (tree.errors) |parse_error| {
                const location = tree.tokenLocation(0, parse_error.token);
                log.err(
                    "{s}:{d}:{d}: syntax error",
                    .{ path, location.line + 1, location.column + 1 },
                );
            }
            return error.ParseFailed;
        }
        return .{
            .arena = arena,
            .path = path,
            .tree = tree,
            .bindings = std.StringArrayHashMap(ast.Expression).init(arena),
        };
    }

    fn fail(
        parser: *const Parser,
        token: ?std.zig.Ast.TokenIndex,
        comptime format: []const u8,
        arguments: anytype,
    ) error{ParseFailed} {
        if (token) |token_index| {
            const location = parser.tree.tokenLocation(0, token_index);
            log.err(
                "{s}:{d}:{d}: " ++ format,
                .{ parser.path, location.line + 1, location.column + 1 } ++ arguments,
            );
        } else {
            log.err("{s}: " ++ format, .{parser.path} ++ arguments);
        }
        return error.ParseFailed;
    }

    fn fail_node(
        parser: *const Parser,
        node: std.zig.Ast.Node.Index,
        comptime message: []const u8,
    ) error{ParseFailed} {
        return parser.fail(parser.tree.firstToken(node), message, .{});
    }

    fn fail_arguments(
        parser: *const Parser,
        call: std.zig.Ast.full.Call,
        comptime expected: []const u8,
    ) error{ParseFailed} {
        return parser.fail(call.ast.lparen, "expected arguments " ++ expected, .{});
    }
};

fn parse_suite(parser: *Parser, name: []const u8) !ast.Suite {
    const tree = &parser.tree;
    var cases = std.ArrayList(ast.Case).init(parser.arena);

    for (tree.rootDecls()) |decl| {
        if (tree.nodes.items(.tag)[decl] != .test_decl) continue;
        try cases.append(try parse_case(parser, decl));
    }
    if (cases.items.len == 0) return parser.fail(null, "no cases", .{});
    return .{ .name = name, .cases = cases.items };
}

fn parse_case(parser: *Parser, node: std.zig.Ast.Node.Index) !ast.Case {
    const tree = &parser.tree;
    parser.bindings.clearRetainingCapacity();

    const data = tree.nodes.items(.data)[node];
    const name_token = data.lhs;
    if (name_token == 0 or tree.tokens.items(.tag)[name_token] != .string_literal) {
        return parser.fail(tree.nodes.items(.main_token)[node], "test needs a description", .{});
    }
    const description = tree.tokenSlice(name_token);
    for (description[1 .. description.len - 1]) |char| {
        const allowed = std.ascii.isAlphanumeric(char) or switch (char) {
            ' ', '_', ',', '-', '\'', '.' => true,
            else => false,
        };
        if (!allowed) {
            return parser.fail(name_token, "invalid character in description", .{});
        }
    }

    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    var statements = block_statements(tree, data.rhs, &buffer);
    // NOTE: For now we only support a single requirements and it needs to come first.
    const requirement: ?ast.Case.Requirement = if (statements.len > 0)
        try parse_requirement(parser, statements[0])
    else
        null;
    if (requirement != null) statements = statements[1..];
    const steps = try parser.arena.alloc(ast.Step, statements.len);
    for (statements, 0..) |statement, index| {
        steps[index] = try parse_step(parser, statement);
    }
    if (steps.len == 0) return parser.fail(name_token, "empty case", .{});
    return .{
        .description = description[1 .. description.len - 1],
        .steps = steps,
        .requirement = requirement,
    };
}

fn parse_requirement(parser: *Parser, node: std.zig.Ast.Node.Index) !?ast.Case.Requirement {
    const tree = &parser.tree;
    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse return null;
    if (tree.nodes.items(.tag)[call.ast.fn_expr] != .field_access) return null;
    const name = tree.tokenSlice(tree.nodes.items(.data)[call.ast.fn_expr].rhs);
    const requirement = std.meta.stringToEnum(ast.Case.Requirement, name) orelse return null;
    try zero_arguments(parser, call);
    return requirement;
}

// block-statement extraction similar to zig/lib/std/zig/AstGen.zig:2410-2423.
fn block_statements(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    buffer: *[2]std.zig.Ast.Node.Index,
) []const std.zig.Ast.Node.Index {
    const data = tree.nodes.items(.data)[node];
    switch (tree.nodes.items(.tag)[node]) {
        .block, .block_semicolon => return tree.extra_data[data.lhs..data.rhs],
        .block_two, .block_two_semicolon => {
            buffer[0] = data.lhs;
            buffer[1] = data.rhs;
            if (data.lhs == 0) return buffer[0..0];
            if (data.rhs == 0) return buffer[0..1];
            return buffer[0..2];
        },
        else => unreachable,
    }
}

fn parse_step(parser: *Parser, node: std.zig.Ast.Node.Index) !ast.Step {
    const tree = &parser.tree;
    if (tree.fullVarDecl(node)) |var_decl| {
        return .{ .binding = try parse_binding(parser, var_decl) };
    }

    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node) orelse
        return parser.fail_node(node, "invalid statement");
    const name = try parse_call_name(parser, call);
    if (std.meta.stringToEnum(ast.Call.Name, name)) |operation| {
        return .{ .call = try parse_operation(parser, operation, call) };
    }
    if (std.mem.eql(u8, name, "concurrently")) {
        return .{ .call = try parse_concurrently(parser, call) };
    }
    if (std.mem.startsWith(u8, name, "assert_")) {
        return .{ .assertion = try parse_assertion(parser, name, call) };
    }
    return parser.fail(tree.firstToken(node), "'{s}' cannot be a statement", .{name});
}

fn parse_binding(parser: *Parser, var_decl: std.zig.Ast.full.VarDecl) !ast.Binding {
    const tree = &parser.tree;
    // Skip over const/var
    const name_token = var_decl.ast.mut_token + 1;
    if (tree.tokens.items(.tag)[var_decl.ast.mut_token] != .keyword_const) {
        return parser.fail(var_decl.ast.mut_token, "bindings must be `const`", .{});
    }
    // No type annotations allowed. Emitters pick the correct types, u128 has special handling.
    if (var_decl.ast.type_node != 0) {
        return parser.fail_node(var_decl.ast.type_node, "invalid type annotation");
    }

    const name = tree.tokenSlice(name_token);
    const value = try parse_expression(parser, var_decl.ast.init_node);
    // NOTE: This may need to change, it mirrors current DSL use.
    switch (value) {
        .generate_id, .generate_ids, .index => {},
        // TODO: Revisit this limitation later.
        .record => |record| if (ast.Record.is_flags(record.type)) {
            return parser.fail(name_token, "flags cannot be bound on their own", .{});
        },
        .call => |call| if (operation_result(call.name) == null) {
            return parser.fail(name_token, "'{s}' has no result", .{@tagName(call.name)});
        },
        .integer, .boolean, .enum_literal, .reference => {
            return parser.fail(
                tree.firstToken(var_decl.ast.init_node),
                "invalid binding: {s}",
                .{@tagName(value)},
            );
        },
    }

    const entry = try parser.bindings.getOrPut(name);
    if (entry.found_existing) {
        return parser.fail(name_token, "duplicate binding '{s}'", .{name});
    }
    entry.value_ptr.* = value;
    return .{ .name = name, .value = value };
}

fn parse_expression(parser: *Parser, node: std.zig.Ast.Node.Index) anyerror!ast.Expression {
    const tree = &parser.tree;
    const main_token = tree.nodes.items(.main_token)[node];
    switch (tree.nodes.items(.tag)[node]) {
        .number_literal => return .{ .integer = tree.tokenSlice(main_token) },
        .enum_literal => return .{ .enum_literal = tree.tokenSlice(main_token) },
        .identifier => {
            const name = tree.tokenSlice(main_token);
            if (std.mem.eql(u8, name, "true")) return .{ .boolean = true };
            if (std.mem.eql(u8, name, "false")) return .{ .boolean = false };
            if (!parser.bindings.contains(name)) {
                return parser.fail(main_token, "unknown binding '{s}'", .{name});
            }
            return .{ .reference = name };
        },
        .array_access => return try parse_index(parser, node),
        else => {},
    }

    var call_buffer: [1]std.zig.Ast.Node.Index = undefined;
    if (tree.fullCall(&call_buffer, node)) |call| {
        const name = try parse_call_name(parser, call);
        if (std.mem.eql(u8, name, "generate_id")) {
            try zero_arguments(parser, call);
            return .generate_id;
        }
        if (std.mem.eql(u8, name, "generate_ids")) {
            const count_node = try one_argument(parser, call, "(count)");
            return .{ .generate_ids = try parse_u32(parser, count_node) };
        }
        if (std.meta.stringToEnum(ast.Call.Name, name)) |operation| {
            return .{ .call = try parse_operation(parser, operation, call) };
        }
        return parser.fail(tree.firstToken(node), "'{s}' cannot be a value", .{name});
    }

    var init_buffer: [2]std.zig.Ast.Node.Index = undefined;
    if (tree.fullStructInit(&init_buffer, node)) |struct_init| {
        if (struct_init.ast.type_expr == 0) {
            return parser.fail_node(node, "record literal needs a type here");
        }
        const record_type = try parse_record_type(parser, struct_init.ast.type_expr);
        return .{ .record = try parse_record(parser, record_type, struct_init) };
    }

    return parser.fail_node(node, "invalid expression");
}

// Extracts the trailing name from a `Namespace.name` field access (`data.rhs` is its token).
fn parse_field_access_name(
    parser: *Parser,
    node: std.zig.Ast.Node.Index,
    comptime message: []const u8,
) ![]const u8 {
    const tree = &parser.tree;
    if (tree.nodes.items(.tag)[node] != .field_access) {
        return parser.fail_node(node, message);
    }
    const data = tree.nodes.items(.data)[node];
    if (tree.nodes.items(.tag)[data.lhs] != .identifier) {
        return parser.fail_node(node, message);
    }
    return tree.tokenSlice(data.rhs);
}

fn parse_call_name(parser: *Parser, call: std.zig.Ast.full.Call) ![]const u8 {
    return parse_field_access_name(parser, call.ast.fn_expr, "invalid call");
}

fn parse_record_type(parser: *Parser, node: std.zig.Ast.Node.Index) !ast.Record.Type {
    const name = try parse_field_access_name(parser, node, "invalid type");
    return std.meta.stringToEnum(ast.Record.Type, name) orelse
        parser.fail(parser.tree.nodes.items(.data)[node].rhs, "unknown type '{s}'", .{name});
}

fn parse_operation(
    parser: *Parser,
    operation: ast.Call.Name,
    call: std.zig.Ast.full.Call,
) anyerror!ast.Call {
    switch (operation) {
        .create_accounts => return parse_batch(parser, operation, call, .Account),
        .create_transfers => return parse_batch(parser, operation, call, .Transfer),
        .lookup_accounts, .lookup_transfers => return parse_lookup(parser, operation, call),
        .get_account_transfers,
        .get_account_balances,
        .query_accounts,
        .query_transfers,
        => return parse_filtered(parser, operation, call),
        .close_client => {
            try zero_arguments(parser, call);
            return .{ .name = operation };
        },
        .sleep_ms => {
            const node = try one_argument(parser, call, "(ms)");
            const arguments = try parser.arena.alloc(ast.Expression, 1);
            arguments[0] = try parse_expression(parser, node);
            return .{ .name = operation, .arguments = arguments };
        },
    }
}

// An empty `.{}` parses as a struct initializer, not an array one.
fn parse_tuple(
    parser: *Parser,
    node: std.zig.Ast.Node.Index,
    buffer: *[2]std.zig.Ast.Node.Index,
    comptime message: []const u8,
) ![]const std.zig.Ast.Node.Index {
    const tree = &parser.tree;
    if (tree.fullArrayInit(buffer, node)) |array_init| return array_init.ast.elements;
    if (tree.fullStructInit(buffer, node)) |struct_init| {
        if (struct_init.ast.type_expr == 0 and struct_init.ast.fields.len == 0) return &.{};
    }
    return parser.fail_node(node, message);
}

fn parse_batch(
    parser: *Parser,
    operation: ast.Call.Name,
    call: std.zig.Ast.full.Call,
    record_type: ast.Record.Type,
) !ast.Call {
    const tree = &parser.tree;
    const events_node = try one_argument(parser, call, "(events)");
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const elements = try parse_tuple(parser, events_node, &buffer, "expected a tuple of events");

    const arguments = try parser.arena.alloc(ast.Expression, elements.len);
    for (elements, 0..) |element, index| {
        var init_buffer: [2]std.zig.Ast.Node.Index = undefined;
        if (tree.fullStructInit(&init_buffer, element)) |struct_init| {
            if (struct_init.ast.type_expr != 0) {
                return parser.fail_node(element, "event type is implied, use .{{...}}");
            }
            arguments[index] = .{
                .record = try parse_record(parser, record_type, struct_init),
            };
            continue;
        }
        const expression = try parse_expression(parser, element);
        if (expression != .reference) {
            return parser.fail_node(element, "expected a record or binding");
        }
        const bound = parser.bindings.get(expression.reference).?;
        if (bound != .record or bound.record.type != record_type) {
            return parser.fail(tree.firstToken(element), "'{s}' is not a {s}", .{
                expression.reference,
                @tagName(record_type),
            });
        }
        arguments[index] = expression;
    }
    return .{ .name = operation, .arguments = arguments };
}

fn parse_lookup(
    parser: *Parser,
    operation: ast.Call.Name,
    call: std.zig.Ast.full.Call,
) !ast.Call {
    const ids_node = try one_argument(parser, call, "(ids)");
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const elements = try parse_tuple(parser, ids_node, &buffer, "expected a tuple of ids");

    const arguments = try parser.arena.alloc(ast.Expression, elements.len);
    for (elements, 0..) |element, index| {
        const expression = try parse_expression(parser, element);
        switch (expression) {
            .reference, .integer, .generate_id => arguments[index] = expression,
            else => return parser.fail_node(element, "expected an id"),
        }
    }
    return .{ .name = operation, .arguments = arguments };
}

fn parse_filtered(
    parser: *Parser,
    operation: ast.Call.Name,
    call: std.zig.Ast.full.Call,
) !ast.Call {
    const tree = &parser.tree;
    const record_type: ast.Record.Type = switch (operation) {
        inline else => |comptime_operation| (comptime filter_type(comptime_operation)) orelse
            unreachable,
    };
    const filter_node = try one_argument(parser, call, "(filter)");
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const struct_init = tree.fullStructInit(&buffer, filter_node) orelse
        return parser.fail_node(filter_node, "expected a filter literal");
    if (struct_init.ast.type_expr != 0) {
        return parser.fail_node(filter_node, "filter type is implied, use .{{...}}");
    }
    const arguments = try parser.arena.alloc(ast.Expression, 1);
    arguments[0] = .{ .record = try parse_record(parser, record_type, struct_init) };
    return .{ .name = operation, .arguments = arguments };
}

fn parse_concurrently(parser: *Parser, call: std.zig.Ast.full.Call) !ast.Call {
    const tree = &parser.tree;
    const args = try two_arguments(parser, call, "(count, call)");
    const count = try parse_u32(parser, args[0]);
    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    const inner = tree.fullCall(&buffer, args[1]) orelse
        return parser.fail_node(args[1], "expected a call");
    const name = try parse_call_name(parser, inner);
    const operation = std.meta.stringToEnum(ast.Call.Name, name) orelse
        return parser.fail_node(inner.ast.fn_expr, "expected an operation");
    var operation_call = try parse_operation(parser, operation, inner);
    operation_call.concurrency = count;
    return operation_call;
}

const AssertionCall = stdx.EnumType(ast.api_decl_names(ast.is_assertion));

fn parse_assertion(
    parser: *Parser,
    name: []const u8,
    call: std.zig.Ast.full.Call,
) !ast.Assertion {
    const tree = &parser.tree;
    const assertion = std.meta.stringToEnum(AssertionCall, name) orelse
        return parser.fail(tree.firstToken(call.ast.fn_expr), "unknown assertion '{s}'", .{name});
    switch (assertion) {
        .assert_equal => {
            const args = try two_arguments(parser, call, "(actual, expected)");
            if (tree.nodes.items(.tag)[args[0]] == .field_access) {
                const value = try parse_expression(parser, args[1]);
                const comparison =
                    try parse_field_comparison(parser, args[0], args[1], value);
                return .{ .equal_field = comparison };
            }

            const actual_token = tree.firstToken(args[0]);
            const actual = try parse_expression(parser, args[0]);
            const record_type = try result_record_type(parser, actual, actual_token);

            var buffer: [2]std.zig.Ast.Node.Index = undefined;
            const array_init = tree.fullArrayInit(&buffer, args[1]) orelse
                return parser.fail_node(args[1], "expected a tuple of records");
            const expected =
                try parser.arena.alloc(ast.Record, array_init.ast.elements.len);
            for (array_init.ast.elements, 0..) |element, index| {
                var init_buffer: [2]std.zig.Ast.Node.Index = undefined;
                const struct_init = tree.fullStructInit(&init_buffer, element) orelse
                    return parser.fail_node(element, "expected a record");
                if (struct_init.ast.type_expr != 0) {
                    return parser.fail_node(element, "record type is implied, use .{{...}}");
                }
                expected[index] = try parse_record(parser, record_type, struct_init);
            }
            if (expected.len == 0) {
                return parser.fail(call.ast.lparen, "use assert_empty", .{});
            }
            return .{ .equal = .{ .actual = actual.reference, .expected = expected } };
        },
        .assert_empty => {
            const node = try one_argument(parser, call, "(actual)");
            return .{ .empty = try parse_reference(parser, node) };
        },
        .assert_unique => {
            const node = try one_argument(parser, call, "(ids)");
            return .{ .unique = try parse_reference(parser, node) };
        },
        .assert_ascending => {
            const node = try one_argument(parser, call, "(ids)");
            return .{ .ascending = try parse_reference(parser, node) };
        },
        .assert_greater_than => {
            const args = try two_arguments(parser, call, "(actual, value)");
            if (tree.nodes.items(.tag)[args[1]] != .number_literal) {
                return parser.fail_node(args[1], "expected an integer");
            }
            const integer = tree.tokenSlice(tree.nodes.items(.main_token)[args[1]]);
            const comparison = try parse_field_comparison(parser, args[0], args[1], .{
                .integer = integer,
            });
            return .{ .greater_than = comparison };
        },
        .assert_fail => {
            const inner_node = try one_argument(parser, call, "(call)");
            var buffer: [1]std.zig.Ast.Node.Index = undefined;
            const inner = tree.fullCall(&buffer, inner_node) orelse
                return parser.fail_node(inner_node, "expected a call");
            const inner_name = try parse_call_name(parser, inner);
            const operation = std.meta.stringToEnum(ast.Call.Name, inner_name) orelse
                return parser.fail_node(inner.ast.fn_expr, "expected an operation");
            return .{ .fail = try parse_operation(parser, operation, inner) };
        },
    }
}

fn parse_record(
    parser: *Parser,
    record_type: ast.Record.Type,
    struct_init: std.zig.Ast.full.StructInit,
) anyerror!ast.Record {
    const tree = &parser.tree;
    const fields = try parser.arena.alloc(ast.Field, struct_init.ast.fields.len);
    for (struct_init.ast.fields, 0..) |field_init, index| {
        const name_token = tree.firstToken(field_init) - 2;
        const field_name = tree.tokenSlice(name_token);
        if (!record_field_exists(record_type, field_name)) {
            return parser.fail(name_token, "no field '{s}' on {s}", .{
                field_name,
                @tagName(record_type),
            });
        }
        // NOTE: Quadratic, but bounded by the record's declared field count, at most 13.
        // I may revisit this later.
        for (fields[0..index]) |existing| {
            if (std.mem.eql(u8, existing.name, field_name)) {
                return parser.fail(name_token, "duplicate field '{s}'", .{field_name});
            }
        }

        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        if (tree.fullStructInit(&buffer, field_init)) |nested| {
            if (nested.ast.type_expr == 0) {
                const nested_type = record_field_record_type(record_type, field_name) orelse
                    return parser.fail(name_token, "field '{s}' takes no record", .{field_name});
                fields[index] = .{
                    .name = field_name,
                    .value = .{ .record = try parse_record(parser, nested_type, nested) },
                    .type = ast.Field.Type.resolve(record_type, field_name),
                };
                continue;
            }
        }

        const value = try parse_expression(parser, field_init);
        if (ast.Record.is_flags(record_type) and (value != .boolean or !value.boolean)) {
            return parser.fail(name_token, "flag '{s}' must be true (omit to leave false)", .{
                field_name,
            });
        }
        if (value == .enum_literal and
            !record_field_enum_has(record_type, field_name, value.enum_literal))
        {
            return parser.fail(name_token, "field '{s}' has no member '.{s}'", .{
                field_name,
                value.enum_literal,
            });
        }
        fields[index] = .{
            .name = field_name,
            .value = value,
            .type = ast.Field.Type.resolve(record_type, field_name),
        };
    }
    if (fields.len == 0) {
        return parser.fail(struct_init.ast.lbrace, "empty record", .{});
    }
    return .{ .type = record_type, .fields = fields };
}

fn result_record_type(
    parser: *Parser,
    actual: ast.Expression,
    token: std.zig.Ast.TokenIndex,
) !ast.Record.Type {
    if (actual == .reference) {
        const value = parser.bindings.get(actual.reference).?;
        if (value == .call) {
            if (operation_result(value.call.name)) |record_type| return record_type;
        }
    }
    return parser.fail(token, "expected a value, not an operation", .{});
}

fn parse_reference(parser: *Parser, node: std.zig.Ast.Node.Index) ![]const u8 {
    const expression = try parse_expression(parser, node);
    if (expression != .reference) return parser.fail_node(node, "expected a binding");
    return expression.reference;
}

// Resolves an identifier node to its binding, failing if the name is unbound.
fn resolve_reference(
    parser: *Parser,
    node: std.zig.Ast.Node.Index,
) !struct { reference: []const u8, value: ast.Expression } {
    const tree = &parser.tree;
    if (tree.nodes.items(.tag)[node] != .identifier) {
        return parser.fail_node(node, "expected a binding");
    }
    const reference = tree.tokenSlice(tree.nodes.items(.main_token)[node]);
    const value = parser.bindings.get(reference) orelse
        return parser.fail(tree.firstToken(node), "unknown binding '{s}'", .{reference});
    return .{ .reference = reference, .value = value };
}

fn parse_index(parser: *Parser, node: std.zig.Ast.Node.Index) !ast.Expression {
    const tree = &parser.tree;
    const data = tree.nodes.items(.data)[node];

    const base_node = data.lhs;
    const resolved = try resolve_reference(parser, base_node);
    const record_type = switch (resolved.value) {
        .call => |call| operation_result(call.name),
        else => null,
    } orelse return parser.fail_node(base_node, "expected an operation result");

    const index = try parse_u32(parser, data.rhs);
    return .{ .index = .{
        .reference = resolved.reference,
        .index = index,
        .record_type = record_type,
    } };
}

// Only legal on a binding already narrowed to one record by indexing (`const foo = foos[0];`),
// never a slice-bound reference directly. This matches how asserts elsewhere only take bindings.
fn parse_field_comparison(
    parser: *Parser,
    node: std.zig.Ast.Node.Index,
    value_node: std.zig.Ast.Node.Index,
    value: ast.Expression,
) !ast.Assertion.FieldComparison {
    const tree = &parser.tree;
    if (tree.nodes.items(.tag)[node] != .field_access) {
        return parser.fail_node(node, "expected a field access");
    }
    const data = tree.nodes.items(.data)[node];
    const field_name = tree.tokenSlice(data.rhs);

    const resolved = try resolve_reference(parser, data.lhs);
    if (resolved.value != .index) {
        return parser.fail_node(data.lhs, "expected an indexed binding");
    }

    const record_type = resolved.value.index.record_type;
    if (!record_field_exists(record_type, field_name)) {
        return parser.fail(data.rhs, "no field '{s}' on {s}", .{
            field_name,
            @tagName(record_type),
        });
    }
    if (value == .enum_literal and
        !record_field_enum_has(record_type, field_name, value.enum_literal))
    {
        return parser.fail(tree.firstToken(value_node), "field '{s}' has no member '.{s}'", .{
            field_name,
            value.enum_literal,
        });
    }
    return .{
        .reference = resolved.reference,
        .field = .{
            .name = field_name,
            .value = value,
            .type = ast.Field.Type.resolve(record_type, field_name),
        },
    };
}

fn check_arguments(
    parser: *Parser,
    call: std.zig.Ast.full.Call,
    count: usize,
    comptime expected: []const u8,
) !void {
    if (call.ast.params.len != count) {
        return parser.fail_arguments(call, expected);
    }
}

fn zero_arguments(parser: *Parser, call: std.zig.Ast.full.Call) !void {
    return check_arguments(parser, call, 0, "()");
}

fn one_argument(
    parser: *Parser,
    call: std.zig.Ast.full.Call,
    comptime expected: []const u8,
) !std.zig.Ast.Node.Index {
    try check_arguments(parser, call, 1, expected);
    return call.ast.params[0];
}

fn two_arguments(
    parser: *Parser,
    call: std.zig.Ast.full.Call,
    comptime expected: []const u8,
) ![2]std.zig.Ast.Node.Index {
    try check_arguments(parser, call, 2, expected);
    return call.ast.params[0..2].*;
}

fn parse_u32(parser: *Parser, node: std.zig.Ast.Node.Index) !u32 {
    const tree = &parser.tree;
    if (tree.nodes.items(.tag)[node] != .number_literal) {
        return parser.fail_node(node, "expected an integer");
    }
    const token = tree.nodes.items(.main_token)[node];
    return stdx.parse_int(u32, tree.tokenSlice(token), .{}) catch
        parser.fail(token, "invalid integer", .{});
}

fn api_record_type(comptime T: type) ?ast.Record.Type {
    inline for (std.enums.values(ast.Record.Type)) |record_type| {
        if (ast.Record.Struct(record_type) == T) return record_type;
    }
    return null;
}

fn filter_type(comptime operation: ast.Call.Name) ?ast.Record.Type {
    const params = @typeInfo(@TypeOf(@field(api, @tagName(operation)))).@"fn".params;
    if (params.len != 1) return null;
    const Param = params[0].type orelse return null;
    return api_record_type(Param);
}

fn operation_result(operation: ast.Call.Name) ?ast.Record.Type {
    switch (operation) {
        inline else => |comptime_operation| return comptime result: {
            const function = @typeInfo(
                @TypeOf(@field(api, @tagName(comptime_operation))),
            ).@"fn";
            if (function.return_type.? == void) break :result null;
            break :result api_record_type(@typeInfo(function.return_type.?).pointer.child);
        },
    }
}

fn field_is_reserved(name: []const u8) bool {
    return std.mem.eql(u8, name, "padding") or std.mem.eql(u8, name, "reserved");
}

fn record_field_exists(record_type: ast.Record.Type, name: []const u8) bool {
    if (field_is_reserved(name)) return false;
    switch (record_type) {
        inline else => |comptime_type| {
            inline for (std.meta.fields(ast.Record.Struct(comptime_type))) |field| {
                if (std.mem.eql(u8, field.name, name)) return true;
            }
            return false;
        },
    }
}

fn record_field_record_type(
    record_type: ast.Record.Type,
    name: []const u8,
) ?ast.Record.Type {
    switch (record_type) {
        inline else => |comptime_type| {
            inline for (std.meta.fields(ast.Record.Struct(comptime_type))) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    if (@typeInfo(field.type) == .@"struct") {
                        return comptime api_record_type(field.type);
                    }
                    return null;
                }
            }
            return null;
        },
    }
}

fn record_field_enum_has(
    record_type: ast.Record.Type,
    field_name: []const u8,
    member: []const u8,
) bool {
    switch (record_type) {
        inline else => |comptime_type| {
            inline for (std.meta.fields(ast.Record.Struct(comptime_type))) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    switch (@typeInfo(field.type)) {
                        .@"enum" => |enum_info| {
                            inline for (enum_info.fields) |enum_field| {
                                if (std.mem.eql(u8, enum_field.name, member)) return true;
                            }
                            return false;
                        },
                        else => return false,
                    }
                }
            }
            return false;
        },
    }
}
