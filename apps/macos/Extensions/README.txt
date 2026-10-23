Kriya for the browser

Chromium browsers (Chrome, Edge, Brave, Vivaldi, Chromium): open chrome://extensions, turn on Developer mode, choose
"Load unpacked", and pick the "chromium" folder. Then press "Install Connection" in Kriya's Link Routing > Browsers tab.

Firefox: open about:debugging, choose "This Firefox", "Load Temporary Add-on", and pick the manifest.json in the
"firefox" folder. A permanent Firefox install needs the extension to be signed by Mozilla, which has not been done.

Safari is not covered: it needs a Safari extension built into the app, which this version does not have.

The extension asks for four permissions: contextMenus (the right-click entries), nativeMessaging (to talk to Kriya),
activeTab (to read the address of the tab when you press its button, and to read a page only when you ask) and scripting
(to run its own bundled extract.js in that one tab, only when you choose a "Page" entry from the right-click menu). It reads
a page's text only then, only in that tab, and sends it only to Kriya on this Mac. It has no access to other sites and it
loads no code from the internet.

Right-click a page for: Save Page as Markdown, Copy Page as Markdown, Put Page on Kriya's Shelf, Save Page as PDF. Files go
to Documents/Kriya Pages.
