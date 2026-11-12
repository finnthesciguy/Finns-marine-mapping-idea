import Foundation

/// The first-launch navigation disclaimer (PLAN.md D5).
public enum Disclaimer {
    /// Bump to ask every user again (for example after the text changes materially).
    public static let currentVersion = 1

    public static let title = "Before you use Gulf Nav"

    public static let points: [String] = [
        "This app is not certified for navigation. It is an aid to situational awareness only.",
        "It is not a substitute for official NOAA charts, Notices to Mariners, or the equipment and charts required for your vessel.",
        "Chart data comes from NOAA and is provided as-is, without warranty. It may be out of date or wrong. Each chart region shows its data date.",
        "Routes and positions are suggestions. The skipper is responsible for checking every route and for the safe navigation of the vessel.",
        "This app is not affiliated with or endorsed by NOAA.",
    ]

    public static let acceptButtonTitle = "I understand and accept"

    /// True when the stored acknowledgement is missing or for an older text.
    public static func needsAcknowledgement(_ record: DisclaimerRecord?, currentVersion: Int = Disclaimer.currentVersion) -> Bool {
        guard let record else { return true }
        return record.version < currentVersion
    }
}

/// A stored acceptance of the disclaimer. Mirrors Persistence's `DisclaimerAcknowledgement`.
public struct DisclaimerRecord: Sendable, Equatable, Codable {
    public var version: Int
    public var date: Date

    public init(version: Int, date: Date) {
        self.version = version
        self.date = date
    }
}

/// Where the disclaimer acceptance is stored.
///
/// The intended implementation is Persistence's `SettingKey.disclaimerAcknowledgement`
/// (`PersistenceAcknowledgementStore`, compiled when Package.swift's `includePersistence` is on). Until
/// ChartKit and Persistence can be linked into one app (both declare a target named `CSQLite`; see
/// App/README.md), the app uses `UserDefaultsAcknowledgementStore`.
public protocol AcknowledgementStore: Sendable {
    func disclaimerAcknowledgement() async throws -> DisclaimerRecord?
    func acknowledgeDisclaimer(_ record: DisclaimerRecord) async throws
}

/// In memory, for previews and tests.
public actor InMemoryAcknowledgementStore: AcknowledgementStore {
    private var record: DisclaimerRecord?

    public init(record: DisclaimerRecord? = nil) {
        self.record = record
    }

    public func disclaimerAcknowledgement() async throws -> DisclaimerRecord? { record }

    public func acknowledgeDisclaimer(_ record: DisclaimerRecord) async throws {
        self.record = record
    }
}

/// `UserDefaults`, JSON-encoded under one key. Interim store (see `AcknowledgementStore`).
public final class UserDefaultsAcknowledgementStore: AcknowledgementStore {
    public static let defaultKey = "legal.disclaimerAcknowledgement"

    private let suiteName: String?
    private let key: String

    /// - Parameter suiteName: nil for `UserDefaults.standard`.
    public init(suiteName: String? = nil, key: String = UserDefaultsAcknowledgementStore.defaultKey) {
        self.suiteName = suiteName
        self.key = key
    }

    private func defaults() -> UserDefaults {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) { return suite }
        return UserDefaults.standard
    }

    public func disclaimerAcknowledgement() async throws -> DisclaimerRecord? {
        guard let data = defaults().data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(DisclaimerRecord.self, from: data)
    }

    public func acknowledgeDisclaimer(_ record: DisclaimerRecord) async throws {
        let data: Data = try JSONEncoder().encode(record)
        defaults().set(data, forKey: key)
    }
}
