Kriya for the browser

Chromium browsers (Chrome, Edge, Brave, Vivaldi, Chromium): open chrome://extensions, turn on Developer mode, choose
"Load unpacked", and pick the "chromium" folder. Then press "Install Connection" in Kriya's Link Routing > Browsers tab.

Firefox: open about:debugging, choose "This Firefox", "Load Temporary Add-on", and pick the manifest.json in the
"firefox" folder. A permanent Firefox install needs the extension to be signed by Mozilla, which has not been done.

Safari is not covered: it needs a Safari extension built into the app, which this version does not have.

The extension asks for three permissions: contextMenus (the right-click entries), nativeMessaging (to talk to Kriya) and
activeTab (to read the address of the tab when you press its button). It has no access to page contents or to other
sites, and it loads no code from the internet.
