import MarkdownUI
import SwiftUI

extension MarkdownUI.Theme {
    static let orbit = MarkdownUI.Theme.basic
        .codeBlock { CodeBlockView(configuration: $0) }
        .table { configuration in
            ScrollView(.horizontal, showsIndicators: true) {
                configuration.label
            }
            .markdownMargin(top: .zero, bottom: .em(1))
        }
}
