# S1i Spike: Camel validator behavior with multi-file schemas

Investigation spike for [KaotoIO/kaoto#3603](https://github.com/KaotoIO/kaoto/issues/3603),
part of [KaotoIO/kaoto#2433 — DataMapper: Support output validation](https://github.com/KaotoIO/kaoto/issues/2433).

**Camel versions:** 4.18.2 LTS, 4.22.0 LTS (Camel JBang)
**Java version:** OpenJDK 21.0.2
**Platform:** macOS (aarch64)

All XML-based scenarios (S1-S3, S5-S6) produce identical results on both LTS versions.
JSON scenario S4 results differ in failure timing only — see [version matrix](#s1i-version-matrix) below.

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

---

## S1i version matrix

All scenarios tested on Camel **4.18.2 LTS** and **4.22.0 LTS**.

| Scenario | 4.18.2 LTS | 4.22.0 LTS | Notes |
|----------|------------|------------|-------|
| S1 `xs:include` | **PASS** | **PASS** | Identical behavior |
| S2 `xs:import` | **PASS** | **PASS** | Identical behavior |
| S3 subdirectory | **PASS** | **PASS** | Identical behavior |
| S4a-c JSON `$ref` without `$id` | **PASS** (\*) | **PASS** | (\*) 4.18.2: tests pass only if route 4d is removed — see S4d note |
| S4d JSON `$ref` with `$id` | **FAIL** (route creation crash) | **FAIL** (runtime error) | Same root cause, different timing — see below |
| S5 classpath | **PASS** | **PASS** | Identical behavior |
| S6 body pass-through | **PASS** | **PASS** | Identical behavior |

**S4d version difference:** In **4.18.2**, NetworkNT eagerly validates the schema at route creation time. The `SchemaException` from the `$id`-based `$ref` resolution kills the entire Camel context — all routes fail to start, including the unrelated S4a-c routes in the same file. In **4.22.0**, schema loading is lazier or better isolated — the error occurs at runtime only when the specific route processes a message, and other routes run normally.

**Impact on S10:** If Kaoto supports Camel 4.18, a JSON schema with `$id` will crash the entire route context at startup, not just fail gracefully at validation time. This makes the `$id` workaround (strip or bundle) more important — leaving it to runtime error handling is not viable on 4.18.

**All GO/NO-GO decisions are version-independent** — the underlying behavior (JAXP for XML, NetworkNT for JSON) is identical; only error handling differs.

---
---

# S2i Spike: XML Schema `xsi:type` and substitution group validation

Investigation spike for [KaotoIO/kaoto#3604](https://github.com/KaotoIO/kaoto/issues/3604),
part of [KaotoIO/kaoto#2433 — DataMapper: Support output validation](https://github.com/KaotoIO/kaoto/issues/2433).

**Camel versions:** 4.18.2 LTS, 4.22.0 LTS (Camel JBang)
**Java version:** OpenJDK 21.0.2
**Platform:** macOS (aarch64)

All scenarios produce identical results on both LTS versions — validation is JAXP-based
(part of the JDK, not Camel-specific).

---

## Purpose

Determine whether the Camel XML Schema validator (JAXP) natively handles type overrides (via
`xsi:type`) and substitution groups, so we know whether schema regeneration or `xsi:type`
emission in the XSLT serializer is needed.

## How to run

```bash
# Run individual scenario
cd scenario7-substitution-group && camel run route.yaml
cd scenario8-xsi-type && camel run route.yaml
cd scenario9-xsi-type-separate-schema && camel run route.yaml

# Run all (stops each after ~15s)
./run-all.sh

# Run single scenario by number
./run-all.sh 7
```

Look for `PASSED`, `EXPECTED`, `UNEXPECTED`, or `FAILED` in the log output.

---

## Results summary

| # | Scenario | Result | Decision |
|---|----------|--------|----------|
| S7a | Substitution group — substitute elements accepted | **PASS** | Substitution groups: **GO — NO-OP** |
| S7b | Substitution group — head element also accepted | **PASS** | No schema regeneration needed |
| S7c | Substitution group — invalid substitute rejected | **PASS** | Negative test confirms validation works |
| S8a | `xsi:type` — derived type with extension children | **PASS** | `xsi:type`: **GO — S5 needed** |
| S8b | `xsi:type` — base type without `xsi:type` | **PASS** | Base type still works standalone |
| S8c | No `xsi:type` but extension children present | **PASS** (rejected) | Confirms `xsi:type` is required |
| S8d | `xsi:type` — incomplete derived type rejected | **PASS** (rejected) | Negative test confirms validation works |
| S9a | `xsi:type` — derived type in imported schema | **PASS** | Cross-file `xsi:type`: **conditional GO** |
| S9b | `xsi:type` — derived type on classpath only (not imported) | **FAIL** | Import chain required |
| S9c | `xsi:type` — invalid derived type in imported schema | **PASS** (rejected) | Negative test confirms validation works |

---

## Scenario details

### Scenario 7: Substitution groups

**Question:** Does the JAXP validator accept substitution group members where the head element
is declared in the schema?

**Setup:**
- `shapes.xsd` — defines `ShapeType` (base), `CircleType` (extends with `radius`),
  `RectangleType` (extends with `width`, `height`). Head element `shape` with substitution
  group members `circle` and `rectangle`. Container element `Drawing` references `tns:shape`
  with `maxOccurs="unbounded"`.

**Route (`route.yaml`):**
Three routes run sequentially (3s intervals):

1. Route `test-subst-group-valid`: Sets body to a `<Drawing>` containing `<circle>` and
   `<rectangle>` elements (substitutes for `<shape>`). Validates against `shapes.xsd`.
2. Route `test-subst-group-head-valid`: Sets body to a `<Drawing>` containing `<shape>`
   (the head element). Validates against `shapes.xsd`.
3. Route `test-subst-group-invalid`: Sets body to a `<Drawing>` with a `<circle>` missing
   the required `<radius>` element. Uses `doTry/doCatch` expecting `ValidationException`.

**Result: PASS**
```
PASSED substitution group - substitute elements accepted where head expected
PASSED substitution group - head element also accepted
EXPECTED: validation correctly rejected invalid substitute element (missing radius)
```

JAXP validates substitution group members natively. The DataMapper's existing
`applySubstitutionToField()` changes `field.name` to the substitute element name, and the
XSLT serializer outputs that name — the validator accepts it without any schema modification.

---

### Scenario 8: `xsi:type` — derived type validation (single schema)

**Question:** Does `xsi:type` make the JAXP validator use the derived type for content
validation? What happens without `xsi:type` when extension children are present?

**Setup:**
- `vehicles.xsd` — defines `VehicleType` (base: `make`, `year`), `CarType` (extends with
  `doors`, `trunkSize`), `TruckType` (extends with `payload`, `axles`). Container element
  `Fleet` with `vehicle` elements typed as `VehicleType`.

**Route (`route.yaml`):**
Four routes run sequentially (3s intervals):

1. Route `test-xsi-type-valid`: Sets body to a `<Fleet>` with two vehicles: a `<vehicle
   xsi:type="v:CarType">` with all Car fields and a `<vehicle xsi:type="v:TruckType">` with
   all Truck fields. Validates against `vehicles.xsd`.
2. Route `test-xsi-type-base-only`: Sets body to a `<Fleet>` with a plain `<vehicle>` (no
   `xsi:type`, only base type fields). Validates against `vehicles.xsd`.
3. Route `test-xsi-type-no-attr-with-extension-children`: Sets body to a `<Fleet>` with a
   `<vehicle>` containing CarType extension children (`doors`, `trunkSize`) but **without**
   `xsi:type`. Uses `doTry/doCatch` expecting `ValidationException`.
4. Route `test-xsi-type-invalid-extension`: Sets body with `xsi:type="v:CarType"` but missing
   required extension elements (`doors`, `trunkSize`). Uses `doTry/doCatch` expecting
   `ValidationException`.

**Result: PASS**
```
PASSED xsi:type - derived types validated correctly with extension elements
PASSED xsi:type - base type still works without xsi:type
EXPECTED: validation rejected - extension children present without xsi:type
EXPECTED: validation rejected - CarType missing required extension elements
```

`xsi:type` correctly switches the validator to the derived type. Without `xsi:type`, the
validator uses the base type and rejects extension children as unexpected. This confirms that
the XSLT serializer **must** emit `xsi:type` when a type override is active.

**Current gap:** `applyTypeOverrideToField()` rebuilds the field's children from the extension
type, but `FieldItemHandler.serialize()` in `xslt-item-handlers.ts` does NOT emit `xsi:type`
on the output element. S5 must add this.

---

### Scenario 9: `xsi:type` — derived type in a separate schema file

**Question:** When the derived type is defined in a separate `.xsd` file, does `xsi:type`
resolution require the type's schema to be imported by the root schema? Or does classpath
presence suffice?

**Setup:**
- `base-types.xsd` — namespace `http://example.com/animals`, defines `AnimalType` (base:
  `name`, `weight`)
- `dog-type.xsd` — same namespace, `xs:include`s `base-types.xsd`, defines `DogType` (extends
  with `breed`, `goodBoy`)
- `zoo-with-import.xsd` — namespace `http://example.com/zoo`, imports `dog-type.xsd` (which
  transitively includes `base-types.xsd`). Element `Zoo` with `animal` elements typed as
  `AnimalType`.
- `zoo-base-only.xsd` — same as above but imports **only** `base-types.xsd` (derived
  `DogType` is NOT in the import chain, only on classpath).

**Route (`route.yaml`):**
Three routes run sequentially (3s intervals):

1. Route `test-xsi-type-separate-with-import`: Validates a `<Zoo>` with
   `<animal xsi:type="a:DogType">` against `zoo-with-import.xsd`.
2. Route `test-xsi-type-separate-base-only`: Validates the same document against
   `zoo-base-only.xsd`. Uses `doTry/doCatch` to detect whether classpath presence suffices.
3. Route `test-xsi-type-separate-invalid`: Validates a `<Zoo>` with `xsi:type="a:DogType"`
   but missing required extension elements, against `zoo-with-import.xsd`.

**Result: PARTIAL PASS**
```
PASSED xsi:type separate schema WITH import - derived type from imported schema validated
FAILED xsi:type separate schema WITHOUT import - derived type NOT resolved from classpath alone
EXPECTED: validation rejected - DogType missing required extension elements
```

| Sub-test | Schema imports | Result |
|----------|----------------|--------|
| 9a | `dog-type.xsd` (contains DogType + includes base) | **PASS** |
| 9b | `base-types.xsd` only (DogType on classpath but not imported) | **FAIL** |
| 9c | `dog-type.xsd` + invalid doc | **PASS** (correctly rejected) |

**Root cause of 9b failure:** JAXP's `SchemaFactory` builds the schema object from the
`xs:import`/`xs:include` graph rooted at the validation schema. Types not reachable through
that graph are unknown to the validator, regardless of classpath presence. When `xsi:type`
references an unknown type, the validator throws a `ValidationException`.

---

## Decisions for downstream issues

### S5 (`xsi:type` generation in XSLT serializer) — **Required**

Without `xsi:type`, the JAXP validator rejects extension children. The XSLT serializer must
emit `xsi:type="ns:DerivedType"` on elements where `applyTypeOverrideToField()` was applied.
Currently, `FieldItemHandler.serialize()` creates the output element with the field's `name`
and `namespaceURI` but does not add `xsi:type`. The `NS_XML_SCHEMA_INSTANCE` constant already
exists in `standard-namespaces.ts`.

### Schema regeneration — **Not needed**

Neither substitution groups nor `xsi:type` require modifying the original schemas. The
schemas are valid as-is — the only requirement is that the runtime document includes the
correct `xsi:type` attributes.

### S3/S9 (schema accessibility) — **Must ensure import chain**

When a derived type is defined in a separate schema file, the root validation schema must
import (directly or transitively) the file containing the derived type definition. Classpath
presence alone is insufficient. The existing `XmlSchemaAnalysisService` already tracks
`xs:import`/`xs:include` edges and resolves schema locations — it can be used to verify that
all type-overridden types are reachable from the root schema. If they are not, either:
- A warning should be surfaced to the user, or
- The generated validation schema should include additional `xs:import` directives for schemas
  containing used derived types

---

## S2i version matrix

All scenarios tested on Camel **4.18.2 LTS** and **4.22.0 LTS**. Results are identical —
validation is JAXP-based (part of the JDK), so behavior does not depend on the Camel version.

| Scenario | 4.18.2 LTS | 4.22.0 LTS |
|----------|------------|------------|
| S7a substitution group — substitutes accepted | **PASS** | **PASS** |
| S7b substitution group — head accepted | **PASS** | **PASS** |
| S7c substitution group — invalid rejected | **PASS** | **PASS** |
| S8a `xsi:type` — derived type valid | **PASS** | **PASS** |
| S8b `xsi:type` — base type valid | **PASS** | **PASS** |
| S8c no `xsi:type` + extension children | **PASS** (rejected) | **PASS** (rejected) |
| S8d `xsi:type` — incomplete derived type | **PASS** (rejected) | **PASS** (rejected) |
| S9a `xsi:type` — imported schema | **PASS** | **PASS** |
| S9b `xsi:type` — classpath only (not imported) | **FAIL** | **FAIL** |
| S9c `xsi:type` — invalid + imported schema | **PASS** (rejected) | **PASS** (rejected) |
