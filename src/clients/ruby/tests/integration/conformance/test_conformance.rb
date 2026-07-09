require "json"
require_relative "../tiger_beetle_integration_test"

class TestConformanceCases < Minitest::Test
  fixtures = File.expand_path("conformance.json", __dir__)
  SUITES = JSON.parse(File.read(fixtures)).fetch("suites")

  def setup
    @tb_address = ENV.fetch("TB_ADDRESS", "3000")
    @client = TigerBeetle::Client.new(cluster_id: 0, replica_addresses: @tb_address)
  end

  def teardown
    @client.close if @client && !@client.closed?
  end

  SUITES.each do |suite|
    suite_name = suite.fetch("suite")
    suite.fetch("cases").each do |test_case|
      description = test_case.fetch("description")

      define_method("test_#{suite_name}_#{description.gsub(/\W+/, "_")}") do
        case_description = "#{suite_name}: #{description}"
        context = { ids: {}, vars: {} }

        test_case.fetch("arrange", []).each { |step| execute_arrange(step, context) }
        expected = test_case.fetch("assert")

        if expects_fail?(expected)
          assert_raises(StandardError, case_description) { execute_act(test_case, context) }
        else
          assert_results(expected, execute_act(test_case, context), case_description, context)
        end
      end
    end
  end

  private

  def execute_act(test_case, context)
    test_case.fetch("act").map { |step| execute_operation(step.fetch("operation"), context) }
  end

  def expects_fail?(expected)
    expected.any? { |assertion| single_entry(assertion).first == "assert_fail" }
  end

  def single_entry(hash)
    flunk("expected a single entry: #{hash.inspect}") unless hash.length == 1

    hash.first
  end

  def execute_arrange(step, context)
    type, value = single_entry(step)

    case type
    when "assign"
      assign(value, context)
    when "operation"
      execute_operation(value, context)
    else
      flunk("unknown arrange step: #{step.inspect}")
    end
  end

  def assign(step, context)
    name = step.fetch("name")
    value = step.fetch("value")
    context.fetch(:vars)[name] = build_value(value, context)
  end

  def execute_operation(step, context)
    operation = step.fetch("name")
    inputs = step.fetch("inputs").map { |input| resolve_input(input, context) }

    case operation
    when "create_accounts"
      { "create_account_results" => @client.create_accounts(inputs) }
    when "lookup_accounts"
      { "accounts" => @client.lookup_accounts(inputs) }
    when "create_transfers"
      { "create_transfer_results" => @client.create_transfers(inputs) }
    when "lookup_transfers"
      { "transfers" => @client.lookup_transfers(inputs) }
    when "get_account_transfers"
      { "transfers" => @client.get_account_transfers(single_input(inputs)) }
    when "get_account_balances"
      { "account_balances" => @client.get_account_balances(single_input(inputs)) }
    when "query_accounts"
      { "accounts" => @client.query_accounts(single_input(inputs)) }
    when "query_transfers"
      { "transfers" => @client.query_transfers(single_input(inputs)) }
    else
      flunk("unknown operation: #{operation}")
    end
  end

  def single_input(inputs)
    flunk("expected a single input: #{inputs.inspect}") unless inputs.length == 1

    inputs.first
  end

  def resolve_input(input, context)
    if input.key?("from")
      context.fetch(:vars).fetch(input.fetch("from"))
    elsif input.key?("value")
      build_value(input.fetch("value"), context)
    else
      flunk("unknown input: #{input.inspect}")
    end
  end

  def build_value(value, context)
    type, data = single_entry(value)

    case type
    when "account"
      build_account(data, context)
    when "transfer"
      build_transfer(data, context)
    when "account_filter"
      build_account_filter(data, context)
    when "query_filter"
      build_query_filter(data, context)
    when "id"
      logical_id(data, context)
    when "u128"
      data.to_i(10)
    else
      flunk("unknown value: #{value.inspect}")
    end
  end

  def build_account(account, context)
    TigerBeetle::Account.new(
      id: build_value(account.fetch("id"), context),
      user_data_128: resolve_value(account.fetch("user_data_128", 0), context),
      ledger: account.fetch("ledger"),
      code: account.fetch("code"),
      flags: build_flags(account.fetch("flags", []), TigerBeetle::AccountFlags)
    )
  end

  def build_account_filter(filter, context)
    TigerBeetle::AccountFilter.new(
      account_id: build_value(filter.fetch("account_id"), context),
      limit: filter.fetch("limit"),
      flags: build_flags(filter.fetch("flags", []), TigerBeetle::AccountFilterFlags)
    )
  end

  def build_query_filter(filter, context)
    TigerBeetle::QueryFilter.new(
      user_data_128: build_value(filter.fetch("user_data_128"), context),
      limit: filter.fetch("limit"),
      flags: build_flags(filter.fetch("flags", []), TigerBeetle::QueryFilterFlags)
    )
  end

  def build_flags(names, flags_module)
    names.reduce(0) { |mask, name| mask | flags_module.const_get(name.upcase) }
  end

  def build_transfer(transfer, context)
    TigerBeetle::Transfer.new(
      id: build_value(transfer.fetch("id"), context),
      debit_account_id: build_value(transfer.fetch("debit_account_id"), context),
      credit_account_id: build_value(transfer.fetch("credit_account_id"), context),
      amount: transfer.fetch("amount"),
      user_data_128: resolve_value(transfer.fetch("user_data_128", 0), context),
      ledger: transfer.fetch("ledger"),
      code: transfer.fetch("code")
    )
  end

  def logical_id(value, context)
    context.fetch(:ids)[value] ||= TigerBeetle.id
  end

  def assert_results(expected, actual, case_description, context)
    assert_equal(expected.length, actual.length, case_description)

    expected.zip(actual).each do |assertion, result|
      assert_result(assertion, result, case_description, context)
    end
  end

  def assert_result(assertion, result, case_description, context)
    assertion_type, assertion_value = single_entry(assertion)

    case assertion_type
    when "assert_empty"
      items = result.fetch(assertion_value)
      assert_empty(items, case_description)
    when "assert_equal"
      result_type = assertion_value.fetch("actual")
      expected_items = assertion_value.fetch("expected")
      items = result.fetch(result_type)
      assert_equal(expected_items.length, items.length, case_description)

      expected_items.zip(items).each do |expected_item, item|
        assert_item(result_type, expected_item, item, case_description, context)
      end
    else
      flunk("unknown assertion type: #{assertion_type}")
    end
  end

  def assert_item(result_type, expected, actual, case_description, context)
    case result_type
    when "create_account_results"
      assert_create_result(expected, actual, TigerBeetle::CreateAccountStatus, case_description)
    when "create_transfer_results"
      assert_create_result(expected, actual, TigerBeetle::CreateTransferStatus, case_description)
    when "accounts", "transfers", "account_balances"
      assert_record(expected, actual, case_description, context)
    else
      flunk("unknown result type: #{result_type}")
    end
  end

  def assert_create_result(expected, actual, status_class, case_description)
    expected.each do |field, value|
      if field == "status"
        assert_equal(status_class.const_get(value.upcase), actual.status, case_description)
      else
        assert_equal(value, actual.public_send(field), case_description)
      end
    end
  end

  def assert_record(expected, actual, case_description, context)
    expected.each do |field, value|
      assert_equal(resolve_value(value, context), actual.public_send(field), case_description)
    end
  end

  # Tagged values are hashes and need resolution; plain scalars pass through.
  def resolve_value(value, context)
    return value unless value.is_a?(Hash)

    build_value(value, context)
  end
end
