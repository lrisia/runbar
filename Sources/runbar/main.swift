import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Menu bar only: no Dock icon. The main menu is never shown, but text fields
// need its Edit items for ⌘X, ⌘C, ⌘V, ⌘A and ⌘Z to work.
app.setActivationPolicy(.accessory)
let mainMenu = NSMenu()
let editItem = NSMenuItem()
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(.separator())
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu
mainMenu.addItem(editItem)
app.mainMenu = mainMenu
app.run()
