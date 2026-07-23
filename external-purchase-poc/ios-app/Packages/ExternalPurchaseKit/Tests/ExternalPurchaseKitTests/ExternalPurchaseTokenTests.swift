import Foundation
import Testing

@testable import ExternalPurchaseKit

struct ExternalPurchaseTokenTests {
    private let appAppleId: Int64 = 1_234_567_890
    private let bundleId = "de.immowelt.app"

    /// Mirrors the mock server's `/debug/mint-token` variants exactly, so
    /// these tests exercise the same shapes the server can actually hand
    /// the client, without needing the server running.
    private func encode(
        payload: [String: Any?], urlsafe: Bool = false
    ) -> String {
        let cleaned = payload.compactMapValues { $0 }
        let data = try! JSONSerialization.data(withJSONObject: cleaned)
        if urlsafe {
            return Data(data).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return data.base64EncodedString()
    }

    private func epochMs(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private func validPayload(
        type: String = "SERVICES", createdAt: Date = Date(), lifetime: TimeInterval = 365 * 24 * 60 * 60,
        includeOptionalFields: Bool = true, extraField: Bool = false
    ) -> [String: Any?] {
        var payload: [String: Any?] = [
            "appAppleId": appAppleId,
            "bundleId": bundleId,
            "tokenCreationDate": epochMs(createdAt),
            "externalPurchaseId": UUID().uuidString,
        ]
        if includeOptionalFields {
            payload["tokenType"] = type
            payload["tokenExpirationDate"] = epochMs(createdAt.addingTimeInterval(lifetime))
        }
        if extraField {
            payload["futureAppleField"] = "the-client-does-not-know-this-field"
        }
        return payload
    }

    // MARK: - Mint-token variants

    @Test
    func validVariantDecodes() throws {
        let value = encode(payload: validPayload())
        let token = try ExternalPurchaseToken(rawValue: value)
        #expect(token.value == value)
        #expect(token.payload.bundleId == bundleId)
        #expect(token.payload.tokenType == .services)
    }

    @Test
    func expiredVariantIsExpired() throws {
        let createdAt = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        let value = encode(payload: validPayload(createdAt: createdAt, lifetime: -24 * 60 * 60))
        let token = try ExternalPurchaseToken(rawValue: value)
        #expect(token.isExpired(asOf: Date()))
    }

    @Test
    func expiringSoonVariantExpiresWithinWindow() throws {
        let value = encode(payload: validPayload(lifetime: 5 * 60))
        let token = try ExternalPurchaseToken(rawValue: value)
        #expect(token.expiresWithin(10 * 60, asOf: Date()))
        #expect(!token.isExpired(asOf: Date()))
    }

    @Test
    func base64urlWithMissingPaddingDecodes() throws {
        let value = encode(payload: validPayload(), urlsafe: true)
        #expect(!value.contains("="))
        let token = try ExternalPurchaseToken(rawValue: value)
        #expect(token.payload.bundleId == bundleId)
    }

    @Test
    func malformedJSONFailsToDecode() {
        let value = Data("{not valid json".utf8).base64EncodedString()
        #expect(throws: TokenDecodingError.self) {
            _ = try ExternalPurchaseToken(rawValue: value)
        }
    }

    @Test
    func invalidBase64FailsToDecode() {
        #expect(throws: TokenDecodingError.invalidBase64) {
            _ = try ExternalPurchaseToken(rawValue: "%%% not base64 %%%")
        }
    }

    @Test
    func typeMismatchOnlyRaisedWhenExpectingDiffersFromPresentTokenType() throws {
        let value = encode(payload: validPayload(type: "SERVICES"))
        #expect(throws: TokenDecodingError.typeMismatch(expected: .acquisition, actual: .services)) {
            _ = try ExternalPurchaseToken(rawValue: value, expecting: .acquisition)
        }
        // Matching type: no throw.
        _ = try ExternalPurchaseToken(rawValue: value, expecting: .services)
    }

    @Test
    func missingOptionalFieldsDecodesWithoutTypeMismatch() throws {
        let value = encode(payload: validPayload(includeOptionalFields: false))
        let token = try ExternalPurchaseToken(rawValue: value, expecting: .acquisition)
        #expect(token.payload.tokenType == nil)
        #expect(token.payload.tokenExpirationDate == nil)
    }

    @Test
    func unknownExtraFieldDecodesWithoutError() throws {
        let value = encode(payload: validPayload(extraField: true))
        let token = try ExternalPurchaseToken(rawValue: value)
        #expect(token.payload.bundleId == bundleId)
    }

    // MARK: - Millisecond date decoding

    @Test
    func millisecondDateDecodingProducesAPlausibleDate() throws {
        let value = encode(payload: validPayload())
        let token = try ExternalPurchaseToken(rawValue: value)
        let yearsFromNow = token.payload.tokenCreationDate.timeIntervalSinceNow / (365 * 24 * 60 * 60)
        // Guards against the `.secondsSince1970` bug, which would land the
        // date roughly 57,000 years in the future instead of "now".
        #expect(abs(yearsFromNow) < 5)
    }

    // MARK: - Round-trip Codable

    @Test
    func roundTripEncodeDecodePreservesRawValueByteIdentically() throws {
        let value = encode(payload: validPayload())
        let token = try ExternalPurchaseToken(rawValue: value)
        let encoded = try JSONEncoder().encode(token)
        let decoded = try JSONDecoder().decode(ExternalPurchaseToken.self, from: encoded)
        #expect(decoded.value == token.value)
        #expect(decoded == token)
    }

    @Test
    func outboxRecordWithOldPayloadShapeStillDecodesAfterFieldAddition() throws {
        // Simulates a record written to disk before `ExternalPurchaseTokenPayload`
        // gained a hypothetical new field: the on-disk JSON is just
        // `{"value": "<original base64>"}, and decoding re-derives the
        // payload from that original base64 each time — it never trusted a
        // previously-serialized decoded shape, so an added field can't
        // break it.
        let value = encode(payload: validPayload())
        let fixture = Data("{\"value\":\"\(value)\"}".utf8)
        let token = try JSONDecoder().decode(ExternalPurchaseToken.self, from: fixture)
        #expect(token.value == value)
        #expect(token.payload.bundleId == bundleId)
    }
}
