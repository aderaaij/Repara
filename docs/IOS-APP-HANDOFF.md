# Handoff — native iOS app

Build a phone app that files Na Minha Rua LX reports in one pass: photograph
the problem, confirm what will be sent, submit. This document is for whoever
(or whatever) builds it, and assumes no prior knowledge of this repo beyond
what is written here.

**The app is a separate repository.** This file lives here because the thing
being ported is `src/core/`, and a porter should find it next to the code it
describes. Copy it into the app repo when you start.

---

## 1. Why an app, when a CLI and an MCP server already exist

Both existing surfaces need the photo to already be a file on the machine
running them. That is fine at a desk and useless in the street, which is where
reports actually get made. The measured effect is real: reports get filed about
once a fortnight, and would be filed considerably more often if the friction
were lower.

An app removes it: the camera, the GPS and the confirmation screen are all in
the same place, and there is no dependency on a home server, a VPN, a NAS or a
sync folder. The portal and the Claude API are both public internet, so it
works on cellular.

Two things the app can do that the other surfaces cannot, and both matter:

- **Fix the location properly.** The most significant unverified path in this
  client is a report whose coordinate lands on the roadway rather than a
  building (§4). An app can show a map with a draggable pin and let the user
  place it on the building frontage before submitting. This is the single
  biggest quality improvement available, not a nicety.
- **Make the confirmation real.** The MCP server needs a two-call token gate
  because the protocol has no way to prompt a human. An app has a screen. The
  gate becomes a Review step the user physically taps through.

---

## 2. The one rule that matters

Submitting files a real work order with a municipal government. A council
worker reads it and is dispatched. **There is no undo, no delete endpoint, and
a wrong or duplicate report wastes public money.**

Therefore:

- **Nothing submits without passing through a Review screen the user has
  seen.** No "quick file" shortcut, no widget that skips it, no retry path that
  bypasses it. The Review screen shows the resolved street address, the
  freguesia, the exact Portuguese text, the photo, and any open reports of the
  same type within 50 m.
- **Build submit last**, behind a dry-run flag that stops before the POST and
  dumps the payload (§8).
- **Do not test by filing.** Every test submission is a real dispatch. Verify
  against the recorded payload instead, then file exactly one real report when
  you believe it is right.

---

## 3. Architecture

```
┌── Capture ─────────┐   AVFoundation photo + CoreLocation fix
│                    │
├── Draft ───────────┤   ONE Claude API call: photo + taxonomy + user's words
│                    │       → { tipo_id, descricao_pt }
├── Resolve ─────────┤   local projection → getGeoAttributes
│                    │       → address, freguesia, nearby duplicates
├── Review ──────────┤   ← THE GATE. Map pin, editable text, duplicates.
│                    │
└── Submit ──────────┘   multipart POST /ocorrencias
```

Suggested layout:

```
Sources/
  Core/            port of src/core/ — no UI, no LLM, fully testable
    Http.swift       cookie handling, request wrapper, error mapping
    Auth.swift       login, session persistence, Keychain
    Geo.swift        projection, getGeoAttributes, PII stripping
    Taxonomy.swift   bundled types, slug/substring resolution
    Submit.swift     payload assembly, multipart POST
    Models.swift     Codable types
  Intelligence/
    Drafter.swift    the single Claude call
  Features/
    Capture/ Review/ Status/
Resources/
  taxonomy.json    bundled, regenerated from this repo
Tests/
  ProjectionTests  PayloadTests  TaxonomyTests  PrivacyTests
```

`Core/` must not import UIKit/SwiftUI or the LLM layer. It is the part with
hard-won correctness properties and it needs to be testable without a device.

---

## 4. What must be ported exactly, and why

Everything in this section is a fact established by capturing a real session.
None of it is documented by the portal, and getting any of it subtly wrong
produces a plausible-looking report filed against the wrong thing.

### 4.1 The coordinate projection — the dangerous one

WGS84 → **EPSG:3763** (ETRS89 / PT-TM06) must be computed **locally**. Do not
delegate it to the portal's GeometryServer: its forward call applies a spurious
datum shift and lands **114 m** off. That bug is why this project exists.

Parameters (`towgs84` is all zeros, so this is a plain Transverse Mercator on
GRS80 — no datum shift needed):

```
proj=tmerc  lat_0=39.6682583333333  lon_0=-8.13310833333333
k=1  x_0=0  y_0=0  ellps=GRS80  units=m
```

Implement Transverse Mercator directly (~80 lines) or link PROJ. Either way,
**port `verifyProjection` with it and run it before any submit**:

| | latitude | longitude |
|---|---|---|
| WGS84 | `38.70757` | `-9.1364` |
| EPSG:3763 | `x = -87269.1457760187` | `y = -106176.89242727536` |

Reference point is Praça do Comércio — a public square, deliberately, so the
constant identifies nobody. Tolerance 1 m; the TypeScript implementation agrees
to sub-centimetre. **If it drifts, refuse to submit.** See
`src/core/geo.ts::verifyProjection`.

Also port the negative test: assert the implementation does **not** reproduce
the portal's shifted output (`x = -87343.711582961347`, `y =
-106263.59125521514`, a constant offset of `dx −74.57, dy −86.7`). Its purpose
is to stop someone "fixing" the projection later by matching the portal.

### 4.2 The two address shapes

`getGeoAttributes` returns `morada` as an **array**, and entries come in two
shapes:

| | `idtipo` | carries | meaning |
|---|---|---|---|
| Building | `"2"` | `morada` (`"Rua X, 210"`), `cod_sig` | verified |
| Street | `"8"` | `designacao` (no number), `cod_via` | **never submitted successfully** |

Never reach for `.morada` directly — a street match has no such field. Port
`moradaLabel` and `isStreetMatch`.

**The street shape is the app's opportunity.** When resolution yields
`idtipo: "8"`, the Review screen should say so plainly and invite the user to
drag the pin onto the building frontage, which usually converts it to a
verified building match. Do not silently submit a street match.

### 4.3 The submit payload quirks

All verified against a submission that returned 201, all counter-intuitive:

- `geo.cod_sig` and `geo.id_tipo` are sent **empty strings**. The real values
  ride in `cod_sig_original` and `idtipo_original`.
- For a building, `cod_sig_original` is `cod_sig`; for a street it is
  `cod_via`.
- `n_pol` is the house number split off the end of `morada` **including its
  leading space** (`"Rua Exemplo, 210"` → `" 210"`), with `morada` left whole.
  A tail that is not a number yields `""`.
- `geo.lat`/`geo.lon` are the **inverse projection of the snapped point**, not
  the user's original coordinates.
- The `obj` multipart part carries **no `Content-Type` header** and is raw
  UTF-8 (addresses are full of diacritics). Photos go in parts named `files`.
- `POST /ficheiro-temp` is **skipped**. The portal calls it, but the returned
  id is never referenced and the bytes are re-sent in the submission.

### 4.4 Auth

Single `JSESSIONID` cookie. `POST /gopiv2/login.jsp` with
`username`/`password`/`provider=AD` as a form body; no CSRF token, no
`Authorization` header. **Bad credentials return 200 with the login form
again** — success is decided by a follow-up `GET /naminharuav2/utilizador`, not
by the POST status.

Sessions are not short-lived (a cookie was still good after 109 minutes).
`URLSession` handles the cookie automatically via `HTTPCookieStorage`.
Credentials go in the **Keychain**. Only the native email/password account
works; Google and Apple SSO are not implemented.

### 4.5 Privacy

`getGeoAttributes` returns a `nearBy` array carrying the **full name and email
of everyone who filed each nearby report**. Port `stripNearBy` as the boundary:
keep type, description, status, coordinates and distance; drop everything else,
at the point of parsing.

Two app-specific rules:

- **Never send raw `nearBy` to the Claude API.** If the model helps judge
  duplicates, give it stripped entries only. A third party's name and email in
  a prompt is a disclosure to a third party.
- Do not log or persist the raw shape.

`PrivacyTests` should assert no email-like string survives parsing — the
TypeScript test asserts no `@` at all, which is a good bar.

### 4.6 Type resolution

127 types across 12 areas. Resolution accepts a numeric id, an exact slug, or a
unique substring — and **throws on an ambiguous match, listing candidates**.
Five subcategories share wording across areas and route to different
departments, so never silently take the first match. Port that refusal.

Bundle the taxonomy rather than fetching it (it is 13 requests and changes
about as often as municipal departments reorganise). Regenerate from this repo:

```sh
npm run nmr -- types --json > taxonomy.json
```

`data/translations.json` holds hand-written English glosses — worth bundling
too, for a searchable picker.

---

## 5. What NOT to port

- The CLI argument plumbing and the MCP server.
- The taxonomy disk-cache logic (bundled instead).
- `uploadTempFile` — `/ficheiro-temp` is skipped (§4.3).
- `pesquisa-desktop` and `exportar-pesquisa`: deliberately not implemented, and
  should stay that way. They return bulk per-occurrence data with no legitimate
  use here.

---

## 6. The Claude call

One request per report. Not an agent, not tool use, not MCP.

- **Endpoint** `POST https://api.anthropic.com/v1/messages`, headers
  `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`.
  There is no official Anthropic Swift SDK; use `URLSession` directly.
- **Model** `claude-opus-5`. This is a narrow structured-extraction task, so
  measure `claude-sonnet-5` against it once it works — likely indistinguishable
  here and cheaper per report.
- **Input** the photo as a base64 `image` content block
  (`media_type: image/jpeg`), plus the bundled type list and whatever the user
  said, in any language.
- **Output** pin the response with `output_config.format` (`type:
  "json_schema"`) to something like:

  ```json
  { "tipo_id": 262,
    "descricao": "Sacos de lixo abandonados no passeio junto ao número 12.",
    "confidence": "high",
    "notes_for_user": "Two other litter reports are already open nearby." }
  ```

  Structured outputs mean a validated object rather than prose to parse.
  Requires `additionalProperties: false` and `required` on the schema.

**Downscale the photo for the model, not for the portal.** ~1024–1568 px on the
long edge is plenty to identify a dumped mattress and costs a fraction of the
tokens. The **full-resolution original** goes to the council — that is the
evidence a worker acts on. Two sizes, two purposes; do not conflate them.

**The description must be Portuguese** — a council worker reads it. The user
may speak English at the app; the model translates, and the Review screen shows
the Portuguese that will actually be sent. Cap at **2000 characters**: the
portal's textarea says `maxlength="2048"` but its placeholder says 2000, and
server-side truncation is silent.

**The API key cannot be baked into the app** — it is extractable from the
bundle. Enter it once into the Keychain alongside the portal credentials, which
also keeps the app free of any server dependency.

---

## 7. Location handling

Use **CoreLocation for the fix**, not photo EXIF. The app has a live, more
accurate position and avoids the ways EXIF gets silently stripped.

But the caveat that applies to EXIF applies here too: **the fix is where the
photographer is standing, not where the problem is.** Someone standing in the
road to photograph a pavement gets a street match (§4.2).

So the Review screen must show a **map with a draggable pin**, defaulting to
the current fix, and re-resolve the address when it moves. Show the resolved
address prominently — it is the cheapest possible check against sending a
worker to the wrong door.

Sanity-check the coordinate is inside Lisbon before resolving (`isInLisbon` in
`src/core/geo.ts`); the portal covers only that municipality.

---

## 8. Suggested phases

Read-only first, irreversible last.

| # | Phase | Done when |
|---|---|---|
| 0 | Project skeleton, Keychain, login | `utilizador` returns your account |
| 1 | **Projection + tests** | Reference pair matches to <1 m and the portal-offset negative test passes |
| 2 | Taxonomy bundling + resolution | Ambiguous substrings raise, listing candidates |
| 3 | Geo resolve + nearby | A known coordinate returns the expected street address; `PrivacyTests` green |
| 4 | Capture + Review UI, map pin | Street matches are visible and correctable |
| 5 | Claude drafting | Photo in, `{tipo_id, descricao}` out, editable |
| 6 | **Submit, dry-run first** | Generated payload matches the recorded one field-for-field |
| 7 | One real report | Filed, and visible in the status list |

Phase 1 before anything that touches the portal. It needs no network, it is the
part most likely to be subtly wrong, and everything downstream is worthless if
it is.

---

## 9. Tests that must come across

Port these alongside the code, not after. They are in
`test/offline.test.ts` and each pins something that was expensive to learn.

- Projection reproduces the reference pair; round-trips; **does not** reproduce
  the portal's 114 m offset.
- `splitHouseNumber` returns `" 210"` verbatim, handles `12A` and `12-14`, and
  returns `""` when the tail is not a number.
- Building and street `morada` shapes are distinguished; a street match has no
  house number; `moradaLabel` returns nil when neither shape is present.
- Stripping drops reporter identity — assert no `@` survives — while keeping
  the duplicate-detection fields.
- Type resolution accepts id/slug/unique-substring and **refuses** ambiguity.
- Payload regeneration matches the recorded submission field-for-field.

None require network or credentials, and they should all run on every build.

---

## 10. Etiquette and hygiene

- **Keep request volume human-paced.** This is a municipal service, not a
  load-test target. Bundled taxonomy, one resolve per pin move (debounced), no
  polling.
- **Never commit real addresses, coordinates, occurrence numbers or reporter
  details.** Sample data stays synthetic and the projection reference stays
  Praça do Comércio. Photos carry GPS EXIF and often show someone's home or
  plate — keep them out of the repo.
- Portal credentials and the Claude API key live in the Keychain, never in the
  bundle, a plist, or source.

---

## 11. Reference

Everything above is implemented and verified in the TypeScript client:

| Concern | File |
|---|---|
| Projection, `getGeoAttributes`, PII stripping | `src/core/geo.ts` |
| Login, session | `src/core/auth.ts` |
| Payload assembly, multipart submit | `src/core/submit.ts` |
| Taxonomy, slugs, ambiguity refusal | `src/core/taxonomy.ts` |
| Wire shapes and the two `morada` variants | `src/core/types.ts` |
| The facts worth pinning | `test/offline.test.ts` |
| What is verified vs assumed | `README.md` § Verification status |

When the TypeScript and this document disagree, the TypeScript is right — it
has run against the live portal.
