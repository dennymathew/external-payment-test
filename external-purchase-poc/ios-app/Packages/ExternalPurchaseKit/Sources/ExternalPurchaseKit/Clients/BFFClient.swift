import ComposableArchitecture
import Foundation

/// Sent to `POST /tokens`. The raw base64 token value never leaves the
/// device — only the UUID Apple embedded in it does.
struct TokenReportPayload: Encodable {
    let acquisitionPurchaseId: UUID?
    let servicesPurchaseId: UUID
    /// Only set when `acquisitionPurchaseId` is nil — the server rejects a
    /// null `servicesPurchaseId` outright, since that means the client's own
    /// token subsystem broke and must not be reported as data.
    let acquisitionAbsenceReason: String?
    let fetchedAt: Date
}

/// Talks to the mock server's BFF endpoints (`/tokens`, `/checkout/session`,
/// `/checkout/session/{id}/verify`, `/debug/*`). Nothing here is
/// StoreKit-related — this client stays as-is when the real entitlement
/// lands; only `ExternalPurchaseClient` changes.
@DependencyClient
public struct BFFClient: Sendable {
    public var reportTokens: @Sendable (
        _ acquisitionPurchaseId: UUID?, _ servicesPurchaseId: UUID,
        _ acquisitionAbsenceReason: String?, _ deviceId: String, _ fetchedAt: Date
    ) async throws -> Void
    public var createCheckoutSession: @Sendable (
        _ productId: String, _ userId: String, _ acquisitionToken: String?, _ servicesToken: String?
    ) async throws -> CheckoutSession
    public var verifySession: @Sendable (_ sessionId: String) async throws -> VerifyResult
    public var debugMintToken: @Sendable (_ type: TokenType, _ variant: DebugTokenVariant) async throws -> String
    public var debugSetHandoffMode: @Sendable (_ mode: String) async throws -> Void
    public var debugReset: @Sendable () async throws -> Void
}

extension BFFClient: DependencyKey {
    public static let liveValue: Self = BFFLiveImplementation().makeClient()

    public static let testValue = Self()
}

extension DependencyValues {
    public var bffClient: BFFClient {
        get { self[BFFClient.self] }
        set { self[BFFClient.self] = newValue }
    }
}

/// Small private helper so the closures above stay free of repeated
/// request-building / error-mapping boilerplate.
private struct BFFLiveImplementation: @unchecked Sendable {
    let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
    let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
    let isoFormatterFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    let isoFormatter = ISO8601DateFormatter()

    func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        return isoFormatterFractional.date(from: string) ?? isoFormatter.date(from: string)
    }

    func request(path: String, method: String, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: ExternalPurchaseKitConfig.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    func request<Body: Encodable>(
        path: String, method: String, jsonBody: Body, headers: [String: String] = [:]
    ) throws -> URLRequest {
        var request = request(path: path, method: method, headers: headers)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(jsonBody)
        return request
    }

    func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ExternalPurchaseError.network("Unexpected response from \(request.url?.path ?? "?")")
        }
        return data
    }

    func makeClient() -> BFFClient {
        BFFClient(
            reportTokens: { acquisitionPurchaseId, servicesPurchaseId, acquisitionAbsenceReason, deviceId, fetchedAt in
                do {
                    let request = try request(
                        path: "tokens",
                        method: "POST",
                        jsonBody: TokenReportPayload(
                            acquisitionPurchaseId: acquisitionPurchaseId,
                            servicesPurchaseId: servicesPurchaseId,
                            acquisitionAbsenceReason: acquisitionAbsenceReason,
                            fetchedAt: fetchedAt
                        ),
                        headers: ["Device-Id": deviceId]
                    )
                    _ = try await send(request)
                } catch let error as ExternalPurchaseError {
                    throw error
                } catch {
                    throw ExternalPurchaseError.network(String(describing: error))
                }
            },
            createCheckoutSession: { productId, userId, acquisitionToken, servicesToken in
                struct Body: Encodable {
                    let productId: String
                    let userId: String
                    let acquisitionToken: String?
                    let servicesToken: String?
                }
                struct Response: Decodable {
                    let sessionId: String
                    let checkoutUrl: String
                    let handoffExpiresAt: String
                    let expiresAt: String
                }
                do {
                    let request = try request(
                        path: "checkout/session",
                        method: "POST",
                        jsonBody: Body(
                            productId: productId, userId: userId,
                            acquisitionToken: acquisitionToken, servicesToken: servicesToken
                        )
                    )
                    let data = try await send(request)
                    let decoded = try decoder.decode(Response.self, from: data)
                    guard let url = URL(string: decoded.checkoutUrl) else {
                        throw ExternalPurchaseError.sessionCreationFailed("Server returned an invalid checkout URL.")
                    }
                    guard
                        let handoffExpiresAt = parseDate(decoded.handoffExpiresAt),
                        let expiresAt = parseDate(decoded.expiresAt)
                    else {
                        throw ExternalPurchaseError.sessionCreationFailed("Server returned an invalid expiry date.")
                    }
                    return CheckoutSession(
                        sessionId: decoded.sessionId, checkoutURL: url,
                        handoffExpiresAt: handoffExpiresAt, expiresAt: expiresAt
                    )
                } catch let error as ExternalPurchaseError {
                    throw error
                } catch {
                    throw ExternalPurchaseError.sessionCreationFailed(String(describing: error))
                }
            },
            verifySession: { sessionId in
                struct Response: Decodable {
                    let status: String
                    let verifiedAt: String?
                }
                do {
                    let request = request(path: "checkout/session/\(sessionId)/verify", method: "GET")
                    let data = try await send(request)
                    let decoded = try decoder.decode(Response.self, from: data)
                    guard let status = VerifyStatus(rawValue: decoded.status) else {
                        throw ExternalPurchaseError.verificationFailed("Unknown session status '\(decoded.status)'.")
                    }
                    return VerifyResult(status: status, verifiedAt: parseDate(decoded.verifiedAt))
                } catch let error as ExternalPurchaseError {
                    throw error
                } catch {
                    throw ExternalPurchaseError.verificationFailed(String(describing: error))
                }
            },
            debugMintToken: { type, variant in
                var components = URLComponents(
                    url: ExternalPurchaseKitConfig.baseURL.appendingPathComponent("debug/mint-token"),
                    resolvingAgainstBaseURL: false
                )!
                components.queryItems = [
                    URLQueryItem(name: "type", value: type.rawValue),
                    URLQueryItem(name: "variant", value: variant.rawValue),
                ]
                struct Response: Decodable { let value: String }
                do {
                    let data = try await send(URLRequest(url: components.url!))
                    return try decoder.decode(Response.self, from: data).value
                } catch let error as ExternalPurchaseError {
                    throw error
                } catch {
                    throw ExternalPurchaseError.network(String(describing: error))
                }
            },
            debugSetHandoffMode: { mode in
                struct Body: Encodable { let mode: String }
                let request = try request(path: "debug/handoff-mode", method: "POST", jsonBody: Body(mode: mode))
                _ = try await send(request)
            },
            debugReset: {
                let request = request(path: "debug/reset", method: "POST")
                _ = try await send(request)
            }
        )
    }
}
