package tigerbeetle_go

import (
	"bytes"
	"encoding/json"
	"errors"
	"math/big"
	"os"
	"reflect"
	"strings"
	"testing"
)

var errInvalidConformanceStep = errors.New("invalid conformance step")

type conformanceFixture struct {
	Suites []conformanceSuite `json:"suites"`
}

type conformanceSuite struct {
	Suite string            `json:"suite"`
	Cases []conformanceCase `json:"cases"`
}

type conformanceCase struct {
	Description string            `json:"description"`
	Arrange     []conformanceStep `json:"arrange"`
	Act         []conformanceStep `json:"act"`
	Assert      []json.RawMessage `json:"assert"`
}

type conformanceStep struct {
	Type      string
	Assign    conformanceAssign
	Operation conformanceOperation
}

func (step *conformanceStep) UnmarshalJSON(data []byte) error {
	var tagged map[string]json.RawMessage
	if err := json.Unmarshal(data, &tagged); err != nil {
		return err
	}
	if len(tagged) != 1 {
		return errInvalidConformanceStep
	}

	for stepType, value := range tagged {
		step.Type = stepType
		switch stepType {
		case "assign":
			return json.Unmarshal(value, &step.Assign)
		case "operation":
			return json.Unmarshal(value, &step.Operation)
		default:
			return errInvalidConformanceStep
		}
	}

	return errInvalidConformanceStep
}

func decodeTaggedObject(t testing.TB, data json.RawMessage) (string, json.RawMessage) {
	var tagged map[string]json.RawMessage
	decodeJSON(t, data, &tagged)
	if len(tagged) != 1 {
		t.Fatalf("expected exactly one tag: %s", data)
	}

	for tag, value := range tagged {
		return tag, value
	}

	t.Fatalf("expected exactly one tag: %s", data)
	return "", nil
}

func decodeJSON(t testing.TB, data json.RawMessage, value interface{}) {
	if err := json.Unmarshal(data, value); err != nil {
		t.Fatal(err)
	}
}

type conformanceAssign struct {
	Name  string          `json:"name"`
	Value json.RawMessage `json:"value"`
}

type conformanceOperation struct {
	Name   string             `json:"name"`
	Inputs []conformanceInput `json:"inputs"`
}

type conformanceInput struct {
	From  string          `json:"from"`
	Value json.RawMessage `json:"value"`
}

type conformanceContext struct {
	ids  map[uint64]Uint128
	vars map[string]interface{}
}

func TestConformance(t *testing.T) {
	fixtureBytes, err := os.ReadFile("conformance/conformance.json")
	if err != nil {
		t.Fatal(err)
	}

	var fixture conformanceFixture
	if err := json.Unmarshal(fixtureBytes, &fixture); err != nil {
		t.Fatal(err)
	}

	WithClient(t, func(client Client) {
		for _, suite := range fixture.Suites {
			for _, testCase := range suite.Cases {
				description := suite.Suite + ": " + testCase.Description
				t.Run(description, func(t *testing.T) {
					context := conformanceContext{
						ids:  map[uint64]Uint128{},
						vars: map[string]interface{}{},
					}

					for _, step := range testCase.Arrange {
						executeArrange(t, client, step, context)
					}

					if expectsFail(t, testCase.Assert) {
						assertFails(t, description, func() error {
							_, err := executeAct(t, client, testCase, context)
							return err
						})
					} else {
						results, err := executeAct(t, client, testCase, context)
						if err != nil {
							t.Fatalf("%s: %s", description, err)
						}
						assertResults(t, testCase.Assert, results, description, context)
					}
				})
			}
		}
	})
}

func executeAct(
	t testing.TB,
	client Client,
	testCase conformanceCase,
	context conformanceContext,
) ([]interface{}, error) {
	results := make([]interface{}, len(testCase.Act))
	for i, step := range testCase.Act {
		if step.Type != "operation" {
			t.Fatalf("act step is not an operation: %#v", step)
		}
		result, err := executeOperation(t, client, step.Operation, context)
		if err != nil {
			return nil, err
		}
		results[i] = result
	}
	return results, nil
}

func expectsFail(t testing.TB, assertions []json.RawMessage) bool {
	for _, assertion := range assertions {
		tag, _ := decodeTaggedObject(t, assertion)
		if tag == "assert_fail" {
			return true
		}
	}
	return false
}

// A failure is either an error returned by the client or a panic.
func assertFails(t testing.TB, description string, action func() error) {
	failed := false
	func() {
		defer func() {
			if recover() != nil {
				failed = true
			}
		}()
		failed = action() != nil
	}()

	if !failed {
		t.Fatalf("%s: expected failure", description)
	}
}

func executeArrange(t testing.TB, client Client, step conformanceStep, context conformanceContext) {
	switch step.Type {
	case "assign":
		assign(t, step.Assign, context)
	case "operation":
		if _, err := executeOperation(t, client, step.Operation, context); err != nil {
			t.Fatalf("arrange operation failed: %s", err)
		}
	default:
		t.Fatalf("unknown arrange step: %#v", step)
	}
}

func assign(t testing.TB, assign conformanceAssign, context conformanceContext) {
	context.vars[assign.Name] = buildValue(t, assign.Value, context)
}

func executeOperation(
	t testing.TB,
	client Client,
	operation conformanceOperation,
	context conformanceContext,
) (interface{}, error) {
	inputs := make([]interface{}, len(operation.Inputs))
	for i, input := range operation.Inputs {
		inputs[i] = resolveInput(t, input, context)
	}

	switch operation.Name {
	case "create_accounts":
		accounts := make([]Account, len(inputs))
		for i, input := range inputs {
			account, ok := input.(Account)
			if !ok {
				t.Fatalf("create_accounts input is not an Account: %#v", input)
			}
			accounts[i] = account
		}

		return client.CreateAccounts(accounts)
	case "lookup_accounts":
		ids := make([]Uint128, len(inputs))
		for i, input := range inputs {
			ids[i] = uint128Value(t, input)
		}

		return client.LookupAccounts(ids)
	case "create_transfers":
		transfers := make([]Transfer, len(inputs))
		for i, input := range inputs {
			transfer, ok := input.(Transfer)
			if !ok {
				t.Fatalf("create_transfers input is not a Transfer: %#v", input)
			}
			transfers[i] = transfer
		}

		return client.CreateTransfers(transfers)
	case "lookup_transfers":
		ids := make([]Uint128, len(inputs))
		for i, input := range inputs {
			ids[i] = uint128Value(t, input)
		}

		return client.LookupTransfers(ids)
	case "get_account_transfers":
		return client.GetAccountTransfers(accountFilterValue(t, inputs))
	case "get_account_balances":
		return client.GetAccountBalances(accountFilterValue(t, inputs))
	default:
		t.Fatalf("unknown operation: %s", operation.Name)
		return nil, nil
	}
}

func resolveInput(t testing.TB, input conformanceInput, context conformanceContext) interface{} {
	if input.From != "" {
		value, ok := context.vars[input.From]
		if !ok {
			t.Fatalf("unknown variable: %s", input.From)
		}
		return value
	}
	if input.Value != nil {
		return buildValue(t, input.Value, context)
	}

	t.Fatalf("unknown input: %#v", input)
	return nil
}

func buildValue(t testing.TB, value json.RawMessage, context conformanceContext) interface{} {
	tag, data := decodeTaggedObject(t, value)

	switch tag {
	case "account":
		return buildAccount(t, data, context)
	case "transfer":
		return buildTransfer(t, data, context)
	case "account_filter":
		return buildAccountFilter(t, data, context)
	case "id":
		var id uint64
		decodeJSON(t, data, &id)
		return logicalID(id, context)
	case "u128":
		var value string
		decodeJSON(t, data, &value)
		return u128(t, value)
	default:
		t.Fatalf("unknown value: %s", tag)
		return nil
	}
}

func u128(t testing.TB, value string) Uint128 {
	integer, ok := new(big.Int).SetString(value, 10)
	if !ok {
		t.Fatalf("invalid u128: %s", value)
	}
	return BigIntToUint128(integer)
}

func buildAccount(t testing.TB, data json.RawMessage, context conformanceContext) Account {
	var account struct {
		ID     json.RawMessage `json:"id"`
		Ledger uint32          `json:"ledger"`
		Code   uint16          `json:"code"`
		Flags  []string        `json:"flags"`
	}
	decodeJSON(t, data, &account)

	var flags AccountFlags
	buildFlags(t, account.Flags, &flags)

	return Account{
		ID:     uint128Value(t, buildValue(t, account.ID, context)),
		Ledger: account.Ledger,
		Code:   account.Code,
		Flags:  flags.ToUint16(),
	}
}

func buildAccountFilter(
	t testing.TB,
	data json.RawMessage,
	context conformanceContext,
) AccountFilter {
	var filter struct {
		AccountID json.RawMessage `json:"account_id"`
		Limit     uint32          `json:"limit"`
		Flags     []string        `json:"flags"`
	}
	decodeJSON(t, data, &filter)

	var flags AccountFilterFlags
	buildFlags(t, filter.Flags, &flags)

	return AccountFilter{
		AccountID: uint128Value(t, buildValue(t, filter.AccountID, context)),
		Limit:     filter.Limit,
		Flags:     flags.ToUint32(),
	}
}

// Sets the named boolean fields on a client flags struct, e.g. AccountFlags.
func buildFlags(t testing.TB, names []string, flags interface{}) {
	value := reflect.ValueOf(flags).Elem()
	for _, name := range names {
		field := recordField(value, name)
		if !field.IsValid() {
			t.Fatalf("unknown flag: %s", name)
		}
		field.SetBool(true)
	}
}

func buildTransfer(t testing.TB, data json.RawMessage, context conformanceContext) Transfer {
	var transfer struct {
		ID              json.RawMessage `json:"id"`
		DebitAccountID  json.RawMessage `json:"debit_account_id"`
		CreditAccountID json.RawMessage `json:"credit_account_id"`
		Amount          uint64          `json:"amount"`
		Ledger          uint32          `json:"ledger"`
		Code            uint16          `json:"code"`
	}
	decodeJSON(t, data, &transfer)

	return Transfer{
		ID:              uint128Value(t, buildValue(t, transfer.ID, context)),
		DebitAccountID:  uint128Value(t, buildValue(t, transfer.DebitAccountID, context)),
		CreditAccountID: uint128Value(t, buildValue(t, transfer.CreditAccountID, context)),
		Amount:          ToUint128(transfer.Amount),
		Ledger:          transfer.Ledger,
		Code:            transfer.Code,
	}
}

func uint128Value(t testing.TB, value interface{}) Uint128 {
	u128, ok := value.(Uint128)
	if !ok {
		t.Fatalf("expected Uint128: %#v", value)
	}
	return u128
}

func accountFilterValue(t testing.TB, inputs []interface{}) AccountFilter {
	if len(inputs) != 1 {
		t.Fatalf("expected a single account filter, got %d inputs", len(inputs))
	}
	filter, ok := inputs[0].(AccountFilter)
	if !ok {
		t.Fatalf("expected AccountFilter: %#v", inputs[0])
	}
	return filter
}

func logicalID(value uint64, context conformanceContext) Uint128 {
	id, ok := context.ids[value]
	if !ok {
		id = ID()
		context.ids[value] = id
	}
	return id
}

func assertResults(
	t testing.TB,
	expected []json.RawMessage,
	results []interface{},
	description string,
	context conformanceContext,
) {
	if len(expected) != len(results) {
		t.Fatalf("%s: expected %d result steps, got %d", description, len(expected), len(results))
	}

	for i := range expected {
		assertResult(t, expected[i], results[i], description, context)
	}
}

func assertResult(
	t testing.TB,
	assertion json.RawMessage,
	result interface{},
	description string,
	context conformanceContext,
) {
	assertionType, assertionValue := decodeTaggedObject(t, assertion)

	switch assertionType {
	case "assert_empty":
		var expectedName string
		decodeJSON(t, assertionValue, &expectedName)
		assertResultEmpty(t, expectedName, result, description)
	case "assert_equal":
		var equal struct {
			Actual   string          `json:"actual"`
			Expected json.RawMessage `json:"expected"`
		}
		decodeJSON(t, assertionValue, &equal)
		assertResultEqual(t, equal.Actual, equal.Expected, result, description, context)
	default:
		t.Fatalf("%s: unknown assertion type: %s", description, assertionType)
	}
}

func resultName(t testing.TB, result interface{}) (string, int) {
	switch result := result.(type) {
	case []CreateAccountResult:
		return "create_account_results", len(result)
	case []Account:
		return "accounts", len(result)
	case []CreateTransferResult:
		return "create_transfer_results", len(result)
	case []Transfer:
		return "transfers", len(result)
	case []AccountBalance:
		return "account_balances", len(result)
	default:
		t.Fatalf("unknown result type: %#v", result)
		return "", 0
	}
}

func assertResultEmpty(
	t testing.TB,
	expectedName string,
	result interface{},
	description string,
) {
	name, length := resultName(t, result)
	if name != expectedName {
		t.Fatalf("%s: expected %s, got %s", description, expectedName, name)
	}
	if length != 0 {
		t.Fatalf("%s: expected empty %s, got %d", description, name, length)
	}
}

func assertResultEqual(
	t testing.TB,
	expectedName string,
	expectedValue json.RawMessage,
	result interface{},
	description string,
	context conformanceContext,
) {
	name, _ := resultName(t, result)
	if name != expectedName {
		t.Fatalf("%s: expected %s, got %s", description, expectedName, name)
	}

	switch result := result.(type) {
	case []CreateAccountResult:
		assertCreateAccountResults(t, expectedValue, result, description)
	case []CreateTransferResult:
		assertCreateTransferResults(t, expectedValue, result, description)
	default:
		assertRecords(t, expectedValue, result, description, context)
	}
}

func assertCreateAccountResults(
	t testing.TB,
	expectedJSON json.RawMessage,
	actual []CreateAccountResult,
	description string,
) {
	var expected []struct {
		Status string `json:"status"`
	}
	decodeJSON(t, expectedJSON, &expected)

	if len(expected) != len(actual) {
		t.Fatalf(
			"%s: expected %d create account results, got %d",
			description,
			len(expected),
			len(actual),
		)
	}

	for i := range expected {
		status := createAccountStatus(t, expected[i].Status)
		if status != actual[i].Status {
			t.Fatalf(
				"%s: expected create account result %d status %s, got %s",
				description,
				i,
				status,
				actual[i].Status,
			)
		}
	}
}

func assertCreateTransferResults(
	t testing.TB,
	expectedJSON json.RawMessage,
	actual []CreateTransferResult,
	description string,
) {
	var expected []struct {
		Status string `json:"status"`
	}
	decodeJSON(t, expectedJSON, &expected)

	if len(expected) != len(actual) {
		t.Fatalf(
			"%s: expected %d create transfer results, got %d",
			description,
			len(expected),
			len(actual),
		)
	}

	for i := range expected {
		status := createTransferStatus(t, expected[i].Status)
		if status != actual[i].Status {
			t.Fatalf(
				"%s: expected create transfer result %d status %s, got %s",
				description,
				i,
				status,
				actual[i].Status,
			)
		}
	}
}

func assertRecords(
	t testing.TB,
	expectedJSON json.RawMessage,
	actual interface{},
	description string,
	context conformanceContext,
) {
	var expected []map[string]json.RawMessage
	decodeJSON(t, expectedJSON, &expected)

	records := reflect.ValueOf(actual)
	if len(expected) != records.Len() {
		t.Fatalf("%s: expected %d records, got %d", description, len(expected), records.Len())
	}

	for i := range expected {
		assertRecord(t, expected[i], records.Index(i), description, i, context)
	}
}

func assertRecord(
	t testing.TB,
	expected map[string]json.RawMessage,
	actual reflect.Value,
	description string,
	index int,
	context conformanceContext,
) {
	for field, value := range expected {
		actualField := recordField(actual, field)
		if !actualField.IsValid() {
			t.Fatalf("%s: unknown field: %s", description, field)
		}

		var expectedValue interface{}
		if bytes.HasPrefix(bytes.TrimSpace(value), []byte("{")) {
			expectedValue = buildValue(t, value, context)
		} else if actualField.Type() == reflect.TypeOf(Uint128{}) {
			var number uint64
			decodeJSON(t, value, &number)
			expectedValue = ToUint128(number)
		} else {
			pointer := reflect.New(actualField.Type())
			decodeJSON(t, value, pointer.Interface())
			expectedValue = pointer.Elem().Interface()
		}

		if !reflect.DeepEqual(expectedValue, actualField.Interface()) {
			t.Fatalf(
				"%s: expected record %d %s %v, got %v",
				description,
				index,
				field,
				expectedValue,
				actualField.Interface(),
			)
		}
	}
}

// Matches a fixture field name to a struct field, ignoring case and underscores,
// e.g. user_data_128 to UserData128.
func recordField(record reflect.Value, name string) reflect.Value {
	normalized := strings.ReplaceAll(name, "_", "")
	for i := 0; i < record.NumField(); i++ {
		if strings.EqualFold(record.Type().Field(i).Name, normalized) {
			return record.Field(i)
		}
	}
	return reflect.Value{}
}

func createAccountStatus(t testing.TB, status string) CreateAccountStatus {
	switch status {
	case "created":
		return AccountCreated
	case "exists":
		return AccountExists
	default:
		t.Fatalf("unknown create account status: %s", status)
		return 0
	}
}

func createTransferStatus(t testing.TB, status string) CreateTransferStatus {
	switch status {
	case "created":
		return TransferCreated
	case "exists":
		return TransferExists
	default:
		t.Fatalf("unknown create transfer status: %s", status)
		return 0
	}
}
