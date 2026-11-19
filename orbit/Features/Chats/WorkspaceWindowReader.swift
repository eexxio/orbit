import SwiftUI

final class WorkspaceWindowReference {
    weak var value: UIWindow?
}

struct WorkspaceWindowReader: UIViewRepresentable {
    var updateWindow: (UIWindow?) -> Void

    func makeUIView(context: Context) -> WindowObserver { WindowObserver() }
    func updateUIView(_ view: WindowObserver, context: Context) {
        view.updateWindow = updateWindow
        updateWindow(view.window)
    }

    final class WindowObserver: UIView {
        var updateWindow: ((UIWindow?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateWindow?(window)
        }
    }
}

extension UIView {
    var firstResponderView: UIView? {
        if isFirstResponder { return self }
        for subview in subviews {
            if let first = subview.firstResponderView { return first }
        }
        return nil
    }
}
