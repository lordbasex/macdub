// Bridge between the Meet page (content.js) and MacDub's local server. Requests go from here so
// MacDub sees this extension's origin (chrome-extension://…), which is the only one it answers.

const PORTS = Array.from({ length: 20 }, (_, i) => 8765 + i);
let base = null;

async function findMacDub() {
  if (base) return base;
  for (const port of PORTS) {
    try {
      const r = await fetch(`http://127.0.0.1:${port}/chat/hello`, { cache: 'no-store' });
      if (r.ok && (await r.json()).app === 'MacDub') return (base = `http://127.0.0.1:${port}`);
    } catch { /* not there */ }
  }
  return null;
}

async function call(path, init) {
  const url = await findMacDub();
  if (!url) return null;
  try {
    const r = await fetch(url + path, { cache: 'no-store', ...init });
    return r.ok ? r.json() : null;
  } catch {
    base = null;   // MacDub quit or moved port: look again next time
    return null;
  }
}

// The toolbar icon says whether MacDub is there: ON (green) or OFF (grey).
let shown = null;
function showConnected(connected, tabId) {
  if (shown === connected) return;
  shown = connected;
  chrome.action.setBadgeText({ text: connected ? 'ON' : 'OFF' });
  chrome.action.setBadgeBackgroundColor({ color: connected ? '#1f9d55' : '#6b6b6b' });
  chrome.action.setTitle({ title: connected
    ? 'MacDub · connected: live translation reaches this Meet chat'
    : 'MacDub · not connected: start Live translation in MacDub' });
}
showConnected(false);

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message.type === 'poll') {
    call('/chat/outbox').then(r => {
      showConnected(!!r, sender.tab?.id);
      reply({ connected: !!r, messages: r?.messages ?? [], virtualMic: !!r?.virtualMic });
    });
    return true;
  }
  if (message.type === 'received') {
    call('/chat/inbox', { method: 'POST', headers: { 'Content-Type': 'application/json' },
                          body: JSON.stringify({ text: message.text, author: message.author }) })
      .then(() => reply({}));
    return true;
  }
});
