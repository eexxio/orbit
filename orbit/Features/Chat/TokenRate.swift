import Foundation

/// Generation speed of one assistant reply, in output tokens per second.
///
/// The clock starts at the first streamed word, so time spent thinking or running tools
/// before the reply begins doesn't drag the number down. When the host reports how many
/// tokens it generated the rate is exact; otherwise it's estimated from the text length.
nonisolated struct TokenRate: Equatable, Sendable {
    let tokens: Int
    let seconds: Double
    /// True when `tokens` is a length-based guess rather than the host's own count.
    let isEstimate: Bool

    var perSecond: Double { Double(tokens) / seconds }

    /// Nil when there's too little to measure (no tokens, or under a quarter second).
    init?(tokens: Int?, text: String, since start: Date, until end: Date = .now) {
        let seconds = end.timeIntervalSince(start)
        let counted = tokens.flatMap { $0 > 0 ? $0 : nil }
        let tokens = counted ?? Self.estimate(text)
        guard tokens > 0, seconds >= 0.25 else { return nil }
        self.tokens = tokens
        self.seconds = seconds
        self.isEstimate = counted == nil
    }

    /// Roughly four characters per token, the usual rule of thumb for English BPE vocabularies.
    static func estimate(_ text: String) -> Int {
        Int((Double(text.count) / 4).rounded(.up))
    }

    /// For example "42 tok/s", or "~42 tok/s" when estimated.
    var label: String {
        let rate = perSecond >= 10 ? String(Int(perSecond.rounded())) : String(format: "%.1f", perSecond)
        return "\(isEstimate ? "~" : "")\(rate) tok/s"
    }

    var accessibilityLabel: String {
        "\(isEstimate ? "About " : "")\(Int(perSecond.rounded())) tokens per second, "
            + "\(tokens) tokens in \(String(format: "%.1f", seconds)) seconds"
    }
}
