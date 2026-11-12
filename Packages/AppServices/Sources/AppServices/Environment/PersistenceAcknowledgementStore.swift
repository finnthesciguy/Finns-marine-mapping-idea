// Compiled only when Package.swift's `includePersistence` is true (it defines APPSERVICES_PERSISTENCE and
// adds the Persistence dependency). It is off because ChartKit and Persistence both declare a target named
// `CSQLite`, and SwiftPM refuses a package graph containing both ("target names need to be unique across
// the package graph"). Rename one of them (see App/README.md, "Needed in existing packages"), then flip the
// switch. This file was compiled and tested on Linux against Persistence in a scratch package.
#if APPSERVICES_PERSISTENCE
import Foundation
import Persistence

/// Disclaimer acceptance stored with Persistence's `SettingKey.disclaimerAcknowledgement`.
public final class PersistenceAcknowledgementStore: AcknowledgementStore {
    private let store: PersistenceStore

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
    /// Opens (creating if needed) the app's Persistence store at `storeURL`.
    public func openStore() throws -> PersistenceStore {
        try prepare()
        return try PersistenceStore(url: storeURL)
    }
}
#endif
