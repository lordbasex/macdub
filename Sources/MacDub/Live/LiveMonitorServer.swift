import Foundation
import Network

/// A debugging page for live translation, served on 127.0.0.1 only: the live transcript of both
/// sides and a latency meter (the browser times your microphone against the virtual one).
/// Started from the Live translation screen; nothing listens until then.
@MainActor
final class LiveMonitorServer: ObservableObject {
    @Published private(set) var url: URL?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.lordbasex.MacDub.live-monitor")
    /// JSON with the current state; read on the main actor for every request.
    var state: () -> [String: Any] = { [:] }

    func start(port: UInt16 = 8765) throws {
        if url != nil { return }
        var lastError: Error?
        for candidate in port..<(port + 20) {
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: candidate)!)
                parameters.allowLocalEndpointReuse = true
                let listener = try NWListener(using: parameters)
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in self?.serve(connection) }
                }
                listener.start(queue: queue)
                self.listener = listener
                url = URL(string: "http://127.0.0.1:\(candidate)/")
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? URLError(.cannotConnectToHost)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        url = nil
    }

    /// A request the page or the Meet extension made.
    struct Request {
        let method: String
        let path: String
        let origin: String?
        /// `Sec-Fetch-Mode`: "cors" for an extension's fetch, "no-cors" for a page's blind request.
        let fetchMode: String?
        let body: Data
    }

    /// Answers requests other than the page and `/state` (the chat bridge); nil → 404.
    var handler: (Request) -> (type: String, body: Data)? = { _ in nil }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    /// Reads until the headers and `Content-Length` bytes of body have arrived.
    private nonisolated func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            let separator = Data("\r\n\r\n".utf8)
            guard let end = buffer.range(of: separator) else {
                if complete || error != nil || buffer.count > 1_000_000 { connection.cancel() } else { self?.receive(connection, buffer: buffer) }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let length = head.split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
            let body = buffer[end.upperBound...]
            guard body.count >= min(length, 1_000_000) || complete || error != nil else {
                self?.receive(connection, buffer: buffer)
                return
            }
            Task { @MainActor in self?.respond(connection, head: head, body: Data(body.prefix(length))) }
        }
    }

    private func respond(_ connection: NWConnection, head: String, body: Data) {
        let lines = head.split(separator: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        let method = parts.first.map(String.init) ?? "GET"
        let path = parts.dropFirst().first.map(String.init) ?? "/"
        func header(_ name: String) -> String? {
            lines.first { $0.lowercased().hasPrefix(name + ":") }
                .map { $0.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces) }
        }
        // DNS rebinding: a web page could point its own name at 127.0.0.1 and read the
        // transcript. Only a Host naming this machine is served.
        let hostName = (header("host") ?? "").lowercased().split(separator: ":").first.map(String.init) ?? ""
        guard hostName == "127.0.0.1" || hostName == "localhost" else { return send(connection, status: "403 Forbidden") }

        if path.hasPrefix("/state") {
            send(connection, type: "application/json", body: (try? JSONSerialization.data(withJSONObject: state())) ?? Data("{}".utf8))
        } else if path == "/" || path.hasPrefix("/?") {
            send(connection, type: "text/html; charset=utf-8", body: Data(Self.page.utf8))
        } else if let answer = handler(Request(method: method, path: path, origin: header("origin"), fetchMode: header("sec-fetch-mode"), body: body)) {
            send(connection, type: answer.type, body: answer.body)
        } else {
            send(connection, status: "404 Not Found")
        }
    }

    private func send(_ connection: NWConnection, status: String = "200 OK", type: String = "text/plain", body: Data = Data()) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    static let page = #"""
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MacDub live monitor</title>
<style>
  :root { --bg:#16121f; --panel:#221b30; --text:#eee8f6; --muted:#a79bbd; --you:#f0a35e; --voice:#5ed3e0; --line:#3a3050; }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--text); font:15px/1.45 -apple-system, system-ui, sans-serif; padding:24px; }
  h1 { font-size:22px; margin:0 0 4px; }
  p { color:var(--muted); margin:0 0 16px; max-width:760px; }
  .row { display:flex; gap:12px; flex-wrap:wrap; align-items:end; margin-bottom:16px; }
  label { display:flex; flex-direction:column; gap:4px; font-size:13px; color:var(--muted); }
  select, button { font:inherit; padding:8px 10px; border-radius:8px; border:1px solid var(--line); background:var(--panel); color:var(--text); }
  button { cursor:pointer; background:#7b4fd6; border-color:#7b4fd6; }
  button.secondary { background:var(--panel); border-color:var(--line); }
  canvas { width:100%; height:180px; background:var(--panel); border-radius:12px; display:block; }
  .legend { display:flex; gap:16px; font-size:13px; color:var(--muted); margin:8px 0 16px; }
  .dot { display:inline-block; width:10px; height:10px; border-radius:50%; margin-right:6px; vertical-align:middle; }
  .stats { display:flex; gap:12px; flex-wrap:wrap; margin-bottom:16px; }
  .stat { background:var(--panel); border-radius:12px; padding:12px 16px; min-width:130px; }
  .stat b { display:block; font-size:24px; font-variant-numeric:tabular-nums; }
  .stat span { font-size:12px; color:var(--muted); }
  table { border-collapse:collapse; width:100%; max-width:760px; font-variant-numeric:tabular-nums; }
  td, th { text-align:left; padding:6px 10px; border-bottom:1px solid var(--line); font-size:14px; }
  th { color:var(--muted); font-weight:500; }
  .cols { display:grid; grid-template-columns:1fr 1fr; gap:16px; margin-bottom:8px; }
  @media (max-width:700px) { .cols { grid-template-columns:1fr; } }
  h2 { font-size:16px; margin:0 0 8px; } h2 small { color:var(--muted); font-weight:400; }
  .lines { background:var(--panel); border-radius:12px; padding:12px; height:320px; overflow-y:auto; }
  .line { margin-bottom:10px; } .line .o { color:var(--muted); font-size:13px; }
  .line .t { font-size:16px; } .line .d { color:var(--muted); font-size:11px; font-variant-numeric:tabular-nums; }
</style>
</head>
<body>
<h1>Traducción en vivo · monitor</h1>
<p id="status">Conectando con MacDub…</p>
<div class="cols">
  <div><h2>Vos <small id="mylang"></small></h2><div id="me" class="lines"></div></div>
  <div><h2>Ellos <small id="theirlang"></small></h2><div id="them" class="lines"></div></div>
</div>
<h1 style="margin-top:28px">Latencia</h1>
<p>Escucha a la vez tu micrófono (lo que decís) y la salida de MacDub (BlackHole 2ch, lo que recibiría Meet) con el mismo reloj.
Mide desde que terminás cada frase hasta que empieza la voz traducida: la demora de MacDub, sin Meet ni internet.
Con Traducción en vivo en marcha, hablá con pausas.</p>

<div class="row">
  <label>Tu micrófono <select id="mic"></select></label>
  <label>Salida de MacDub <select id="out"></select></label>
  <button id="start">Empezar</button>
  <button id="reset" class="secondary">Limpiar</button>
</div>

<canvas id="plot" width="1600" height="360"></canvas>
<div class="legend">
  <span><i class="dot" style="background:var(--you)"></i>Tu voz</span>
  <span><i class="dot" style="background:var(--voice)"></i>Voz traducida (BlackHole)</span>
</div>

<div class="stats">
  <div class="stat"><b id="median">–</b><span>mediana</span></div>
  <div class="stat"><b id="min">–</b><span>mínima</span></div>
  <div class="stat"><b id="max">–</b><span>máxima</span></div>
  <div class="stat"><b id="count">0</b><span>frases</span></div>
</div>

<table>
  <thead><tr><th>#</th><th>terminaste de hablar</th><th>empezó la voz</th><th>demora</th></tr></thead>
  <tbody id="rows"></tbody>
</table>

<script>
// Voice activity: level above THRESHOLD starts a segment; below it for HANGOVER seconds ends it.
const THRESHOLD = { mic: 0.02, out: 0.01 };
const HANGOVER = 0.45;       // pauses inside a sentence are shorter than this
const WINDOW = 30;           // seconds shown on the plot

let ctx, running = false;
const tracks = { mic: newTrack(), out: newTrack() };
const results = [];

function newTrack() { return { level: [], active: false, since: 0, lastLoud: 0, segments: [] }; }

async function listDevices() {
  // Labels are only visible after one permission grant.
  const tmp = await navigator.mediaDevices.getUserMedia({ audio: true });
  tmp.getTracks().forEach(t => t.stop());
  const inputs = (await navigator.mediaDevices.enumerateDevices()).filter(d => d.kind === 'audioinput');
  for (const [id, pick] of [['mic', d => !/blackhole/i.test(d.label)], ['out', d => /blackhole/i.test(d.label)]]) {
    const sel = document.getElementById(id);
    sel.innerHTML = '';
    inputs.forEach(d => sel.add(new Option(d.label || d.deviceId, d.deviceId)));
    const best = inputs.find(pick);
    if (best) sel.value = best.deviceId;
  }
}

async function open(deviceId) {
  // Raw audio: no echo cancellation, noise suppression or gain, which would move the edges.
  return navigator.mediaDevices.getUserMedia({ audio: {
    deviceId: { exact: deviceId }, echoCancellation: false, noiseSuppression: false, autoGainControl: false } });
}

async function start() {
  if (running) return;
  ctx = new AudioContext();
  for (const id of ['mic', 'out']) {
    const stream = await open(document.getElementById(id).value);
    const source = ctx.createMediaStreamSource(stream);
    const analyser = ctx.createAnalyser();
    analyser.fftSize = 512;
    source.connect(analyser);
    tracks[id].analyser = analyser;
    tracks[id].buf = new Float32Array(analyser.fftSize);
  }
  running = true;
  document.getElementById('start').textContent = 'Midiendo…';
  setInterval(sample, 10);      // 100 Hz on the audio clock
  requestAnimationFrame(draw);
}

function sample() {
  const t = ctx.currentTime;
  for (const id of ['mic', 'out']) {
    const tr = tracks[id];
    tr.analyser.getFloatTimeDomainData(tr.buf);
    let peak = 0;
    for (const v of tr.buf) peak = Math.max(peak, Math.abs(v));
    tr.level.push([t, peak]);
    while (tr.level.length && tr.level[0][0] < t - WINDOW) tr.level.shift();
    const loud = peak > THRESHOLD[id];
    if (loud) {
      if (!tr.active) { tr.active = true; tr.since = t; if (id === 'out') voiceStarted(t); }
      tr.lastLoud = t;
    } else if (tr.active && t - tr.lastLoud > HANGOVER) {
      tr.active = false;
      tr.segments.push([tr.since, tr.lastLoud]);
    }
  }
}

// The translated voice started: it answers the most recent sentence you finished before it
// that has no answer yet.
function voiceStarted(t) {
  const pending = tracks.mic.segments.filter(s => s[1] < t && !s.answered);
  if (!pending.length) return;
  const said = pending[pending.length - 1];
  pending.forEach(s => s.answered = true);   // older ones were merged into this sentence
  results.push({ end: said[1], voice: t, delay: t - said[1] });
  render();
}

function render() {
  const d = results.map(r => r.delay).sort((a, b) => a - b);
  const fmt = x => x.toFixed(2) + ' s';
  document.getElementById('median').textContent = d.length ? fmt(d[Math.floor(d.length / 2)]) : '–';
  document.getElementById('min').textContent = d.length ? fmt(d[0]) : '–';
  document.getElementById('max').textContent = d.length ? fmt(d[d.length - 1]) : '–';
  document.getElementById('count').textContent = d.length;
  document.getElementById('rows').innerHTML = results.map((r, i) =>
    `<tr><td>${i + 1}</td><td>${r.end.toFixed(2)} s</td><td>${r.voice.toFixed(2)} s</td><td><b>${fmt(r.delay)}</b></td></tr>`).reverse().join('');
}

function draw() {
  const c = document.getElementById('plot'), g = c.getContext('2d');
  const t = ctx.currentTime, w = c.width, h = c.height;
  g.clearRect(0, 0, w, h);
  const x = tt => w - (t - tt) / WINDOW * w;
  const styles = getComputedStyle(document.documentElement);
  for (const [id, color, y0] of [['mic', styles.getPropertyValue('--you'), h * 0.25], ['out', styles.getPropertyValue('--voice'), h * 0.75]]) {
    const tr = tracks[id];
    g.fillStyle = color;
    for (const s of tr.segments.concat(tr.active ? [[tr.since, t]] : [])) {
      g.globalAlpha = 0.18; g.fillRect(x(s[0]), y0 - h * 0.22, x(s[1]) - x(s[0]), h * 0.44);
    }
    g.globalAlpha = 1;
    for (const [tt, p] of tr.level) {
      const a = Math.min(1, p * 3) * h * 0.22;
      g.fillRect(x(tt), y0 - a, 2, a * 2);
    }
  }
  g.strokeStyle = '#ffffff55';
  for (const r of results) {
    if (r.voice < t - WINDOW) continue;
    g.beginPath(); g.moveTo(x(r.end), h * 0.25); g.lineTo(x(r.voice), h * 0.75); g.stroke();
  }
  requestAnimationFrame(draw);
}

document.getElementById('start').onclick = () => start().catch(e => alert(e.message));
document.getElementById('reset').onclick = () => { results.length = 0; tracks.mic.segments = []; tracks.out.segments = []; render(); };
listDevices().catch(e => alert('Micrófono: ' + e.message));

// Live transcript from MacDub (this page is served by the app).
async function poll() {
  try {
    const s = await (await fetch('/state', { cache: 'no-store' })).json();
    document.getElementById('status').textContent = s.phase === 'running'
      ? 'MacDub traduciendo en vivo.' : 'MacDub no está traduciendo (' + s.phase + ').';
    document.getElementById('mylang').textContent = s.myLocale + ' → ' + s.theirLocale;
    document.getElementById('theirlang').textContent = s.theirLocale + ' → ' + s.myLocale;
    for (const side of ['me', 'them']) {
      const box = document.getElementById(side);
      const atBottom = box.scrollTop + box.clientHeight >= box.scrollHeight - 20;
      box.innerHTML = s.lines.filter(l => l.side === side).map(l =>
        `<div class="line"><div class="o">${esc(l.original)}</div><div class="t">${esc(l.translated ?? '…')}</div>` +
        `<div class="d">${l.delay != null ? 'voz a los ' + l.delay.toFixed(2) + ' s del texto' : ''}</div></div>`).join('');
      if (atBottom) box.scrollTop = box.scrollHeight;
    }
  } catch { document.getElementById('status').textContent = 'Sin conexión con MacDub.'; }
  setTimeout(poll, 500);
}
const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
poll();
</script>
</body>
</html>

"""#
}
