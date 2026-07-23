import Foundation

/// Mirrors the mock server's `MintTokenVariant` literal exactly — each one
/// exercises a specific decode path so the debug menu can drive the real
/// `ExternalPurchaseToken` decoder against a known-bad (or known-good) shape
/// without needing the real Apple entitlement.
public enum DebugTokenVariant: String, Equatable, Sendable, CaseIterable, Codable {
    case valid
    case expired
    case expiringSoon = "expiring_soon"
    case base64url
    case malformedJSON = "malformed_json"
    case invalidBase64 = "invalid_base64"
    case typeMismatch = "type_mismatch"
    case missingOptionalFields = "missing_optional_fields"
    case unknownExtraField = "unknown_extra_field"
}
