import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches plan usage from Claude.
///
/// Both endpoints are the ones Claude's own clients use (`/usage` in Claude Code and
/// Settings › Usage on claude.ai). They are not a published API and may change.
public final class UsageClient: @unchecked Sendable {
    public static let oauthUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let webBaseURL = URL(string: "https://claude.ai/api/")!

    public struct WebResult: Sendable {
        public let snapshot: UsageSnapshot
        public let organizationID: String
        public let planName: String?
    }

    private let session: URLSession
    private let userAgent: String

    public init(session: URLSession? = nil, appVersion: String = "1.0") {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 40
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            // The claude.ai cookie is sent verbatim; never store cookies from responses.
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
        userAgent = "ClaudeUsage/\(appVersion) (macOS menu bar)"
    }

    // MARK: - Claude Code sign-in

    public func fetchOAuthUsage(accessToken: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: Self.oauthUsageURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data = try await send(request, source: .claudeCode)
        return try UsageParser.snapshot(from: data, fetchedAt: Date())
    }

    // MARK: - claude.ai browser session

    /// - Parameters:
    ///   - cookieHeader: Value for the `Cookie` header (see `ClaudeWebCookie.normalize`).
    ///   - organizationID: A previously resolved organization, to skip the lookup.
    public func fetchWebUsage(cookieHeader: String, organizationID: String?) async throws -> WebResult {
        var planName: String?
        let orgID: String
        if let known = organizationID ?? ClaudeWebCookie.value(named: "lastActiveOrg", in: cookieHeader),
           ClaudeWebCookie.isValidOrganizationID(known) {
            orgID = known
        } else {
            let organization = try await fetchOrganization(cookieHeader: cookieHeader)
            orgID = organization.id
            planName = organization.planName
        }

        let url = Self.webBaseURL.appendingPathComponent("organizations/\(orgID)/usage")
        let data = try await send(webRequest(url: url, cookieHeader: cookieHeader), source: .claudeWeb)
        let snapshot = try UsageParser.snapshot(from: data, fetchedAt: Date())
        return WebResult(snapshot: snapshot, organizationID: orgID, planName: planName)
    }

    private func fetchOrganization(cookieHeader: String) async throws -> (id: String, planName: String?) {
        let url = Self.webBaseURL.appendingPathComponent("organizations")
        let data = try await send(webRequest(url: url, cookieHeader: cookieHeader), source: .claudeWeb)
        guard let organizations = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw UsageError.invalidResponse("Unexpected organizations response.")
        }
        // Prefer the organization that has chat (the consumer plan) over API-only orgs.
        let candidates = organizations.filter { org in
            (JSONValue.string(org["uuid"]).map(ClaudeWebCookie.isValidOrganizationID)) == true
        }
        let chosen = candidates.first { (($0["capabilities"] as? [String]) ?? []).contains("chat") }
            ?? candidates.first
        guard let chosen, let id = JSONValue.string(chosen["uuid"]) else {
            throw UsageError.noOrganization
        }
        return (id, PlanName.from(capabilities: (chosen["capabilities"] as? [String]) ?? []))
    }

    private func webRequest(url: URL, cookieHeader: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
        // claude.ai sits behind bot protection that rejects non-browser user agents.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        return request
    }

    // MARK: - Transport

    private func send(_ request: URLRequest, source: UsageSourceKind) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw UsageError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.invalidResponse("Not an HTTP response.")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            throw UsageError.unauthorized(source: source, status: http.statusCode, message: Self.errorMessage(in: data))
        case 429:
            throw UsageError.rateLimited(retryAfter: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        default:
            throw UsageError.httpStatus(http.statusCode, message: Self.errorMessage(in: data))
        }
    }

    /// Pulls a human-readable message out of an error body.
    static func errorMessage(in data: Data) -> String? {
        if let json = try? JSONValue.parseObject(data) {
            let nested = JSONValue.object(json["error"])
            return JSONValue.string(nested?["message"]) ?? JSONValue.string(json["message"])
                ?? JSONValue.string(json["error"])
        }
        let body = String(decoding: data.prefix(4096), as: UTF8.self)
        if body.contains("cf-chl") || body.contains("Just a moment") || body.contains("challenge-platform") {
            return "blocked by claude.ai's bot protection. Paste the full Cookie header (including cf_clearance)"
        }
        return nil
    }

    /// `Retry-After` is either delta-seconds or an HTTP date.
    static func retryAfter(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let seconds = TimeInterval(header) {
            return seconds > 0 ? seconds : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return nil }
        let delay = date.timeIntervalSince(now)
        return delay > 0 ? delay : nil
    }
}
