import Foundation
import UltraBarKit

/// The bar's Monitor app (android/DeckhandMonitor) opens a full-screen page that this Mac serves:
/// `GET /monitor` (the page) and `GET /monitor/stats.json` (one sample per second). The app finds
/// the page through a UDP beacon this Mac sends every 5 s while the Monitor is on (2026-11-04).
extension AppModel {
    nonisolated static let monitorPackage = "nl.denoronha.deckhand.monitor"

    func startMonitor(settings: AppSettings) {
        monitorTask?.cancel(); monitorTask = nil
        guard settings.monitorServe else { if MonitorServer.shared.isRunning { MonitorServer.shared.stop() }; barPages.stop(); monitorURL = nil; return }
        let sys = SystemStats(), net = NetworkStats()
        _ = sys.sample(); _ = net.sample()
        let host = Host.current().localizedName ?? "Mac"
        let page = Self.monitorPage
        barPages.start(model: self, settings: settings)
        let pages = barPages
        MonitorServer.shared.setRoute { [weak self] path in
            switch path {
            case "/", "/monitor", "/monitor/": return .html(page)
            case "/monitor/stats.json":
                let s = sys.sample(), n = net.sample()
                return .json(["cpu": Int(s.cpuPercent.rounded()), "mem": Int(s.memPercent.rounded()),
                              "memUsedGB": (s.memUsedGB * 10).rounded() / 10, "memTotalGB": (s.memTotalGB * 10).rounded() / 10,
                              "down": Int(n.downBytesPerSec), "up": Int(n.upBytesPerSec),
                              "disk": Self.diskUsedPercent(), "host": host, "t": Int(Date().timeIntervalSince1970)])
            default:
                guard let self else { return nil }
                return pages.route(path, model: self)
            }
        }
        do { try MonitorServer.shared.start() } catch { monitorError = "\(error)"; say("Monitor page could not start: \(error)"); return }
        monitorError = nil
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let peer = self.ipForSelected()
                let url = MonitorServer.shared.url(reachableFrom: peer ?? "192.168.255.255")
                if url != self.monitorURL { self.monitorURL = url }
                if let url { MonitorBeacon.send(url: url, base: String(url.dropLast("/monitor".count)), to: peer) }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        say("Monitor page is on — the bar's Monitor app finds it by itself.")
    }

    var monitorInstalled: Bool { barApps.contains { $0.packageName == Self.monitorPackage } }

    /// The six bar apps (android/DeckhandMonitor flavors): page id, label, bundled APK name.
    static let barAppPages: [(page: String, label: String, apk: String)] = [
        ("monitor", "Monitor", "DeckhandMonitor"), ("claude", "Claude", "DeckhandClaude"), ("crypto", "Crypto", "DeckhandCrypto"),
        ("weather", "Weather", "DeckhandWeather"), ("music", "Music", "DeckhandMusic"), ("calendar", "Calendar", "DeckhandCalendar")]

    /// APKs shipped inside Deckhand.app (packaging/make-app.sh copies dist/bar-apps) or next to the dev build.
    static func bundledAPK(_ name: String) -> URL? {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("bar-apps/\(name).apk"),
                          URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/bar-apps/\(name).apk")]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func barAppVersion(_ page: String) -> String? { barApps.first { $0.packageName == BarPages.package(for: page) }?.versionName }
    /// Version of the APKs shipped with this build — keep in step with android/DeckhandMonitor/app/build.gradle.kts.
    nonisolated static let barAppsVersion = "1.2"
    /// The bar's copy is older than the one shipped with Deckhand.
    func barAppNeedsUpdate(_ page: String) -> Bool {
        guard let v = barAppVersion(page) else { return false }
        let a = v.split(separator: ".").map { Int($0) ?? 0 }, b = Self.barAppsVersion.split(separator: ".").map { Int($0) ?? 0 }
        return a.lexicographicallyPrecedes(b)
    }
    func barAppIconURL(_ page: String) -> URL? { barApps.first { $0.packageName == BarPages.package(for: page) }?.iconUrl.flatMap(URL.init) }

    /// Install (or update) one bar app over ADB — Deckhand's own `adb install -r` of the bundled APK.
    func installBarApp(_ page: String) {
        guard let entry = Self.barAppPages.first(where: { $0.page == page }), let apk = Self.bundledAPK(entry.apk) else { say("No APK for \(page) in this build."); return }
        guard let adb = AdbBridge.find() else { say("adb not found — brew install --cask android-platform-tools."); return }
        guard let ip = ipForSelected() else { return }
        barAppBusy = page
        Task {
            let bridge = AdbBridge(path: adb, ip: ip)
            guard await bridge.connect() else { say("The bar refuses ADB — turn Wi-Fi ADB on in its Developer options."); barAppBusy = nil; return }
            let out = await bridge.install(apkPath: apk.path)
            say(out.contains("Success") ? "\(entry.label) installed on the bar — add its card on the CoreBar page." : "Install of \(entry.label) failed: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
            barAppBusy = nil
            refreshAppStore()
        }
    }

    /// Full-screen page for the 1424×280 bar: a moving CPU area chart, memory and disk bars, network
    /// up/down sparkline, clock. Plain canvas, no libraries; polls stats.json once a second.
    nonisolated static let monitorPage = #"""
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=1424,height=280,initial-scale=1">
    <title>Deckhand Monitor</title>
    <style>
      html,body{margin:0;background:#1c2029;color:#fff;font:18px -apple-system,Roboto,Helvetica,Arial,sans-serif;overflow:hidden;width:1424px;height:280px;-webkit-user-select:none}
      canvas{display:block}
      #x{position:absolute;right:14px;top:10px;width:40px;height:40px;border-radius:20px;background:rgba(255,255,255,.16);color:#e5e9f0;font-size:22px;line-height:40px;text-align:center}
      #wait{position:absolute;left:0;top:0;width:1424px;height:280px;display:flex;align-items:center;justify-content:center;color:#6b7280;font-size:20px;background:#1c2029}
    </style></head><body>
    <canvas id="c" width="1424" height="280"></canvas><div id="x">✕</div><div id="wait">Waiting for the Mac…</div>
    <script>
    const c=document.getElementById('c'),g=c.getContext('2d');
    const N=120, cpu=new Array(N).fill(0), down=new Array(N).fill(0), up=new Array(N).fill(0);
    let last=null, shown={cpu:0,mem:0,disk:0,down:0,up:0}, okAt=0;
    document.getElementById('x').onclick=()=>{ if(window.Deckhand) Deckhand.close(); };
    async function poll(){
      try{ const r=await fetch('/monitor/stats.json',{cache:'no-store'}); const j=await r.json();
        last=j; okAt=Date.now(); cpu.push(j.cpu); cpu.shift(); down.push(j.down); down.shift(); up.push(j.up); up.shift();
        document.getElementById('wait').style.display='none';
      }catch(e){ if(Date.now()-okAt>6000) document.getElementById('wait').style.display='flex'; }
    }
    setInterval(poll,1000); poll();
    function fmt(b){ if(b>=1e9) return (b/1e9).toFixed(1)+' GB/s'; if(b>=1e6) return (b/1e6).toFixed(1)+' MB/s'; if(b>=1e3) return (b/1e3).toFixed(0)+' kB/s'; return b+' B/s'; }
    function lerp(a,b,t){ return a+(b-a)*t; }
    function area(xs,x0,y0,w,h,max,col){
      g.beginPath(); for(let i=0;i<N;i++){ const x=x0+i*w/(N-1), y=y0+h-Math.min(1,xs[i]/max)*h; i?g.lineTo(x,y):g.moveTo(x,y); }
      g.lineTo(x0+w,y0+h); g.lineTo(x0,y0+h); g.closePath();
      const gr=g.createLinearGradient(0,y0,0,y0+h); gr.addColorStop(0,col+'f0'); gr.addColorStop(1,col+'50'); g.fillStyle=gr; g.fill();
      g.beginPath(); for(let i=0;i<N;i++){ const x=x0+i*w/(N-1), y=y0+h-Math.min(1,xs[i]/max)*h; i?g.lineTo(x,y):g.moveTo(x,y); }
      g.strokeStyle=col; g.lineWidth=3.5; g.stroke();
    }
    function bar(x,y,w,h,pct,col,label,sub){
      g.fillStyle='#3a4253'; g.fillRect(x,y,w,h);
      g.fillStyle=col; g.fillRect(x,y,w*Math.min(1,pct/100),h);
      g.fillStyle='#d6dbe6'; g.font='600 17px sans-serif'; g.textAlign='left'; g.fillText(label,x,y-8);
      g.textAlign='right'; g.fillStyle='#fff'; g.fillText(sub,x+w,y-8);
    }
    function draw(){
      g.fillStyle='#1c2029'; g.fillRect(0,0,1424,280);
      if(last){ shown.cpu=lerp(shown.cpu,last.cpu,.15); shown.mem=lerp(shown.mem,last.mem,.15); shown.disk=lerp(shown.disk,last.disk,.15); shown.down=lerp(shown.down,last.down,.2); shown.up=lerp(shown.up,last.up,.2); }
      // CPU: big number + 2-minute area chart
      g.fillStyle='#d6dbe6'; g.font='600 20px sans-serif'; g.textAlign='left'; g.fillText('CPU',40,42);
      g.fillStyle='#fff'; g.font='700 76px sans-serif'; g.fillText(Math.round(shown.cpu)+'%',40,118);
      area(cpu,200,30,560,200,100,'#6aa6ff');
      g.strokeStyle='#4a5365'; g.lineWidth=1; for(const q of [.25,.5,.75]){ g.beginPath(); g.moveTo(200,30+200*q); g.lineTo(760,30+200*q); g.stroke(); }
      g.fillStyle='#8b94a6'; g.font='13px sans-serif'; g.textAlign='left'; g.fillText('2 min',200,250);
      // network sparkline
      const m=Math.max(1e5, ...down, ...up);
      area(down,820,30,330,96,m,'#4ade80'); area(up,820,136,330,96,m,'#fbbf24');
      g.fillStyle='#fff'; g.font='600 18px sans-serif'; g.textAlign='left'; g.fillText('↓ '+fmt(Math.round(shown.down)),826,52); g.fillText('↑ '+fmt(Math.round(shown.up)),826,158);
      // memory + disk bars
      bar(1190,70,190,22,shown.mem,'#c4b5fd','Memory',last?(last.memUsedGB+' / '+last.memTotalGB+' GB'):'');
      bar(1190,140,190,22,shown.disk,'#f9a8d4','Disk',Math.round(shown.disk)+'%');
      // clock + host
      const d=new Date(); g.fillStyle='#fff'; g.font='700 34px sans-serif'; g.textAlign='right';
      g.fillText(d.toTimeString().slice(0,5)+':'+String(d.getSeconds()).padStart(2,'0'),1380,230);
      g.fillStyle='#b4bccb'; g.font='15px sans-serif'; g.fillText(last?last.host:'',1380,256);
      requestAnimationFrame(draw);
    }
    draw();
    </script></body></html>
    """#
}
