import SwiftUI

/// Two kinds of looking, in one place: what you have filed, and what the
/// council already has near a point.
///
/// They sit behind one toolbar button because they answer the same question at
/// different scopes — "has this been dealt with?" — and because the app has
/// exactly one thing to do besides looking, which is filing, and that lives on
/// the screen behind this one.
struct ReportsView: View {
    @Environment(AppModel.self) private var model

    enum Tab: Hashable {
        case mine
        case nearby
    }

    /// Starts on Mine, which costs one request the user has already paid for by
    /// signing in. Nearby only asks the council anything once it is chosen.
    @State private var tab: Tab

    init(initialTab: Tab = .mine) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Which reports", selection: $tab) {
                Text("Mine").tag(Tab.mine)
                Text("Nearby").tag(Tab.nearby)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            switch tab {
            case .mine:
                StatusView()
            case .nearby:
                NearbyView(browser: model.browse)
            }
        }
        .background(Repara.canvas)
        .navigationTitle("Reports")
        .navigationBarTitleDisplayMode(.inline)
    }
}
