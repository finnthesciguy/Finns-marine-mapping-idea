import Foundation
import Persistence

/// Disclaimer acceptance stored with Persistence's `SettingKey.disclaimerAcknowledgement`. The app's store.
public final class PersistenceAcknowledgementStore: AcknowledgementStore {
    public let store: PersistenceStore

    public init(store: PersistenceStore) {
        self.store = store
    }

    public func disclaimerAcknowledgement() async throws -> DisclaimerRecord? {
        let key: SettingKey<DisclaimerAcknowledgement?> = .disclaimerAcknowledgement
        let value: DisclaimerAcknowledgement? = try await store.setting(key)
        guard let value else { return nil }
        return DisclaimerRecord(version: value.version, date: value.date)
    }

    public func acknowledgeDisclaimer(_ record: DisclaimerRecord) async throws {
        let key: SettingKey<DisclaimerAcknowledgement?> = .disclaimerAcknowledgement
        let value: DisclaimerAcknowledgement? = DisclaimerAcknowledgement(version: record.version, date: record.date)
        try await store.setSetting(key, to: value)
    }
}

extension AppPaths {
    /// Opens (creating if needed) the app's Persistence store at `storeURL`. Prefer `StoreOpener.open(paths:)`,
    /// which never fails and reports what happened.
    public func openStore() throws -> PersistenceStore {
        try prepare()
        return try PersistenceStore(url: storeURL)
    }
}

/// Moves a disclaimer acceptance stored by an earlier build (UserDefaults) into the Persistence store.
public enum AcknowledgementMigration {
    public enum Outcome: Sendable, Equatable {
        /// The legacy store holds nothing.
        case nothingToMigrate
        /// Copied into the target (and removed from the legacy store when asked to).
        case migrated(DisclaimerRecord)
        /// The target already had an acceptance at least as new; the legacy copy was dropped (when asked to).
        case targetAlreadyCurrent
        /// Writing to the target failed; the legacy copy was kept.
        case failed(String)
    }

    /// - Parameter removeLegacy: delete the legacy copy once the target holds it. Pass false when the target
    ///   is a temporary (in-memory) store, so the acceptance is not lost at the next launch.
    public static func run(from legacy: any RemovableAcknowledgementStore, to target: any AcknowledgementStore,
                           removeLegacy: Bool) async -> Outcome {
        var old: DisclaimerRecord? = nil
        do {
            old = try await legacy.disclaimerAcknowledgement()
        } catch {
            old = nil
        }
        guard let old else { return .nothingToMigrate }
        var current: DisclaimerRecord? = nil
        do {
            current = try await target.disclaimerAcknowledgement()
        } catch {
            current = nil
        }
        if let current, current.version >= old.version {
            if removeLegacy { try? await legacy.removeDisclaimerAcknowledgement() }
            return .targetAlreadyCurrent
        }
        do {
            try await target.acknowledgeDisclaimer(old)
        } catch {
            return .failed(String(describing: error))
        }
        if removeLegacy { try? await legacy.removeDisclaimerAcknowledgement() }
        return .migrated(old)
    }
}
