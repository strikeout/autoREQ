import AutoREQCore
import Foundation
import Network
import Security

/// A small HTTP server for the web viewer and the JSON API. It is off by default.
///
/// Each request must carry the token, as `?token=…` or as `Authorization: Bearer …`.
/// The server binds to 127.0.0.1 unless the user selects the LAN.
@MainActor @Observable
final class RemoteServer {
    static let defaultPort: UInt16 = 52_770
    let token: String
    private(set) var port: UInt16
    private(set) var lan = false
    private var listener: NWListener?
    private weak var model: AppModel?
    private let queue = DispatchQueue(label: "autoreq.remote")
    /// The server calls this when the listener stops with an error, for example when another app uses the port.
    var onFailure: ((String) -> Void)?
    /// A cancelled listener holds its port until it reports `.cancelled`. A new start waits for that.
    private var closing: NWListener?
    private var pendingLAN: Bool?
    private var connections = 0
    /// The server refuses a connection above this count, so slow clients cannot use all the resources.
    static let maxConnections = 32
    /// The server closes a connection after this time, also when the request is not complete.
    static let timeoutSeconds = 10.0

    var isRunning: Bool { listener != nil || pendingLAN != nil }

    /// - Parameter port: The TCP port. 0 lets the system select a free port; `port` then shows it when the server is ready.
    init(model: AppModel, port: UInt16 = RemoteServer.defaultPort) {
        self.model = model
        self.port = port
        var bytes = [UInt8](repeating: 0, count: 16)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess, "The system gave no random bytes for the token.")
        token = bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The URL of the web viewer. On the LAN, the URL uses the host name of this Mac.
    var viewerURL: String {
        let host = lan ? (ProcessInfo.processInfo.hostName) : "127.0.0.1"
        return "http://\(host):\(port)/?token=\(token)"
    }

    /// Starts the listener. If an old listener still closes, the start waits until its port is free.
    func start(lan: Bool) throws {
        if listener != nil { stop() }
        self.lan = lan
        if closing != nil { pendingLAN = lan; return }
        let params = NWParameters.tcp
        let p = NWEndpoint.Port(rawValue: port) ?? .any
        if !lan { params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: p) }
        let l = try lan ? NWListener(using: params, on: p) : NWListener(using: params)
        l.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    if self.listener === l, let actual = l.port?.rawValue { self.port = actual }
                case .failed(let e):
                    // A failure of an old listener must not stop the new one.
                    guard self.listener === l else { return }
                    self.stop()
                    self.onFailure?("The server stopped: \(e.localizedDescription). Another app can use port \(self.port).")
                case .cancelled:
                    guard self.closing === l else { return }
                    self.closing = nil
                    if let next = self.pendingLAN {
                        self.pendingLAN = nil
                        do { try self.start(lan: next) } catch { self.onFailure?("The server did not start: \(error.localizedDescription)") }
                    }
                default: break
                }
            }
        }
        let q = queue
        l.newConnectionHandler = { [weak self] c in
            Task { @MainActor in
                guard let self, self.connections < Self.maxConnections else { c.cancel(); return }
                self.connections += 1
                c.stateUpdateHandler = { [weak self] st in
                    // A failed connection still reports `.cancelled` after the cancel, so only that state counts.
                    switch st {
                    case .failed: c.cancel()
                    case .cancelled: Task { @MainActor in self?.connections -= 1 }
                    default: break
                    }
                }
                c.start(queue: q)
                q.asyncAfter(deadline: .now() + Self.timeoutSeconds) { c.cancel() }
                self.receive(c, buffer: Data())
            }
        }
        l.start(queue: queue)
        listener = l
        self.lan = lan
    }

    func stop() {
        pendingLAN = nil
        guard let l = listener else { return }
        closing = l
        listener = nil
        l.cancel()
    }

    // MARK: - HTTP

    private struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var body: Data
    }

    /// Reads until the end of the headers and the body. A request larger than 64 KB gets an error.
    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { c.cancel(); return }
                var buf = buffer
                if let data { buf.append(data) }
                if let req = Self.parse(buf) {
                    self.respond(c, to: req)
                } else if error != nil || done || buf.count > 65_536 {
                    self.send(c, status: "400 Bad Request", type: "text/plain", body: Data("The request is not valid.".utf8))
                } else {
                    self.receive(c, buffer: buf)
                }
            }
        }
    }

    private static func parse(_ d: Data) -> Request? {
        guard let end = d.range(of: Data("\r\n\r\n".utf8)), let head = String(data: d[..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let body = d[end.upperBound...]
        if let n = headers["content-length"].flatMap(Int.init), body.count < n { return nil }
        let comps = URLComponents(string: String(parts[1]))
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(method: String(parts[0]), path: comps?.path ?? "/", query: query, headers: headers, body: Data(body))
    }

    /// Compares two strings in constant time, so the time of a reply does not tell an attacker the token.
    private static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func authorized(_ r: Request) -> Bool {
        let bearer = r.headers["authorization"].map { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : "" }
        return Self.same(r.query["token"] ?? bearer ?? "", token)
    }

    private func respond(_ c: NWConnection, to r: Request) {
        guard authorized(r) else {
            send(c, status: "401 Unauthorized", type: "text/plain", body: Data("The token is missing or wrong.".utf8))
            return
        }
        guard let model else { send(c, status: "503 Service Unavailable", type: "text/plain", body: Data()); return }
        switch (r.method, r.path) {
        case ("GET", "/"):
            send(c, status: "200 OK", type: "text/html; charset=utf-8", body: Data(RemoteViewer.html.utf8))
        case ("GET", "/api/status"):
            json(c, RemoteAPI.status(model))
        case ("GET", "/api/response"):
            json(c, RemoteAPI.response(model, channel: r.query["channel"].flatMap(Int.init)))
        case ("GET", "/api/impulse"):
            // "nan" and "inf" parse as a Double, so the server keeps finite values only.
            let ms = r.query["ms"].flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil } ?? 100
            json(c, RemoteAPI.impulse(model, channel: r.query["channel"].flatMap(Int.init), ms: ms))
        case ("GET", "/api/spectrum"):
            json(c, RemoteAPI.spectrum(model))
        case ("GET", "/api/spl"):
            json(c, RemoteAPI.spl(model))
        case ("POST", "/api/generator/start"):
            let body = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
            RemoteAPI.applyGenerator(model, body)
            Task { @MainActor in
                await model.startGenerator()
                self.json(c, RemoteAPI.status(model))
            }
        case ("POST", "/api/generator/stop"):
            model.setNoise([])
            json(c, RemoteAPI.status(model))
        case ("POST", "/api/snapshot"):
            let made = model.takeSnapshot(name: (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any])?["name"] as? String)
            json(c, ["snapshots": made.map(\.name)])
        default:
            send(c, status: "404 Not Found", type: "text/plain", body: Data("The path is not known.".utf8))
        }
    }

    private func json(_ c: NWConnection, _ value: Any) {
        // A NaN or an infinite value makes JSONSerialization raise an exception that `try` cannot catch.
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            send(c, status: "500 Internal Server Error", type: "text/plain", body: Data("The values are not valid JSON.".utf8))
            return
        }
        send(c, status: "200 OK", type: "application/json", body: data)
    }

    private func send(_ c: NWConnection, status: String, type: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }
}

/// The JSON values of the API. Each value uses only plain JSON types.
@MainActor
enum RemoteAPI {
    /// Every 4th point of the 1/48-octave grid gives a 1/12-octave curve, small enough to poll.
    static let step = 4

    static func status(_ m: AppModel) -> [String: Any] {
        [
            "version": (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "",
            "engine": m.engine != nil,
            "status": m.status.label,
            "generator": [
                "playing": !m.noiseChannels.isEmpty,
                "signal": m.playingSignal?.label ?? m.state.generator.signal.label,
                "levelDBFS": m.state.generator.levelDBFS,
                "channel": m.state.generator.channel,
            ],
            "micChannels": [m.state.micChannel] + m.state.extraMicChannels,
            "snapshots": m.state.snapshots.map(\.name),
        ]
    }

    static func response(_ m: AppModel, channel: Int?) -> [String: Any] {
        guard let r = channel.flatMap({ m.liveByChannel[$0] }) ?? m.live else { return ["available": false] }
        let idx = Array(stride(from: 0, to: FrequencyGrid.count, by: step))
        return [
            "available": true,
            "frequency": idx.map { FrequencyGrid.frequencies[$0] },
            "magnitudeDB": idx.map { r.magnitudeDB[$0] },
            "phaseDeg": idx.map { r.phaseDeg[$0] },
            "coherence": idx.map { r.coherence[$0] },
            "latencyMs": Double(r.latencySamples) / r.sampleRate * 1000,
        ]
    }

    static func impulse(_ m: AppModel, channel: Int?, ms: Double) -> [String: Any] {
        guard let ir = (channel.flatMap { m.liveByChannel[$0] } ?? m.live)?.impulse else { return ["available": false] }
        let n = min(ir.samples.count, ir.zeroIndex + Int(min(max(ms, 1), 1000) / 1000 * ir.sampleRate))
        return ["available": true, "sampleRate": ir.sampleRate, "zeroIndex": ir.zeroIndex, "samples": ir.samples[0..<n].map(Double.init)]
    }

    static func spectrum(_ m: AppModel) -> [String: Any] {
        let bands = m.spectrumBands
        return [
            "banding": m.state.spectrum.banding.label,
            "centre": bands.map(\.centre),
            "levels": Dictionary(uniqueKeysWithValues: m.spectrum.map { (String($0.key), $0.value) }),
        ]
    }

    /// The SPL values of each meter channel. The SPL screen fills `RemoteAPI.splProvider`.
    static var splProvider: ((AppModel) -> [String: Any])?

    static func spl(_ m: AppModel) -> [String: Any] { splProvider?(m) ?? ["available": false] }

    /// Changes the generator setup from a JSON body: `signal` (a `SignalKind` raw value), `levelDBFS`,
    /// `channel`, `frequency` and `frequency2`. Unknown keys have no effect.
    static func applyGenerator(_ m: AppModel, _ b: [String: Any]) {
        var g = m.state.generator
        if let k = (b["signal"] as? String).flatMap(SignalKind.init(rawValue:)), k != .file { g.signal.kind = k }
        if let l = b["levelDBFS"] as? Double { g.levelDBFS = min(max(l, -60), -3) }
        if let c = b["channel"] as? Int { g.channel = c }
        if let f = b["frequency"] as? Double { g.signal.frequency = min(max(f, 10), 20_000) }
        if let f = b["frequency2"] as? Double { g.signal.frequency2 = min(max(f, 10), 20_000) }
        m.state.generator = g
    }
}

/// The read-only web viewer. It polls the API twice per second.
enum RemoteViewer {
    static let html = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>AutoREQ Viewer</title>
    <style>
    :root{--bg:#1e1e1e;--fg:#eee;--dim:#999;--grid:#333;--acc:#ffc400}
    body{margin:0;background:var(--bg);color:var(--fg);font:14px -apple-system,system-ui,sans-serif}
    header{padding:12px 16px;display:flex;gap:16px;align-items:baseline;flex-wrap:wrap}
    h1{font-size:18px;margin:0}.dim{color:var(--dim)}
    section{padding:0 16px 16px}canvas{width:100%;height:260px;background:#151515;border-radius:8px}
    table{border-collapse:collapse}td{padding:2px 12px 2px 0;font-variant-numeric:tabular-nums}
    </style></head><body>
    <header><h1>AutoREQ</h1><span id="status" class="dim">Connecting…</span></header>
    <section><h3>Transfer function</h3><canvas id="tf"></canvas></section>
    <section><h3>RTA</h3><canvas id="rta"></canvas></section>
    <section><h3>SPL</h3><div id="spl" class="dim">No SPL meter runs.</div></section>
    <script>
    const token=new URLSearchParams(location.search).get('token');
    const get=p=>fetch(p+(p.includes('?')?'&':'?')+'token='+token).then(r=>r.json());
    function axes(c,lo,hi){const g=c.getContext('2d'),w=c.width=c.clientWidth*devicePixelRatio,h=c.height=c.clientHeight*devicePixelRatio;
      g.clearRect(0,0,w,h);g.strokeStyle='#333';g.fillStyle='#999';g.font=(11*devicePixelRatio)+'px system-ui';
      const x=f=>Math.log(f/20)/Math.log(1000)*w,y=d=>(hi-d)/(hi-lo)*h;
      for(const f of [20,50,100,200,500,1000,2000,5000,10000,20000]){g.beginPath();g.moveTo(x(f),0);g.lineTo(x(f),h);g.stroke();g.fillText(f>=1000?f/1000+'k':f,x(f)+3,h-4)}
      for(let d=Math.ceil(lo/10)*10;d<=hi;d+=10){g.beginPath();g.moveTo(0,y(d));g.lineTo(w,y(d));g.stroke();g.fillText(d+' dB',4,y(d)-3)}
      return {g,x,y}}
    async function tick(){
      try{
        const s=await get('/api/status');
        document.getElementById('status').textContent=(s.generator.playing?'Playing '+s.generator.signal+' · ':'')+s.status;
        const r=await get('/api/response');
        {const c=document.getElementById('tf'),{g,x,y}=axes(c,-60,10);
         if(r.available){g.strokeStyle='#fff';g.lineWidth=2*devicePixelRatio;g.beginPath();
          r.frequency.forEach((f,i)=>{if(f<20||f>20000)return;const yy=y(r.magnitudeDB[i]);i?g.lineTo(x(f),yy):g.moveTo(x(f),yy)});g.stroke()}}
        const sp=await get('/api/spectrum');
        {const c=document.getElementById('rta'),{g,x,y}=axes(c,-120,0),cols=['#ffc400','#4fc3f7','#ef5350','#66bb6a'];
         Object.values(sp.levels).forEach((lv,k)=>{g.strokeStyle=cols[k%4];g.lineWidth=2*devicePixelRatio;g.beginPath();
          lv.forEach((d,i)=>{const xx=x(sp.centre[i]),yy=y(Math.max(d,-120));i?g.lineTo(xx,yy):g.moveTo(xx,yy)});g.stroke()})}
        const spl=await get('/api/spl');
        if(spl.available){document.getElementById('spl').innerHTML='<table>'+spl.meters.map(m=>'<tr><td class="dim">'+m.label+'</td><td>'+(m.value==null?'–':m.value.toFixed(1)+' dB')+'</td></tr>').join('')+'</table>'}
      }catch(e){document.getElementById('status').textContent='The connection is lost.'}
    }
    async function loop(){await tick();setTimeout(loop,500)}
    loop();
    </script></body></html>
    """
}
