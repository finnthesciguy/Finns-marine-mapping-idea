import Foundation
import Persistence

/// The notice the skipper must acknowledge before the first auto-route plan (PLAN.md D5), and again whenever
/// its text changes (bump ``version``). Stored in Persistence settings.
public enum AutoRouteNotice {
    /// Version of the text below. Bump it when the wording changes in substance: everyone is asked again.
    public static let version: Int = 1

    public static let title: String = "Auto-routes are suggestions"

    public static let points: [String] = [
        "An auto-route is a suggestion computed from chart data. It is not a safe route and not a substitute for official charts, local knowledge or a proper lookout.",
        "Review every leg before you use it. Green legs meet your boat's draft and air draft on charted data; yellow legs rely on something you must check yourself, and each says why.",
        "Depths are charted depths at chart datum (mean lower low water). No tide is added. Gulf water levels often fall below datum in winter northers, and channels shoal between surveys.",
        "Each route shows the date of the chart data it was computed from. Older data is less reliable, especially in passes and inlets.",
    ]

    public static let acceptLabel: String = "I understand"

    /// The whole notice as one text (title, then the points).
    public static var fullText: String {
        ([title] + points.map { "• " + $0 }).joined(separator: "\n")
    }

    /// True when `acknowledgement` covers the current text.
    public static func isAcknowledged(_ acknowledgement: DisclaimerAcknowledgement?, currentVersion: Int = AutoRouteNotice.version) -> Bool {
        guard let acknowledgement else { return false }
        return acknowledgement.version >= currentVersion
    }
}

extension SettingKey where Value == DisclaimerAcknowledgement? {
    /// The skipper's acknowledgement of ``AutoRouteNotice`` (version and date).
    public static var autoRouteNoticeAcknowledgement: Self { .init("autoroute.noticeAcknowledgement", default: nil) }
}

/// Reads and records the acknowledgement of ``AutoRouteNotice`` in a Persistence store.
public struct AutoRouteNoticeGate: Sendable {
    public let store: PersistenceStore
    public let currentVersion: Int

    public init(store: PersistenceStore, currentVersion: Int = AutoRouteNotice.version) {
        self.store = store
        self.currentVersion = currentVersion
    }

    /// True when the notice must be shown (never acknowledged, an older version, or unreadable).
    public func needsAcknowledgement() async -> Bool {
        let stored: DisclaimerAcknowledgement?
        do {
            stored = try await store.setting(.autoRouteNoticeAcknowledgement)
        } catch {
            return true
        }
        return !AutoRouteNotice.isAcknowledged(stored, currentVersion: currentVersion)
    }

    public func acknowledge(now: Date = Date()) async throws {
        try await store.setSetting(.autoRouteNoticeAcknowledgement,
                                   to: DisclaimerAcknowledgement(version: currentVersion, date: now))
    }
}
