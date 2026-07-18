import Foundation

enum DeepLinkParser {
    private static let codeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

    static func parse(_ url: URL) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "soloshot",
              components.host?.lowercased() == "handoff",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw HandoffClientError.invalidCode
        }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 1 else {
            throw HandoffClientError.invalidCode
        }
        return try normalizeCode(String(parts[0]))
    }

    static func normalizeCode(_ value: String) throws -> String {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 6, code.allSatisfy(codeAlphabet.contains) else {
            throw HandoffClientError.invalidCode
        }
        return code
    }
}
