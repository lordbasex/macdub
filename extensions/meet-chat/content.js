// MacDub for Google Meet: posts MacDub's translations in the chat and reports new chat messages.
// Meet's markup is not an API; everything here looks for it defensively and logs what it finds.

const log = (...a) => console.log('[MacDub]', ...a);
const seen = new Set();
let primed = false;

// --- Posting -------------------------------------------------------------------------------

// The chat is the panel titled "In-call messages" ("Mensajes de la llamada"…); its box says
// "Send a message" ("Envía un mensaje"…). Only that box is ever written to — never another
// field of the page (captions, notes…).
const CHAT_BOX = /send a message|envía un mensaje|enviar un mensaje|enviar mensagem|envie uma mensagem/i;
const CHAT_BUTTON = /chat|in-call messages|mensajes de la llamada|mensagens na chamada/i;

const visible = el => el && el.offsetParent !== null && el.getClientRects().length > 0;
const label = el => (el.getAttribute('aria-label') || el.getAttribute('placeholder') || '').trim();

function chatInput() {
  return [...document.querySelectorAll('textarea, [contenteditable="true"]')]
    .find(el => visible(el) && CHAT_BOX.test(label(el))) || null;
}

function chatButton() {
  // The toolbar toggle (bottom right), not buttons inside the panel.
  return [...document.querySelectorAll('button')]
    .filter(b => visible(b) && CHAT_BUTTON.test(label(b)))
    .sort((a, b) => b.getBoundingClientRect().top - a.getBoundingClientRect().top)[0] || null;
}

const wait = ms => new Promise(r => setTimeout(r, ms));

async function post(text) {
  let input = chatInput();
  let opened = false;
  if (!input) {
    // Chat closed: open it just for this message, then put it back.
    const button = chatButton();
    if (!button) { log('chat button not found', probe()); return false; }
    button.click();
    opened = true;
    for (let i = 0; i < 20 && !input; i++) { await wait(100); input = chatInput(); }
  }
  if (!input) { log('chat box not found', probe()); return false; }
  // Remember it before sending: Meet may render it back before this function returns.
  posted.push(normalize(text));
  if (posted.length > 50) posted.shift();
  input.focus();
  if (input.tagName === 'TEXTAREA') {
    // React-style inputs ignore .value = …; use the native setter and announce the change.
    Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value').set.call(input, text);
  } else {
    input.textContent = text;
  }
  input.dispatchEvent(new Event('input', { bubbles: true }));
  await wait(150);
  const panel = input.closest('aside, [role="complementary"], [role="dialog"]') || document;
  const send = [...panel.querySelectorAll('button')]
    .find(b => visible(b) && !b.disabled && /send|enviar|envía/i.test(label(b)));
  if (send) send.click();
  else input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true }));
  log('posted', JSON.stringify(text), send ? '(send button)' : '(Enter)', opened ? '(chat opened for it)' : '');
  if (opened) { await wait(400); chatButton()?.click(); }
  return true;
}

/// What the page offers, for fixing the selectors when Meet changes.
function probe() {
  const inputs = [...document.querySelectorAll('textarea, [contenteditable="true"]')]
    .map(el => `${el.tagName.toLowerCase()} "${label(el)}"${visible(el) ? '' : ' (hidden)'}`);
  const buttons = [...document.querySelectorAll('button')].map(label)
    .filter(l => /chat|mensaje|message|mensag|send|enviar|envía/i.test(l));
  const messages = document.querySelectorAll('[data-message-id]').length;
  return { inputs, buttons, messages };
}
window.macdubProbe = probe;

// --- Reading ---------------------------------------------------------------------------------

const normalize = t => t.replace(/\s+/g, ' ').trim();
const posted = [];   // our own messages come back through the chat: never report them

function messageElements() {
  // Buttons inside a message (pin, "keep"…) carry the id too: keep only the outermost.
  return [...document.querySelectorAll('[data-message-id]')]
    .filter(el => !el.parentElement?.closest('[data-message-id]'));
}

/// The message text without its buttons and icon ligatures ("keep", "Fijar mensaje"…).
function textOf(el) {
  const copy = el.cloneNode(true);
  copy.querySelectorAll('button, [role="button"], i, svg, [aria-hidden="true"], [data-tooltip], [role="tooltip"]')
    .forEach(n => n.remove());
  return normalize(copy.innerText || copy.textContent || '');
}

function authorOf(el) {
  const holder = el.closest('[data-sender-name]') || el.parentElement?.closest('[data-sender-id]');
  return holder?.getAttribute('data-sender-name') || null;
}

function scan() {
  for (const el of messageElements()) {
    const id = el.getAttribute('data-message-id');
    if (seen.has(id)) continue;
    const text = textOf(el);
    if (!text) continue;   // still rendering: look again on the next change
    seen.add(id);
    if (!primed) continue;   // messages already there when MacDub connected are history
    const mine = posted.findIndex(p => p === text || text.startsWith(p));
    if (mine >= 0) { posted.splice(mine, 1); continue; }
    const author = authorOf(el);
    log('received', author, JSON.stringify(text));
    chrome.runtime.sendMessage({ type: 'received', text, author });
  }
  primed = true;
}

new MutationObserver(() => scan()).observe(document.body, { childList: true, subtree: true });
scan();

// --- Polling MacDub --------------------------------------------------------------------------

let connected = null;
async function poll() {
  try {
    const r = await chrome.runtime.sendMessage({ type: 'poll' });
    if (r.connected !== connected) { connected = r.connected; log(connected ? 'connected to MacDub' : 'MacDub not found'); }
    // page.js sends the virtual microphone while MacDub translates with "send as audio".
    const mic = r.connected && r.virtualMic ? 'on' : 'off';
    if (document.documentElement.dataset.macdubMic !== mic) {
      document.documentElement.dataset.macdubMic = mic;
      log('virtual microphone', mic);
    }
    for (const text of r.messages) await post(text);
  } catch (e) {
    log('poll failed', e.message);
  }
  setTimeout(poll, connected ? 700 : 3000);
}
poll();
log('loaded on', location.href);
setTimeout(() => log('probe', JSON.stringify(probe())), 5000);
