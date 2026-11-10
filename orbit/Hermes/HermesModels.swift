import Foundation

struct HermesSession: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let lastActive: Double?
}

struct HermesMessage: Codable, Sendable {
    let role: String
    let text: String
}
