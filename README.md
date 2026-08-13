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
cd scenario4-json-ref && camel run route.yaml definitions.json schema-without-id.json schema-with-id.json schema-without-id-bare-ref.json

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
| S4a | JSON `$ref: "./definitions.json"` without `$id` | **PASS** | JSON multi-file: **conditional GO** |
| S4b | JSON `$ref: "./definitions.json"` without `$id`, invalid doc | **PASS** | Negative test confirms validation works |
| S4c | JSON `$ref: "definitions.json"` (bare, no `./`) without `$id` | **PASS** | Both `$ref` formats work |
| S4d | JSON `$ref: "./definitions.json"` with `$id` | **FAIL** | JSON with `$id`: **NO-GO** — needs workaround |
| S5 | Camel JBang classpath for project files | **PASS** | Classpath: **GO** |
| S6a | XML `validator` body pass-through | **PASS** | No save/restore needed: **GO** |
| S6b | JSON `json-validator` body pass-through | **PASS** | No save/restore needed: **GO** |

### URI format note

All tests use bare filename URIs (e.g. `validator:main.xsd`, `json-validator:schema.json`) without
any `classpath:` or `file:` prefix. This matches how the DataMapper already references resources at
runtime — the existing `xslt-saxon` step uses `xslt-saxon:kaoto-datamapper-xxxxxxxx.xsl` (bare filename,
classpath-resolved). The new validator step will follow the same pattern: `validator:ShipOrder.xsd`
where the filename comes from `IDocumentMetadata.filePath`.

---

## Scenario details

### Scenario 1: `xs:include` — same namespace, separate file

**Question:** Does `validator:main.xsd` resolve `xs:include schemaLocation="types.xsd"` when both
files are on the classpath?

**Setup:**
- `main.xsd` — defines `Order` element, includes `types.xsd` for `AddressType`
- `types.xsd` — defines `AddressType` (street, city, zip)
- Both in the same target namespace `http://example.com/order`, both with `elementFormDefault="qualified"`

**Route (`route.yaml`):**
Two routes run sequentially (3s delay on the second):

1. Route `test-xs-include-valid`: Sets body to a valid `<Order>` XML (inline via `constant`),
   sends to `validator:main.xsd`. If validation passes, logs `PASSED`.
2. Route `test-xs-include-invalid`: Sets body to an `<Order>` missing required `city` and `zip`
   elements inside `<shipTo>`. Uses `doTry/doCatch` to verify `org.apache.camel.ValidationException`
   is thrown. Logs `EXPECTED` on catch, `UNEXPECTED` if validation passes.

**Result: PASS**
```
PASSED xs:include validation with valid document
EXPECTED: validation correctly rejected invalid document
```

The JAXP `LSResourceResolver` used by Camel's `validator` component successfully resolves
`xs:include` references from the classpath. Both positive (valid doc accepted) and negative
(invalid doc rejected with correct error) cases work correctly.

---

### Scenario 2: `xs:import` — cross-namespace reference

**Question:** Does `validator:invoice.xsd` resolve `xs:import namespace="..." schemaLocation="common-types.xsd"`
when both files are on the classpath but have different target namespaces?

**Setup:**
- `invoice.xsd` — namespace `http://example.com/invoice`, imports `common-types.xsd`
- `common-types.xsd` — namespace `http://example.com/common`, defines `MoneyType` (amount, currency)

**Route (`route.yaml`):**
Two routes run sequentially (3s delay on the second):

1. Route `test-xs-import-valid`: Sets body to a valid `<Invoice>` XML with `<common:amount>` and
   `<common:currency>` elements (inline via `constant`). Validates against `invoice.xsd`.
2. Route `test-xs-import-invalid`: Sets body to an `<Invoice>` with `<common:amount>not-a-number</common:amount>`
   (violates `xs:decimal` type from imported `MoneyType`) and missing `<common:currency>`.
   Uses `doTry/doCatch` expecting `ValidationException`.

**Result: PASS**
```
PASSED xs:import validation - common-types.xsd resolved from classpath
EXPECTED: validation correctly rejected invalid invoice (imported type constraint violated)
```

Cross-namespace `xs:import` with `schemaLocation` is resolved correctly from classpath.
Both positive (valid doc accepted) and negative (invalid doc — imported type constraint
violated) cases work correctly.

---

### Scenario 3: Subdirectory relative path

**Question:** Does `validator:main.xsd` resolve `xs:include schemaLocation="types/PersonType.xsd"`
when the included file is in a subdirectory?

**Setup:**
- `main.xsd` — includes `types/PersonType.xsd`
- `types/PersonType.xsd` — defines `PersonType` (firstName, lastName, email)

**Route (`route.yaml`):**
- Route `test-subdirectory`: Sets body to a valid `<Person>` XML (inline via `constant`),
  validates against `main.xsd`.

**Result: PASS**
```
PASSED subdirectory validation - types/PersonType.xsd resolved via relative path
```

Relative paths in `schemaLocation` are resolved correctly, including subdirectories.

---

### Scenario 4: JSON Schema `$ref` resolution

**Question:** Does `json-validator:schema.json` resolve `"$ref": "./definitions.json"` from the
classpath? Does the `$ref` format matter (`./file` vs bare `file`)? Does the presence of `$id`
in the schema affect resolution?

**Setup:**
- `definitions.json` — standalone schema defining an address object (street, city, zip — all required)
- `schema-without-id.json` — references `"$ref": "./definitions.json"`, no `$id` property
- `schema-without-id-bare-ref.json` — references `"$ref": "definitions.json"` (no `./` prefix), no `$id`
- `schema-with-id.json` — references `"$ref": "./definitions.json"`, with `"$id": "http://example.com/order-schema"`

**Important:** JSON schema files must be explicitly passed as arguments to `camel run`:
```bash
camel run route.yaml definitions.json schema-without-id.json schema-with-id.json schema-without-id-bare-ref.json
```
Unlike the XML `validator` component which resolves schema references automatically via JAXP's
`LSResourceResolver`, the `json-validator` uses NetworkNT's `SchemaRegistry` which only sees
files explicitly loaded onto the classpath.

**Route (`route.yaml`):**
Four routes run sequentially (3s intervals):

1. Route `test-json-ref-dotslash-valid`: Validates a valid JSON order against `schema-without-id.json`
   (which uses `$ref: "./definitions.json"`). Body set inline via `constant`.
2. Route `test-json-ref-dotslash-invalid`: Validates an invalid JSON (missing required `city`, `zip`)
   against the same schema. Uses `doTry/doCatch` expecting `ValidationException`.
3. Route `test-json-ref-bare-valid`: Validates a valid JSON against `schema-without-id-bare-ref.json`
   (which uses `$ref: "definitions.json"` without `./` prefix). Uses `doTry/doCatch` defensively —
   logs `PASSED` on success, `FAILED` if an exception is caught. Tests whether the `$ref` format matters.
4. Route `test-json-ref-with-id`: Validates a valid JSON against `schema-with-id.json`. Uses
   `doTry/doCatch` catching `SchemaException`, `JsonValidationException`, and generic `Exception`
   separately to identify the exact failure mode.

**Result: PARTIAL PASS**
```
PASSED json-validator ./ref WITHOUT $id - $ref resolved
EXPECTED: validation correctly rejected invalid JSON
PASSED json-validator bare ref WITHOUT $id - $ref resolved
FAILED json-validator WITH $id - SchemaException (NetworkNT resolved $ref relative to $id URL):
  java.io.FileNotFoundException: http://example.com/definitions.json
```

| Sub-test | `$ref` format | `$id` | Result |
|----------|---------------|-------|--------|
| 4a | `./definitions.json` | absent | **PASS** |
| 4b | `./definitions.json` (invalid doc) | absent | **PASS** (correctly rejected) |
| 4c | `definitions.json` (bare) | absent | **PASS** |
| 4d | `./definitions.json` | `http://example.com/order-schema` | **FAIL** |

**Root cause of 4d failure:** NetworkNT's JSON Schema library resolves `$ref` relative to the
schema's `$id` base URI. When `$id` is `http://example.com/order-schema`, the `$ref`
`./definitions.json` resolves to `http://example.com/definitions.json` — an HTTP URL that
cannot be found. The exception type is `com.networknt.schema.SchemaException`, wrapping
`java.io.FileNotFoundException`.

---

### Scenario 5: Camel JBang classpath behavior

**Question:** Does Camel JBang automatically place project files (`.xsd`, `.json`) on the
classpath so that `validator:simple.xsd` works without explicit configuration?

**Setup:**
- `simple.xsd` — a trivial schema defining a `Ping` element
- `route.yaml` — references `validator:simple.xsd` directly

**Route (`route.yaml`):**
- Route `test-classpath`: Sets body to an inline `<Ping>` XML (via `constant`), validates
  against `simple.xsd`.

**Result: PASS**
```
PASSED classpath test - Camel JBang puts project files on classpath
```

Camel JBang automatically makes `.xsd` and route files available for classpath resolution
when they are in the same directory as the route. The `validator:` component URI resolves
them without any `classpath:` prefix or additional configuration.

**Note:** This automatic classpath behavior applies to the `validator:` and `json-validator:`
component URIs (which resolve schemas internally). It does NOT apply to `resource:classpath:`
in `setBody` expressions — those require files to be explicitly passed as `camel run` arguments
or configured via `camel.jbang.classpathFiles`.

---

### Scenario 6: Body pass-through verification

**Question:** Do `validator` and `json-validator` pass the message body through unchanged after
validation, or do they modify/consume it?

**Setup:**
- `simple.xsd` — XML schema for an `Item` element (name, price)
- `simple-schema.json` — JSON schema for an item object (name, price)

**Route (`route.yaml`):**
Two routes run sequentially (3s delay):

1. Route `test-xml-passthrough`: Sets body to an inline `<Item>` XML (via `constant`).
   Captures body into `bodyBefore` header, validates with `validator:simple.xsd`, captures
   body into `bodyAfter` header, then uses `choice` to compare them.
   Logs `PASSED` if equal, `FAILED` with lengths if different.
2. Route `test-json-passthrough`: Same pattern with inline JSON body and
   `json-validator:simple-schema.json`.

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
- No body save/restore needed. The validation step can be appended directly after `xslt-saxon`
  without any wrapper logic.

### S8 (Multi-file XML schema support)
- **NO-OP.** JAXP's `LSResourceResolver` handles `xs:include`, `xs:import`, and relative
  subdirectory paths out of the box. No schema flattening is needed.

### S9 (Additional schema file accessibility)
- Schema files in the project directory are available on the classpath in Camel JBang.
  For `json-validator`, referenced files (`$ref` targets) must be explicitly passed to
  `camel run` as additional arguments, or configured via `camel.jbang.classpathFiles`.
  The `validator` (XML) resolves includes/imports automatically via JAXP without this
  requirement.

### S10 (Multi-file JSON schema support)
- **Conditional.** Works out of the box if schemas don't have `$id`. If they do, a workaround
  is needed. See fallback assessment below.

---

## Fallback assessment: JSON `$id` workaround

Since JSON `$ref` resolution fails when `$id` is present (scenario 4d), and the issue requires
an effort assessment for this case, here are two approaches:

### Approach A: Strip `$id` before validation

Remove `$id` from the schema before passing it to `json-validator`. Kaoto's internal DataMapper
processing would still use the original schemas with `$id` intact — the stripping only applies
to the copy used for runtime validation.

**Simple case (root `$id` only):** ~2-4 hours. A single utility function that clones the schema
and deletes `$id`.

**Full case (nested `$id` + rewrite `$ref` targets):** ~1-2 days. JSON Schema allows `$id` on
any sub-schema (changing the base URI for `$ref` within that scope). If schemas reference each
other by `$id` value (e.g. `"$ref": "http://example.com/address-schema"`), those references
would also need rewriting to file paths.

**Risk:** Medium. Fragile for schemas that use `$id` as a `$ref` target or have nested `$id`.
Works cleanly only when `$id` is a root-level metadata property and all `$ref` values use
relative file paths.

### Approach B: Bundle `$ref` into a single schema

Resolve all cross-file `$ref` values and inline/relocate referenced definitions into a single
self-contained schema.

**Existing infrastructure that helps (~60-70% coverage):**
- `JsonSchemaAnalysisService` (615 lines) — already extracts `$ref` recursively, builds
  dependency graphs, detects circular dependencies, does topological load ordering
- `JsonSchemaDocumentUtilService` — resolves JSON pointers to actual definitions
- `JsonSchemaCollection` — multi-tier reference resolution (by `$id`, file path, relative path)

**What's missing:** The output/transformation side — copying external definitions into a
`$defs` section with namespaced keys to avoid collisions, and rewriting `$ref` pointers.

**Effort estimate:** 3-5 days for a custom `JsonSchemaBundleService` (~200-300 lines) plus tests.

**Alternative:** Add `@apidevtools/json-schema-ref-parser` library (~50KB) which has a `.bundle()`
method. Would reduce custom code to ~50 lines, but needs adaptation since schemas are in-memory
`Record<string, string>`, not filesystem files.

**Risk:** Low-Medium. Bundling is well-understood. Main complexity: circular refs, nested `$id`,
relative path rewriting, definition name collisions across schemas.

### Recommendation

Start with **Approach A (simple strip)** — it covers the common case where `$id` is root-level
metadata and `$ref` uses relative file paths. If edge cases emerge where `$id` is used as a
reference target, Approach B can be built incrementally on top of the existing
`JsonSchemaAnalysisService` infrastructure.
