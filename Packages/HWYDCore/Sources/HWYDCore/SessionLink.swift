import Foundation

/// Parses `hwyd://` links that point at one recording.
/// Accepted forms: the canonical `hwyd://session/<uuid>` from exports, and the
/// MCP resource URIs `hwyd://recording/<uuid>/{transcript,summary,notes}.md`.
public struct SessionLink: Equatable, Sendable {
    public enum Artifact: String, Sendable { case transcript, summary, notes }
    public let recordingID: UUID
    public let artifact: Artifact?

    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == "hwyd", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.port == nil, components.query == nil, components.fragment == nil else { return nil }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first, let id = UUID(uuidString: first) else { return nil }
        switch (components.host?.lowercased(), parts.count) {
        case ("session", 1):
            recordingID = id; artifact = nil
        case ("recording", 1):
            recordingID = id; artifact = nil
        case ("recording", 2):
            guard parts[1].hasSuffix(".md"), let kind = Artifact(rawValue: String(parts[1].dropLast(3))) else { return nil }
            recordingID = id; artifact = kind
        default:
            return nil
        }
    }

    public static func session(_ id: UUID) -> URL { URL(string: "hwyd://session/" + id.uuidString.lowercased())! }
}
