import Foundation

enum HermesError: LocalizedError {
    case notConfigured, invalidAddress, notDashboard, wrongPassword, browserOnly
    case http(Int, String?), unsupported, socketClosed, server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add your Hermes server in Settings."
        case .invalidAddress: return "That server address isn't valid."
        case .notDashboard: return "That address didn't answer like a Hermes dashboard."
        case .wrongPassword: return "The username or password was rejected."
        case .browserOnly: return "This dashboard only allows browser sign-in. Enable Username & password on the host."
        case .http(let code, let detail): return detail.map { "Server error \(code): \($0)" } ?? "Server error \(code)."
        case .unsupported: return "The server sent a reply this app doesn't understand."
        case .socketClosed: return "The connection to the server was lost."
        case .server(let message): return message
        }
    }
}
