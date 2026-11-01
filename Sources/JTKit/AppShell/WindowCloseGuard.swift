import AppKit
import SwiftUI

/// Stops the window it sits in from closing while `isActive`, and calls
/// `ask` instead, e.g. to ask Save / Discard / Cancel. The close button,
/// ⌘W and File › Close all go through it. `ask` gets `close`, which closes
/// the window without asking again (after Save or Discard).
///
/// It sits in front of the window’s own delegate (SwiftUI’s) and passes
/// everything else on to it.
struct WindowCloseGuard: NSViewRepresentable {
    let isActive: Bool
    let ask: @MainActor (_ close: @escaping @MainActor () -> Void) -> Void

    func makeNSView(context: Context) -> GuardView {
        GuardView()
    }

    func updateNSView(_ view: GuardView, context: Context) {
        view.closeGuard.isActive = isActive
        view.closeGuard.ask = ask
        view.attach()
    }

    static func dismantleNSView(_ view: GuardView, coordinator: ()) {
        view.closeGuard.detach()
    }

    final class GuardView: NSView {
        let closeGuard = CloseGuard()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        func attach() {
            guard let window else { return }
            closeGuard.attach(to: window)
        }
    }
}

/// The window delegate that asks before closing. Every other delegate
/// message goes to the delegate the window had.
@MainActor
final class CloseGuard: NSObject, NSWindowDelegate {
    var isActive = false
    var ask: (@MainActor (_ close: @escaping @MainActor () -> Void) -> Void)?
    private weak var window: NSWindow?
    // read by the Objective-C runtime’s forwarding, which runs on the main
    // thread for a window’s delegate
    nonisolated(unsafe) private weak var original: (any NSWindowDelegate)?
    private var closingWithoutAsking = false

    func attach(to window: NSWindow) {
        guard self.window !== window || window.delegate !== self else { return }
        detach()
        self.window = window
        // another guard in front (an editor replaced before the old one is
        // dismantled): take over the delegate it kept, not the guard itself,
        // which goes away
        if let other = window.delegate as? CloseGuard {
            original = other.original
        } else {
            original = window.delegate
        }
        window.delegate = self
    }

    /// Gives the window its own delegate back, also when another guard
    /// took over in front of this one.
    func detach() {
        if let window {
            if window.delegate === self {
                window.delegate = original
            } else if let other = window.delegate as? CloseGuard, other.original === self {
                other.original = original
            }
        }
        window = nil
        original = nil
    }

    /// Closes the window, e.g. after Save or Discard, without asking again.
    ///
    /// The question’s buttons run while its sheet is still on the window,
    /// and a window with a sheet ignores a close: then it closes once the
    /// sheet is gone (up to `sheetWait`).
    func close(_ window: NSWindow, sheetWait: Duration = .seconds(5)) {
        guard window.attachedSheet == nil else {
            Task { @MainActor [weak self, weak window] in
                let clock = ContinuousClock()
                let deadline = clock.now + sheetWait
                while let window, window.attachedSheet != nil, clock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                guard let window, window.attachedSheet == nil else { return }
                // a guard dismantled meanwhile no longer stands in front
                if let self { closeNow(window) } else { window.performClose(nil) }
            }
            return
        }
        closeNow(window)
    }

    private func closeNow(_ window: NSWindow) {
        closingWithoutAsking = true
        defer { closingWithoutAsking = false }
        window.performClose(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isActive && !closingWithoutAsking {
            ask? { [weak self, weak sender] in
                if let sender { self?.close(sender) }
            }
            return false
        }
        return original?.windowShouldClose?(sender) ?? true
    }

    // Everything else goes to the window’s own delegate.

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        if let original, original.responds(to: selector) { return original }
        return super.forwardingTarget(for: selector)
    }
}
