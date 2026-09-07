const ct = @import("../conformance_test_api.zig");

test "returns accounts matching user data" {
    const account_1_id = ct.generate_id();
    const account_2_id = ct.generate_id();
    const user_data = ct.generate_id();
    ct.create_accounts(.{
        .{ .id = account_1_id, .user_data_128 = user_data, .ledger = 1, .code = 1 },
        .{ .id = account_2_id, .user_data_128 = user_data, .ledger = 1, .code = 1 },
        .{ .id = ct.generate_id(), .user_data_128 = ct.generate_id(), .ledger = 1, .code = 1 },
    });

    const accounts = ct.query_accounts(.{ .user_data_128 = user_data, .limit = 10 });

    ct.assert_equal(accounts, .{
        .{ .id = account_1_id, .user_data_128 = user_data },
        .{ .id = account_2_id, .user_data_128 = user_data },
    });
}

test "returns accounts in reverse order with the reversed flag" {
    const account_1_id = ct.generate_id();
    const account_2_id = ct.generate_id();
    const user_data = ct.generate_id();
    ct.create_accounts(.{
        .{ .id = account_1_id, .user_data_128 = user_data, .ledger = 1, .code = 1 },
        .{ .id = account_2_id, .user_data_128 = user_data, .ledger = 1, .code = 1 },
    });

    const accounts = ct.query_accounts(.{
        .user_data_128 = user_data,
        .limit = 10,
        .flags = .{ .reversed = true },
    });

    ct.assert_equal(accounts, .{
        .{ .id = account_2_id },
        .{ .id = account_1_id },
    });
}

test "returns accounts matching ledger and code" {
    const account_id = ct.generate_id();
    const user_data = ct.generate_id();
    ct.create_accounts(.{
        .{ .id = account_id, .user_data_128 = user_data, .ledger = 7, .code = 42 },
        .{ .id = ct.generate_id(), .user_data_128 = user_data, .ledger = 7, .code = 43 },
        .{ .id = ct.generate_id(), .user_data_128 = user_data, .ledger = 8, .code = 42 },
    });

    const accounts = ct.query_accounts(.{
        .user_data_128 = user_data,
        .ledger = 7,
        .code = 42,
        .limit = 10,
    });

    ct.assert_equal(accounts, .{.{ .id = account_id, .ledger = 7, .code = 42 }});
}

test "returns no more accounts than the limit" {
    const account_1_id = ct.generate_id();
    const account_2_id = ct.generate_id();
    const user_data = ct.generate_id();
    ct.create_accounts(.{
        .{ .id = account_1_id, .user_data_128 = user_data, .ledger = 1, .code = 1 },
        .{ .id = account_2_id, .user_data_128 = user_data, .ledger = 1, .code = 1 },
        .{ .id = ct.generate_id(), .user_data_128 = user_data, .ledger = 1, .code = 1 },
    });

    const accounts = ct.query_accounts(.{ .user_data_128 = user_data, .limit = 2 });

    ct.assert_equal(accounts, .{
        .{ .id = account_1_id },
        .{ .id = account_2_id },
    });
}

test "pages through accounts with a timestamp cursor" {
    const account_1_id = ct.generate_id();
    const account_2_id = ct.generate_id();
    const account_3_id = ct.generate_id();
    const user_data = ct.generate_id();
    ct.create_accounts(.{
        .{ .id = account_1_id, .user_data_128 = user_data, .ledger = 1, .code = 1 },
        .{ .id = account_2_id, .user_data_128 = user_data, .ledger = 1, .code = 1 },
        .{ .id = account_3_id, .user_data_128 = user_data, .ledger = 1, .code = 1 },
    });

    const page_1 = ct.query_accounts(.{ .user_data_128 = user_data, .limit = 2 });

    ct.assert_equal(page_1, .{
        .{ .id = account_1_id },
        .{ .id = account_2_id },
    });

    const page_1_last = page_1[1];
    const cursor_1 = page_1_last.timestamp;
    const page_2 = ct.query_accounts(.{
        .user_data_128 = user_data,
        .timestamp_min = ct.increment(cursor_1, 1),
        .limit = 2,
    });

    ct.assert_equal(page_2, .{.{ .id = account_3_id }});

    const page_2_last = page_2[0];
    const cursor_2 = page_2_last.timestamp;
    const page_3 = ct.query_accounts(.{
        .user_data_128 = user_data,
        .timestamp_min = ct.increment(cursor_2, 1),
        .limit = 2,
    });

    ct.assert_empty(page_3);
}

test "returns no accounts for unused user data" {
    const accounts = ct.query_accounts(.{ .user_data_128 = ct.generate_id(), .limit = 10 });

    ct.assert_empty(accounts);
}

test "fails when the limit is too large" {
    ct.assert_fail(ct.query_accounts(.{
        .user_data_128 = ct.generate_id(),
        .limit = 10000,
    }));
}
