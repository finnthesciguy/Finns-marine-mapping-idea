import Foundation
import NavCore
import Persistence
import RoutingKit

/// Defaults and limits for boat profiles.
public enum BoatProfileDefaults {
    /// Values a new profile starts with (the user is expected to change them): a typical Gulf Coast cruiser.
    public static let name: String = "My boat"
    public static let draft: Distance = .feet(4.5)
    public static let safetyMargin: Distance = .feet(1.5)
    public static let airDraft: Distance = .feet(20)
    public static let cruisingSpeed: Speed = .knots(6)

    /// Upper limits accepted by the form (generous, but they catch a unit mix-up such as metres typed as feet
    /// the other way round, and stay well inside RoutingKit's 1000 ft limit).
    public static let maximumDraft: Distance = .feet(40)
    public static let maximumSafetyMargin: Distance = .feet(20)
    public static let maximumAirDraft: Distance = .feet(250)
    public static let maximumBeam: Distance = .feet(100)
    public static let maximumCruisingSpeed: Speed = .knots(60)
    public static let maximumNameLength: Int = 40

    /// A new, unsaved profile with the default values.
    public static func newProfile(isDefault: Bool = false, now: Date = Date()) -> Persistence.BoatProfile {
        Persistence.BoatProfile(name: name, draft: draft, safetyMargin: safetyMargin, airDraft: airDraft, beam: nil,
                                cruisingSpeed: cruisingSpeed, useMaintainedChannels: false,
                                acceptUnknownClearance: false, isDefault: isDefault, createdAt: now)
    }
}

/// One problem with a boat profile form.
public struct BoatProfileProblem: Sendable, Equatable {
    public enum Field: String, Sendable, Equatable {
        case name, draft, safetyMargin, airDraft, beam, cruisingSpeed
    }

    public var field: Field
    public var message: String

    public init(field: Field, message: String) {
        self.field = field
        self.message = message
    }
}

/// The add/edit form of a boat profile: text fields in the user's units, parsed and checked here.
///
/// Lengths (draft, safety margin, air draft, beam) use the depth unit from Settings (feet, metres or
/// fathoms); cruising speed uses the speed unit. Persistence stores metres and m/s.
public struct BoatProfileForm: Sendable, Equatable {
    public var name: String
    public var draft: String
    public var safetyMargin: String
    public var airDraft: String
    public var beam: String
    public var cruisingSpeed: String
    public var useMaintainedChannels: Bool
    public var acceptUnknownClearance: Bool
    public var isDefault: Bool
    public var lengthUnit: DepthUnit
    public var speedUnit: SpeedUnit

    /// The form for an existing profile, or for a new one with ``BoatProfileDefaults`` when `profile` is nil.
    public init(profile: Persistence.BoatProfile?, units: UnitPreferences, makeDefault: Bool = false) {
        let p: Persistence.BoatProfile = profile ?? BoatProfileDefaults.newProfile(isDefault: makeDefault)
        lengthUnit = units.depth
        speedUnit = units.speed
        name = p.name
        draft = BoatProfileForm.lengthText(p.draft, unit: units.depth)
        safetyMargin = BoatProfileForm.lengthText(p.safetyMargin, unit: units.depth)
        airDraft = p.airDraft.map { BoatProfileForm.lengthText($0, unit: units.depth) } ?? ""
        beam = p.beam.map { BoatProfileForm.lengthText($0, unit: units.depth) } ?? ""
        cruisingSpeed = p.cruisingSpeed.map { BoatProfileForm.speedText($0, unit: units.speed) } ?? ""
        useMaintainedChannels = p.useMaintainedChannels
        acceptUnknownClearance = p.acceptUnknownClearance
        isDefault = p.isDefault || makeDefault
    }

    /// "ft", "m", "fm".
    public var lengthUnitSymbol: String { BoatProfileForm.symbol(lengthUnit) }
    /// "kn", "mph", "km/h".
    public var speedUnitSymbol: String { BoatProfileForm.symbol(speedUnit) }

    /// Everything wrong with the form (empty when it can be saved).
    public var problems: [BoatProfileProblem] {
        switch build(onto: nil) {
        case .success: return []
        case .failure(let list): return list.problems
        }
    }

    /// The profile to save: `existing` updated (id, creation date kept), or a new profile.
    public func profile(updating existing: Persistence.BoatProfile?, now: Date = Date()) -> Result<Persistence.BoatProfile, BoatProfileProblems> {
        build(onto: existing, now: now)
    }

    func build(onto existing: Persistence.BoatProfile?, now: Date = Date()) -> Result<Persistence.BoatProfile, BoatProfileProblems> {
        var problems: [BoatProfileProblem] = []
        let trimmedName: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            problems.append(BoatProfileProblem(field: .name, message: "Enter a name for the boat."))
        } else if trimmedName.count > BoatProfileDefaults.maximumNameLength {
            problems.append(BoatProfileProblem(field: .name, message: "Use a name of at most \(BoatProfileDefaults.maximumNameLength) characters."))
        }
        let unit: String = lengthUnitSymbol
        let draftValue: Distance? = parseLength(draft, field: .draft, label: "Draft", required: true, allowZero: false,
                                                maximum: BoatProfileDefaults.maximumDraft, unit: unit, into: &problems)
        let marginValue: Distance? = parseLength(safetyMargin, field: .safetyMargin, label: "Safety margin", required: true,
                                                 allowZero: true, maximum: BoatProfileDefaults.maximumSafetyMargin, unit: unit,
                                                 into: &problems)
        let airValue: Distance? = parseLength(airDraft, field: .airDraft, label: "Air draft", required: true, allowZero: false,
                                              maximum: BoatProfileDefaults.maximumAirDraft, unit: unit, into: &problems)
        let beamValue: Distance? = parseLength(beam, field: .beam, label: "Beam", required: false, allowZero: false,
                                               maximum: BoatProfileDefaults.maximumBeam, unit: unit, into: &problems)
        var speedValue: Speed? = nil
        let speedText: String = cruisingSpeed.trimmingCharacters(in: .whitespaces)
        if !speedText.isEmpty {
            if let number = BoatProfileForm.number(speedText), number > 0 {
                let speed: Speed = BoatProfileForm.speed(number, unit: speedUnit)
                if speed > BoatProfileDefaults.maximumCruisingSpeed {
                    problems.append(BoatProfileProblem(field: .cruisingSpeed, message: "Cruising speed looks too high (at most \(BoatProfileForm.speedText(BoatProfileDefaults.maximumCruisingSpeed, unit: speedUnit)) \(speedUnitSymbol))."))
                } else {
                    speedValue = speed
                }
            } else {
                problems.append(BoatProfileProblem(field: .cruisingSpeed, message: "Cruising speed must be a number above 0 \(speedUnitSymbol), or left empty."))
            }
        }
        guard problems.isEmpty, let draftValue, let marginValue, let airValue else {
            return .failure(BoatProfileProblems(problems: problems))
        }
        var profile: Persistence.BoatProfile = existing ?? Persistence.BoatProfile(name: trimmedName, draft: draftValue, createdAt: now)
        profile.name = trimmedName
        profile.draft = draftValue
        profile.safetyMargin = marginValue
        profile.airDraft = airValue
        profile.beam = beamValue
        profile.cruisingSpeed = speedValue
        profile.useMaintainedChannels = useMaintainedChannels
        profile.acceptUnknownClearance = acceptUnknownClearance
        profile.isDefault = isDefault
        return .success(profile)
    }

    private func parseLength(_ text: String, field: BoatProfileProblem.Field, label: String, required: Bool, allowZero: Bool,
                             maximum: Distance, unit: String, into problems: inout [BoatProfileProblem]) -> Distance? {
        let trimmed: String = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if required { problems.append(BoatProfileProblem(field: field, message: "Enter the \(label.lowercased()) in \(unit).")) }
            return nil
        }
        guard let number = BoatProfileForm.number(trimmed), number >= 0, allowZero || number > 0 else {
            let rule: String = allowZero ? "0 or more" : "above 0"
            problems.append(BoatProfileProblem(field: field, message: "\(label) must be a number \(rule) \(unit)."))
            return nil
        }
        let value: Distance = BoatProfileForm.length(number, unit: lengthUnit)
        if value > maximum {
            problems.append(BoatProfileProblem(field: field, message: "\(label) looks too large (at most \(BoatProfileForm.lengthText(maximum, unit: lengthUnit)) \(unit)). Check the unit."))
            return nil
        }
        return value
    }

    // MARK: Units

    /// Parses "4.5", "4,5", " 12 ". Nil for anything else (including NaN and infinity).
    public static func number(_ text: String) -> Double? {
        let cleaned: String = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }

    public static func length(_ value: Double, unit: DepthUnit) -> Distance {
        switch unit {
        case .feet: return .feet(value)
        case .meters: return .meters(value)
        case .fathoms: return .fathoms(value)
        }
    }

    public static func speed(_ value: Double, unit: SpeedUnit) -> Speed {
        switch unit {
        case .knots: return .knots(value)
        case .milesPerHour: return .metersPerSecond(value * UnitConversion.metersPerStatuteMile / 3600)
        case .kilometersPerHour: return .kilometersPerHour(value)
        }
    }

    /// Up to two decimals, trailing zeros removed: 4.5 ft → "4.5", 1.3716 m → "1.37".
    public static func lengthText(_ distance: Distance, unit: DepthUnit) -> String {
        let value: Double
        switch unit {
        case .feet: value = distance.feet
        case .meters: value = distance.meters
        case .fathoms: value = distance.fathoms
        }
        return trimmed(value)
    }

    public static func speedText(_ speed: Speed, unit: SpeedUnit) -> String {
        let value: Double
        switch unit {
        case .knots: value = speed.knots
        case .milesPerHour: value = speed.metersPerSecond * 3600 / UnitConversion.metersPerStatuteMile
        case .kilometersPerHour: value = speed.kilometersPerHour
        }
        return trimmed(value)
    }

    static func trimmed(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        var text: String = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        if text == "-0" { text = "0" }
        return text
    }

    public static func symbol(_ unit: DepthUnit) -> String {
        switch unit {
        case .feet: return "ft"
        case .meters: return "m"
        case .fathoms: return "fm"
        }
    }

    public static func symbol(_ unit: SpeedUnit) -> String {
        switch unit {
        case .knots: return "kn"
        case .milesPerHour: return "mph"
        case .kilometersPerHour: return "km/h"
        }
    }
}

/// The problems of a form that could not be turned into a profile.
public struct BoatProfileProblems: Error, Sendable, Equatable {
    public var problems: [BoatProfileProblem]
    public init(problems: [BoatProfileProblem]) { self.problems = problems }
}

/// A row of the boat profile list.
public struct BoatProfileRow: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// "Draft 4.5 ft + 1.5 ft margin · air draft 20 ft · 6.0 kn".
    public var detail: String
    public var isDefault: Bool
    /// Options that are on: "Uses maintained channels", "Accepts unknown clearance".
    public var options: [String]

    public init(profile: Persistence.BoatProfile, units: UnitPreferences) {
        id = profile.id
        name = profile.name
        isDefault = profile.isDefault
        var parts: [String] = ["Draft \(NavFormat.depth(profile.draft.meters, unit: units.depth)) + \(NavFormat.depth(profile.safetyMargin.meters, unit: units.depth)) margin"]
        if let air = profile.airDraft {
            parts.append("air draft \(NavFormat.depth(air.meters, unit: units.depth))")
        } else {
            parts.append("no air draft")
        }
        if let speed = profile.cruisingSpeed { parts.append(NavFormat.speed(speed.metersPerSecond, unit: units.speed)) }
        detail = parts.joined(separator: " · ")
        var opts: [String] = []
        if profile.useMaintainedChannels { opts.append("Uses maintained channels") }
        if profile.acceptUnknownClearance { opts.append("Accepts unknown clearance") }
        options = opts
    }
}

/// Options of one plan that are not part of the boat profile.
public struct AutoRouteOptions: Sendable, Equatable {
    /// Overrides the profile's "use maintained channels" for this plan (nil: the profile's setting). Set only
    /// when the user picks the hint action or the option in the planner.
    public var useMaintainedChannels: Bool?
    /// Overrides the profile's "accept unknown clearance" for this plan (nil: the profile's setting).
    public var acceptUnknownClearance: Bool?
    /// Inside route only: open-Gulf water is not used.
    public var avoidOpenGulf: Bool
    /// Largest distance an end point may be moved onto navigable water.
    public var maxSnapMeters: Double
    /// Planning stops after this many seconds.
    public var timeLimitSeconds: Double

    public static let defaultMaxSnapMeters: Double = 750
    public static let defaultTimeLimitSeconds: Double = 30

    public init(useMaintainedChannels: Bool? = nil, acceptUnknownClearance: Bool? = nil, avoidOpenGulf: Bool = false,
                maxSnapMeters: Double = AutoRouteOptions.defaultMaxSnapMeters,
                timeLimitSeconds: Double = AutoRouteOptions.defaultTimeLimitSeconds) {
        self.useMaintainedChannels = useMaintainedChannels
        self.acceptUnknownClearance = acceptUnknownClearance
        self.avoidOpenGulf = avoidOpenGulf
        self.maxSnapMeters = maxSnapMeters
        self.timeLimitSeconds = timeLimitSeconds
    }
}

/// The boat as one plan uses it: the profile with this plan's option overrides applied.
public struct EffectiveBoat: Sendable, Equatable {
    public var profileID: UUID
    public var name: String
    public var draft: Distance
    public var safetyMargin: Distance
    public var airDraft: Distance
    public var cruisingSpeed: Speed?
    public var useMaintainedChannels: Bool
    public var acceptUnknownClearance: Bool
    public var avoidOpenGulf: Bool

    /// Nil when the profile cannot be used for routing (see ``AutoRouteProfileCheck``).
    public init?(profile: Persistence.BoatProfile, options: AutoRouteOptions) {
        guard AutoRouteProfileCheck.problems(profile).isEmpty, let air = profile.airDraft else { return nil }
        profileID = profile.id
        name = profile.name
        draft = profile.draft
        safetyMargin = profile.safetyMargin
        airDraft = air
        cruisingSpeed = profile.cruisingSpeed
        useMaintainedChannels = options.useMaintainedChannels ?? profile.useMaintainedChannels
        acceptUnknownClearance = options.acceptUnknownClearance ?? profile.acceptUnknownClearance
        avoidOpenGulf = options.avoidOpenGulf
    }

    public var requiredDepth: Distance { draft + safetyMargin }

    /// RoutingKit's profile. RoutingKit works in feet; Persistence and NavCore in metres, so the conversion
    /// is `Distance.feet` (metres / 0.3048). RoutingKit then rounds the requirement up to whole feet
    /// (spec B.2, with a 1e-9 ft allowance, so 4.5 + 1.5 ft stored as metres still needs exactly 6 ft = 18 dm).
    public var routingProfile: RoutingKit.BoatProfile {
        RoutingKit.BoatProfile(draft: draft, safetyMargin: safetyMargin, airDraft: airDraft,
                               useMaintainedChannels: useMaintainedChannels, acceptUnknownClearance: acceptUnknownClearance,
                               avoidOpenGulf: avoidOpenGulf)
    }

    /// The snapshot stored with a saved route (metres, the options actually used).
    public var snapshot: AutoRouteInfo.BoatSnapshot {
        AutoRouteInfo.BoatSnapshot(profileID: profileID, name: name, draftMeters: draft.meters,
                                   safetyMarginMeters: safetyMargin.meters, airDraftMeters: airDraft.meters,
                                   useMaintainedChannels: useMaintainedChannels, acceptUnknownClearance: acceptUnknownClearance)
    }
}

/// Whether a stored profile can be used to plan a route.
public enum AutoRouteProfileCheck {
    public static func problems(_ profile: Persistence.BoatProfile) -> [String] {
        var out: [String] = []
        let draft: Double = profile.draft.meters
        let margin: Double = profile.safetyMargin.meters
        if !(draft.isFinite && draft > 0) || profile.draft > BoatProfileDefaults.maximumDraft {
            out.append("The boat's draft must be above 0 and at most \(Int(BoatProfileDefaults.maximumDraft.feet)) ft.")
        }
        if !(margin.isFinite && margin >= 0) || profile.safetyMargin > BoatProfileDefaults.maximumSafetyMargin {
            out.append("The safety margin must be 0 or more and at most \(Int(BoatProfileDefaults.maximumSafetyMargin.feet)) ft.")
        }
        if let air = profile.airDraft {
            if !(air.meters.isFinite && air.meters > 0) || air > BoatProfileDefaults.maximumAirDraft {
                out.append("The air draft must be above 0 and at most \(Int(BoatProfileDefaults.maximumAirDraft.feet)) ft.")
            }
        } else {
            out.append("Enter the boat's air draft (height above the waterline) in its boat profile: the router needs it to check bridges and cables.")
        }
        return out
    }
}
