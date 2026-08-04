#if DEBUG

    import ReparaCore
    import SwiftUI

    /// One screen per launch, selected by `--screenshot-scene`.
    ///
    /// Screens that live inside the signed-in flow go through the real
    /// `RootView`, so what gets photographed is the actual navigation chrome and
    /// the actual stage machine. The rest are the sheets and pushed screens that
    /// `RootView` would otherwise hide behind a tap, presented directly because a
    /// screenshot cannot tap.
    ///
    /// **Nothing renders until staging has finished.** Views load their own data
    /// in `.task` the moment they appear — `StatusView` decides it is signed out,
    /// `NearbyView` starts a search of its own — and a screen that raced the setup
    /// photographs an error message instead of the feature.
    struct ScreenshotHost: View {
        @Environment(AppModel.self) private var model

        @State private var ready = false
        @State private var pickerSelection: TipoOcorrencia? =
            Taxonomy.bundled.types.first { $0.id == 262 }

        var body: some View {
            Group {
                if ready {
                    scene
                } else {
                    Color(.systemBackground).ignoresSafeArea()
                }
            }
            .task {
                await ScreenshotMode.stage(model)
                ready = true

                // Only now does a scroll view exist to scroll. Twice, because a
                // list that is still laying out clamps the first attempt to a
                // content height it is about to outgrow.
                try? await Task.sleep(for: .milliseconds(700))
                ScreenshotMode.applyScroll()
                try? await Task.sleep(for: .milliseconds(500))
                ScreenshotMode.applyScroll()
            }
        }

        @ViewBuilder private var scene: some View {
            switch ScreenshotMode.scene {
            case "launch":
                LaunchView()

            case "welcome":
                WelcomeView()

            case "sign-in":
                SignInView()

            case "types":
                NavigationStack { TypeCatalogueView() }

            case "settings", "settings-gemini":
                SettingsView()

            case "type-picker":
                TypePickerView(selection: $pickerSelection, onPick: {})

            // The sheet the red card now leads to. Presented directly because a
            // screenshot cannot tap, and photographed at all because the whole
            // point of the change is that this screen exists — a warning saying
            // "don't file this" about a report nobody can see is a warning
            // asking to be taken on faith.
            case "occurrence-compare":
                OccurrenceSheet(
                    report: ScreenshotMode.bookedCollectionFixture,
                    comparedTo: Projection.reference.wgs84)

            case "reports-mine":
                NavigationStack { ReportsView(initialTab: .mine) }

            // The screen behind a row on the one above. Presented directly
            // because a screenshot cannot tap, and inside a `NavigationStack`
            // because that is what it is pushed onto in the app.
            case "my-report":
                NavigationStack {
                    MyReportDetailView(report: ScreenshotMode.myReportFixture)
                }

            case "browse-empty", "browse-results", "browse-nothing", "browse-filtered":
                NavigationStack { ReportsView(initialTab: .nearby) }

            default:
                // capture, drafting, review*, dry-run, filed — all of them are
                // stages of the one flow, so they are photographed through it.
                RootView()
            }
        }
    }

#endif
