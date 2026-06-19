import Foundation
import Testing
@testable import UnragerKit

@Suite("FontScale stepping")
struct FontScaleTests {
    @Test("standard is the unscaled 1.0 multiplier")
    func standardIsUnscaled() {
        #expect(FontScale.standard.multiplier == 1.0)
    }

    @Test("raw values double as a contiguous 0-based segmented-control index")
    func rawValuesAreContiguousIndices() {
        for (index, scale) in FontScale.allCases.enumerated() {
            #expect(scale.rawValue == index)
        }
        #expect(FontScale.allCases.count == 5)
    }

    @Test("multipliers increase monotonically and stay in a sane band")
    func multipliersAscend() {
        let multipliers = FontScale.allCases.map(\.multiplier)
        #expect(multipliers == multipliers.sorted())
        #expect(multipliers.first == 0.85)
        #expect(multipliers.last == 1.5)
    }

    @Test("every step has a non-empty label")
    func labelsPresent() {
        for scale in FontScale.allCases {
            #expect(!scale.title.isEmpty)
        }
    }
}
