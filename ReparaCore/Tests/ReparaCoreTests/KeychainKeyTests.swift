import Foundation
import Testing

@testable import ReparaCore

/// `Keychain.Key.rawValue` is the `kSecAttrAccount` a secret is filed under, so
/// it is storage, not naming. Changing one does not migrate anything — it makes
/// the app look in a drawer nobody has ever put anything in, and the old secret
/// stays on the device unreachable.
///
/// These are cheap because they touch no Keychain: they read the case names,
/// which is exactly where the hazard is.
@Suite("Keychain keys")
struct KeychainKeyTests {

    /// `claude-api-key` was the account name before the app spoke to anyone but
    /// Anthropic. It has to keep it: someone who stored a key in an earlier
    /// build should not be silently asked for it again after updating.
    ///
    /// The portal credentials are the same argument with worse consequences —
    /// losing those signs the user out of the service the app exists to file
    /// with.
    @Test("account names already on people's devices never change")
    func storedAccountNamesAreStable() {
        #expect(Keychain.Key.claudeAPIKey.rawValue == "claude-api-key")
        #expect(Keychain.Key.portalUsername.rawValue == "portal-username")
        #expect(Keychain.Key.portalPassword.rawValue == "portal-password")
    }

    /// Two keys sharing an account name is not a compile error and not a
    /// runtime error: the second `set` silently overwrites the first, so
    /// storing an OpenAI key would erase the Gemini one and both providers
    /// would then authenticate with whichever was saved last.
    @Test("no two keys share an account name")
    func accountNamesAreUnique() {
        let names = Keychain.Key.allCases.map(\.rawValue)
        #expect(Set(names).count == names.count)
    }

    /// `removeAll` iterates `allCases`, and signing out is the only thing that
    /// clears secrets wholesale. A provider key added to the enum but somehow
    /// absent from `allCases` would survive a sign-out on a shared device.
    @Test("every key is reachable from allCases")
    func allCasesCoversEveryKey() {
        #expect(Keychain.Key.allCases.count == 5)
        for key in Keychain.Key.allCases {
            #expect(!key.rawValue.isEmpty)
        }
    }
}
