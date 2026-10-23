import Foundation

/// Other Mac utilities that do some of what Kriya does. Two programs that both watch the mouse, remap keys or move windows can
/// fight, so Kriya says which ones are running and what they overlap on.
struct CompetingUtility: Equatable, Identifiable {
    let name: String
    /// Bundle identifier prefixes that identify it when it runs.
    let bundlePrefixes: [String]
    /// Words in the running app's name that identify it, for apps whose identifier is not certain.
    let nameWords: [String]
    /// What it overlaps with in Kriya, in plain words.
    let overlaps: String
    var id: String { name }
}

struct RunningProgram: Equatable {
    let bundleID: String?
    let name: String?
}

enum CompetingUtilities {
    static let known: [CompetingUtility] = [
        CompetingUtility(name: "Karabiner-Elements", bundlePrefixes: ["org.pqrs.Karabiner"], nameWords: ["karabiner"], overlaps: "Keyboard remapping and mouse-button remapping. Both change keys before apps see them, so a key can be remapped twice."),
        CompetingUtility(name: "BetterTouchTool", bundlePrefixes: ["com.hegenberg.BetterTouchTool"], nameWords: ["bettertouchtool"], overlaps: "Mouse buttons, gestures, window snapping, shortcuts and window-button actions."),
        CompetingUtility(name: "Logi Options+", bundlePrefixes: ["com.logi.", "com.logitech."], nameWords: ["logi options", "logitech"], overlaps: "Logitech mouse buttons, gestures and scrolling. Its settings can override Kriya's for the same buttons."),
        CompetingUtility(name: "LinearMouse", bundlePrefixes: ["com.lujjjh.LinearMouse"], nameWords: ["linearmouse"], overlaps: "Pointer speed, acceleration, scrolling direction and button remapping."),
        CompetingUtility(name: "Mos", bundlePrefixes: ["com.caldis.Mos"], nameWords: [], overlaps: "Smooth scrolling and scroll direction."),
        CompetingUtility(name: "Scroll Reverser", bundlePrefixes: ["com.pilotmoon.scroll-reverser"], nameWords: ["scroll reverser"], overlaps: "Scroll direction per device."),
        CompetingUtility(name: "SteerMouse", bundlePrefixes: ["jp.plentycom.boa.SteerMouse"], nameWords: ["steermouse"], overlaps: "Mouse speed, buttons and scrolling."),
        CompetingUtility(name: "Rectangle", bundlePrefixes: ["com.knollsoft.Rectangle"], nameWords: [], overlaps: "Window snapping and shortcuts."),
        CompetingUtility(name: "Magnet", bundlePrefixes: ["com.crowdcafe.windowmagnet"], nameWords: ["magnet"], overlaps: "Window snapping and shortcuts."),
        CompetingUtility(name: "BetterSnapTool", bundlePrefixes: ["com.hegenberg.BetterSnapTool"], nameWords: ["bettersnaptool"], overlaps: "Window snapping and drag-to-edge."),
        CompetingUtility(name: "Moom", bundlePrefixes: ["com.manytricks.Moom"], nameWords: ["moom"], overlaps: "Window snapping and saved layouts."),
        CompetingUtility(name: "AltTab", bundlePrefixes: ["com.lwouis.alt-tab-macos"], nameWords: ["alttab"], overlaps: "The window switcher. Both may want ⌥Tab."),
        CompetingUtility(name: "Contexts", bundlePrefixes: ["com.contextsformac.Contexts"], nameWords: [], overlaps: "The window switcher."),
        CompetingUtility(name: "Alfred", bundlePrefixes: ["com.runningwithcrayons.Alfred"], nameWords: [], overlaps: "The launcher, clipboard history, snippets and text expansion. Both may want ⌘Space."),
        CompetingUtility(name: "Raycast", bundlePrefixes: ["com.raycast.macos"], nameWords: ["raycast"], overlaps: "The launcher, clipboard history, snippets, window management and quicklinks. Both may want ⌘Space."),
        CompetingUtility(name: "Keyboard Maestro", bundlePrefixes: ["com.stairways.keyboardmaestro"], nameWords: ["keyboard maestro"], overlaps: "Macros, text expansion, shortcuts and automation."),
        CompetingUtility(name: "Hammerspoon", bundlePrefixes: ["org.hammerspoon.Hammerspoon"], nameWords: ["hammerspoon"], overlaps: "Anything its scripts do: shortcuts, windows, automation."),
        CompetingUtility(name: "TextExpander", bundlePrefixes: ["com.smileonmymac.textexpander"], nameWords: ["textexpander"], overlaps: "Text expansion and snippets. Both watch what you type."),
        CompetingUtility(name: "Espanso", bundlePrefixes: ["com.federicoterzi.espanso"], nameWords: ["espanso"], overlaps: "Text expansion."),
        CompetingUtility(name: "PopClip", bundlePrefixes: ["com.pilotmoon.popclip"], nameWords: ["popclip"], overlaps: "The selection bar."),
        CompetingUtility(name: "Maccy", bundlePrefixes: ["org.p0deje.Maccy"], nameWords: ["maccy"], overlaps: "Clipboard history."),
        CompetingUtility(name: "Paste", bundlePrefixes: ["com.wiheads.paste"], nameWords: [], overlaps: "Clipboard history."),
        CompetingUtility(name: "Bartender", bundlePrefixes: ["com.surteesstudios.Bartender"], nameWords: ["bartender"], overlaps: "Menu-bar icon hiding."),
        CompetingUtility(name: "Ice", bundlePrefixes: ["com.jordanbaird.Ice"], nameWords: [], overlaps: "Menu-bar icon hiding."),
        CompetingUtility(name: "Amphetamine", bundlePrefixes: ["com.if.Amphetamine"], nameWords: ["amphetamine"], overlaps: "Keeping the Mac awake."),
        CompetingUtility(name: "Caffeine", bundlePrefixes: ["com.intelliscapesolutions.caffeine"], nameWords: ["caffeine"], overlaps: "Keeping the Mac awake."),
        CompetingUtility(name: "SoundSource", bundlePrefixes: ["com.rogueamoeba.soundsource"], nameWords: ["soundsource"], overlaps: "Per-app volume, outputs and the equaliser. Both tap app audio."),
        CompetingUtility(name: "BetterDisplay", bundlePrefixes: ["pro.betterdisplay.BetterDisplay"], nameWords: ["betterdisplay"], overlaps: "Display resolution, scaling and brightness."),
        CompetingUtility(name: "CleanShot X", bundlePrefixes: ["pl.maketheweb.cleanshotx"], nameWords: ["cleanshot"], overlaps: "Screen capture, recording and annotation. Both may want the same capture shortcuts."),
        CompetingUtility(name: "Shottr", bundlePrefixes: ["cc.ffitch.shottr"], nameWords: ["shottr"], overlaps: "Screen capture, OCR and the pixel ruler."),
        CompetingUtility(name: "Dropover", bundlePrefixes: ["me.damir.dropover"], nameWords: ["dropover"], overlaps: "The file shelf."),
        CompetingUtility(name: "Yoink", bundlePrefixes: ["net.mediaatelier.Yoink"], nameWords: ["yoink"], overlaps: "The file shelf."),
        CompetingUtility(name: "Hazel", bundlePrefixes: ["com.noodlesoft.Hazel"], nameWords: [], overlaps: "Folder rules. Two tools moving the same files can race."),
        CompetingUtility(name: "AppCleaner", bundlePrefixes: ["net.freemacsoft.AppCleaner"], nameWords: ["appcleaner"], overlaps: "App removal and leftovers."),
    ]

    /// Which of the known utilities are among the running programs. Each is listed once, in the order of `known`.
    static func detect(in running: [RunningProgram]) -> [CompetingUtility] {
        known.filter { utility in
            running.contains { program in
                if let id = program.bundleID, utility.bundlePrefixes.contains(where: { id == $0 || id.hasPrefix($0) }) { return true }
                if let name = program.name?.lowercased(), utility.nameWords.contains(where: { name.contains($0) }) { return true }
                return false
            }
        }
    }
}
