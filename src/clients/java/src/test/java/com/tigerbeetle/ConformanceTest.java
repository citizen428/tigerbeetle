package com.tigerbeetle;

import java.math.BigInteger;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import javax.xml.parsers.DocumentBuilderFactory;

import org.junit.AfterClass;
import org.junit.BeforeClass;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.junit.runners.Parameterized;
import org.w3c.dom.Element;
import org.w3c.dom.Node;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

@RunWith(Parameterized.class)
public class ConformanceTest {
    private static final byte[] clusterId = new byte[16];

    private static IntegrationTest.Server server;
    private static Client client;

    @BeforeClass
    public static void initialize() throws Exception {
        server = new IntegrationTest.Server("conformance");
        client = new Client(clusterId, new String[] {server.getAddress()});
    }

    @AfterClass
    public static void cleanup() throws Exception {
        client.close();
        server.close();
    }

    @Parameterized.Parameters(name = "{0}")
    public static List<Object[]> cases() throws Exception {
        final var fixture = DocumentBuilderFactory.newInstance().newDocumentBuilder()
                .parse(ConformanceTest.class.getResourceAsStream("/conformance.xml"));

        final var cases = new ArrayList<Object[]>();
        for (final var suite : children(fixture.getDocumentElement())) {
            final var suiteName = child(suite, "suite").getTextContent();
            for (final var testCase : children(child(suite, "cases"))) {
                final var description = child(testCase, "description").getTextContent();
                cases.add(new Object[] {suiteName + ": " + description, testCase});
            }
        }
        return cases;
    }

    private final Element testCase;
    private final Map<Long, byte[]> ids = new HashMap<>();
    private final Map<String, Object> vars = new HashMap<>();

    public ConformanceTest(final String description, final Element testCase) {
        this.testCase = testCase;
    }

    @Test
    public void test() throws Exception {
        final var arrange = childOptional(testCase, "arrange");
        if (arrange != null) {
            for (final var item : children(arrange)) {
                executeArrange(onlyChild(item));
            }
        }

        final var assertions = new ArrayList<Element>();
        for (final var item : children(child(testCase, "assert"))) {
            assertions.add(onlyChild(item));
        }

        if (expectsFail(assertions)) {
            try {
                executeAct();
            } catch (Exception exception) {
                return;
            }
            fail("expected failure");
        } else {
            assertResults(assertions, executeAct());
        }
    }

    private void executeArrange(final Element step) throws Exception {
        switch (step.getTagName()) {
            case "assign":
                vars.put(child(step, "name").getTextContent(), buildValue(child(step, "value")));
                break;
            case "operation":
                executeOperation(step);
                break;
            default:
                fail("unknown arrange step: <" + step.getTagName() + ">");
        }
    }

    private List<Object> executeAct() throws Exception {
        final var results = new ArrayList<Object>();
        for (final var item : children(child(testCase, "act"))) {
            final var step = onlyChild(item);
            if (!step.getTagName().equals("operation")) {
                fail("act step is not an operation: <" + step.getTagName() + ">");
            }
            results.add(executeOperation(step));
        }
        return results;
    }

    private Object executeOperation(final Element operation) throws Exception {
        final var name = child(operation, "name").getTextContent();
        final var inputs = new ArrayList<Object>();
        for (final var item : children(child(operation, "inputs"))) {
            inputs.add(resolveInput(item));
        }

        switch (name) {
            case "create_accounts": {
                final var accounts = new AccountBatch(inputs.size());
                for (final var input : inputs) {
                    addAccount(accounts, accountValue(input));
                }
                return client.createAccounts(accounts);
            }
            case "lookup_accounts": {
                final var lookupIds = new IdBatch(inputs.size());
                for (final var input : inputs) {
                    lookupIds.add(uint128Value(input));
                }
                return client.lookupAccounts(lookupIds);
            }
            default:
                fail("unknown operation: " + name);
                return null;
        }
    }

    private Object resolveInput(final Element input) {
        final var from = childOptional(input, "from");
        if (from != null) {
            final var variable = vars.get(from.getTextContent());
            if (variable == null) {
                fail("unknown variable: " + from.getTextContent());
            }
            return variable;
        }

        final var value = childOptional(input, "value");
        if (value != null) {
            return buildValue(value);
        }

        fail("unknown input: <" + input.getTagName() + ">");
        return null;
    }

    private Object buildValue(final Element value) {
        final var element = onlyChild(value);
        switch (element.getTagName()) {
            case "account":
                return element;
            case "id":
                return logicalId(Long.parseLong(element.getTextContent()));
            case "u128":
                return UInt128.asBytes(new BigInteger(element.getTextContent()));
            default:
                fail("unknown value: <" + element.getTagName() + ">");
                return null;
        }
    }

    private void addAccount(final AccountBatch accounts, final Element account) {
        accounts.add();
        accounts.setId(uint128Value(buildValue(child(account, "id"))));

        final var ledger = childOptional(account, "ledger");
        if (ledger != null) {
            accounts.setLedger(Integer.parseInt(ledger.getTextContent()));
        }

        final var code = childOptional(account, "code");
        if (code != null) {
            accounts.setCode(Integer.parseInt(code.getTextContent()));
        }
    }

    private byte[] logicalId(final long value) {
        return ids.computeIfAbsent(value, unused -> UInt128.id());
    }

    private static Element accountValue(final Object value) {
        if (!(value instanceof Element)) {
            fail("expected an account: " + value);
        }
        return (Element) value;
    }

    private static byte[] uint128Value(final Object value) {
        if (!(value instanceof byte[])) {
            fail("expected a 128-bit value: " + value);
        }
        return (byte[]) value;
    }

    private static boolean expectsFail(final List<Element> assertions) {
        for (final var assertion : assertions) {
            if (assertion.getTagName().equals("assert_fail")) {
                return true;
            }
        }
        return false;
    }

    private void assertResults(final List<Element> assertions, final List<Object> results)
            throws Exception {
        assertEquals("result steps", assertions.size(), results.size());
        for (int i = 0; i < assertions.size(); i++) {
            assertResult(assertions.get(i), results.get(i));
        }
    }

    private void assertResult(final Element assertion, final Object result) throws Exception {
        switch (assertion.getTagName()) {
            case "assert_empty":
                assertEquals(assertion.getTextContent(), resultName(result));
                assertEquals(0, ((Batch) result).getLength());
                break;
            case "assert_equal": {
                assertEquals(child(assertion, "actual").getTextContent(), resultName(result));
                final var expected = children(child(assertion, "expected"));
                if (result instanceof CreateAccountResultBatch) {
                    assertCreateAccountResults(expected, (CreateAccountResultBatch) result);
                } else {
                    assertAccounts(expected, (AccountBatch) result);
                }
                break;
            }
            default:
                fail("unknown assertion: <" + assertion.getTagName() + ">");
        }
    }

    private static String resultName(final Object result) {
        if (result instanceof CreateAccountResultBatch) {
            return "create_account_results";
        }
        if (result instanceof AccountBatch) {
            return "accounts";
        }

        fail("unknown result type: " + result);
        return null;
    }

    private void assertCreateAccountResults(final List<Element> expected,
            final CreateAccountResultBatch actual) {
        assertEquals("create account results", expected.size(), actual.getLength());
        for (final var item : expected) {
            assertTrue(actual.next());
            assertEquals(createAccountStatus(child(item, "status").getTextContent()),
                    actual.getStatus());
        }
    }

    private void assertAccounts(final List<Element> expected, final AccountBatch actual)
            throws Exception {
        assertEquals("accounts", expected.size(), actual.getLength());
        for (final var item : expected) {
            assertTrue(actual.next());
            for (final var field : children(item)) {
                final var actualValue =
                        AccountBatch.class.getMethod(getterName(field.getTagName())).invoke(actual);
                if (children(field).isEmpty()) {
                    assertEquals(field.getTagName(), Long.parseLong(field.getTextContent()),
                            ((Number) actualValue).longValue());
                } else {
                    assertArrayEquals(uint128Value(buildValue(field)), (byte[]) actualValue);
                }
            }
        }
    }

    // The fixture's snake_case field maps to a getter, e.g. user_data_128 to getUserData128().
    private static String getterName(final String field) {
        final var name = new StringBuilder("get");
        for (final var part : field.split("_")) {
            name.append(Character.toUpperCase(part.charAt(0))).append(part.substring(1));
        }
        return name.toString();
    }

    private static CreateAccountStatus createAccountStatus(final String status) {
        switch (status) {
            case "created":
                return CreateAccountStatus.Created;
            case "exists":
                return CreateAccountStatus.Exists;
            default:
                fail("unknown create account status: " + status);
                return null;
        }
    }

    private static List<Element> children(final Element parent) {
        final var elements = new ArrayList<Element>();
        final var nodes = parent.getChildNodes();
        for (int i = 0; i < nodes.getLength(); i++) {
            if (nodes.item(i).getNodeType() == Node.ELEMENT_NODE) {
                elements.add((Element) nodes.item(i));
            }
        }
        return elements;
    }

    private static Element child(final Element parent, final String tag) {
        final var element = childOptional(parent, tag);
        if (element == null) {
            fail("missing <" + tag + "> in <" + parent.getTagName() + ">");
        }
        return element;
    }

    private static Element childOptional(final Element parent, final String tag) {
        for (final var element : children(parent)) {
            if (element.getTagName().equals(tag)) {
                return element;
            }
        }
        return null;
    }

    // Steps, values, and assertions are encoded as an element with exactly one child.
    private static Element onlyChild(final Element parent) {
        final var elements = children(parent);
        if (elements.size() != 1) {
            fail("expected exactly one child in <" + parent.getTagName() + ">");
        }
        return elements.get(0);
    }
}
