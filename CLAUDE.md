# Repara — working notes

An unofficial iOS client for **Na Minha Rua LX**, Lisbon's municipal
problem-reporting portal. Ported from the TypeScript client
[`naminharua-client`](https://github.com/aderaaij/naminharua-client), checked
out locally at `../../minharua`; `docs/IOS-APP-HANDOFF.md` is the specification
it was built from, kept locally and untracked. When this repo and that document
disagree, check the TypeScript — it has run against the live portal.

## The one rule

**Submitting files a real work order with a municipal government.** A council
worker reads it and is dispatched. There is no undo and no delete endpoint.

- **Never file a report to test something.** Every submission is a real
  dispatch. Verify against the dry-run payload instead.
- `SubmitMode.dryRun` is the **default value of the parameter**, not a
  convention. Do not change that default, and do not add a code path that
  submits without a `ReviewConfirmation`.
- `ReviewConfirmation` is bound to one `PreparedReport.id`. Any edit re-prepares
  and invalidates it. That is the mechanism that guarantees the user saw what
  was sent — do not loosen it to "any confirmation for any report".

## The projection — read before touching `Projection.swift`

WGS84 → EPSG:3763 is computed on-device. The portal's own GeometryServer
forward call applies a spurious datum shift and lands **114 m** off; that bug is
the reason this project exists.

**If our output ever disagrees with the portal's, the portal is wrong.** Never
resolve such a discrepancy by matching it. `ProjectionTests` asserts both
directions on purpose: that we reproduce the reference point, and that we do
*not* reproduce the portal's shifted output. Deleting the negative test to make
something pass is the failure mode it exists to prevent.

The reference point is Praça do Comércio — a public square, chosen so the
constant identifies nobody. Keep it that way.

## Layout rules

- **`ReparaCore/` must not import UIKit, SwiftUI, or anything LLM-related.** It
  holds the parts that were expensive to learn and it has to stay testable with
  no device and no network. The Claude call lives in `Repara/Intelligence/`.
- `NearByOccurrence` decodes only the fields duplicate detection needs, so
  retaining reporter identity is structurally impossible. **Do not add a
  `CodingKey` for `requerente`, `email`, `criador_id`, `logedUser` or `local`** —
  that re-opens the leak `PrivacyTests` exists to prevent.
- Only `promptSummary` may be sent to the Claude API. A third party's name or
  email in a prompt is a disclosure to a third party.

## Accounts

Repara files under the user's own portal account and has none of its own, so the
account gates the app: `RootView` shows `WelcomeView` and nothing else until
there is a session, because every screen past it leads to filing something.

It signs in; it does **not** sign up. "Create an account" and "Forgotten
password" open the council's own `registo.html` in Safari.

`isRestoringSession` is why the gate does not flash in front of returning users:
`account == nil` means both "signed out" and "the stored cookie has not been
checked yet", and those must not look the same at launch.

`TypeCatalogueView` is the deliberate exception to the gate — the 127 types are
readable from the welcome screen without an account, because "what can I even
report?" is a fair question to ask before signing up for a municipal service.
It reads bundled JSON and touches no session, so it costs the portal nothing.

Do not replace that with a native form. There is no registration endpoint in the
captured session, `api-reference.json` or the TypeScript — it would be a guessed
URL. More importantly, registration is where the user agrees to the council's
privacy and data-protection terms, and this client cannot take that consent on
the council's behalf; the flow also ends in an email confirmation we could not
complete. `AccountLinkTests` pins the URLs to the council's origin over TLS,
because Settings builds those rows with `if let url = URL(string:)` and would
otherwise fail by rendering nothing.

## Duplicate detection — two layers, on purpose

1. **Deterministic**, in `Submitter.prepare`: same `tipoId`, within 50 m, not
   resolved. Surfaced as `PreparedReport.possibleDuplicates` and in `warnings`.
2. **`Drafter.judgeDuplicates`**, a second text-only Claude call. It exists
   because layer 1 only matches the *same type id* — the same pothole filed as
   "Pavimento danificado" and as "Buraco na via" is two ids and one hole.

The second call is deliberate, against the "one Claude call per report" rule the
`Drafter` doc comment used to state. It could not be folded into the draft:
nearby reports are resolved from the occurrence type, and the type is what the
draft produces, so at draft time there is nothing to compare against. **This is
also why `draft` takes no `nearBy` and gets `address: nil`** — both need the
type. That parameter used to exist and was always empty; do not re-add it
believing it works.

It adds **no** requests to the municipal service — `prepare` already fetched
`nearBy`. It does cost a Claude call, so it fires only when something is nearby
and is keyed on type + description + the set of nearby ids; dragging the pin
around the same reports re-uses the verdict instead of re-buying it.

Only `promptSummary` goes to the API, and the model answers with **positions in
the list**, never occurrence numbers — somebody else's report number is theirs.

The two calls run on different models on purpose: the draft on `claude-opus-5`,
because picking one of 127 types from a photograph routes the report to a
department; the judge on `claude-sonnet-5`, because comparing a few sentences
against at most eight more is narrow, and its mistakes are visible next to the
reports it compared. Only the draft sends `fallbacks` — a refusal there strands
somebody in the street, whereas a refused judgement just clears the verdict.

## Verifying

```sh
cd ReparaCore && swift test     # 48 tests, no network, no credentials
```

Run these before claiming anything works. They pin facts that were established
by capturing a real session — the payload quirks in particular are
counter-intuitive and a "cleanup" that makes them look sensible will break the
submission silently.

```sh
# simulator
xcodebuild -project Repara.xcodeproj -scheme Repara \
  -destination 'generic/platform=iOS Simulator' build

# device (Apple team NS76532L76; a NEW bundle id needs portal access, so an
# unaccepted Program License Agreement blocks signing with a confusing
# "profile doesn't include device" error)
xcodebuild -project Repara.xcodeproj -scheme Repara \
  -destination 'id=<device-id>' -allowProvisioningUpdates build
xcrun devicectl device install app --device <device-id> <path/to/Repara.app>
```

## Regenerating the bundled taxonomy

127 types across 12 areas, bundled rather than fetched (13 requests and 711 KB
for data that changes about as often as municipal departments reorganise):

```sh
cd ../../minharua && npm run nmr -- types --json \
  > ../swift/Repara/ReparaCore/Sources/ReparaCore/Resources/taxonomy.json
```

Five descriptions collide across areas and get a `--<area>` suffix in their
slug. `Taxonomy.resolve` matches the raw slug *before* slugifying, because
`slugify` collapses `--` to `-` and would otherwise make those five
unresolvable. (The TypeScript has this bug; this port does not.)

## Etiquette

- Keep request volume human-paced. This is a municipal service, not a load-test
  target: bundled taxonomy, one address lookup per pin placement, no polling.
- **Never commit real addresses, coordinates, occurrence numbers or reporter
  details.** Fixtures stay synthetic. Photos carry GPS EXIF and often show
  someone's home or number plate — they stay out of the repo.
- Portal credentials and the Claude API key live in the Keychain. Never in the
  bundle, a plist, or source.

## Status

Phases 0–6 of the handoff are done. **Phase 7 — one real report — is
outstanding and is the user's to do, outdoors.** The street-match submit shape
(`idtipo: "8"`, `cod_via`, empty `n_pol`) is inferred by analogy and has never
been submitted by any client; the Review screen warns and invites the user to
move the pin onto the building frontage.
