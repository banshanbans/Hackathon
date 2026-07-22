import Foundation

enum DeepLinkParser {
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
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6,
              code.unicodeScalars.allSatisfy({ (48...57).contains($0.value) })
        else {
            throw HandoffClientError.invalidCode
        }
        return code
    }
}
