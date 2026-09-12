import Observation
import XCTest

/// What `AppDelegate` follows on the store, kept honest against what the store actually has.
///
/// **The check this file exists for.** Under `ObservableObject` the app delegate subscribed to
/// `objectWillChange`, which covered every `@Published` property including ones added later — the
/// dependency was implicit and could not go stale. Under `@Observable` a non-SwiftUI observer has to
/// name what it reads, and a property added without being added to that list is simply never noticed:
/// the menubar quietly stops reacting to one kind of change, with nothing logged and nothing failing.
/// So the list is compared against the type.
///
/// **And the other direction, which is the migration's own trap.** `@Observable` instruments *every*
/// stored `var`, not just the ones that used to be `@Published`. A store's private bookkeeping —
/// its Combine bag, the key it is bound to — was deliberately not published, and becomes an
/// invalidation source for every SwiftUI view the moment the macro is applied. The rule this file
/// enforces is therefore: what used to be `@Published` is observable, and everything else carries
/// `@ObservationIgnored`.
@MainActor
final class PMStoreObservationTests: XCTestCase {

    /// The property names the `@Observable` macro instrumented, read off the instance.
    ///
    /// The macro rewrites each observed stored property into a computed one over an underscored
    /// backing field, so the underscored children of the mirror *are* the observable surface. Reading
    /// them through `Mirror` touches the storage rather than the accessor, so this does not itself
    /// register as a dependency.
    private func observableProperties(of store: PMStore) -> Set<String> {
        Set(Mirror(reflecting: store).children.compactMap { child -> String? in
            guard let label = child.label,
                  label.hasPrefix("_"),
                  label != "_$observationRegistrar" else { return nil }
            return String(label.dropFirst())
        })
    }

    /// Only one direction is checked, and it is the one that can fail silently: a stored property the
    /// app delegate does not follow. The other direction cannot go wrong — every entry in the list
    /// *reads* its property, so a name for something that no longer exists would not compile. Some
    /// entries deliberately name computed pass-throughs to `ProjectIndex`, which have no stored
    /// property here at all.
    func testEveryObservablePropertyOfTheStoreIsFollowed() {
        let observable = observableProperties(of: PMStore(boundKey: nil))
        let tracked = Set(PMStore.appDelegateDependencies.map(\.name))

        let unfollowed = observable.subtracting(tracked).sorted()
        XCTAssertTrue(unfollowed.isEmpty,
                      "\(unfollowed.joined(separator: ", ")) would invalidate every view that reads "
                      + "the store and never wake the app delegate. Either add it to "
                      + "trackForAppDelegate and appDelegateDependencies, or mark it "
                      + "@ObservationIgnored if it is bookkeeping rather than state.")

    }

    /// The names are distinct, so a copy-pasted entry — the way a list like this goes wrong — does
    /// not hide a missing property behind a duplicate that makes the counts look right.
    func testNoDependencyIsListedTwice() {
        let names = PMStore.appDelegateDependencies.map(\.name)
        XCTAssertEqual(Set(names).count, names.count,
                       "duplicated: " + Dictionary(grouping: names, by: { $0 })
                           .filter { $0.value.count > 1 }.keys.sorted().joined(separator: ", "))
    }
}
