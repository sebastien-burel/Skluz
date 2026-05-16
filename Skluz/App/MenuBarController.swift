import AppKit
import SwiftUI

final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var isSheetOpen = false
    nonisolated(unsafe) private var outsideClickMonitor: Any?

    init(viewModel: TunnelsViewModel) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        super.init()
        configurePopover(viewModel: viewModel)
        configureButton()
    }

    deinit {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
    }

    private func configurePopover(viewModel: TunnelsViewModel) {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let root = MenuBarPopoverView(viewModel: viewModel) { [weak self] isOpen in
            self?.isSheetOpen = isOpen
        }
        popover.contentViewController = NSHostingController(rootView: root)
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
            closePopover()
            return
        }
        showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
        installOutsideClickMonitor()
    }

    private func closePopover() {
        // Une sheet SwiftUI ouverte (éditeur ou préférences) doit garder le
        // popover ouvert : sa fermeture remet l'état SwiftUI à zéro proprement.
        // Fermer le popover par-dessous laisserait la sheet "logiquement
        // présentée" et bloquerait sa réouverture.
        guard !isSheetOpen else { return }
        popover.performClose(nil)
        removeOutsideClickMonitor()
    }

    // MARK: - NSPopoverDelegate

    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        !isSheetOpen
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
    }

    // MARK: - Outside click monitor

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }
}
