import Foundation
import Testing
@testable import RoutingKit

/// Every query of both `*.vectors.json` files must reproduce exactly (spec part D).
@Suite struct VectorTests {
    func runAll(_ name: String) throws {
        let file = try Fixtures.decode(VectorFile.self, "\(name).vectors.json")
        #expect(file.schema == "routing-vectors/1")
        let pack = Fixtures.pack(named: name)
        var matched = 0
        for q in file.queries {
            let mismatches: [String] = compareVector(q, on: pack)
            if mismatches.isEmpty {
                matched += 1
            } else {
                Issue.record("\(name) \(q.id): \(mismatches.prefix(12).joined(separator: "; "))")
            }
        }
        print("[vectors] \(name): \(matched)/\(file.queries.count) queries match exactly")
        #expect(matched == file.queries.count)
    }

    @Test func syntheticVectors() throws { try runAll("synthetic") }

    @Test func sarasotaVectors() throws { try runAll("sarasota") }
}
