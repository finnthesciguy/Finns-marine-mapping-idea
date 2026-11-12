import Foundation

/// Per-triangle derived booleans (spec B.3), packed in a byte.
struct TriBits: OptionSet {
    let rawValue: UInt8
    static let viaMaint = TriBits(rawValue: 1 << 0)
    static let viaSound = TriBits(rawValue: 1 << 1)
    static let needsOpening = TriBits(rawValue: 1 << 2)
    static let unknownUsed = TriBits(rawValue: 1 << 3)
    static let restricted = TriBits(rawValue: 1 << 4)
}

/// Spec B.3–B.5 for one profile, computed on demand per triangle (no O(T) arrays per query).
struct Classifier {
    let req: Int
    let air: Int
    let useMaintained: Bool
    let acceptUnknown: Bool
    let avoidOpenGulf: Bool

    let depth: ContiguousArray<Int16>
    let band: ContiguousArray<Int16>
    let maint: ContiguousArray<Int16>
    let clr: ContiguousArray<UInt16>
    let flags: ContiguousArray<UInt16>

    init(pack: RoutingPack, profile: BoatProfile) {
        req = profile.requiredDepthDm
        air = profile.requiredAirDm
        useMaintained = profile.useMaintainedChannels
        acceptUnknown = profile.acceptUnknownClearance
        avoidOpenGulf = profile.avoidOpenGulf
        depth = pack.depth
        band = pack.band
        maint = pack.maint
        clr = pack.clr
        flags = pack.flags
    }

    private static let fChannel: UInt16 = 1 << 0
    private static let fHighway: UInt16 = 1 << 1
    private static let fOpening: UInt16 = 1 << 2
    private static let fUnknown: UInt16 = 1 << 3
    private static let fRestricted: UInt16 = 1 << 4
    private static let fCaution: UInt16 = 1 << 5
    private static let fNearHazard: UInt16 = 1 << 6
    private static let fHazardDepth: UInt16 = 1 << 7
    private static let fProhibited: UInt16 = 1 << 8
    private static let fOutside: UInt16 = 1 << 9

    /// The B.3 block reason code (0..4), or -1 when passable.
    @inline(__always) func reason(_ t: Int) -> Int {
        let fl = flags[t]
        if fl & Self.fProhibited != 0 { return 0 }
        if avoidOpenGulf && fl & Self.fOutside != 0 { return 1 }
        let d = Int(depth[t])
        let hasDepth = d != -32768
        let depthOK = hasDepth && d >= req
        let m = Int(maint[t])
        let maintOK = useMaintained && hasDepth && m != -32768 && m >= req && fl & Self.fHazardDepth == 0
        if !(depthOK || maintOK) { return 2 }
        let c = clr[t]
        let hasOvh = c != 0xFFFF
        let opening = fl & Self.fOpening != 0
        let knownOK = c == 0xFFFE || Int(c) >= air
        if hasOvh && !opening && !knownOK { return 3 }
        if hasOvh && !opening && knownOK && fl & Self.fUnknown != 0 && !acceptUnknown { return 4 }
        return -1
    }

    @inline(__always) func ok(_ t: Int) -> Bool { reason(t) < 0 }

    /// Derived booleans of B.3 (via_maint and via_sound are only meaningful for passable triangles).
    @inline(__always) func bits(_ t: Int) -> TriBits {
        let fl = flags[t]
        let d = Int(depth[t])
        let hasDepth = d != -32768
        let depthOK = hasDepth && d >= req
        let m = Int(maint[t])
        let maintOK = useMaintained && hasDepth && m != -32768 && m >= req && fl & Self.fHazardDepth == 0
        var b: TriBits = []
        if !depthOK && maintOK { b.insert(.viaMaint) }
        let bd = Int(band[t])
        if depthOK && (bd == -32768 || bd < req) { b.insert(.viaSound) }
        let c = clr[t]
        let hasOvh = c != 0xFFFF
        let opening = fl & Self.fOpening != 0
        if opening && hasOvh && (c == 0xFFFE || Int(c) < air) { b.insert(.needsOpening) }
        if fl & Self.fUnknown != 0 && !opening && hasOvh { b.insert(.unknownUsed) }
        if fl & Self.fRestricted != 0 { b.insert(.restricted) }
        return b
    }

    /// The B.5 cost factor, multiplied in the spec's order.
    @inline(__always) func factor(_ t: Int, _ b: TriBits) -> Double {
        let fl = flags[t]
        var f = 1.0
        if fl & Self.fHighway != 0 {
            f = f * 0.80
        } else if fl & Self.fChannel != 0 {
            f = f * 0.90
        }
        let shore = (fl >> 11) & 3
        if shore == 0 {
            f = f * 1.5
        } else if shore == 1 {
            f = f * 1.15
        }
        if fl & Self.fNearHazard != 0 { f = f * 1.2 }
        let spare = Int(depth[t]) - req
        if b.contains(.viaMaint) {
            f = f * 3.0
        } else if spare < 3 {
            f = f * 1.3
        } else if spare < 10 {
            f = f * 1.1
        }
        if b.contains(.viaSound) { f = f * 1.5 }
        if b.contains(.restricted) { f = f * 2.0 }
        if fl & Self.fCaution != 0 { f = f * 1.25 }
        return f
    }
}
