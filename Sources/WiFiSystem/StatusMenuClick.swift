/// Whether a mouse-down on the menu bar icon opens the right-click menu instead of the panel: any right-button
/// click, or a left click with Control held (the Mac's usual secondary click). A left click with Command never
/// does, because ⌘-drag is how menu bar icons are rearranged.
public func isStatusMenuClick(rightButton: Bool, control: Bool, command: Bool) -> Bool {
    rightButton || (control && !command)
}
