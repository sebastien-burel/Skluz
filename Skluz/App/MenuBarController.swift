import AppKit
import SwiftUI

final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    init(viewModel: TunnelsViewModel) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        super.init()
        configurePopover(viewModel: viewModel)
        configureButton()
    }

    private func configurePopover(viewModel: TunnelsViewModel) {
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(viewModel: viewModel)
        )
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        if let image = NSImage(
            systemSymbolName: "arrow.left.arrow.right.square",
            accessibilityDescription: "Skluz"
        ) {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "Skluz"
        }
        button.target = self
        button.action = #selector(togglePopover(_:))
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
}
