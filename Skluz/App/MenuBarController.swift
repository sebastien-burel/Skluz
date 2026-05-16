import AppKit

final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
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
        button.action = #selector(handleClick(_:))
    }

    @objc private func handleClick(_ sender: Any?) {
        print("[Skluz] menubar clicked")
    }
}
