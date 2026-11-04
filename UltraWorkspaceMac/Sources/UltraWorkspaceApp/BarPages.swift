import Foundation
import AppKit
import UltraBarKit

/// Full-width pages for the bar's Deckhand apps (2026-11-04): one page per app, each a 1424×280 HTML view
/// served by `MonitorServer` and polled by the page's own script. `BarPages` keeps the data the pages
/// need fresh on its own cadence (crypto and weather every few minutes, calendar every minute, Claude
/// sessions and Music every 2 s) so a request never waits on the network.
///
/// Routes: `/<page>` (html), `/<page>/data.json`, `/music/art.jpg`, `/music/cmd/<play|next|previous>`.
@MainActor
final class BarPages {
    nonisolated static let pages = ["monitor", "claude", "crypto", "weather", "music", "calendar", "flights", "sky", "news", "verse", "tasks"]
    nonisolated static let packagePrefix = "nl.denoronha.deckhand."
    nonisolated static func package(for page: String) -> String { packagePrefix + page }

    private var claude: [String: Any] = ["sessions": [], "tokens": "", "active": 0, "waiting": 0]
    private var crypto: [String: Any] = ["coins": []]
    private var weather: [String: Any] = [:]
    private var calendar: [String: Any] = ["days": []]
    private var music: [String: Any] = ["playing": false, "hasTrack": false]
    private var art: (key: String, jpeg: Data)?
    private var flights: [String: Any] = ["aircraft": [], "radius": 3]
    private var sky: [String: Any] = [:]
    private var news: [String: Any] = ["items": []]
    private var verse: [String: Any] = [:]
    private var linear: [String: Any] = ["issues": [], "hasKey": false]
    /// When each page's data was last asked for: the flights poll runs fast only while the page is open.
    private var lastHit: [String: Date] = [:]
    private var tasks: [Task<Void, Never>] = []

    func start(model: AppModel, settings: AppSettings) {
        stop()
        startFeeds(model: model, settings: settings)
        tasks.append(Task { [weak self] in   // Claude sessions + Music: 2 s
            while !Task.isCancelled {
                // Low priority and incremental (ClaudeUsage.snapshot): this must never crowd out the link.
                let s = await Task.detached(priority: .utility) { ClaudeUsage.sessions() }.value
                let snap = await Task.detached(priority: .utility) { ClaudeUsage.snapshot() }.value
                let np = AppleMusic.nowPlaying()
                guard let self else { return }
                let now = Date()
                self.claude = ["sessions": s.prefix(6).map { ["project": $0.project, "title": $0.title, "state": $0.state.rawValue, "ago": Int(now.timeIntervalSince($0.lastAt)), "last": $0.lastText] },
                               "tokens": ClaudeUsage.shortTokens(snap.todayTokens), "active": snap.activeSessions, "waiting": s.filter { $0.state != .working }.count]
                let key = np.title + "|" + np.artist + "|" + np.album
                if np.hasTrack, self.art?.key != key {
                    let jpeg = AppleMusic.currentArtwork().flatMap { Self.jpeg($0, side: 240) }
                    self.art = (key, jpeg ?? Data())
                }
                self.music = ["playing": np.isPlaying, "hasTrack": np.hasTrack, "title": np.title, "artist": np.artist, "album": np.album, "artKey": key.hashValue]
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        })
        tasks.append(Task { [weak self] in   // crypto: 2 min
            while !Task.isCancelled {
                let ids = settings.cryptoCoinsConfigured, cur = settings.cryptoCurrency
                let coins = await CryptoStats.fetch(ids: ids, currency: cur)
                var out: [[String: Any]] = []
                for id in ids {
                    let day = await CryptoStats.today(id: id, currency: cur)
                    let c = coins.first { $0.symbol.lowercased() == CryptoStats.symbol(for: id).lowercased() }
                    out.append(["symbol": CryptoStats.symbol(for: id).uppercased(), "price": c?.price ?? day?.current ?? 0, "change": c?.change24h ?? 0,
                                "points": Self.thin(day?.points ?? [], to: 90), "open": day?.open ?? 0])
                }
                guard let self else { return }
                self.crypto = ["coins": out, "suffix": CryptoStats.suffix(for: cur), "at": Int(Date().timeIntervalSince1970)]
                try? await Task.sleep(nanoseconds: 120_000_000_000)
            }
        })
        tasks.append(Task { [weak self] in   // weather: 15 min
            while !Task.isCancelled {
                let metric = settings.units == .metric
                if let loc = try? await model.resolveLocation(settings: settings),
                   let now = try? await OpenMeteo.current(latitude: loc.lat, longitude: loc.lon, metric: metric, placeName: loc.name),
                   let days = try? await OpenMeteo.daily(latitude: loc.lat, longitude: loc.lon, metric: metric, days: 4) {
                    guard let self else { return }
                    self.weather = ["place": now.place, "temp": now.temperature.rounded(), "unit": now.unitSuffix, "sky": "\(now.sky)", "code": now.code,
                                    "isDay": now.isDay, "humidity": now.humidity ?? 0, "wind": now.windSpeed.map { Int($0.rounded()) } ?? 0, "windUnit": now.windSuffix,
                                    "days": days.map { ["date": $0.date, "sky": "\($0.sky)", "code": $0.code, "max": $0.tmax.rounded(), "min": $0.tmin.rounded(), "rain": $0.precipProb ?? 0] }]
                }
                try? await Task.sleep(nanoseconds: 900_000_000_000)
            }
        })
        tasks.append(Task { [weak self] in   // calendar: 1 min
            while !Task.isCancelled {
                let events = await CalendarSource.upcoming(limit: 40, calendarIDs: settings.calendarIDs, days: 3)
                guard let self else { return }
                let cal = Calendar.current, today = cal.startOfDay(for: Date())
                let df = DateFormatter(); df.dateFormat = "HH:mm"
                var days: [[String: Any]] = []
                for i in 0..<3 {
                    let d = cal.date(byAdding: .day, value: i, to: today)!, next = cal.date(byAdding: .day, value: 1, to: d)!
                    var seen = Set<String>()   // the same event in two subscribed calendars shows once
                    let evs = events.filter { $0.start < next && $0.end > d && seen.insert($0.title + "\($0.start.timeIntervalSince1970)").inserted }.map { e -> [String: Any] in
                        let (r, g, b) = e.calendarColorRGBA
                        return ["title": e.title, "time": e.isAllDay ? "all day" : df.string(from: e.start) + "–" + df.string(from: e.end), "allDay": e.isAllDay,
                                "color": String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255)), "past": e.end < Date()]
                    }
                    let name = i == 0 ? "Today" : i == 1 ? "Tomorrow" : d.formatted(.dateTime.weekday(.wide))
                    days.append(["name": name, "date": d.formatted(.dateTime.day().month(.abbreviated)), "events": evs])
                }
                self.calendar = ["days": days, "authorized": CalendarSource.authStatus() == .authorized]
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        })
    }

    func stop() { tasks.forEach { $0.cancel() }; tasks.removeAll() }

    /// The newer apps' feeds (2026-11-04): flights, sun and moon, headlines, the verse of the day, Linear.
    private func startFeeds(model: AppModel, settings: AppSettings) {
        tasks.append(Task { [weak self] in   // flights: every 10 s while the page is open, else every 2 min
            var routes: [String: Flights.Route?] = [:]
            while !Task.isCancelled {
                guard let self else { return }
                let open = self.lastHit["flights"].map { Date().timeIntervalSince($0) < 60 } ?? false
                let radius = Double(max(1, settings.flightsRadiusKm))
                if let loc = try? await model.resolveLocation(settings: settings) {
                    // Ask for a wider circle so "nearest beyond" can be shown when nothing is overhead.
                    let all = (try? await Flights.nearby(lat: loc.lat, lon: loc.lon, radiusKm: max(radius, 25))) ?? []
                    var out: [[String: Any]] = []
                    for a in all.prefix(8) {
                        var r = routes[a.callsign]
                        if r == nil, !a.callsign.isEmpty { let fetched = await Flights.route(callsign: a.callsign); routes[a.callsign] = .some(fetched); r = .some(fetched) }
                        let route = r ?? nil
                        func ap(_ x: Flights.Airport?) -> Any { x.map { ["iata": $0.iata, "name": $0.name, "city": $0.city, "country": $0.country] as [String: Any] } ?? NSNull() }
                        out.append(["callsign": a.callsign, "reg": a.registration, "type": a.type, "alt": a.altitudeM ?? NSNull(), "ground": a.onGround,
                                    "speed": a.speedKmh ?? NSNull(), "vs": a.verticalMps ?? NSNull(), "track": a.track ?? NSNull(),
                                    "km": (a.distanceKm * 10).rounded() / 10, "bearing": a.bearing, "dir": Flights.compass(a.bearing), "inside": a.distanceKm <= radius,
                                    "airline": route?.airline ?? NSNull(), "from": ap(route?.origin), "to": ap(route?.destination)])
                    }
                    self.flights = ["aircraft": out, "radius": Int(radius), "place": loc.name, "at": Int(Date().timeIntervalSince1970)]
                }
                try? await Task.sleep(nanoseconds: (open ? 10 : 120) * 1_000_000_000)
            }
        })
        tasks.append(Task { [weak self] in   // sun & moon: every minute, computed locally
            while !Task.isCancelled {
                guard let self else { return }
                if let loc = try? await model.resolveLocation(settings: settings) {
                    let now = Date()
                    let s = SkyMath.sunDay(at: now, lat: loc.lat, lon: loc.lon), m = SkyMath.moonInfo(at: now, lat: loc.lat, lon: loc.lon)
                    func t(_ d: Date?) -> Any { d.map { Int($0.timeIntervalSince1970) as Any } ?? NSNull() }
                    self.sky = ["place": loc.name, "lat": loc.lat, "now": Int(now.timeIntervalSince1970), "tz": TimeZone.current.secondsFromGMT(),
                                "sun": ["rise": t(s.sunrise), "set": t(s.sunset), "noon": t(s.solarNoon), "dawn": t(s.civilDawn), "dusk": t(s.civilDusk),
                                        "goldenEnd": t(s.goldenEnd), "goldenStart": t(s.goldenStart), "dayLength": Int(s.dayLength),
                                        "elevation": (s.now.elevation * 10).rounded() / 10, "azimuth": s.now.azimuth.rounded()],
                                "moon": ["phase": m.phase, "illumination": m.illumination, "age": (m.ageDays * 10).rounded() / 10, "name": m.name, "waxing": m.waxing,
                                         "rise": t(m.rise), "set": t(m.set), "nextFull": t(m.nextFull), "nextNew": t(m.nextNew),
                                         "elevation": (m.now.elevation * 10).rounded() / 10, "azimuth": m.now.azimuth.rounded(), "distanceKm": Int(m.distanceKm)]]
                }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        })
        tasks.append(Task { [weak self] in   // headlines: every 10 min
            while !Task.isCancelled {
                guard let self else { return }
                let src = NewsFeed.source(settings.newsSource)
                if let items = try? await NewsFeed.fetch(src, limit: 14) {
                    self.news = ["source": src.name, "at": Int(Date().timeIntervalSince1970),
                                 "items": items.map { i -> [String: Any] in
                                    ["title": i.title, "ago": i.date.map { Int(Date().timeIntervalSince($0)) as Any } ?? NSNull(), "summary": String(i.summary.prefix(160)),
                                     "day": i.day.map { (Calendar.current.isDateInToday($0) ? "today" : Calendar.current.isDateInYesterday($0) ? "yesterday" : $0.formatted(date: .abbreviated, time: .omitted)) as Any } ?? NSNull()] }]
                } else if (self.news["items"] as? [Any])?.isEmpty ?? true {
                    self.news = ["source": src.name, "items": [], "error": "Could not load \(src.name)."]
                }
                try? await Task.sleep(nanoseconds: 600_000_000_000)
            }
        })
        tasks.append(Task { [weak self] in   // verse of the day: once an hour (the reference changes at midnight)
            var have = ""
            while !Task.isCancelled {
                guard let self else { return }
                let ref = DailyVerse.reference(for: Date())
                if ref != have, let v = try? await DailyVerse.fetch(reference: ref) {
                    have = ref
                    self.verse = ["reference": v.reference, "text": v.text, "translation": v.translation, "date": Date().formatted(date: .long, time: .omitted)]
                }
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
        })
        tasks.append(Task { [weak self] in   // Linear: every 2 min while a key is set
            var lastKey = ""
            while !Task.isCancelled {
                guard let self else { return }
                let key = model.linearKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if key.isEmpty {
                    self.linear = ["issues": [], "hasKey": false]; model.linearError = nil
                } else {
                    do {
                        let r = try await LinearTasks.fetch(apiKey: key)
                        model.linearError = nil
                        self.linear = ["hasKey": true, "me": r.me, "at": Int(Date().timeIntervalSince1970), "issues": r.issues.map {
                            i -> [String: Any] in ["id": i.identifier, "title": i.title, "priority": i.priority, "priorityLabel": i.priorityLabel, "due": i.dueDate.map { $0 as Any } ?? NSNull(),
                             "state": i.state, "stateType": i.stateType, "color": i.stateColor, "project": i.project.map { $0 as Any } ?? NSNull(), "team": i.team] }]
                    } catch {
                        model.linearError = error.localizedDescription
                        self.linear = ["hasKey": true, "issues": self.linear["issues"] ?? [], "error": error.localizedDescription]
                    }
                }
                // A new key takes effect at once; otherwise wait two minutes.
                for _ in 0..<24 { try? await Task.sleep(nanoseconds: 5_000_000_000); if Task.isCancelled || model.linearKey != key { break } }
                lastKey = key
            }
            _ = lastKey
        })
    }

    /// Answer one request (called off the main actor by the server; reads a snapshot).
    nonisolated func route(_ path: String, model: AppModel) -> MonitorServer.Response? {
        let parts = path.split(separator: "/").map(String.init)
        guard let page = parts.first else { return .html(Self.html("monitor")) }
        guard Self.pages.contains(page) else { return nil }
        if parts.count == 1 { return .html(Self.html(page)) }
        if parts[1] == "data.json" { return .json(DispatchQueue.main.sync { self.lastHit[page] = Date(); return self.data(page) }) }
        if page == "music", parts[1] == "art.jpg" {
            let jpeg = DispatchQueue.main.sync { self.art?.jpeg } ?? Data()
            return jpeg.isEmpty ? nil : MonitorServer.Response(type: "image/jpeg", body: jpeg)
        }
        if page == "music", parts.count == 3, parts[1] == "cmd" {
            DispatchQueue.main.async {
                switch parts[2] { case "play": model.musicPlayPause(); case "next": model.musicNext(); case "previous": model.musicPrevious(); default: break }
            }
            return .json(["ok": true])
        }
        return nil
    }

    private func data(_ page: String) -> [String: Any] {
        switch page {
        case "claude": return claude
        case "crypto": return crypto
        case "weather": return weather
        case "music": return music
        case "calendar": return calendar
        case "flights": return flights
        case "sky": return sky
        case "news": return news
        case "verse": return verse
        case "tasks": return linear
        default: return [:]
        }
    }

    // MARK: helpers

    nonisolated static func thin(_ pts: [Double], to n: Int) -> [Double] {
        guard pts.count > n, n > 1 else { return pts }
        return (0..<n).map { pts[$0 * (pts.count - 1) / (n - 1)] }
    }

    nonisolated static func jpeg(_ img: NSImage, side: Int) -> Data? {
        let out = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            img.draw(in: rect, from: .zero, operation: .copy, fraction: 1); return true
        }
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    // MARK: pages

    nonisolated static func html(_ page: String) -> String {
        switch page {
        case "monitor": return AppModel.monitorPage
        case "claude": return wrap("Claude", claudeJS)
        case "crypto": return wrap("Crypto", cryptoJS)
        case "weather": return wrap("Weather", weatherJS)
        case "music": return wrap("Music", musicJS)
        case "calendar": return wrap("Calendar", calendarJS)
        case "flights": return wrap("Flights", flightsJS)
        case "sky": return wrap("Sun & Moon", skyJS)
        case "news": return wrap("Headlines", newsJS)
        case "verse": return wrap("Verse", verseJS)
        case "tasks": return wrap("Tasks", tasksJS)
        default: return wrap(page, "")
        }
    }

    /// Shared shell: dark grey 1424×280 canvas, a ✕, a "waiting" overlay, and a poll loop that calls `render(d)`.
    nonisolated static func wrap(_ title: String, _ js: String) -> String {
        #"""
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=1424,height=280,initial-scale=1">
        <title>Deckhand </title>
        <style>
          html,body{margin:0;background:#1c2029;color:#fff;font:18px -apple-system,Roboto,Helvetica,Arial,sans-serif;overflow:hidden;width:1424px;height:280px;-webkit-user-select:none}
          canvas{display:block}
          #x{position:absolute;right:14px;top:10px;width:40px;height:40px;border-radius:20px;background:rgba(255,255,255,.16);color:#e5e9f0;font-size:22px;line-height:40px;text-align:center}
          #wait{position:absolute;left:0;top:0;width:1424px;height:280px;display:flex;align-items:center;justify-content:center;color:#8b94a6;font-size:20px;background:#1c2029}
          .btn{position:absolute;top:200px;width:64px;height:64px;border-radius:32px;background:rgba(255,255,255,.14);color:#fff;font-size:28px;line-height:64px;text-align:center}
        </style></head><body>
        <canvas id="c" width="1424" height="280"></canvas><div id="x">✕</div><div id="wait">Waiting for the Mac…</div>
        <script>
        const c=document.getElementById('c'),g=c.getContext('2d'); let D=null, okAt=0;
        document.getElementById('x').onclick=()=>{ if(window.Deckhand) Deckhand.close(); };
        async function poll(){ try{ const r=await fetch(location.pathname.replace(/\/$/,'')+'/data.json',{cache:'no-store'}); D=await r.json(); okAt=Date.now();
            document.getElementById('wait').style.display='none'; }catch(e){ if(Date.now()-okAt>8000) document.getElementById('wait').style.display='flex'; } }
        function bg(){ g.fillStyle='#1c2029'; g.fillRect(0,0,1424,280); }
        function txt(s,x,y,size,col,align,weight){ g.fillStyle=col||'#fff'; g.font=(weight||'400')+' '+size+'px -apple-system,Roboto,Helvetica,Arial,sans-serif'; g.textAlign=align||'left'; g.fillText(s,x,y); }
        function rr(x,y,w,h,r,col){ g.fillStyle=col; g.beginPath(); g.moveTo(x+r,y); g.arcTo(x+w,y,x+w,y+h,r); g.arcTo(x+w,y+h,x,y+h,r); g.arcTo(x,y+h,x,y,r); g.arcTo(x,y,x+w,y,r); g.closePath(); g.fill(); }
        function clip(s,n){ s=s||''; return s.length>n? s.slice(0,n-1)+'…':s; }
        function ago(s){ return s<60? s+' s' : s<3600? Math.round(s/60)+' min' : Math.round(s/3600)+' h'; }
        function frame(){ bg(); if(D) render(D); requestAnimationFrame(frame); }
        JS
        setInterval(poll, POLL); poll(); frame();
        </script></body></html>
        """#.replacingOccurrences(of: "<title>Deckhand </title>", with: "<title>Deckhand \(title)</title>").replacingOccurrences(of: "\nJS\n", with: "\n" + js + "\n")
    }

    nonisolated static let claudeJS = #"""
        const POLL=2000;
        function render(d){
          const w=d.waiting||0;
          txt('Claude Code',40,46,20,'#d6dbe6','left','600');
          txt(w? (w===1?'1 terminal needs you':w+' terminals need you') : 'Nothing waiting', 40,100,40,w?'#fbbf24':'#9aa3b2','left','700');
          txt((d.active||0)+' active · '+(d.tokens||'0')+' tokens today',40,136,17,'#8b94a6');
          const list=(d.sessions||[]).slice().sort((a,b)=> (a.state!=='working')===(b.state!=='working') ? 0 : (a.state!=='working'? -1:1)).slice(0,4);
          const pulse=0.5+0.5*Math.sin(Date.now()/350);
          list.forEach((s,i)=>{ const x=470+i*235, y=28, W=222, H=224;
            const wait=s.state!=='working';
            rr(x,y,W,H,14, wait? 'rgba(251,191,36,'+(0.22+0.18*pulse)+')' : 'rgba(255,255,255,.07)');
            if(wait){ g.strokeStyle='rgba(251,191,36,'+(0.6+0.4*pulse)+')'; g.lineWidth=3; g.strokeRect(x+1.5,y+1.5,W-3,H-3); }
            txt(clip(s.project,16),x+16,y+40,24,'#fff','left','700');
            txt(s.state==='question'?'asks a question': wait?'waiting for you':'working…', x+16,y+68,16, wait?'#fde68a':'#8b94a6','left','600');
            txt(clip(s.title,26),x+16,y+100,15,'#c7cdd8');
            const t2=clip(s.title,52).slice(25); if(t2) txt(t2,x+16,y+122,15,'#c7cdd8');
            txt(clip(s.last,30),x+16,y+170,14,'#8b94a6'); const l2=clip(s.last,60).slice(29); if(l2) txt(l2,x+16,y+190,14,'#8b94a6');
            txt(ago(s.ago)+' ago',x+16,y+H-16,14,'#6b7280');
          });
          if(!list.length) txt('No Claude Code session in the last hour.',470,150,20,'#6b7280');
        }
        """#

    nonisolated static let cryptoJS = #"""
        const POLL=15000;
        function render(d){
          const coins=d.coins||[], n=Math.max(1,Math.min(5,coins.length)), W=Math.floor((1424-80-(n-1)*20)/n);
          coins.slice(0,5).forEach((c,i)=>{ const x=40+i*(W+20), y=24, H=232; rr(x,y,W,H,16,'rgba(255,255,255,.07)');
            const up=(c.change||0)>=0, col=up?'#4ade80':'#f87171';
            txt(c.symbol,x+18,y+42,26,'#fff','left','700');
            txt((c.change>=0?'+':'')+(c.change||0).toFixed(2)+'%',x+W-18,y+42,22,col,'right','700');
            const p=c.price||0; txt(p.toLocaleString(undefined,{maximumFractionDigits:p<10?4:2})+' '+(d.suffix||''),x+18,y+84,34,'#fff','left','700');
            const pts=c.points||[]; if(pts.length>1){ const lo=Math.min(...pts,c.open||Infinity), hi=Math.max(...pts,c.open||-Infinity), gx=x+18, gy=y+104, gw=W-36, gh=100;
              const Y=v=> gy+gh-(hi>lo?(v-lo)/(hi-lo):0.5)*gh;
              if(c.open){ g.strokeStyle='rgba(255,255,255,.25)'; g.setLineDash([4,4]); g.beginPath(); g.moveTo(gx,Y(c.open)); g.lineTo(gx+gw,Y(c.open)); g.stroke(); g.setLineDash([]); }
              g.beginPath(); pts.forEach((v,j)=>{ const px=gx+j*gw/(pts.length-1); j?g.lineTo(px,Y(v)):g.moveTo(px,Y(v)); });
              g.lineTo(gx+gw,gy+gh); g.lineTo(gx,gy+gh); g.closePath(); const gr=g.createLinearGradient(0,gy,0,gy+gh); gr.addColorStop(0,col+'c0'); gr.addColorStop(1,col+'20'); g.fillStyle=gr; g.fill();
              g.beginPath(); pts.forEach((v,j)=>{ const px=gx+j*gw/(pts.length-1); j?g.lineTo(px,Y(v)):g.moveTo(px,Y(v)); }); g.strokeStyle=col; g.lineWidth=3; g.stroke();
              txt('today',gx,y+H-14,13,'#8b94a6'); }
          });
          if(!coins.length) txt('No coins set — Widgets → Crypto in Deckhand.',40,150,22,'#8b94a6');
        }
        """#

    nonisolated static let weatherJS = #"""
        const POLL=60000;
        function icon(sky,x,y,r,isDay){ // simple canvas glyphs
          const sun=()=>{ g.fillStyle='#fbbf24'; g.beginPath(); g.arc(x,y,r*.55,0,7); g.fill(); g.strokeStyle='#fbbf24'; g.lineWidth=r*.12; for(let a=0;a<8;a++){ g.beginPath(); g.moveTo(x+Math.cos(a*Math.PI/4)*r*.75,y+Math.sin(a*Math.PI/4)*r*.75); g.lineTo(x+Math.cos(a*Math.PI/4)*r,y+Math.sin(a*Math.PI/4)*r); g.stroke(); } };
          const moon=()=>{ g.fillStyle='#e5e7eb'; g.beginPath(); g.arc(x,y,r*.6,0,7); g.fill(); g.fillStyle='#1c2029'; g.beginPath(); g.arc(x+r*.3,y-r*.2,r*.5,0,7); g.fill(); };
          const cloud=(dx,dy,s,col)=>{ g.fillStyle=col; g.beginPath(); g.arc(x+dx-s*.5,y+dy,s*.45,0,7); g.arc(x+dx,y+dy-s*.3,s*.6,0,7); g.arc(x+dx+s*.55,y+dy,s*.45,0,7); g.fill(); g.fillRect(x+dx-s*.5,y+dy,s*1.05,s*.45); };
          const drops=(col,len)=>{ g.strokeStyle=col; g.lineWidth=r*.1; g.lineCap='round'; for(let i=-1;i<=1;i++){ g.beginPath(); g.moveTo(x+i*r*.35,y+r*.5); g.lineTo(x+i*r*.35-r*.1,y+r*.5+len); g.stroke(); } };
          switch(sky){
            case 'clear': isDay?sun():moon(); break;
            case 'partlyCloudy': isDay?sun():moon(); cloud(r*.15,r*.25,r*.75,'#cbd5e1'); break;
            case 'cloudy': case 'fog': cloud(0,r*.1,r*.9,'#cbd5e1'); break;
            case 'drizzle': case 'rain': case 'showers': cloud(0,-r*.1,r*.85,'#94a3b8'); drops('#60a5fa',r*.4); break;
            case 'snow': cloud(0,-r*.1,r*.85,'#cbd5e1'); drops('#fff',r*.3); break;
            case 'thunder': cloud(0,-r*.1,r*.85,'#64748b'); g.fillStyle='#fbbf24'; g.beginPath(); g.moveTo(x,y+r*.3); g.lineTo(x-r*.25,y+r*.8); g.lineTo(x+r*.05,y+r*.7); g.lineTo(x-r*.1,y+r*1.1); g.lineTo(x+r*.3,y+r*.55); g.lineTo(x,y+r*.65); g.closePath(); g.fill(); break;
            default: cloud(0,r*.1,r*.9,'#94a3b8');
          }
        }
        const names={clear:'Clear',partlyCloudy:'Partly cloudy',cloudy:'Cloudy',fog:'Fog',drizzle:'Drizzle',rain:'Rain',showers:'Showers',snow:'Snow',thunder:'Thunderstorm',unknown:''};
        function render(d){
          if(!d.place && !d.days){ txt('Waiting for the weather…',40,150,22,'#8b94a6'); return; }
          icon(d.sky,130,130,80,d.isDay);
          txt(Math.round(d.temp)+(d.unit||'°'),250,150,96,'#fff','left','700');
          txt(d.place||'',250,46,22,'#d6dbe6','left','600');
          txt((names[d.sky]||'')+'  ·  '+d.humidity+' %  ·  wind '+d.wind+' '+(d.windUnit||''),250,200,19,'#8b94a6');
          const days=(d.days||[]).slice(1,4); days.forEach((day,i)=>{ const x=760+i*215, y=24, W=200, H=232; rr(x,y,W,H,16,'rgba(255,255,255,.07)');
            const dt=new Date(day.date+'T12:00:00'); txt(i===0?'Tomorrow':dt.toLocaleDateString(undefined,{weekday:'long'}),x+16,y+36,20,'#fff','left','700');
            icon(day.sky,x+W/2,y+110,46,true);
            txt(Math.round(day.max)+'°',x+16,y+205,30,'#fff','left','700'); txt(Math.round(day.min)+'°',x+W-16,y+205,24,'#8b94a6','right','600');
            if(day.rain>0) txt(day.rain+' % rain',x+W/2,y+H-16,14,'#60a5fa','center');
          });
          const today=(d.days||[])[0]; if(today) txt('Today '+Math.round(today.max)+'° / '+Math.round(today.min)+'°'+(today.rain>0?'  ·  '+today.rain+' % rain':''),250,236,17,'#b4bccb');
        }
        """#

    nonisolated static let musicJS = #"""
        const POLL=2000; let artKey=null, img=null;
        document.body.insertAdjacentHTML('beforeend','<div class="btn" id="p" style="left:330px">⏮</div><div class="btn" id="pp" style="left:410px">⏯</div><div class="btn" id="n" style="left:490px">⏭</div>');
        for(const [id,cmd] of [['p','previous'],['pp','play'],['n','next']]) document.getElementById(id).onclick=()=>fetch('/music/cmd/'+cmd).then(poll);
        function render(d){
          if(d.hasTrack && d.artKey!==artKey){ artKey=d.artKey; const i=new Image(); i.onload=()=>{img=i}; i.onerror=()=>{img=null}; i.src='/music/art.jpg?k='+encodeURIComponent(artKey); }
          if(!d.hasTrack){ txt('Nothing playing in Music',330,140,30,'#8b94a6','left','600'); img=null; }
          if(img){ g.save(); rr(40,20,240,240,18,'#000'); g.clip(); g.drawImage(img,40,20,240,240); g.restore(); } else { rr(40,20,240,240,18,'rgba(255,255,255,.08)'); txt('♪',160,170,90,'#4b5363','center'); }
          if(d.hasTrack){ txt(clip(d.title,40),330,70,38,'#fff','left','700'); txt(clip(d.artist,50),330,112,26,'#d6dbe6'); txt(clip(d.album,60),330,146,20,'#8b94a6');
            txt(d.playing?'Playing':'Paused',330,182,17,d.playing?'#4ade80':'#fbbf24','left','600'); }
          const t=Date.now()/1000; if(d.playing){ for(let i=0;i<24;i++){ const h=18+Math.abs(Math.sin(t*2+i*.7))*60; rr(820+i*24,150-h/2,14,h,5,'#4f8cff'); } }
          document.getElementById('pp').textContent=d.playing?'⏸':'▶';
        }
        """#

    nonisolated static let calendarJS = #"""
        const POLL=30000;
        function render(d){
          if(d.authorized===false){ txt('Calendar access is off — allow it in Deckhand (Widgets → Calendar).',40,150,22,'#8b94a6'); return; }
          (d.days||[]).forEach((day,i)=>{ const x=40+i*455, y=20, W=435, H=240; rr(x,y,W,H,16,'rgba(255,255,255,.07)');
            txt(day.name,x+18,y+38,24,'#fff','left','700'); txt(day.date,x+W-18,y+38,18,'#8b94a6','right');
            const evs=day.events||[]; if(!evs.length) txt('Nothing planned',x+18,y+90,18,'#6b7280');
            evs.slice(0,5).forEach((e,j)=>{ const ey=y+66+j*34; rr(x+18,ey,6,24,3,e.color||'#4f8cff');
              txt(e.time,x+34,ey+18,15,e.past?'#6b7280':'#b4bccb','left','600'); txt(clip(e.title,34),x+150,ey+18,17,e.past?'#6b7280':'#fff'); });
            if(evs.length>5) txt('+'+(evs.length-5)+' more',x+18,y+H-14,14,'#8b94a6');
          });
        }
        """#

    // MARK: newer pages (2026-11-04)

    nonisolated static let flightsJS = #"""
        const POLL=5000;
        function plane(x,y,r,heading,col){ g.save(); g.translate(x,y); g.rotate((heading||0)*Math.PI/180); g.fillStyle=col; g.beginPath();
          g.moveTo(0,-r); g.lineTo(r*.35,r*.25); g.lineTo(r*.12,r*.15); g.lineTo(r*.12,r*.6); g.lineTo(r*.3,r*.8); g.lineTo(0,r*.65); g.lineTo(-r*.3,r*.8); g.lineTo(-r*.12,r*.6); g.lineTo(-r*.12,r*.15); g.lineTo(-r*.35,r*.25); g.closePath(); g.fill(); g.restore(); }
        function render(d){
          const R=d.radius||3, ac=d.aircraft||[], inside=ac.filter(a=>a.inside), show=(inside.length?inside:ac.slice(0,1)).slice(0,3);
          // radar
          const cx=150,cy=140,rr0=118; g.strokeStyle='rgba(255,255,255,.14)'; g.lineWidth=1.5;
          [1/3,2/3,1].forEach(f=>{ g.beginPath(); g.arc(cx,cy,rr0*f,0,7); g.stroke(); });
          g.beginPath(); g.moveTo(cx-rr0,cy); g.lineTo(cx+rr0,cy); g.moveTo(cx,cy-rr0); g.lineTo(cx,cy+rr0); g.stroke();
          const sweep=(Date.now()/4000*Math.PI*2)%(Math.PI*2); const gr=g.createConicalGradient? null:null;
          g.save(); g.beginPath(); g.moveTo(cx,cy); g.arc(cx,cy,rr0,sweep-0.9,sweep); g.closePath(); g.fillStyle='rgba(74,222,128,.10)'; g.fill(); g.restore();
          g.fillStyle='#4ade80'; g.beginPath(); g.arc(cx,cy,4,0,7); g.fill();
          txt('N',cx,cy-rr0-8,13,'#8b94a6','center'); txt(R+' km',cx+rr0+6,cy+5,12,'#6b7280','left');
          ac.forEach(a=>{ if(a.km>R) return; const rad=a.bearing*Math.PI/180, dd=Math.min(1,a.km/R)*rr0; plane(cx+Math.sin(rad)*dd, cy-Math.cos(rad)*dd, 13, a.track, a.inside?'#fff':'#6b7280'); });
          txt('Overhead',40,30,15,'#8b94a6','left','600'); txt((d.place||'')+' · '+R+' km',300,30,15,'#8b94a6','right');
          // cards
          if(!show.length){ txt('Nothing within '+R+' km',330,130,36,'#9aa3b2','left','700'); txt(ac.length? ac.length+' aircraft within 25 km, nearest '+ac[0].km+' km '+ac[0].dir:'Clear skies for 25 km around.',330,172,19,'#6b7280'); return; }
          const n=show.length, W=Math.floor((1424-330-40-(n-1)*16)/n);
          show.forEach((a,i)=>{ const x=330+i*(W+16), y=20, H=240; rr(x,y,W,H,16, a.inside?'rgba(255,255,255,.07)':'rgba(255,255,255,.04)');
            txt(a.callsign||a.reg||'—',x+18,y+44,34,'#fff','left','700'); if(a.airline) txt(clip(a.airline,W>400?34:22),x+18,y+70,16,'#b4bccb');
            if(a.from||a.to){ const f=a.from?a.from.iata:'?', t=a.to?a.to.iata:'?'; txt(f+' → '+t,x+18,y+112,28,'#fbbf24','left','700');
              txt(clip((a.from?a.from.city||a.from.name:'')+'  →  '+(a.to?a.to.city||a.to.name:''),W>400?44:28),x+18,y+138,15,'#8b94a6'); }
            else txt('route unknown',x+18,y+112,18,'#6b7280');
            const alt=a.ground?'on the ground':(a.alt!=null? a.alt.toLocaleString()+' m':'—'), vs=a.vs==null?'':(a.vs>1?' ↑':a.vs<-1?' ↓':' →');
            txt(alt+vs+(a.speed!=null?'  ·  '+a.speed+' km/h':''),x+18,y+176,17,'#d6dbe6');
            txt((a.type||'')+(a.reg?'  ·  '+a.reg:''),x+18,y+200,15,'#8b94a6');
            txt(a.km+' km '+a.dir+(a.inside?'':'  ·  outside the circle'),x+18,y+H-16,15,a.inside?'#4ade80':'#6b7280','left','600');
            plane(x+W-40,y+44,16,a.track,'#fff');
          });
        }
        """#

    nonisolated static let skyJS = #"""
        const POLL=20000;
        function hm(t){ if(!t) return '—'; const d=new Date(t*1000); return d.toTimeString().slice(0,5); }
        function dur(s){ return Math.floor(s/3600)+' h '+String(Math.round(s%3600/60)).padStart(2,'0')+' min'; }
        function moonDisc(cx,cy,r,ill,waxing){
          g.fillStyle='#2a3140'; g.beginPath(); g.arc(cx,cy,r,0,7); g.fill();
          g.fillStyle='#f3f4f6'; g.beginPath(); g.arc(cx,cy,r,-Math.PI/2,Math.PI/2, !waxing); g.fill();   // lit half (right when waxing)
          const rx=r*Math.abs(1-2*ill); g.fillStyle= ill>0.5? '#f3f4f6':'#2a3140'; g.beginPath(); g.ellipse(cx,cy,Math.max(0.01,rx),r,0,0,7); g.fill();
          g.strokeStyle='rgba(255,255,255,.18)'; g.lineWidth=1.5; g.beginPath(); g.arc(cx,cy,r,0,7); g.stroke();
          // a few craters for texture
          g.fillStyle='rgba(0,0,0,.08)'; [[-.3,-.2,.18],[.25,.1,.12],[-.05,.35,.09],[.1,-.45,.07]].forEach(c=>{ g.beginPath(); g.arc(cx+c[0]*r,cy+c[1]*r,c[2]*r,0,7); g.fill(); });
        }
        function render(d){
          const s=d.sun, m=d.moon; if(!s||!m){ txt('Working out the sky for '+(d.place||'your location')+'…',40,150,22,'#8b94a6'); return; }
          // --- sun arc (left 700 px)
          const x0=60, x1=660, hy=190, top=50, now=d.now;
          g.strokeStyle='rgba(255,255,255,.18)'; g.lineWidth=1.5; g.beginPath(); g.moveTo(x0-20,hy); g.lineTo(x1+20,hy); g.stroke();
          g.strokeStyle='rgba(251,191,36,.35)'; g.setLineDash([5,6]); g.beginPath(); g.ellipse((x0+x1)/2,hy,(x1-x0)/2,hy-top,0,Math.PI,2*Math.PI); g.stroke(); g.setLineDash([]);
          const rise=s.rise, set=s.set;
          if(rise&&set){ const f=Math.min(1.08,Math.max(-0.08,(now-rise)/(set-rise))); const a=Math.PI+f*Math.PI; const sx=(x0+x1)/2+Math.cos(a)*(x1-x0)/2, sy=hy+Math.sin(a)*(hy-top);
            if(f>=0&&f<=1){ const gl=g.createRadialGradient(sx,sy,4,sx,sy,40); gl.addColorStop(0,'rgba(251,191,36,.9)'); gl.addColorStop(1,'rgba(251,191,36,0)'); g.fillStyle=gl; g.beginPath(); g.arc(sx,sy,40,0,7); g.fill(); }
            g.fillStyle= f>=0&&f<=1?'#fbbf24':'#6b7280'; g.beginPath(); g.arc(sx,Math.min(sy,hy+6),11,0,7); g.fill(); }
          txt('↑ '+hm(rise),x0,hy+28,20,'#fff','left','700'); txt('↓ '+hm(set),x1,hy+28,20,'#fff','right','700');
          txt('sunrise',x0,hy+48,13,'#8b94a6','left'); txt('sunset',x1,hy+48,13,'#8b94a6','right');
          txt('noon '+hm(s.noon),(x0+x1)/2,top-16,14,'#8b94a6','center');
          txt(d.place||'',x0,30,15,'#8b94a6','left','600'); txt(s.elevation>0? 'sun '+s.elevation+'° up':'sun below the horizon',x1,30,15,'#8b94a6','right');
          txt('day '+dur(s.dayLength)+'  ·  golden '+hm(s.goldenStart)+'  ·  dusk '+hm(s.dusk)+'  ·  dawn '+hm(s.dawn),(x0+x1)/2,hy+76,15,'#b4bccb','center');
          // --- moon (right)
          moonDisc(860,140,92,m.illumination,m.waxing);
          txt(m.name,990,70,34,'#fff','left','700');
          txt(Math.round(m.illumination*100)+' % lit  ·  '+Math.round(m.age)+' days old',990,104,18,'#d6dbe6');
          txt('↑ '+hm(m.rise)+'   ↓ '+hm(m.set)+(m.elevation>0?'   ·  up now, '+Math.round(m.elevation)+'°':''),990,146,18,'#b4bccb');
          const df=new Date(m.nextFull*1000), dn=new Date(m.nextNew*1000), fmt=x=>x.toLocaleDateString(undefined,{weekday:'short',day:'numeric',month:'short'});
          txt('full '+fmt(df)+'   ·   new '+fmt(dn),990,180,17,'#8b94a6');
          txt(Math.round(m.distanceKm/1000)+' thousand km away',990,214,15,'#6b7280');
        }
        """#

    nonisolated static let newsJS = #"""
        const POLL=60000; let start=0, tick=0;
        function wrapText(s,max){ const words=(s||'').split(' '), lines=[]; let cur=''; for(const w of words){ const t=cur?cur+' '+w:w; if(t.length>max){ lines.push(cur); cur=w; } else cur=t; } if(cur) lines.push(cur); return lines; }
        function render(d){
          const items=d.items||[]; if(!items.length){ txt(d.error||'Loading '+(d.source||'headlines')+'…',40,150,22,'#8b94a6'); return; }
          const t=Math.floor(Date.now()/15000); if(t!==tick){ tick=t; start=(start+4)%Math.max(1,items.length); }
          txt(d.source||'',40,34,15,'#8b94a6','left','600'); txt(d.at? 'updated '+ago(Math.floor(Date.now()/1000-d.at))+' ago':'',1384,34,13,'#6b7280','right');
          for(let i=0;i<4;i++){ const it=items[(start+i)%items.length]; const col=i%2, row=Math.floor(i/2); const x=40+col*700, y=70+row*105;
            rr(x,y,660,90,12,'rgba(255,255,255,.06)');
            const lines=wrapText(it.title,52).slice(0,2); lines.forEach((l,j)=> txt(l,x+18,y+34+j*28,22,'#fff','left',j?'400':'600'));
            if(it.ago!=null) txt(ago(it.ago)+' ago',x+642,y+78,13,'#8b94a6','right'); else if(it.day) txt(it.day,x+642,y+78,13,'#8b94a6','right'); }
          txt((start+1)+'–'+Math.min(items.length,start+4)+' of '+items.length,712,272,12,'#4b5363','center');
        }
        """#

    nonisolated static let verseJS = #"""
        const POLL=600000;
        function wrapText(s,max){ const words=(s||'').split(' '), lines=[]; let cur=''; for(const w of words){ const t=cur?cur+' '+w:w; if(t.length>max){ lines.push(cur); cur=w; } else cur=t; } if(cur) lines.push(cur); return lines; }
        function render(d){
          const gr=g.createLinearGradient(0,0,1424,280); gr.addColorStop(0,'#1f2433'); gr.addColorStop(1,'#2b2340'); g.fillStyle=gr; g.fillRect(0,0,1424,280);
          if(!d.text){ txt('Fetching today’s verse…',712,150,22,'#8b94a6','center'); return; }
          const long=d.text.length>230, size=long?24:(d.text.length>150?28:32), lines=wrapText(d.text, long?95:(size>28?70:80)).slice(0,4);
          const lh=size*1.25, y0=140-(lines.length-1)*lh/2-10;
          lines.forEach((l,i)=> txt(l,712,y0+i*lh,size,'#fff','center',i===0?'600':'400'));
          txt('— '+d.reference,712,y0+lines.length*lh+14,20,'#fbbf24','center','700');
          txt((d.date||'')+'  ·  '+(d.translation||''),712,264,13,'#6b7280','center');
        }
        """#

    nonisolated static let tasksJS = #"""
        const POLL=30000;
        function bars(x,y,p,col){ for(let i=0;i<4;i++){ g.fillStyle= (p&&i<5-p)?col:'rgba(255,255,255,.14)'; g.fillRect(x+i*6,y+12-(i+1)*3,4,(i+1)*3); } }
        function render(d){
          if(!d.hasKey){ txt('Add your Linear API key in Deckhand',40,130,32,'#9aa3b2','left','700'); txt('Apps → App settings → Tasks. The key stays on the Mac.',40,172,19,'#6b7280'); return; }
          const items=d.issues||[]; if(d.error&&!items.length){ txt(d.error,40,150,22,'#f87171'); return; }
          const today=new Date().toISOString().slice(0,10), week=new Date(Date.now()+7*86400000).toISOString().slice(0,10);
          const due=items.filter(i=>i.due&&i.due<=week).length, over=items.filter(i=>i.due&&i.due<today).length;
          txt((d.me?d.me+' · ':'')+items.length+' open',40,34,15,'#8b94a6','left','600');
          txt(over? over+' overdue · ':''+(due? due+' due this week':''),1384,34,15,over?'#f87171':'#8b94a6','right','600');
          if(!items.length){ txt('Nothing assigned to you. Enjoy it.',40,150,30,'#9aa3b2','left','700'); return; }
          const pc={1:'#f87171',2:'#fbbf24',3:'#60a5fa',4:'#8b94a6'};
          items.slice(0,6).forEach((it,i)=>{ const col=i%2, row=Math.floor(i/2); const x=40+col*700, y=60+row*70; rr(x,y,660,60,10,it.stateType==='started'?'rgba(96,165,250,.12)':'rgba(255,255,255,.06)');
            bars(x+16,y+22,it.priority,pc[it.priority]||'#8b94a6'); txt(it.id,x+50,y+26,14,'#8b94a6','left','600');
            txt(clip(it.title,46),x+50,y+48,19,'#fff','left','600');
            rr(x+520,y+14,120,22,11,it.color||'#4b5363'); txt(clip(it.state,14),x+580,y+30,12,'#fff','center','700');
            if(it.due){ const late=it.due<today; txt((late?'overdue ':'due ')+it.due.slice(5),x+640,y+52,13,late?'#f87171':'#8b94a6','right'); } });
          if(items.length>6) txt('+'+(items.length-6)+' more',712,272,12,'#4b5363','center');
        }
        """#
}
