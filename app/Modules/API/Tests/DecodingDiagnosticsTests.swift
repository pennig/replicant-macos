import Foundation
import Testing
@testable import API

struct DecodingDiagnosticsTests {
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    @Test func describesCodingPathAndReason() {
        let ctx = DecodingError.Context(
            codingPath: [Key("planets"), Key("asteroid_belt")],
            debugDescription: "Additional properties are disallowed.")
        let (path, reason) = DecodingDiagnostics.describe(.dataCorrupted(ctx))
        #expect(path == "planets.asteroid_belt")
        #expect(reason.contains("Additional properties are disallowed."))
    }

    @Test func unwrapsAndIgnores() {
        let decode = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))
        #expect(DecodingDiagnostics.decodingError(in: decode) != nil)

        struct NotADecodeError: Error {}
        #expect(DecodingDiagnostics.decodingError(in: NotADecodeError()) == nil)
    }
}
