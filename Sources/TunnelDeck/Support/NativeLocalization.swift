import AppKit
import SwiftUI
import TunnelLocalization

extension View {
    func localizedWindowTitle(_ title: String) -> some View {
        background(WindowTitleBridge(title: title).frame(width: 0, height: 0))
    }
}

private struct WindowTitleBridge: NSViewRepresentable {
    let title: String
    func makeNSView(context: Context) -> TitleView { TitleView() }
    func updateNSView(_ view: TitleView, context: Context) {
        view.localizedTitle = title
        view.window?.title = title
    }
    final class TitleView: NSView {
        var localizedTitle = ""
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.title = localizedTitle
        }
    }
}

/// Only titles change: AppKit retains targets, validation, shortcuts, and responders.
@MainActor enum MenuLocalization {
    private static var delegates: [ObjectIdentifier: LocalizingMenuDelegate] = [:]
    private static let actions = [
        "orderFrontStandardAboutPanel:": "menu.about",
        "showSettingsWindow:": "menu.settings",
        "showPreferencesWindow:": "menu.settings",
        "hide:": "menu.hide",
        "hideOtherApplications:": "menu.hide_others",
        "unhideAllApplications:": "menu.show_all",
        "terminate:": "menubaractions.quit_tunneldeck",
        "performClose:": "menu.close",
        "closeAll:": "menu.close_all",
        "undo:": "menu.undo", "redo:": "menu.redo",
        "cut:": "menu.cut", "copy:": "menu.copy", "paste:": "menu.paste",
        "delete:": "action.delete",
        "pasteAsPlainText:": "menu.paste_match_style", "selectAll:": "menu.select_all",
        "performMiniaturize:": "menu.minimize", "performZoom:": "menu.zoom",
        "arrangeInFront:": "menu.bring_all_front",
        "toggleFullScreen:": "menu.full_screen"
    ]
    private static let titleKeys = [
        "menu.file", "menu.edit", "menu.view", "menu.window", "menu.help",
        "menu.settings", "menu.services", "menu.about", "menu.hide", "menu.hide_others",
        "menu.show_all", "menu.minimize", "menu.zoom", "menu.bring_all_front",
        "menu.full_screen", "menu.close", "menu.undo", "menu.redo", "menu.cut",
        "menu.copy", "menu.paste", "menu.paste_match_style", "menu.select_all"
    ]
    static func refresh() { refresh(menu: NSApp?.mainMenu) }
    static func refresh(menu: NSMenu?) {
        guard let menu else { return }
        // SwiftUI rebuilds standard item labels in its delegate callbacks. Forward
        // those callbacks first, then apply the selected language to the result.
        delegates = delegates.filter { $0.value.menu != nil }
        if !(menu.delegate is LocalizingMenuDelegate), menu !== NSApp?.servicesMenu {
            let delegate = LocalizingMenuDelegate(menu: menu, original: menu.delegate)
            delegates[ObjectIdentifier(menu)] = delegate
            menu.delegate = delegate
        }
        if menu === NSApp?.mainMenu?.items.first?.submenu {
            // Some SwiftUI versions insert Settings even when appSettings is replaced.
            let settings = menu.items.filter { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command) }
            let keep = settings.first { $0.title == L10n.text("menu.settings") } ?? settings.first
            for duplicate in settings where duplicate !== keep { menu.removeItem(duplicate) }
        }
        for originalItem in menu.items {
            var item = originalItem
            if let action = item.action, actions[NSStringFromSelector(action)] != nil,
               !(item is LocalizedMenuItem), item.view == nil {
                let replacement = LocalizedMenuItem(title: item.title, action: action, keyEquivalent: item.keyEquivalent)
                replacement.target = item.target
                replacement.keyEquivalentModifierMask = item.keyEquivalentModifierMask
                replacement.isEnabled = item.isEnabled
                replacement.state = item.state
                replacement.isHidden = item.isHidden
                replacement.isAlternate = item.isAlternate
                replacement.image = item.image
                replacement.indentationLevel = item.indentationLevel
                replacement.representedObject = item.representedObject
                replacement.tag = item.tag
                replacement.toolTip = item.toolTip
                replacement.submenu = item.submenu
                let index = menu.index(of: item)
                menu.removeItem(item)
                menu.insertItem(replacement, at: index)
                item = replacement
            }
            var actionKey = item.action.flatMap { actions[NSStringFromSelector($0)] }
            if actionKey == "menu.full_screen", NSApp?.keyWindow?.styleMask.contains(.fullScreen) == true {
                actionKey = "menu.exit_full_screen"
            }
            let titleKey = titleKeys.first { key in
                [.russian, .englishUS].contains { language in
                    L10n.message(key).resolve(language: language) == item.title
                }
            }
            if let key = actionKey ?? titleKey {
                item.title = L10n.text(key)
                item.submenu?.title = item.title
            }
            if let submenu = item.submenu { refresh(menu: submenu) }
        }
    }

    /// AppKit validates standard items after menuWillOpen and resets their titles
    /// to the process language. An owned item translates those updates while
    /// preserving the original action, target, and responder-chain validation.
    private final class LocalizedMenuItem: NSMenuItem {
        override var title: String {
            get { super.title }
            set {
                let translated = MainActor.assumeIsolated { () -> String in
                    guard let action, let key = actions[NSStringFromSelector(action)] else { return newValue }
                    let actual = key == "menu.full_screen" && NSApp?.keyWindow?.styleMask.contains(.fullScreen) == true
                        ? "menu.exit_full_screen" : key
                    return L10n.text(actual)
                }
                super.title = translated
            }
        }
    }

    private final class LocalizingMenuDelegate: NSObject, NSMenuDelegate {
        weak var menu: NSMenu?
        weak var original: (any NSMenuDelegate)?
        init(menu: NSMenu, original: (any NSMenuDelegate)?) {
            self.menu = menu; self.original = original
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            original?.menuNeedsUpdate?(menu)
            MenuLocalization.refresh(menu: menu)
            MenuLocalization.refresh()
        }
        func menuWillOpen(_ menu: NSMenu) {
            original?.menuWillOpen?(menu)
            MenuLocalization.refresh(menu: menu)
            MenuLocalization.refresh()
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || original?.responds(to: selector) == true
        }
        override func forwardingTarget(for selector: Selector!) -> Any? { original }
    }
}
