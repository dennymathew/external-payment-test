import Foundation

/// The two token flavors Apple's real API vends. ACQUISITION identifies the
/// campaign/link that brought a first-time customer in; SERVICES is minted
/// per-transaction and proves eligibility for a specific purchase. Raw values
/// match Apple's wire format (and the mock server's `tokenType` field)
/// exactly — this is decoded JSON, not just a client-side label.
public enum TokenType: String, Equatable, Sendable, CaseIterable, Codable {
    case acquisition = "ACQUISITION"
    case services = "SERVICES"
}

/// Every way `ExternalPurchaseToken(rawValue:)` can fail. Not a wrapped
/// `Error` — a plain, comparable value so it can flow through `TestStore`
/// assertions and across actor boundaries without losing equality.
public enum TokenDecodingError: Error, Equatable, Sendable {
    /// The raw string itself isn't valid base64 (after base64url
    /// normalization), so JSON decoding was never attempted.
    case invalidBase64
    /// Base64 decoded fine, but the payload's shape didn't match, a
    /// required field was missing, or a date was unparseable.
    case malformedPayload(description: String)
    /// `tokenType` was present but didn't match what the caller expected
    /// (e.g. an ACQUISITION token handed to `token(.services)`'s caller).
    /// Never raised when `tokenType` is absent — that's documented as
    /// custom-link-only, not a mismatch.
    case typeMismatch(expected: TokenType, actual: TokenType)
}

/// The decoded contents of Apple's base64 token — `ExternalPurchaseCustomLink.Token.value`
/// is base64-encoded JSON, not an opaque string.
public struct ExternalPurchaseTokenPayload: Equatable, Sendable, Codable {
    public let appAppleId: Int64
    public let bundleId: String
    public let tokenCreationDate: Date
    public let externalPurchaseId: UUID
    /// Custom link tokens only.
    public let tokenType: TokenType?
    /// Custom link tokens only.
    public let tokenExpirationDate: Date?

    public init(
        appAppleId: Int64, bundleId: String, tokenCreationDate: Date, externalPurchaseId: UUID,
        tokenType: TokenType?, tokenExpirationDate: Date?
    ) {
        self.appAppleId = appAppleId
        self.bundleId = bundleId
        self.tokenCreationDate = tokenCreationDate
        self.externalPurchaseId = externalPurchaseId
        self.tokenType = tokenType
        self.tokenExpirationDate = tokenExpirationDate
    }
}

public struct ExternalPurchaseToken: Equatable, Sendable {
    /// Raw base64 exactly as StoreKit issued it. Retained for diagnostics
    /// and forward compatibility — NOT transmitted to the BFF.
    public let value: String
    /// Decoded view, for local decisions only.
    public let payload: ExternalPurchaseTokenPayload

    public init(rawValue: String) throws {
        self.value = rawValue
        self.payload = try Self.decodePayload(from: rawValue)
    }

    public init(rawValue: String, expecting expectedType: TokenType) throws {
        try self.init(rawValue: rawValue)
        if let actualType = payload.tokenType, actualType != expectedType {
            throw TokenDecodingError.typeMismatch(expected: expectedType, actual: actualType)
        }
    }

    // Identity is the raw string.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.value == rhs.value }

    public var externalPurchaseId: UUID { payload.externalPurchaseId }
    public var expiresAt: Date? { payload.tokenExpirationDate }

    public func isExpired(asOf now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }

    public func expiresWithin(_ interval: TimeInterval, asOf now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= interval
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // Apple documents these fields as epoch milliseconds, not seconds —
        // `.secondsSince1970` would still "succeed" but land ~55,000 years in
        // the future, so every expiry check silently passes forever.
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    private static func decodePayload(from rawValue: String) throws -> ExternalPurchaseTokenPayload {
        guard let data = normalizedBase64Data(from: rawValue) else {
            throw TokenDecodingError.invalidBase64
        }
        do {
            return try decoder.decode(ExternalPurchaseTokenPayload.self, from: data)
        } catch {
            throw TokenDecodingError.malformedPayload(description: String(describing: error))
        }
    }

    /// Apple's real tokens (and the mock server's `base64url` debug variant)
    /// use unpadded base64url. `Data(base64Encoded:)` only understands
    /// standard base64, so `-`/`_` and missing `=` padding must be fixed up
    /// first or every token silently fails to decode.
    private static func normalizedBase64Data(from rawValue: String) -> Data? {
        var normalized = rawValue
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: normalized)
    }
}

extension ExternalPurchaseToken: Codable {
    private enum CodingKeys: String, CodingKey { case value }

    /// Serializes ONLY the raw string, re-deriving `payload` on decode.
    /// Outbox records sit on disk across app versions — persisting the
    /// decoded struct would mean a future field addition breaks queued
    /// records we're obligated to report within 15 days. Re-decoding the
    /// original base64 blob every time sidesteps that entirely.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        try self.init(rawValue: rawValue)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
