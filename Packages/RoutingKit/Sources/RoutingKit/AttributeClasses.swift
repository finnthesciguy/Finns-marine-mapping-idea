import Foundation

/// One `ATTR` row (spec A.5): the attributes a triangle shares with every other triangle of its class.
struct AttributeRow: Hashable {
    var depth: Int16
    var band: Int16
    var maint: Int16
    var clr: UInt16
    var flags: UInt16
    var chan: UInt16
    var ovhd: UInt16
    var area: UInt16
    var quality: UInt8
    var advisory: UInt16
}

/// The distinct `ATTR` rows of a pack, as columns. A Gulf region pack has a few tens of thousands of classes
/// for millions of triangles, so each triangle needs only its 4-byte class number.
struct AttributeClasses {
    var depth = ContiguousArray<Int16>()
    var band = ContiguousArray<Int16>()
    var maint = ContiguousArray<Int16>()
    var clr = ContiguousArray<UInt16>()
    var flags = ContiguousArray<UInt16>()
    var chan = ContiguousArray<UInt16>()
    var ovhd = ContiguousArray<UInt16>()
    var area = ContiguousArray<UInt16>()
    var quality = ContiguousArray<UInt8>()
    var advisory = ContiguousArray<UInt16>()

    var count: Int { depth.count }

    mutating func append(_ r: AttributeRow) {
        depth.append(r.depth)
        band.append(r.band)
        maint.append(r.maint)
        clr.append(r.clr)
        flags.append(r.flags)
        chan.append(r.chan)
        ovhd.append(r.ovhd)
        area.append(r.area)
        quality.append(r.quality)
        advisory.append(r.advisory)
    }

    /// Bytes held by the columns (19 per class).
    var memoryBytes: Int { count * 19 }
}
