// Kriya for the browser. It sends a link, the page you are on, or the text you selected to the Kriya app on this Mac,
// and does nothing else: no page content is read, nothing is sent over the network, and no remote code is run.
const HOST = "app.kriya.bridge";
const api = typeof browser !== "undefined" ? browser : chrome;

const MENU = [
  { id: "kriya-link", title: "Open Link with Kriya", contexts: ["link"] },
  { id: "kriya-page", title: "Open This Page with Kriya", contexts: ["page"] },
  { id: "kriya-selection", title: "Send Selection to Kriya", contexts: ["selection"] },
];

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
  }
});

api.action.onClicked.addListener((tab) => {
  if (tab && tab.url) deliver({ type: "open", url: tab.url, title: tab.title });
});
