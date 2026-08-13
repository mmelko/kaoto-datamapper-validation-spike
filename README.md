# S1i Spike: Camel validator behavior with multi-file schemas

Investigation spike for [KaotoIO/kaoto#3603](https://github.com/KaotoIO/kaoto/issues/3603),
part of [KaotoIO/kaoto#2433 — DataMapper: Support output validation](https://github.com/KaotoIO/kaoto/issues/2433).

**Camel version:** 4.18.3 (Camel JBang)
**Java version:** OpenJDK 21.0.2
**Platform:** macOS (aarch64)

---

## Purpose

Verify that the Camel `validator` (XML Schema) and `json-validator` (JSON Schema) components
can resolve multi-file schemas when all files are placed on the classpath. The results determine
whether S8 (multi-file XML), S10 (multi-file JSON), and body save/restore logic in S4 are needed.

## How to run

Each scenario is a self-contained directory with a `route.yaml` and test schemas.

```bash
# Run individual scenario
cd scenario1-xs-include && camel run route.yaml

# Scenario 4 (JSON $ref) requires explicit classpath files
cd scenario4-json-ref && camel run route.yaml definitions.json schema-without-id.json schema-with-id.json

# Run all (stops each after ~15s)
./run-all.sh

# Run single scenario by number
./run-all.sh 1
```

Look for `PASSED`, `EXPECTED`, `UNEXPECTED`, or `FAILED` in the log output.

---

## Results summary

| # | Scenario | Result | GO/NO-GO decision |
|---|----------|--------|--------------------|
| S1 | `xs:include` resolution | **PASS** | XML multi-file: **GO** |
| S2 | `xs:import` resolution (cross-namespace) | **PASS** | XML multi-file: **GO** |
| S3 | Subdirectory relative path resolution | **PASS** | XML multi-file: **GO** |
| S4a | JSON `$ref` without `$id` | **PASS** | JSON multi-file: **conditional GO** |
| S4b | JSON `$ref` with `$id` | **FAIL** | JSON with `$id`: **NO-GO** — needs workaround |
| S5 | Camel JBang classpath for project files | **PASS** | Classpath: **GO** |
| S6a | XML `validator` body pass-through | **PASS** | No save/restore needed: **GO** |
| S6b | JSON `json-validator` body pass-through | **PASS** | No save/restore needed: **GO** |

---

## Scenario details

### Scenario 1: `xs:include` — same namespace, separate file

**Question:** Does `validator:main.xsd` resolve `xs:include schemaLocation="types.xsd"` when both
files are on the classpath?

**Setup:**
- `main.xsd` — defines `Order` element, includes `types.xsd` for `AddressType`
- `types.xsd` — defines `AddressType` (street, city, zip)
- Both in the same target namespace `http://example.com/order`

**Route (`route.yaml`):**
- Route `test-xs-include-valid`: sets body to a valid `<Order>` XML, validates against `main.xsd`.
  Expected: validation passes.
- Route `test-xs-include-invalid`: sets body to an `<Order>` missing `city` and `zip` inside
  `<shipTo>`. Uses `doTry/doCatch` to verify `ValidationException` is thrown.
  Expected: validation fails with `SchemaValidationException`.

**Result: PASS**
```
PASSED xs:include validation with valid document
EXPECTED: validation correctly rejected invalid document
```

The JAXP `LSResourceResolver` used by Camel's `validator` component successfully resolves
`xs:include` references from the classpath. Both positive (valid doc) and negative (invalid doc)
cases work correctly.

---

### Scenario 2: `xs:import` — cross-namespace reference

**Question:** Does `validator:invoice.xsd` resolve `xs:import namespace="..." schemaLocation="common-types.xsd"`
when both files are on the classpath but have different target namespaces?

**Setup:**
- `invoice.xsd` — namespace `http://example.com/invoice`, imports `common-types.xsd`
- `common-types.xsd` — namespace `http://example.com/common`, defines `MoneyType` (amount, currency)

**Route (`route.yaml`):**
- Route `test-xs-import-valid`: sets body to a valid `<Invoice>` XML with `<common:amount>` and
  `<common:currency>` elements. Validates against `invoice.xsd`.

**Result: PASS**
```
PASSED xs:import validation - common-types.xsd resolved from classpath
```

Cross-namespace `xs:import` with `schemaLocation` is resolved correctly from classpath.

---

### Scenario 3: Subdirectory relative path

**Question:** Does `validator:main.xsd` resolve `xs:include schemaLocation="types/PersonType.xsd"`
when the included file is in a subdirectory?

**Setup:**
- `main.xsd` — includes `types/PersonType.xsd`
- `types/PersonType.xsd` — defines `PersonType` (firstName, lastName, email)

**Route (`route.yaml`):**
- Route `test-subdirectory`: sets body to a valid `<Person>` XML, validates against `main.xsd`.

**Result: PASS**
```
PASSED subdirectory validation - types/PersonType.xsd resolved via relative path
```

Relative paths in `schemaLocation` are resolved correctly, including subdirectories.

---

### Scenario 4: JSON Schema `$ref` resolution

**Question:** Does `json-validator:schema.json` resolve `"$ref": "definitions.json"` from the
classpath? Does the presence of `$id` in the schema affect resolution?

**Setup:**
- `definitions.json` — standalone schema defining an address object (street, city, zip required)
- `schema-without-id.json` — references `definitions.json` via `$ref`, no `$id` property
- `schema-with-id.json` — same as above but with `"$id": "http://example.com/order-schema"`

**Important:** JSON schema files must be explicitly passed as arguments to `camel run`:
```bash
camel run route.yaml definitions.json schema-without-id.json schema-with-id.json
```
Unlike the XML `validator` component which resolves schema references automatically via JAXP's
`LSResourceResolver`, the `json-validator` uses NetworkNT's `SchemaRegistry` which only sees
files explicitly loaded onto the classpath.

**Route (`route.yaml`):**
- Route `test-json-ref-without-id-valid`: validates a valid JSON order against `schema-without-id.json`.
- Route `test-json-ref-without-id-invalid`: validates an invalid JSON (missing city, zip) — expects failure.
- Route `test-json-ref-with-id`: validates a valid JSON against `schema-with-id.json` — tests whether
  `$id` breaks `$ref` resolution.

**Result: PARTIAL PASS**
```
PASSED json-validator WITHOUT $id - $ref resolved
EXPECTED: validation correctly rejected invalid JSON
FAILED json-validator WITH $id: java.io.FileNotFoundException: http://example.com/definitions.json
```

- **Without `$id`: PASS** — `$ref: "definitions.json"` resolves correctly from classpath.
- **With `$id`: FAIL** — NetworkNT resolves `$ref` relative to the `$id` URL base, producing
  `http://example.com/definitions.json` instead of a classpath lookup. This causes a
  `FileNotFoundException`.

**Implication for S10:** If target JSON schemas use `$id`, Kaoto will need to either:
1. Strip `$id` before passing the schema to `json-validator`, or
2. Bundle/inline all `$ref` references into a single schema file.

If schemas don't use `$id` (common for simpler schemas), multi-file JSON validation works
out of the box.

---

### Scenario 5: Camel JBang classpath behavior

**Question:** Does Camel JBang automatically place project files (`.xsd`, `.json`) on the
classpath so that `validator:simple.xsd` works without explicit configuration?

**Setup:**
- `simple.xsd` — a trivial schema defining a `Ping` element
- `route.yaml` — references `validator:simple.xsd` directly

**Route (`route.yaml`):**
- Route `test-classpath`: sets body to an inline `<Ping>` XML, validates against `simple.xsd`.

**Result: PASS**
```
PASSED classpath test - Camel JBang puts project files on classpath
```

Camel JBang automatically makes `.xsd` and route files available for classpath resolution
when they are in the same directory as the route. The `validator:` component URI resolves
them without any `classpath:` prefix or additional configuration.

**Note:** This automatic classpath behavior applies to the `validator:` and `json-validator:`
component URIs (which resolve schemas internally). It does NOT apply to `resource:classpath:`
in `setBody` expressions — those require files to be explicitly passed as `camel run` arguments.

---

### Scenario 6: Body pass-through verification

**Question:** Do `validator` and `json-validator` pass the message body through unchanged after
validation, or do they modify/consume it?

**Setup:**
- `simple.xsd` — XML schema for an `Item` element
- `simple-schema.json` — JSON schema for an item object

**Route (`route.yaml`):**
- Route `test-xml-passthrough`: captures body into `bodyBefore` header, validates with
  `validator:simple.xsd`, captures body into `bodyAfter` header, compares them.
- Route `test-json-passthrough`: same pattern with `json-validator:simple-schema.json`.

**Result: PASS**
```
PASSED XML pass-through: body is UNCHANGED after validation
PASSED JSON pass-through: body is UNCHANGED after validation
```

Both components are pure validators — they read the body for validation but do not modify it.
The message body after the validation step is identical to the body before it.

**Implication for S4:** No save/restore pattern is needed around the validation step in the
DataMapper step group. The body flows through unchanged.

---

## Decisions for downstream issues

### S4 (Step management service)
- No body save/restore needed. The validation step can be appended after `xslt-saxon` without
  any wrapper logic.

### S8 (Multi-file XML schema support)
- **NO-OP.** JAXP's `LSResourceResolver` handles `xs:include`, `xs:import`, and relative
  subdirectory paths out of the box. No schema flattening is needed.

### S10 (Multi-file JSON schema support)
- **Conditional.** Works if schemas don't have `$id`. If they do, either strip `$id` or
  bundle `$ref` references. The `$id` restriction is a NetworkNT (json-schema-validator)
  library behavior, not a Camel limitation.

### S9 (Additional schema file accessibility)
- Schema files in the project directory are available on the classpath in Camel JBang.
  For `json-validator`, referenced files (`$ref` targets) must be explicitly passed to
  `camel run` as additional arguments, or configured via `camel.jbang.classpathFiles`.
  The `validator` (XML) resolves includes/imports automatically via JAXP without this
  requirement.
