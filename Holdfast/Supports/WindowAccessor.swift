//
//  WindowAccessor.swift
//  Holdfast
//
//  Created by apple on 2024/11/7.
//

import AppKit
import SwiftUI

struct WindowAccessor: NSViewRepresentable {
    var onWindowOpen: ((NSWindow?) -> Void)?
    var onWindowActive: ((NSWindow?) -> Void)?
    var onWindowDeactivate: ((NSWindow?) -> Void)?
    var onWindowClose: (() -> Void)?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.delegate = context.coordinator
                context.coordinator.window = window
                self.onWindowOpen?(window)
            } else {
                self.onWindowOpen?(nil)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onWindowActive: onWindowActive,
            onWindowDeactivate: onWindowDeactivate,
            onWindowClose: onWindowClose
        )
    }

    class Coordinator: NSObject, NSWindowDelegate {
        weak var window: NSWindow?
        var onWindowActive: ((NSWindow?) -> Void)?
        var onWindowDeactivate: ((NSWindow?) -> Void)?
        var onWindowClose: (() -> Void)?

        init(onWindowActive: ((NSWindow?) -> Void)? = nil,
             onWindowDeactivate: ((NSWindow?) -> Void)? = nil,
             onWindowClose: (() -> Void)? = nil) {
            self.onWindowClose = onWindowClose
            self.onWindowActive = onWindowActive
            self.onWindowDeactivate = onWindowDeactivate
        }

        func windowWillClose(_ notification: Notification) {
            onWindowClose?()
        }
        
        func windowDidBecomeKey(_ notification: Notification) {
            onWindowActive?(window)
        }

        func windowDidResignKey(_ notification: Notification) {
            onWindowDeactivate?(window)
        }
    }
}
