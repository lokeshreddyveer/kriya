// Kriya for the browser. It sends a link, the page you are on, or the text you selected to the Kriya app on this Mac.
// It reads a page's text only when you choose "Save Page to Kriya" for that tab (extract.js), nothing is sent over the
// network, and no remote code is run.
const HOST = "app.kriya.bridge";
const api = typeof browser !== "undefined" ? browser : chrome;

const MENU = [
  { id: "kriya-link", title: "Open Link with Kriya", contexts: ["link"] },
  { id: "kriya-page", title: "Open This Page with Kriya", contexts: ["page"] },
  { id: "kriya-selection", title: "Send Selection to Kriya", contexts: ["selection"] },
  { id: "kriya-page-markdown", title: "Save Page as Markdown (Kriya)", contexts: ["page"] },
  { id: "kriya-page-copy", title: "Copy Page as Markdown (Kriya)", contexts: ["page"] },
  { id: "kriya-page-shelf", title: "Put Page on Kriya's Shelf", contexts: ["page"] },
  { id: "kriya-page-pdf", title: "Save Page as PDF (Kriya)", contexts: ["page"] },
];

const PAGE_ACTIONS = {
  "kriya-page-markdown": "markdown",
  "kriya-page-copy": "copy",
  "kriya-page-shelf": "shelf",
  "kriya-page-pdf": "pdf",
};

// Reads the readable text of the tab you chose it in, and hands it to Kriya. The text is not kept here.
async function sendPage(tab, as) {
  if (!tab || tab.id === undefined) return;
  try {
    const results = await api.scripting.executeScript({ target: { tabId: tab.id }, files: ["extract.js"] });
    const page = results && results[0] && results[0].result;
    if (!page || !page.markdown) { flag("!", "Kriya found no readable text on this page."); return; }
    await deliver({ type: "page", as, title: page.title, url: page.url, site: page.site, byline: page.byline, markdown: page.markdown, truncated: !!page.truncated });
  } catch (error) {
    flag("!", "Kriya could not read this page. Browser pages and the store cannot be read.");
  }
}

async function buildMenu() {
  await api.contextMenus.removeAll();
  for (const item of MENU) api.contextMenus.create(item);
}

api.runtime.onInstalled.addListener(buildMenu);
if (api.runtime.onStartup) api.runtime.onStartup.addListener(buildMenu);

function flag(text, title) {
  api.action.setBadgeText({ text });
  if (title) api.action.setTitle({ title });
  if (text) setTimeout(() => api.action.setBadgeText({ text: "" }), 4000);
}

async function deliver(message) {
  try {
    const reply = await api.runtime.sendNativeMessage(HOST, message);
    if (!reply || !reply.ok) flag("!", "Kriya: " + ((reply && reply.error) || "no answer"));
  } catch (error) {
    flag("!", "Kriya could not be reached. Is the connection installed in Kriya's Link Routing settings?");
  }
}

api.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === "kriya-link" && info.linkUrl) {
    deliver({ type: "open", url: info.linkUrl });
  } else if (info.menuItemId === "kriya-page") {
    deliver({ type: "open", url: info.pageUrl || (tab && tab.url), title: tab && tab.title });
  } else if (info.menuItemId === "kriya-selection" && info.selectionText) {
    deliver({ type: "selection", text: info.selectionText, url: info.pageUrl });
  } else if (PAGE_ACTIONS[info.menuItemId]) {
    sendPage(tab, PAGE_ACTIONS[info.menuItemId]);
  }
});

api.action.onClicked.addListener((tab) => {
  if (tab && tab.url) deliver({ type: "open", url: tab.url, title: tab.title });
});
