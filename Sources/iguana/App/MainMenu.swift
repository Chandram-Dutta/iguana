import AppKit

/// An app without a Dock icon still needs a menu bar for Copy, Paste, Close and Quit to work
/// in its windows.
final class MainMenu: NSObject {
    var onSettings: (() -> Void)?

    func make() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [(String, Selector?, String)]) {
            let menu = NSMenu(title: title)
            for (name, action, key) in items {
                if name == "-" {
                    menu.addItem(.separator())
                } else {
                    menu.addItem(NSMenuItem(title: name, action: action, keyEquivalent: key))
                }
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        submenu("Iguana", [("Settings…", #selector(showSettings), ","), ("-", nil, ""), ("Quit Iguana", #selector(NSApplication.terminate(_:)), "q")])
        submenu("Edit", [
            ("Undo", Selector(("undo:")), "z"), ("Redo", Selector(("redo:")), "Z"), ("-", nil, ""),
            ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("Window", [("Close", #selector(NSWindow.performClose(_:)), "w"), ("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")])
        // A menu item does not keep its target alive: whoever makes the menu keeps this object.
        main.items.first?.submenu?.items.first?.target = self
        return main
    }

    @objc private func showSettings() { onSettings?() }
}
