//
//  JSONValueTests.swift
//  UtilsTests
//
//  `intValue`, the accessor `Operation.printedQuantity` decodes a print op's
//  quantity through.
//

import Testing
@testable import Utils

@Suite("JSONValue — intValue")
struct JSONValueIntValueTests {
    @Test("a whole number decodes to its Int value")
    func wholeNumberDecodes() {
        #expect(JSONValue.number(3).intValue == 3)
    }

    @Test("a non-number is nil")
    func nonNumberIsNil() {
        #expect(JSONValue.string("3").intValue == nil)
    }
}
