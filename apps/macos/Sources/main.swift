import AppKit

// A browser starts Kriya's program in this mode to pass one message to the app, and no window or menu bar icon appears.
if NativeHost.isRequested(CommandLine.arguments) { NativeHost.run() }

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
