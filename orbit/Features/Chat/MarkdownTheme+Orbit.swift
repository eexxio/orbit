import MarkdownUI
import SwiftUI

extension MarkdownUI.Theme {
    static let orbit = MarkdownUI.Theme.basic
        .codeBlock { CodeBlockView(configuration: $0) }
        .table { configuration in
            ScrollView(.horizontal, showsIndicators: true) {
                configuration.label
                    .markdownTableBackgroundStyle(.init { row, _ in
                        row == 0 ? Color(.secondarySystemBackground) : Color.clear
                    })
                    .clipShape(.rect(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color(.separator), lineWidth: 0.5)
                            .allowsHitTesting(false)
                    }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.table")
            .markdownMargin(top: .zero, bottom: .em(1))
        }
}
