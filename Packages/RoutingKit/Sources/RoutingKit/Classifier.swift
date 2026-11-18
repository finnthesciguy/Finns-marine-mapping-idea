import Foundation

/// Per-triangle derived booleans (spec B.3), packed in a byte.
struct TriBits: OptionSet {
    let rawValue: UInt8
    static let viaMaint = TriBits(rawValue: 1 << 0)
    static let viaSound = TriBits(rawValue: 1 << 1)
    static let needsOpening = TriBits(rawValue: 1 << 2)
    static let unknownUsed = TriBits(rawValue: 1 << 3)
    static let restricted = TriBits(rawValue: 1 << 4)
    static let lock = TriBits(rawValue: 1 << 5)
    static let prohibited = TriBits(rawValue: 1 << 6)
    static let uncharted = TriBits(rawValue: 1 << 7)
}

/// Spec B.3–B.5 and the B.9 yellow reasons for one profile, computed once per attribute class (a pack has a few
/// tens of thousands of classes), so a query needs no O(T) arrays for classification.
struct Classifier {
    let req: Int
    let air: Int
    let useMaintained: Bool
    let avoidOpenGulf: Bool

    let attrClass: ContiguousArray<UInt32>
    /// Per class: the B.3 block reason (1..3 since round 4) or -1.
    private let reasons: ContiguousArray<Int8>
    private let classBits: ContiguousArray<TriBits>
    private let factors: ContiguousArray<Double>
    /// Per class: the B.9 yellow reasons as a mask (bit k = `CautionReason.allCases[k]`).
    private let yellow: ContiguousArray<UInt16>

    init(pack: RoutingPack, profile: BoatProfile) {
        req = profile.requiredDepthDm
        air = profile.requiredAirDm
        useMaintained = profile.useMaintainedChannels
        avoidOpenGulf = profile.avoidOpenGulf
        attrClass = pack.attrClass
        let c = pack.classes
        let n = c.count
        var r = ContiguousArray<Int8>(repeating: -1, count: n)
        var b = ContiguousArray<TriBits>(repeating: [], count: n)
        var f = ContiguousArray<Double>(repeating: 1, count: n)
        var y = ContiguousArray<UInt16>(repeating: 0, count: n)
        for k in 0..<n {
            r[k] = Int8(Self.reason(c, k, req: req, air: air, useMaintained: useMaintained,
                                    avoidOpenGulf: avoidOpenGulf))
            b[k] = Self.bits(c, k, req: req, air: air, useMaintained: useMaintained)
            f[k] = Self.factor(c, k, b[k], req: req)
            y[k] = Self.yellowMask(c, k, b[k], req: req)
        }
        reasons = r
        classBits = b
        factors = f
        yellow = y
    }

    static let fChannel: UInt16 = 1 << 0
    static let fHighway: UInt16 = 1 << 1
    static let fOpening: UInt16 = 1 << 2
    static let fUnknown: UInt16 = 1 << 3
    static let fRestricted: UInt16 = 1 << 4
    static let fCaution: UInt16 = 1 << 5
    static let fNearHazard: UInt16 = 1 << 6
    static let fHazardDepth: UInt16 = 1 << 7
    static let fProhibited: UInt16 = 1 << 8
    static let fOutside: UInt16 = 1 << 9
    static let fLock: UInt16 = 1 << 13
    static let fUncharted: UInt16 = 1 << 14

    /// The B.3 block reason code (0..4), or -1 when passable.
    @inline(__always) func reason(_ t: Int) -> Int { Int(reasons[Int(attrClass[t])]) }
    @inline(__always) func ok(_ t: Int) -> Bool { reasons[Int(attrClass[t])] < 0 }
    /// Derived booleans of B.3 (via_maint and via_sound are only meaningful for passable triangles).
    @inline(__always) func bits(_ t: Int) -> TriBits { classBits[Int(attrClass[t])] }
    /// The B.5 cost factor.
    @inline(__always) func factor(_ t: Int) -> Double { factors[Int(attrClass[t])] }
    /// The B.9 yellow reasons of one triangle, as a mask in `CautionReason.allCases` order.
    @inline(__always) func yellowMask(_ t: Int) -> UInt16 { yellow[Int(attrClass[t])] }

    static func reason(_ c: AttributeClasses, _ k: Int, req: Int, air: Int, useMaintained: Bool,
                               avoidOpenGulf: Bool) -> Int {
        let fl = c.flags[k]
        // Format 1.3: PROHIBITED (code 0) is no longer a block reason; entry-prohibited areas are yellow and cost more.
        if avoidOpenGulf && fl & fOutside != 0 { return 1 }
        let d = Int(c.depth[k])
        let hasDepth = d != -32768
        let depthOK = hasDepth && d >= req
        let m = Int(c.maint[k])
        let maintOK = useMaintained && hasDepth && m != -32768 && m >= req && fl & fHazardDepth == 0
        if !(depthOK || maintOK) { return 2 }
        let cl = c.clr[k]
        let hasOvh = cl != 0xFFFF
        let opening = fl & fOpening != 0
        let knownOK = cl == 0xFFFE || Int(cl) >= air
        if hasOvh && !opening && !knownOK { return 3 }
        // Round 4: an object without a charted clearance (cable, pipe) is passable with a caution, so code 4
        // (UNKNOWN_CLEARANCE) is no longer produced; `acceptUnknownClearance` has no effect.
        return -1
    }

    private static func bits(_ c: AttributeClasses, _ k: Int, req: Int, air: Int, useMaintained: Bool) -> TriBits {
        let fl = c.flags[k]
        let d = Int(c.depth[k])
        let hasDepth = d != -32768
        let depthOK = hasDepth && d >= req
        let m = Int(c.maint[k])
        let maintOK = useMaintained && hasDepth && m != -32768 && m >= req && fl & fHazardDepth == 0
        var b: TriBits = []
        if !depthOK && maintOK { b.insert(.viaMaint) }
        let bd = Int(c.band[k])
        if depthOK && (bd == -32768 || bd < req) { b.insert(.viaSound) }
        let cl = c.clr[k]
        let hasOvh = cl != 0xFFFF
        let opening = fl & fOpening != 0
        if opening && hasOvh && (cl == 0xFFFE || Int(cl) < air) { b.insert(.needsOpening) }
        if fl & fUnknown != 0 && !opening && hasOvh { b.insert(.unknownUsed) }
        if fl & fRestricted != 0 { b.insert(.restricted) }
        if fl & fLock != 0 { b.insert(.lock) }
        if fl & fProhibited != 0 { b.insert(.prohibited) }
        if fl & fUncharted != 0 { b.insert(.uncharted) }
        return b
    }

    /// The B.5 cost factor, multiplied in the spec's order.
    private static func factor(_ c: AttributeClasses, _ k: Int, _ b: TriBits, req: Int) -> Double {
        let fl = c.flags[k]
        var f = 1.0
        if fl & fHighway != 0 {
            f = f * 0.80
        } else if fl & fChannel != 0 {
            f = f * 0.90
        }
        let shore = (fl >> 11) & 3
        if shore == 0 {
            f = f * 1.5
        } else if shore == 1 {
            f = f * 1.15
        }
        if fl & fNearHazard != 0 { f = f * 1.2 }
        let spare = Int(c.depth[k]) - req
        if b.contains(.viaMaint) {
            f = f * 3.0
        } else if spare < 3 {
            f = f * 1.3
        } else if spare < 10 {
            f = f * 1.1
        }
        if b.contains(.viaSound) { f = f * 1.5 }
        if b.contains(.prohibited) {
            f = f * 3.0
        } else if b.contains(.restricted) {
            f = f * 2.0
        }
        if fl & fCaution != 0 { f = f * 1.25 }
        return f
    }

    /// Spec B.9, per triangle: bit k set when `CautionReason.allCases[k]` applies.
    private static func yellowMask(_ c: AttributeClasses, _ k: Int, _ b: TriBits, req: Int) -> UInt16 {
        let fl = c.flags[k]
        let cz = Int(c.quality[k] & 7)
        var m: UInt16 = 0
        if b.contains(.viaMaint) { m |= 1 << 0 }
        if b.contains(.viaSound) { m |= 1 << 1 }
        if b.contains(.needsOpening) { m |= 1 << 2 }
        if b.contains(.lock) { m |= 1 << 3 }
        if b.contains(.uncharted) { m |= 1 << 4 }
        if b.contains(.unknownUsed) { m |= 1 << 5 }
        if b.contains(.prohibited) { m |= 1 << 6 }
        if fl & fRestricted != 0 { m |= 1 << 7 }
        if fl & fCaution != 0 { m |= 1 << 8 }
        if fl & fHazardDepth != 0 { m |= 1 << 9 }
        if cz == 0 || cz == 5 || cz == 6 { m |= 1 << 10 }
        if !b.contains(.viaMaint) && Int(c.depth[k]) - req < 3 && (cz == 0 || cz == 4 || cz == 5 || cz == 6) { m |= 1 << 11 }
        return m
    }
}
