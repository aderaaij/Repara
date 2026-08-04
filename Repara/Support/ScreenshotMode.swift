#if DEBUG

    import Foundation
    import ReparaCore
    import SwiftUI
    import UIKit

    /// Drives the app into one screen at a time, against a stubbed portal, so the
    /// screenshots in `docs/screenshots/` can be regenerated without a network, an
    /// account, or a photograph of somebody's front door.
    ///
    /// **Nothing here can file a report.** `StubPortal` has no `POST /ocorrencias`
    /// route at all, so a submission cannot reach a server even by accident, and
    /// `submitMode` is never written — it stays at its `.dryRun` default like
    /// everywhere else. The `filed` scene decodes a synthetic `SubmitResult`
    /// locally; no council worker exists to be dispatched by it.
    ///
    /// Compiled out of release builds, and inert unless `--screenshot-scene <name>`
    /// is on the command line. In every other run this file contributes one
    /// `ProcessInfo` read at launch and nothing else.
    enum ScreenshotMode {

        // MARK: Activation

        /// Simulator only, on top of `#if DEBUG`.
        ///
        /// `applyDefaults` writes placeholder API keys so the stubbed model call
        /// has something to find. On a real device that would overwrite the
        /// user's own key in the Keychain — a secret this app deliberately has no
        /// other copy of — and there is nothing here worth photographing on a
        /// phone anyway. So the harness does not exist off the simulator.
        static let scene: String? = {
            #if targetEnvironment(simulator)
                let args = ProcessInfo.processInfo.arguments
                guard let flag = args.firstIndex(of: "--screenshot-scene"),
                    args.index(after: flag) < args.endIndex
                else { return nil }
                return args[args.index(after: flag)]
            #else
                return nil
            #endif
        }()

        static var isActive: Bool { scene != nil }

        /// How far down the screen's scroll view to sit before the shot is taken,
        /// in points. Review is several screens long and its two warning sections
        /// are in the middle of it, so photographing only the top would leave the
        /// newest thing in the app permanently undocumented.
        ///
        /// Done by reaching into the window for the scroll view rather than by
        /// threading an anchor through the views: a screenshot harness has no
        /// business appearing in `ReviewView`.
        static let scrollOffset: CGFloat? = {
            let args = ProcessInfo.processInfo.arguments
            guard let flag = args.firstIndex(of: "--screenshot-scroll"),
                args.index(after: flag) < args.endIndex,
                let value = Double(args[args.index(after: flag)])
            else { return nil }
            return CGFloat(value)
        }()

        @MainActor
        static func applyScroll() {
            // Zero means "leave it alone", not "scroll to y=0" — a `Form` sits at a
            // negative offset under its navigation bar, and forcing it to zero
            // slides the first section up behind the title.
            guard let scrollOffset, scrollOffset > 0 else { return }
            guard
                let window = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .flatMap(\.windows)
                    .first(where: \.isKeyWindow),
                let scrollView = firstScrollView(in: window)
            else { return }

            let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            scrollView.setContentOffset(
                CGPoint(x: 0, y: min(scrollOffset, maxY)), animated: false)
        }

        private static func firstScrollView(in view: UIView) -> UIScrollView? {
            if let scrollView = view as? UIScrollView, scrollView.contentSize.height > 0 {
                return scrollView
            }
            for subview in view.subviews {
                if let found = firstScrollView(in: subview) { return found }
            }
            return nil
        }

        /// Every scene the capture script knows how to ask for. Kept here rather
        /// than in the script so adding a screen means touching one file.
        static let allScenes = [
            "launch", "welcome", "sign-in", "types",
            // Both halves of Capture. `capture-empty` is the first screen a
            // signed-in user meets and it stages nothing at all — it is here
            // because the placeholder state is the one that has to *not* look
            // like a camera viewfinder, and an undocumented screen is one
            // nobody notices regressing.
            "capture-empty", "capture", "drafting",
            "review", "review-booked", "review-booked-far", "review-checking", "review-failed",
            "type-picker", "dry-run", "filed",
            "reports-mine", "my-report", "occurrence-compare",
            "browse-empty", "browse-results", "browse-nothing",
            "browse-filtered",
            "settings", "settings-gemini",
        ]

        /// The one fixture a scene needs to build a view directly rather than
        /// reach it through the app. `Fixtures` stays private — a screenshot
        /// harness's synthetic data has no business being visible to the app.
        static var bookedCollectionFixture: NearByOccurrence { Fixtures.bookedCollection }

        /// The row `my-report` is opened on — the first of the three the stubbed
        /// `/ocorrencias/my` answers with, decoded through the real path so the
        /// screenshot shows what the decoder actually keeps.
        static var myReportFixture: MyOccurrence { Fixtures.myReport }

        // MARK: The stubbed portal

        /// A session that answers from `Fixtures` below and never opens a socket.
        /// The real header and cookie configuration is deliberately kept — the
        /// point is to photograph the app as it behaves, not a simplified copy.
        static let session: URLSession = {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [StubPortal.self]
            config.httpAdditionalHeaders = nil
            return URLSession(configuration: config)
        }()

        // MARK: Staging

        /// Put the app into the requested state. Runs once, at launch, in place of
        /// `AppModel.start()`.
        ///
        /// Scenes drive the **real** code paths wherever they can — `resolve()`,
        /// `NearbyBrowser.search`, `Taxonomy.related` — against the stub, rather
        /// than assigning finished state onto the model. A screenshot of a screen
        /// that was reached some other way is a screenshot of something the app
        /// does not do.
        /// Anything a view reads in its `@State` initialiser has to be true before
        /// the view is built, which is earlier than `stage` runs — `SettingsView`
        /// latches `ModelSettings.provider` into `@State`, so setting it later
        /// photographs the wrong provider.
        ///
        /// Called from `ReparaApp.init`.
        static func applyDefaults() {
            guard let scene else { return }

            // The model calls are stubbed too, so the duplicate judge has to think
            // it has a key. Simulator keychain only, DEBUG only, and never a real
            // secret.
            try? Keychain.set("sk-ant-screenshot-stub", for: .claudeAPIKey)
            try? Keychain.set("AIza-screenshot-stub", for: .geminiAPIKey)

            // Browse now signs in to the app API, which authenticates with a
            // token rather than the `JSESSIONID` the rest of the app uses — and
            // `AppSession` fetches that token from the Keychain credentials, so
            // without these every browse scene photographs "not signed in".
            // Stubbed like the API keys above: simulator only, DEBUG only, and
            // posted to a `URLSession` that never opens a socket.
            try? Keychain.set("utilizador@example.invalid", for: .portalUsername)
            try? Keychain.set("screenshot-stub", for: .portalPassword)
            ModelSettings.provider = scene == "settings-gemini" ? .gemini : .anthropic

            // Model ids are shown as placeholders when unset, which is the state
            // worth documenting — a stale override baked into a screenshot would
            // outlive the release that fixed it.
            for provider in ModelProviderID.allCases {
                ModelSettings.setDraftModel(nil, for: provider)
                ModelSettings.setJudgeModel(nil, for: provider)
            }

            // Twenty launches share one `UserDefaults`, so anything the app
            // remembers between visits leaks from one scene into the next — the
            // browse type in particular, which is remembered on purpose.
            UserDefaults.standard.removeObject(forKey: "browseTypeId")

            // Explicitly the dry run. It is already the default; saying so here
            // means a simulator left switched to live from a real session cannot
            // put "File reports for real" in a screenshot.
            UserDefaults.standard.set(false, forKey: "liveSubmit")
        }

        @MainActor
        static func stage(_ model: AppModel) async {
            guard let scene else { return }

            // The real launch path: the projection self-check, the location
            // provider, and the stored-session check. It is also what clears
            // `isRestoringSession`, without which every scene behind `RootView`
            // would photograph the launch placeholder.
            await model.start()

            switch scene {
            case "launch", "welcome", "sign-in", "types":
                // Signed out on purpose, even if this simulator has credentials
                // left over from a real run.
                model.account = nil
                return
            default:
                model.account = Fixtures.account
            }

            // `NearbyBrowser` reads its remembered filter in `init`, which has
            // already run by the time `applyDefaults` clears the key. Each scene
            // states its own starting point.
            model.browse.typeFilter = nil

            switch scene {
            case "capture":
                await model.accept(image: examplePhoto())
                model.pin = Projection.reference.wgs84
                model.userText = "Sacos de lixo abandonados junto aos contentores, há vários dias."

            case "drafting":
                await model.accept(image: examplePhoto())
                model.pin = Projection.reference.wgs84
                model.stage = .drafting

            case "review", "review-booked", "review-booked-far", "review-checking", "review-failed",
                "type-picker":
                await stageReview(model, scene: scene)

            case "dry-run":
                await stageReview(model, scene: "review")
                model.stage = .dryRan(payload: Fixtures.dryRunPayload, bytes: 1_482_301)

            case "filed":
                model.stage = .filed(Fixtures.submitResult)

            case "browse-empty":
                break

            case "browse-results", "browse-nothing", "browse-filtered":
                await stageBrowse(model, scene: scene)

            default:
                break
            }
        }

        /// The Review screen, reached the way the app reaches it: a photo, a type,
        /// a pin, and `resolve()` — which resolves the address, finds the same-type
        /// duplicates, spends the cross-type collection lookup and then judges the
        /// union of both with the (stubbed) model.
        @MainActor
        private static func stageReview(_ model: AppModel, scene: String) async {
            await model.accept(image: examplePhoto())
            model.pin = Projection.reference.wgs84
            model.stage = .review

            switch scene {
            case "review":
                // Graffiti: nothing reported under it and no sibling types, so
                // neither warning section appears. It is the clean path, and it is
                // the counter-example the sibling map is built around — the offer
                // showing on litter and not on graffiti is the whole point.
                model.type = Taxonomy.bundled.types.first { $0.id == Fixtures.quietSoloTypeId }
                model.descricao =
                    "Grafitis na fachada lateral do edifício, junto à entrada."
            default:
                model.type = Taxonomy.bundled.types.first { $0.id == Fixtures.litterTypeId }
                model.descricao =
                    "Sacos de lixo abandonados junto aos contentores, há vários dias."
            }

            model.resolve()
            // `resolve` debounces 400 ms, then makes up to three stubbed calls and
            // a model call with its own 600 ms debounce.
            try? await Task.sleep(for: .seconds(scene == "review-checking" ? 1.2 : 3))
        }

        @MainActor
        private static func stageBrowse(_ model: AppModel, scene: String) async {
            // One request, every type — so the filter is applied *after* the
            // search rather than being the question it asked.
            await model.browse.search(at: Projection.reference.wgs84)
            if scene == "browse-filtered" {
                model.browse.typeFilter = Taxonomy.bundled.type(id: Fixtures.litterTypeId)
            }
        }

        // MARK: The photo

        /// A drawn placeholder, not a photograph.
        ///
        /// Real photos carry GPS EXIF and usually somebody's front door or number
        /// plate, which is exactly why they are gitignored. The screenshots are
        /// published-ish artefacts, so the thing in the frame has to be synthetic
        /// too.
        static func examplePhoto() -> UIImage {
            let size = CGSize(width: 1200, height: 1600)
            return UIGraphicsImageRenderer(size: size).image { context in
                UIColor.secondarySystemBackground.setFill()
                context.fill(CGRect(origin: .zero, size: size))

                let label = "example photo" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 72, weight: .regular),
                    .foregroundColor: UIColor.tertiaryLabel,
                ]
                let bounds = label.size(withAttributes: attributes)
                label.draw(
                    at: CGPoint(
                        x: (size.width - bounds.width) / 2,
                        y: (size.height - bounds.height) / 2),
                    withAttributes: attributes)
            }
        }
    }

    // MARK: - The stub

    /// Answers the handful of endpoints the screens below actually call.
    ///
    /// Anything unrecognised 404s rather than falling through to the network: a
    /// screenshot run that silently reached the live portal would be exactly the
    /// accident this whole file exists to make impossible.
    private final class StubPortal: URLProtocol {

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let (status, body, delay) = Self.answer(for: request)

            let respond = { [weak self] in
                guard let self, let url = self.request.url else { return }
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json; charset=utf-8"]
                )!
                self.client?.urlProtocol(
                    self, didReceive: response, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: body)
                self.client?.urlProtocolDidFinishLoading(self)
            }

            if delay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: respond)
            } else {
                respond()
            }
        }

        override func stopLoading() {}

        /// - Returns: status, body, and how long to sit on it. The delay is what
        ///   makes the "Checking whether this is already booked…" row photographable
        ///   — it is a real state the app spends a second in, not a mock-up.
        private static func answer(for request: URLRequest) -> (Int, Data, TimeInterval) {
            guard let url = request.url,
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { return (404, Data(), 0) }

            let path = components.path
            let scene = ScreenshotMode.scene ?? ""

            // The model providers. Only the duplicate judge is ever reached in a
            // screenshot run — no scene calls `draft`, because `drafting` is a
            // spinner and every other scene sets the type directly.
            if url.host?.contains("anthropic.com") == true
                || url.host?.contains("openai.com") == true
                || url.host?.contains("googleapis.com") == true
            {
                return (200, Fixtures.judgeResponse, 0)
            }

            // The app API's login. A different context, a different credential
            // and a different envelope from `login.jsp` — see `AppSession`.
            if path.hasSuffix("/publico-app/utilizador/login") {
                return (200, Fixtures.appToken, 0)
            }

            // The area search: every type around a point, in one request.
            //
            // Matched on the **`-app` context**, not on "/ocorrencias", because
            // on that API the filter query and filing a report are the same URL
            // separated only by content type. Keying this on the path suffix
            // alone would put a stubbed submit endpoint one Content-Type away
            // from existing, and the rule at the top of this file is that
            // nothing here can file anything.
            if path.hasPrefix("/gopiv2/naminharuav2-app/ocorrencias") {
                guard request.httpMethod == "POST" else { return (405, Data("{}".utf8), 0) }
                switch scene {
                case "browse-nothing": return (200, Fixtures.emptyArea, 0)
                default: return (200, Fixtures.areaOccurrences, 0)
                }
            }

            if path.hasSuffix("/utilizador") {
                return (200, Fixtures.utilizador, 0)
            }

            // The second request a report costs, made only when one is opened.
            // Answered empty rather than left to 404: "no photograph on this
            // report" is a real state worth photographing, and a stub gap
            // rendering as a failure card documents the harness, not the app.
            if path.hasSuffix("/fotos") {
                return (200, Data("[]".utf8), 0)
            }

            if path.hasSuffix("/ocorrencias/my") {
                return (200, Fixtures.myReports, 0)
            }

            if path.contains("getGeoAttributes") {
                let tipo = components.queryItems?
                    .first { $0.name == "ocoTipo" }?.value
                    .flatMap(Int.init)

                switch tipo {
                case Fixtures.litterTypeId:
                    return (200, Fixtures.litterNearBy, 0)

                case Fixtures.collectionTypeId:
                    // The one lookup the Review screen spends unasked, and the
                    // three states it can be in.
                    switch scene {
                    case "review-checking": return (200, Fixtures.collectionNearBy, 30)
                    case "review-failed": return (503, Data("{}".utf8), 0)
                    case "review-booked-far":
                        return (200, Fixtures.farCollectionNearBy, 0)
                    case "review-booked", "review-widened":
                        return (200, Fixtures.collectionNearBy, 0)
                    default: return (200, Fixtures.collectionNearBy, 0)
                    }

                default:
                    return (200, Fixtures.emptyNearBy, 0)
                }
            }

            // login.jsp and the session-seeding GET. No body is read from either.
            if path.hasSuffix("login.jsp") || path.hasSuffix("/gopiv2/") {
                return (200, Data(), 0)
            }

            return (404, Data("{}".utf8), 0)
        }
    }

    // MARK: - Synthetic data

    /// Every value here is invented. The addresses are "Rua Exemplo", the names use
    /// `.invalid` (RFC 2606), the occurrence numbers are `OCO/0000n/2000`, and the
    /// coordinates are Praça do Comércio — a public square, the same one the
    /// projection self-check uses, chosen so the constant identifies nobody.
    ///
    /// These mirror `ReparaCore/Tests/.../Fixtures/` deliberately: same shapes,
    /// same quirks, so a screenshot shows what the tests pin.
    private enum Fixtures {

        /// `Sacos ou outros lixos abandonados` — a problem somebody reports.
        static let litterTypeId = 262
        /// `Remoção-Monstros-Pedido de recolha` — how the council is *asked* to
        /// come and take it away. The pair is what the cross-type check exists for.
        static let collectionTypeId = 256
        /// `Entulhos, objetos volumosos […] abandonados na via pública`, with
        /// nothing reported under it — the "nothing of this type here" empty
        /// state.
        ///
        /// Deliberately a type that *has* siblings. An empty answer is exactly
        /// when somebody concludes the area is clear, so the version of that
        /// screen worth documenting is the one still offering to look under the
        /// collection requests.
        static let quietTypeId = 97
        /// Real ids from the bundled taxonomy: the browse filter resolves these
        /// through `Taxonomy.bundled`, so an invented id would vanish from it.
        static let lightingTypeId = 74
        static let pavementTypeId = 506

        /// `Grafitis` — nothing reported under it *and* no siblings, so the Review
        /// screen shows neither warning. The one type the docs name as the case
        /// where no related lookup is worth spending.
        static let quietSoloTypeId = 98

        static var account: Utilizador {
            try! JSONDecoder().decode(Utilizador.self, from: utilizador)
        }

        static var myReport: MyOccurrence {
            try! JSONDecoder().decode([MyOccurrence].self, from: myReports)[0]
        }

        static var submitResult: SubmitResult {
            try! JSONDecoder().decode(
                SubmitResult.self,
                from: Data(#"{"id": 1000900, "numero": "OCO/00900/2000"}"#.utf8))
        }

        /// The app API's token. Invented, and never sent anywhere: `StubPortal`
        /// answers every request in this process.
        static let appToken = Data(
            (#"{"data":{"authToken":"00000000-0000-0000-0000-000000000000"},"#
                + #""gap":{"operationSucceeded":true}}"#).utf8)

        /// The area search: several types around one point, which is the whole
        /// point of the call. Coordinates are WGS84 here — the app API takes and
        /// returns degrees, not EPSG:3763 — and cluster around Praça do
        /// Comércio.
        ///
        /// Carries `local` on every row so the screenshot run exercises the
        /// decoder actually dropping the address rather than merely not being
        /// offered one.
        static let areaOccurrences = Data(
            """
            {"data":{"ocos":[
              {"id":1000000,"num":"OCO/00000/2000","desc":"Sacos de lixo deixados ao lado do contentor, já rasgados.",
               "tipo":"Sacos ou outros lixos abandonados","tipoId":262,
               "area":"Higiene Urbana","areaId":10,"freg":"Freguesia Exemplo",
               "est":"Em análise","estId":"AN","lat":38.70760,"lon":-9.13660,"dist":24,
               "local":"Rua Exemplo 1, 1000-000 Lisboa"},
              {"id":1000001,"num":"OCO/00001/2000","desc":"Candeeiro apagado há mais de uma semana.",
               "tipo":"Candeeiro apagado","tipoId":\(Fixtures.lightingTypeId),
               "area":"Iluminação Pública","areaId":11,"freg":"Freguesia Exemplo",
               "est":"Em execução","estId":"EX","lat":38.70735,"lon":-9.13700,"dist":61,
               "local":"Rua Exemplo 9, 1000-000 Lisboa"},
              {"id":1000002,"num":"OCO/00002/2000","desc":"Passeio levantado junto à esquina.",
               "tipo":"Descalcetamento do passeio","tipoId":\(Fixtures.pavementTypeId),
               "area":"Passeios e Acessibilidades","areaId":5,"freg":"Freguesia Exemplo",
               "est":"Registado para Resolução","estId":"ENC","lat":38.70790,"lon":-9.13590,"dist":118,
               "local":"Rua Exemplo 14, 1000-000 Lisboa"},
              {"id":1000003,"num":"OCO/00003/2021","desc":"Lixo acumulado junto ao jardim.",
               "tipo":"Sacos ou outros lixos abandonados","tipoId":262,
               "area":"Higiene Urbana","areaId":10,"freg":"Freguesia Exemplo",
               "est":"Resolvida","estId":"RS","lat":38.70700,"lon":-9.13620,"dist":73,
               "local":"Rua Exemplo 3, 1000-000 Lisboa"}
            ]},"gap":{"operationSucceeded":true}}
            """.utf8)

        /// A point with nothing open around it, for the tick.
        static let emptyArea = Data(#"{"data":{"ocos":[]},"gap":{"operationSucceeded":true}}"#.utf8)

        static let utilizador = Data(
            """
            {
              "type": "AD",
              "code": 999000,
              "contacto": "000000000",
              "nome": "Utilizador Exemplo",
              "email": "utilizador@example.invalid"
            }
            """.utf8)

        /// Carries the whole row the portal's own `my.html` binds — address,
        /// department, freguesia, who has it and when it was filed — because
        /// those are what the report screen behind a row is made of, and a
        /// fixture with only the five fields the list uses would photograph an
        /// empty one.
        ///
        /// `requerente` and `email` ride along on the first row for the same
        /// reason the `nearBy` fixtures carry them: the decoder dropping them is
        /// only demonstrated by a run where they were offered.
        static let myReports = Data(
            """
            [
              {
                "id": 1000800,
                "numero": "OCO/00800/2000",
                "descricao": "Sacos de lixo abandonados junto aos contentores, há vários dias.",
                "tipo": "Sacos ou outros lixos abandonados",
                "area": "Higiene Urbana",
                "local": "Rua Exemplo 1, 1000-000 Lisboa",
                "freguesia": "Freguesia Exemplo",
                "responsavel": "Departamento Exemplo",
                "data_criacao": "12-03-2000",
                "naminharua_estado": "Em curso",
                "requerente": "Utilizador Exemplo",
                "email": "utilizador@example.invalid"
              },
              {
                "id": 1000801,
                "numero": "OCO/00801/2000",
                "descricao": "Passeio levantado junto à paragem, com risco de queda.",
                "tipo": "Pavimento danificado",
                "area": "Passeios e Acessibilidades",
                "local": "Rua Exemplo 14, 1000-000 Lisboa",
                "freguesia": "Freguesia Exemplo",
                "responsavel": "Departamento Exemplo",
                "data_criacao": "04-11-2000",
                "naminharua_estado": "Concluído"
              },
              {
                "id": 1000802,
                "numero": "OCO/00802/2000",
                "descricao": "Candeeiro apagado há mais de uma semana.",
                "tipo": "Iluminação pública avariada",
                "area": "Iluminação Pública",
                "local": "Rua Exemplo 9, 1000-000 Lisboa",
                "freguesia": "Freguesia Exemplo",
                "data_criacao": "27-09-2000",
                "naminharua_estado": "Concluído"
              }
            ]
            """.utf8)

        /// The answer to `ocoTipo=262`, so every row is type 262 — the portal
        /// scopes `nearBy` to the type asked for, and a fixture carrying a second
        /// type would depict a response the server does not produce.
        ///
        /// One row per outcome of the duplicate filter: `OCO/00000` is open and
        /// 20 m away, so it is the duplicate; `OCO/00001` is open but 141 m away;
        /// `OCO/00002` is 14 m away but resolved.
        static let litterNearBy = geoAttributes(
            nearBy: """
                {
                  "id": 1000000,
                  "numero": "OCO/00000/2000",
                  "requerente": "Fulano De Tal",
                  "email": "FULANO.DETAL@EXAMPLE.INVALID",
                  "criador_id": 999999,
                  "local": "Rua Exemplo 1, 1000-000 Lisboa",
                  "descricao": "Sacos de lixo deixados ao lado do contentor, já rasgados.",
                  "tipo": "Sacos ou outros lixos abandonados",
                  "tipo_id": 262,
                  "geo_x": -87257.1457760187,
                  "geo_y": -106160.89242727536,
                  "area": "Higiene Urbana",
                  "area_oco_id": 10,
                  "freg_descricao": "Freguesia Exemplo",
                  "naminharua_estado": "Em curso"
                },
                {
                  "id": 1000001,
                  "numero": "OCO/00001/2000",
                  "requerente": "Beltrano De Tal",
                  "email": "BELTRANO.DETAL@EXAMPLE.INVALID",
                  "criador_id": 999998,
                  "local": "Rua Exemplo 9, 1000-000 Lisboa",
                  "descricao": "Lixo acumulado mais acima na rua, junto ao jardim.",
                  "tipo": "Sacos ou outros lixos abandonados",
                  "tipo_id": 262,
                  "geo_x": -87369.1457760187,
                  "geo_y": -106276.89242727536,
                  "area": "Higiene Urbana",
                  "area_oco_id": 10,
                  "freg_descricao": "Freguesia Exemplo",
                  "naminharua_estado": "Em curso"
                },
                {
                  "id": 1000002,
                  "numero": "OCO/00002/2000",
                  "requerente": "Cicrano De Tal",
                  "email": "CICRANO.DETAL@EXAMPLE.INVALID",
                  "criador_id": 999997,
                  "local": "Rua Exemplo 40, 1000-000 Lisboa",
                  "descricao": "Recolhido pelos serviços na semana passada.",
                  "tipo": "Sacos ou outros lixos abandonados",
                  "tipo_id": 262,
                  "geo_x": -87259.1457760187,
                  "geo_y": -106166.89242727536,
                  "area": "Higiene Urbana",
                  "area_oco_id": 10,
                  "freg_descricao": "Freguesia Exemplo",
                  "naminharua_estado": "Resolvido"
                }
                """)

        /// `ocoTipo=256`. The open entry sits 8 m from the reference point — near
        /// enough that the mattress on the pavement and the report about to be
        /// filed on top of it are plainly the same thing.
        /// The same booked collection, moved to the far end of the window this
        /// warning can fire in at all.
        ///
        /// Not a variation for variation's sake. `apply` already drops anything
        /// past `Submitter.duplicateRadiusMetres`, so the whole range this
        /// warning speaks about is 0–50 m — and a real collection request
        /// across the road at the far end of it was still getting a filled red
        /// "don't file this". That is the weakest evidence in the window
        /// drawing the loudest card in the set. It has a scene so the softer of
        /// the two can never quietly regress into the louder one.
        static let farCollectionNearBy = geoAttributes(
            nearBy: """
                {
                  "id": 1000100,
                  "numero": "OCO/00100/2000",
                  "requerente": "Sicrano De Tal",
                  "email": "SICRANO.DETAL@EXAMPLE.INVALID",
                  "criador_id": 999900,
                  "local": "Rua Exemplo 210, 1000-000 Lisboa",
                  "descricao": "Colchão e duas cadeiras para recolha.",
                  "tipo": "Remoção-Monstros-Pedido de recolha",
                  "tipo_id": 256,
                  "geo_x": -87226.3457760187,
                  "geo_y": -106170.49242727536,
                  "area": "Higiene Urbana",
                  "area_oco_id": 10,
                  "freg_descricao": "Freguesia Exemplo",
                  "naminharua_estado": "Em curso"
                }
                """)

        static let collectionNearBy = geoAttributes(
            nearBy: """
                {
                  "id": 1000100,
                  "numero": "OCO/00100/2000",
                  "requerente": "Sicrano De Tal",
                  "email": "SICRANO.DETAL@EXAMPLE.INVALID",
                  "criador_id": 999900,
                  "local": "Rua Exemplo 210, 1000-000 Lisboa",
                  "descricao": "Colchão e duas cadeiras para recolha.",
                  "tipo": "Remoção-Monstros-Pedido de recolha",
                  "tipo_id": 256,
                  "geo_x": -87264.3457760187,
                  "geo_y": -106170.49242727536,
                  "area": "Higiene Urbana",
                  "area_oco_id": 10,
                  "freg_descricao": "Freguesia Exemplo",
                  "naminharua_estado": "Em curso"
                },
                {
                  "id": 1000101,
                  "numero": "OCO/00101/2000",
                  "requerente": "Fulana De Tal",
                  "email": "FULANA.DETAL@EXAMPLE.INVALID",
                  "criador_id": 999901,
                  "local": "Rua Exemplo 44, 1000-000 Lisboa",
                  "descricao": "Sofá já recolhido.",
                  "tipo": "Remoção-Monstros-Pedido de recolha",
                  "tipo_id": 256,
                  "geo_x": -87251.1457760187,
                  "geo_y": -106152.89242727536,
                  "area": "Higiene Urbana",
                  "area_oco_id": 10,
                  "freg_descricao": "Freguesia Exemplo",
                  "naminharua_estado": "Resolvido"
                }
                """)

        static let emptyNearBy = geoAttributes(nearBy: "")

        /// The identifying fields above — `requerente`, `email`, `criador_id`,
        /// `local` — are here on purpose, exactly as the real server sends them.
        /// `NearByOccurrence` declares no `CodingKey` for any of them, so none
        /// survives parsing and none can reach a screenshot or a model provider.
        /// See `PrivacyTests`.
        /// The booked collection, decoded — for the sheet that compares it
        /// against the pin. Same bytes the warning itself is built from, so the
        /// screenshot cannot drift from the card that leads to it.
        static var bookedCollection: NearByOccurrence {
            let attributes = try! JSONDecoder().decode(
                GeoAttributes.self, from: collectionNearBy)
            return attributes.nearBy[0]
        }

        private static func geoAttributes(nearBy: String) -> Data {
            Data(
                """
                {
                  "morada": [
                    {
                      "idtipo": "2",
                      "morada": "Rua Exemplo, 210",
                      "cod_sig": "1000000000000",
                      "objectid": 111111,
                      "freguesia": "121",
                      "codlocal_todos": null,
                      "nprincip": null
                    }
                  ],
                  "freguesia": "121",
                  "freguesia_nome": "Freguesia Exemplo",
                  "PFM": "-1",
                  "UIT": "59",
                  "EVENE": "-1",
                  "COD_LOCAL": "00000",
                  "nearBy": [\(nearBy)]
                }
                """.utf8)
        }

        /// One Messages API response, shaped like Anthropic's. The judge answers
        /// with **positions in the list it was sent**, never occurrence numbers —
        /// somebody else's report number is theirs.
        static let judgeResponse: Data = {
            let verdict =
                #"{\"duplicate_of\": [1], \"reason\": \"O pedido de recolha a 8 m descreve o mesmo colchão e continua por resolver.\"}"#
            return Data(
                """
                {
                  "id": "msg_screenshot",
                  "type": "message",
                  "role": "assistant",
                  "stop_reason": "end_turn",
                  "content": [{"type": "text", "text": "\(verdict)"}]
                }
                """.utf8)
        }()

        static let dryRunPayload = """
            {
              "descricao" : "Sacos de lixo abandonados junto aos contentores, há vários dias.",
              "geo" : {
                "cod_sig" : "",
                "cod_sig_original" : "1000000000000",
                "freguesia_id" : 121,
                "freguesia_nome" : "Freguesia Exemplo",
                "id_tipo" : "",
                "id_tipo_original" : "2",
                "lat" : 38.70757,
                "lon" : -9.1364,
                "morada" : "Rua Exemplo, 210",
                "n_pol" : " 210",
                "x" : -87262.1457760187,
                "y" : -106165.89242727536
              },
              "referencia" : "",
              "tipo_ocorrencia_id" : 262
            }
            """
    }

#endif
