import Foundation

/// BriefBar's first launch, before it saved anything of its own, and what it starts with then: a look, and one menu-bar
/// item, each saved as if you had chosen it in Settings, so that it's yours from then on. An update never counts as a new
/// install: every version since the first saves `launchedKey` each time it launches, so every install that ever launched
/// has it, and keeps the look and the menu bar it had.
public enum NewInstall {
    /// Saved at every launch.
    public static let launchedKey = "hasLaunched"

    /// Whether BriefBar never launched with these preferences.
    public static func isNew(_ defaults: some SettingsStorage) -> Bool {
        defaults.object(forKey: launchedKey) == nil
    }

    /// Saves that BriefBar launched, so it's a new install no more.
    public static func launched(_ defaults: some SettingsStorage) {
        defaults.set(true, forKey: launchedKey)
    }

    // MARK: The look

    /// The options Settings › Appearance has on for a new install. The others start off, as they do for everyone.
    public static let interfaceOptions: Set<InterfaceOption> = [.clearerStates, .readableRows, .simpleLayoutControls]

    /// On a new install, saves its look, as Settings › Appearance saves what you choose: an option that's somehow saved
    /// already keeps its value. Does nothing once BriefBar has launched, so an update keeps your look.
    public static func saveLook(to defaults: some SettingsStorage) {
        guard isNew(defaults) else { return }
        var options = InterfaceOptions.load(from: defaults)
        for option in interfaceOptions where defaults.object(forKey: option.defaultsKey) == nil {
            options[option] = true
        }
        options.save(to: defaults)
    }

    // MARK: The menu bar

    /// How a new install's menu-bar item shows its sections: added up by state, with one list by state, as Settings › Menu
    /// Bar sets them.
    public static let menuBarItemOptions = MenuBarItemOptions(byState: true, listByState: true)

    /// A new install's menu bar: every section in one item, as Put All in One Item puts them, those of the sources that
    /// are off too, so that each source you turn on joins it, and those that start hidden, such as the sprint, hidden in
    /// it.
    /// - Parameters:
    ///   - sections: every section that can show in the menu bar, in the sources' order.
    ///   - hidden: those that start hidden there.
    public static func menuBarLayout(sections: [SectionID], hidden: Set<SectionID>) -> SectionLayout {
        var layout = SectionLayout(.menuBar)
        layout.combineAll(sections)
        for section in sections where hidden.contains(section) {
            layout.hide(section)
        }
        return layout
    }

    /// On a new install, saves its menu bar (`menuBarLayout`), with its item's options. Does nothing once BriefBar has
    /// launched, or a menu bar is saved, so an update keeps your arrangement.
    public static func saveMenuBar(sections: [SectionID], hidden: Set<SectionID>, to defaults: some SettingsStorage) {
        guard isNew(defaults), defaults.object(forKey: Surface.menuBar.defaultsKey) == nil else { return }
        let layout = menuBarLayout(sections: sections, hidden: hidden)
        guard let item = layout.items.first else { return }
        layout.save(to: defaults)
        var options = MenuBarItemOptions.load(from: defaults)
        if options[item.id] == nil {
            options[item.id] = menuBarItemOptions
        }
        MenuBarItemOptions.save(options, to: defaults)
    }
}
