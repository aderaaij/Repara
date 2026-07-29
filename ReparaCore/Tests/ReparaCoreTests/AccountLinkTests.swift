import Foundation
import Testing

@testable import ReparaCore

/// Repara does not host a sign-up form. Creating an account and resetting a
/// password hand off to the council's own pages, for reasons that are as much
/// about consent as about protocol: registration gates on the Política de
/// Privacidade and the Informação sobre Proteção de Dados, and an unofficial
/// client is not in a position to collect that agreement on the council's
/// behalf. No registration endpoint appears anywhere in the captured session
/// either, so a native form would be posting to a guessed URL.
///
/// The Settings screen builds those rows with `if let url = URL(string:)`, which
/// fails by quietly rendering nothing — a signed-out user would be left with a
/// login form and no way to get an account. These tests are what stops that
/// being silent.
@Suite("Account links")
struct AccountLinkTests {

    @Test("the account pages parse as URLs")
    func urlsParse() throws {
        #expect(URL(string: Portal.registration) != nil)
        #expect(URL(string: Portal.passwordRecovery) != nil)
    }

    /// These send the user somewhere to type a password. If a refactor ever
    /// repoints them off the council's own origin, that is a phishing surface
    /// shipped inside an app whose whole pitch is that it is trustworthy about
    /// the portal.
    @Test("they point at the council's own site over TLS")
    func stayOnTheCouncilOrigin() throws {
        for link in [Portal.registration, Portal.passwordRecovery] {
            let url = try #require(URL(string: link))
            #expect(url.scheme == "https")
            #expect(url.host() == "naminharualx.cm-lisboa.pt")
        }
    }

    /// `login.jsp` links to `registo.html` as "Crie um novo utilizador", and to
    /// the same page under a `#/pass_recover/` client-side route. The fragment
    /// is the whole difference between the two, so a copy-paste that drops it
    /// would send someone wanting a password reset to a blank sign-up form.
    @Test("password recovery keeps the route that distinguishes it")
    func recoveryKeepsItsFragment() throws {
        #expect(Portal.passwordRecovery.hasPrefix(Portal.registration))
        #expect(URL(string: Portal.passwordRecovery)?.fragment() == "/pass_recover/")
        #expect(URL(string: Portal.registration)?.fragment() == nil)
    }
}
