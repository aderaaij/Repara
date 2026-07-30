# Repara

File a Na Minha Rua LX report in one pass: photograph the problem, place the pin
on the building, confirm what will be sent, submit.

An unofficial iOS client for Lisbon's occurrence-reporting portal — not built
by, endorsed by, or affiliated with Câmara Municipal de Lisboa. It is a port of
the TypeScript client
[`naminharua-client`](https://github.com/aderaaij/naminharua-client), which is
the implementation that has actually run against the live portal.

---

## The one rule

Submitting files a real work order with a municipal government. A council worker
reads it and is dispatched. **There is no undo, no delete endpoint, and a wrong
or duplicate report wastes public money.**

- **Nothing submits without passing through Review**, which shows the resolved
  street address, the freguesia, the exact Portuguese text, the photo, and any
  open report of the same type within 50 m.
- **`ReviewConfirmation` is bound to one exact prepared report.** Drag the pin,
  edit the text or change the type and the report is re-prepared with a new id;
  the stale confirmation is refused rather than filing something nobody read.
- **Submission defaults to a dry run.** `SubmitMode.dryRun` is the default value
  of the parameter, so a forgotten argument cannot file anything. Live mode is a
  toggle in Settings, and Review says in red which mode it is in.

**Do not test by filing.** Every test submission is a real dispatch. Verify
against the dry-run payload instead.

---

## Layout

```
ReparaCore/     SPM package — no UIKit, no SwiftUI, no LLM. 57 tests that run
                on a Mac with no device and no network.
  Projection    WGS84 ⇄ EPSG:3763, computed locally
  Models        wire shapes; the privacy boundary lives here
  Http · Auth   cookie session, error mapping, login, Keychain
  Geo           getGeoAttributes, house numbers, the two morada shapes
  Taxonomy      127 bundled types, ambiguity refusal
  Multipart     the body quirks
  Submit        payload assembly and the submission gate

Repara/         the app — SwiftUI features, CoreLocation, the model calls
  DesignSystem  ink & tape: the palette, and CautionTier — the four things this
                app can say before a report is filed, each with its own shape
                signature so they survive greyscale and direct sun
```

`ReparaCore` must not import UIKit, SwiftUI or anything to do with a model
API. It holds the parts that were expensive to learn and it needs to stay
testable without a device.

```sh
cd ReparaCore && swift test    # 57 tests, no network, no credentials
xcodebuild -project Repara.xcodeproj -scheme Repara \
  -destination 'generic/platform=iOS Simulator' build
```

Requires Xcode 26 and an iOS 26 target. `ReparaCore` builds against iOS 18 /
macOS 15 so its tests run natively on a Mac.

---

## Secrets

All in the Keychain, none in the bundle or in source: the portal email and
password (Welcome → I already have one), and one API key per model provider
(Settings) — Claude, OpenAI and Gemini each keep their own, so switching between
them does not mean finding the key again. A key cannot ship inside the app — anyone could extract it from the bundle.
Entering it once also keeps the app free of any server of its own, so it works
on cellular with no home server, VPN or sync folder in the path.

Repara files under your own portal account and has none of its own, so the
account is the gate: with no session you get the welcome screen and nothing
else, because every screen past it leads to filing something. Creating an
account and resetting a password open the council's own page in Safari — signing
up means agreeing to their privacy and data-protection terms, which is between
you and them. Only the native email/password login works; Google and Apple
sign-in are not implemented.

The one exception to the gate is the report types. All 127, grouped under their
12 council areas and searchable in either language, are readable from the
welcome screen without an account — "what can I even report?" deserves an answer
before you sign up for anything.

### Two languages, one report

The app is in English and European Portuguese, following your phone unless you
override it in Settings. Any Portuguese counts as Portuguese, Brazilian
included; anything else gets English.

**What gets filed is Portuguese either way.** A council worker reads the report
and acts on it, so the description is written in European Portuguese whatever
language the app is in — and the Review screen shows you that exact text, and
lets you edit every word of it, before anything is sent. The setting changes the
app around the report, never the report.

---

## What was carried across, and why it matters

### The projection

WGS84 → EPSG:3763 is computed **on the phone**, never delegated to the portal's
GeometryServer: its forward call applies a spurious datum shift and lands
**114 m** off. That bug is why this project exists, and why the portal's own map
picker centres in the wrong place.

The implementation is the Krüger series to sixth order in the third flattening
(Karney 2011), ~120 lines, agreeing with proj4 to **2.4 nanometres** across
twelve points spanning Lisbon. `ProjectionTests` asserts both directions: that
it reproduces the reference point, and that it does **not** reproduce the
portal's shifted output — the negative test exists so nobody later "fixes" the
projection by matching the portal. `Projection.verify()` runs at launch and
again immediately before every submission; on drift the app refuses to submit.

### The payload quirks

All verified against a submission the portal answered 201 to, all
counter-intuitive, all pinned by `PayloadTests`:

- `geo.cod_sig` and `geo.id_tipo` are sent **empty**; the real values ride in
  `cod_sig_original` and `idtipo_original`.
- For a building `cod_sig_original` is `cod_sig`; for a street it is `cod_via`.
- `n_pol` is the house number split off the end of `morada` **including its
  leading space** (`"Rua Exemplo, 210"` → `" 210"`), with `morada` left whole.
- `geo.lat`/`geo.lon` are the **inverse projection of the snapped point**, not
  the phone's original fix.
- The `obj` multipart part carries **no `Content-Type`** and is raw UTF-8.
  Photos go in repeated parts named `files`.
- `POST /ficheiro-temp` is **skipped** — the portal calls it but never
  references the id it returns.

The payload is encoded with `.sortedKeys` so the bytes are identical run to run
and a dry run can be diffed. Key order therefore differs from the captured
browser submission, which is fine: JSON objects are unordered by specification
and the portal's Jersey backend deserialises into a POJO.

### Privacy

`getGeoAttributes` returns a `nearBy` array carrying the full name and email of
everyone who filed each nearby report. `NearByOccurrence` decodes only the
fields duplicate detection needs, so retaining the rest is **structurally
impossible** rather than merely discouraged — there is no raw shape to leak into
a log, a cache, or a model prompt. `PrivacyTests` asserts no `@` survives
parsing. Only `promptSummary` is ever sent to the model.

### Type resolution

127 types across 12 areas, bundled rather than fetched (13 requests and 711 KB
for data that changes about as often as municipal departments reorganise).
Resolution accepts an id, an exact slug or a unique substring, and **refuses an
ambiguous match**, listing candidates — five subcategories share wording across
areas and route to different departments.

Regenerate the bundle from the
[TypeScript client](https://github.com/aderaaij/naminharua-client):

```sh
git clone https://github.com/aderaaij/naminharua-client
cd naminharua-client && npm install
npm run nmr -- types --json \
  > /path/to/Repara/ReparaCore/Sources/ReparaCore/Resources/taxonomy.json
```

---

## The model call

One request per report, `URLSession` straight at the provider's endpoint — not
an agent, not tool use, not MCP.

**The provider is the user's choice: Claude, OpenAI or Gemini, picked in
Settings.** The two calls are the same narrow job whoever answers them, so
`Drafter` owns the prompts, the schemas and the validation, and a `ModelProvider`
owns one wire format each. Keys are stored per provider, and model ids are
overridable free text — they go stale faster than this app ships.

- **The strongest model the provider offers, at high effort.** Picking the wrong
  one of 127 types routes the report to the wrong department, so it starts high;
  cheaper models and efforts are worth measuring.
- **Structured output** constrains `tipo_id` to an `enum` of the 127 bundled
  ids, so an invalid type is structurally impossible rather than merely
  unlikely — on two of the three providers. See below.
- **Refusals are handled before reading content** — a refused reply has no
  content to index, whatever shape the provider signals it in. On Claude,
  server-side `fallbacks` is enabled so a spurious refusal re-runs rather than
  dead-ending someone standing in the street; the others have no equivalent.
- **Two photo sizes, two purposes.** The model gets a copy downscaled to
  1568 px; the council gets the full-resolution original, because that is the
  evidence a worker acts on. Do not conflate them.
- The description must be **Portuguese** — a council worker reads it. You may
  speak English at the app; Review shows the Portuguese that will actually be
  sent, capped at 2000 characters.

A failed draft is not a dead end: Review still works, it just starts blank.
Someone in the street should never be blocked by the model.

### Gemini does not enforce the type list — two checks do

Anthropic and OpenAI both take real JSON Schema, so `tipo_id` is constrained to
an `enum` of the 127 bundled ids and an invalid type cannot come back. Gemini's
`responseSchema` is an OpenAPI 3.0 subset instead: it rejects
`additionalProperties` outright and only honours `enum` on strings, so the
integer enum is dropped on the way out (`GeminiProvider.sanitized`). On that
provider nothing structural stops the model naming a type that does not exist.

Two checks are what make that safe, and **neither may be deleted on the grounds
that the schema covers it** — on one of the three it does not:

- `Drafter.parse` resolves `tipo_id` against the bundled taxonomy and throws
  `unknownType` rather than trusting it. The failure it prevents is a report
  filed against the wrong council department.
- `judgeDuplicates` filters the returned positions against the list it actually
  sent, so an out-of-range answer is dropped rather than indexed into.

The full type list is in the prompt on every provider, so this is a backstop,
not the primary mechanism. It is still the only mechanism on Gemini.

---

## Status

`swift test` passes 136 tests across 18 suites with no network. The projection
agrees with proj4 to 2.4 nm across Lisbon and the portal-offset negative test
passes. The recorded submission is regenerated field-for-field from its
coordinates. The app builds for the iOS 26 simulator and launches.

Not verified:

- **No report has been filed by this app.** That step is deliberately
  outstanding — it has to happen outdoors, in front of a real problem.
- **The street-match submit shape** (`idtipo: "8"`, `cod_via`, empty `n_pol`) is
  inferred by analogy and has never been submitted by any client. Review warns
  and invites you to move the pin onto the building frontage.
- Camera capture on a physical device — the simulator has no camera, so the
  library picker was used.

---

## Etiquette

Keep request volume human-paced: bundled taxonomy, one address lookup per pin
placement (the map settles before it fires), no polling. This is a municipal
service, not a load-test target.

**Never commit real addresses, coordinates, occurrence numbers or reporter
details.** Fixtures stay synthetic and the projection reference stays Praça do
Comércio — a public square, so the constant identifies nobody. Photos carry GPS
EXIF and often show someone's home or number plate; they stay out of the repo.
