//! Defines the generated conformance suite: cases appear in the generated test
//! files in the order they are referenced here.

pub const cases = .{
    @import("cases/ids_generate.zon"),
    @import("cases/accounts_create.zon"),
    @import("cases/accounts_lookup.zon"),
    @import("cases/transfers_create.zon"),
    @import("cases/transfers_lookup.zon"),
    @import("cases/account_transfers_get.zon"),
    @import("cases/account_balances_get.zon"),
    @import("cases/accounts_query.zon"),
    @import("cases/transfers_query.zon"),
    @import("cases/uint128_max.zon"),
    @import("cases/transfers_create_concurrent.zon"),
    @import("cases/client_close.zon"),
};
