import Foundation
import os

/// What this client did, kept for the times a report does not go through.
///
/// A submission that fails in the street is the one failure this app must never
/// ask somebody to reproduce: trying again is a second work order, and the
/// portal has no undo. So the facts that would explain a failure are recorded as
/// they happen, and the ones that would identify a person or a place are not.
///
/// **The privacy line is the one `NearByOccurrence` already draws.** Statuses,
/// byte counts, durations and paths are `.public` — they are exactly what
/// somebody would paste into a bug report, and none of them says who or where.
/// Anything carrying a coordinate, an address, a description or a response body
/// stays private, which is `os.Logger`'s default for strings: the unified log
/// stores it redacted unless the device is attached to a debugger. A log that
/// records where somebody was standing is a log that should not have been
/// written.
///
/// Note that a query string is *not* a path — `getGeoAttributes/?x=…&y=…` is a
/// location. `PortalClient` logs the path and the names of the query keys, never
/// their values.
///
/// **The level is chosen for what survives, not for how interesting it is.**
/// The unified log keeps `.notice` and above on disk and throws `.debug` away
/// unless something is attached and streaming. So anything needed to explain a
/// failure *after* the fact — the submission's photo count and byte sizes, and
/// every error — is `.notice` or `.error`. The per-request trace is `.debug`:
/// it is a live-debugging convenience, and a report costing one line rather
/// than a dozen is what keeps the persistent log readable.
///
/// Read it back with either of:
/// ```sh
/// # what is kept: the submissions and the failures
/// log show   --predicate 'subsystem == "com.ardennl.Repara"' --last 1h
///
/// # the full request trace, live, while reproducing something
/// log stream --predicate 'subsystem == "com.ardennl.Repara"' --level debug
/// ```
public enum Log {
    /// The app's bundle identifier, so Console.app groups this with the app
    /// rather than with an unrecognised subsystem.
    static let subsystem = "com.ardennl.Repara"

    /// Every request that leaves the phone, and what came back.
    public static let portal = Logger(subsystem: subsystem, category: "portal")

    /// The irreversible one. Logged in more detail than anything else here,
    /// because it is the only call in this client that cannot be retried for
    /// free.
    public static let submit = Logger(subsystem: subsystem, category: "submit")

    /// What the camera handed over and what the council is going to get.
    public static let photos = Logger(subsystem: subsystem, category: "photos")
}

extension Duration {
    /// Whole milliseconds, which is the only resolution a log line about a
    /// municipal server needs.
    var milliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds * 1000 + attoseconds / 1_000_000_000_000_000)
    }
}
