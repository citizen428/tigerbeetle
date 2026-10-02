const ct = @import("../conformance_test_api.zig");

test "fails operations after close" {
    ct.close_client();

    ct.assert_fail_with(ct.lookup_accounts(.{ct.generate_id()}), .client_closed);
}

test "ignores a second close" {
    ct.close_client();

    ct.close_client();
}
