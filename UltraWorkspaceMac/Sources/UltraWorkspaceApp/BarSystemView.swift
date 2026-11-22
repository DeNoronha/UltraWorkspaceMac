import SwiftUI
import UltraBarKit

/// Bar System: tasks on the bar's Android system that you run and watch — its software, its home screen and the
/// launcher's pages, keeping its screen on, restarting its launcher. They were sections of the old Settings page; they are not preferences of the
/// Mac app. All of them go through the debug bridge (Settings → Debug Bridge).
struct BarSystemView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: AppSettings
    @State private var confirmSoftwareUpdate = false
    @State private var confirmLauncher = false

    private var adbOK: Bool { model.adbStatus.wifi == true && !model.adbStatus.unauthorized }

    var body: some View {
        Form {
            if !adbOK {
                Section {
                    HStack {
                        StatusLabel(model.adbStatus.checkedAt == nil ? "Checking the debug bridge…" : "These tasks need the debug bridge.", model.adbStatus.checkedAt == nil ? .info : .attention)
                        Spacer()
                        Button("Debug Bridge Settings…") { SettingsWindow.open(.debugBridge) }
                    }
                }
            }
            software
            home
            cycle
            screen
            launcher
        }
        .formStyle(.grouped)
        .navigationSubtitle("Software, home screen, pages and screen of the bar")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.barSoftwareBusy != nil || model.barHomeBusy != nil)
                    .help("Read the versions, the home screen and the launcher's pages off the bar, and the latest release from GitHub (⌘R)")
            }
        }
        .onAppear {
            if model.adbStatus.checkedAt == nil { model.checkAdb() }
            if model.corebarPages.isEmpty { model.refreshPages() }   // as the CoreBar page does
        }
        .alert("Restart the bar's launcher?", isPresented: $confirmLauncher) {
            Button("Restart", role: .destructive) { Task { await model.restartBarLauncher(reason: "requested in Bar System") } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The bar's screen reloads for a few seconds; the cube and the other modules stay as they are.") }
    }

    private func refresh() {
        model.checkAdb()
        model.checkBarSoftware()
        model.refreshPages()
        if adbOK { model.checkBarHome() }
    }

    // MARK: Software

    private var software: some View {
        let sw = model.barSoftware
        return Section {
            SoftwareRow(title: "Launcher", installed: sw.launcher, latest: sw.release?.launcher, update: sw.launcherUpdate != nil)
            SoftwareRow(title: "Bridge", installed: sw.bridge, latest: sw.release?.bridge, update: sw.bridgeUpdate != nil)
            if let r = sw.release {
                LabeledContent("Latest release") {
                    HStack(spacing: 6) {
                        Text(r.tag + (r.published.map { " · " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "")).foregroundStyle(.secondary)
                        Link("GitHub", destination: VendorRelease.pageURL)
                    }
                }
            }
            if let m = sw.message { StatusLabel(m, .attention) }
            HStack {
                Button(sw.updates.isEmpty ? "Update Bar Software…" : "Update Bar Software (\(sw.updates.count))…") { confirmSoftwareUpdate = true }
                    .primaryInline(!sw.updates.isEmpty)
                    .disabled(sw.updates.isEmpty || !adbOK || model.barSoftwareBusy != nil)
                    .help(sw.updates.isEmpty ? "Nothing newer than what the bar has" : "Install " + sw.updates.map(\.name).joined(separator: " and ") + " on the bar")
                if let b = model.barSoftwareBusy { BusyLabel(b) }
            }
            .confirmationDialog("Update the bar's software?", isPresented: $confirmSoftwareUpdate, titleVisibility: .visible) {
                Button("Install " + sw.updates.map(\.name).joined(separator: " and ")) { model.updateBarSoftware() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deckhand downloads \(sw.updates.map { "\($0.name) (\($0.size / 1_000_000) MB)" }.joined(separator: " and ")) from Sanytron's GitHub release, checks the package and installs it. A new launcher restarts the bar's screen for a few seconds; keep the bar powered. Your pages and pairing stay.")
            }
        } header: {
            Text("Bar software")
        } footer: {
            Footnote("The launcher and bridge as published by Sanytron. The vendor's desktop app is not needed.")
        }
    }

    // MARK: Home screen and pages

    /// What the bar's screen starts in (Deckhand Home or the bar's own launcher) and the launcher's pages (Standard
    /// Mode, Deckhand, any made in the official app), in one section. The pages were a section of the CoreBar page
    /// until 2026-11-15; that page keeps only its card list, preview and Publish.
    private var home: some View {
        let h = model.barHome
        let needsInstall = h.installed == nil || h.updateAvailable
        return Section {
            LabeledContent("Home screen now") {
                Text(h.deckhandIsHome ? "Deckhand Home" : h.vendorIsHome ? "The bar's own launcher" : h.current == nil ? "Not read yet" : "Another app").foregroundStyle(.secondary)
                    .help(h.current ?? "")
            }
            LabeledContent("Deckhand Home") {
                if let i = h.installed { Text("\(i.name)" + (h.updateAvailable ? " · \(AppModel.homeVersion) available" : "")).foregroundStyle(.secondary) }
                else { Text(h.checkedAt != nil ? "Not installed" : "Not read yet").foregroundStyle(.secondary) }
            }
            if let m = h.message { StatusLabel(m, .attention) }
            HStack {
                Button(h.installed == nil ? "Install Deckhand Home" : h.updateAvailable ? "Update to \(AppModel.homeVersion)" : "Reinstall") { model.installBarHome() }
                    .primaryInline(needsInstall)
                    .disabled(model.barHomeBusy != nil || !adbOK)
                if h.deckhandIsHome {
                    Button("Use the Bar's Own Home") { model.setBarHome(deckhand: false) }
                        .disabled(model.barHomeBusy != nil || !adbOK)
                } else {
                    Button("Use Deckhand Home") { model.setBarHome(deckhand: true) }
                        .disabled(model.barHomeBusy != nil || !adbOK || h.installed == nil)
                }
                if let b = model.barHomeBusy { BusyLabel(b) }
            }
            if model.corebarPages.isEmpty {
                LabeledContent("Launcher pages") { Text(model.link.isConnected ? "Not read yet" : "Connect to the bar to read them").foregroundStyle(.secondary) }
            }
            ForEach(model.corebarPages, id: \.id) { p in
                LabeledContent {
                    if model.currentPageId == p.id {
                        Text("Showing").foregroundStyle(.secondary)
                    } else {
                        Button("Show") { model.switchPage(id: p.id) }
                            .help("Switch the bar's launcher to the \(p.name) page").accessibilityLabel("Show the \(p.name) page")
                    }
                } label: {
                    Text(p.name)
                    Text([AppModel.defaultPageId, AppModel.deckhandPageId].contains(p.id) ? "Page of the bar's own launcher" : "Made in the official app")
                }
            }
        } header: {
            Text("Home screen and pages")
        } footer: {
            Footnote("Deckhand Home shows the clock and one tile per app; the bar's own launcher keeps running, one tap away, with its pages. Publish on the CoreBar page rewrites those pages: after a Deploy from the official app, publish again. Refresh (⌘R) reads all of this off the bar.")
        }
    }

    // MARK: Cycle

    /// Every 1, 3, 5 or 10 minutes the next bar app (AppModel+Cycle).
    private var cycle: some View {
        let installed = AppModel.barAppPages.filter { model.barApps.isEmpty || model.barAppVersion($0.page) != nil }
        return Section {
            Toggle("Cycle through the bar apps", isOn: $settings.barCycle)
            Picker("Next app every", selection: $settings.barCycleMinutes) {
                ForEach(BarCycle.intervals, id: \.self) { Text("\($0) min").tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(!settings.barCycle)
            if settings.barCycle {
                StatusLabel(model.barCycleStatus, .info)
                DisclosureGroup("Apps in the cycle (\(model.barCyclePackages(settings: settings).count))") {
                    ForEach(installed, id: \.page) { app in
                        Toggle(app.label, isOn: Binding(
                            get: { settings.barCyclePages.isEmpty || settings.barCyclePages.contains(app.page) },
                            set: { on in toggleCycle(app.page, on: on, all: installed.map(\.page)) }))
                    }
                }
            }
        } header: {
            Text("Cycle through apps")
        } footer: {
            Footnote("Deckhand opens the next app over the debug bridge while this Mac is on, in the order of the Apps page. It waits while you use the bar (until the screen has not been touched for the whole interval) and while the screen is off, and leaves alone any other app you opened.")
        }
    }

    /// Empty means every app on the bar; switching one off turns the list into "all the others".
    private func toggleCycle(_ page: String, on: Bool, all: [String]) {
        var set = settings.barCyclePages.isEmpty ? Set(all) : Set(settings.barCyclePages)
        if on { set.insert(page) } else { set.remove(page) }
        settings.barCyclePages = set.count == all.count ? [] : all.filter { set.contains($0) }
    }

    // MARK: Screen

    private var screen: some View {
        Section {
            Toggle("Keep the screen on while someone is at the desk", isOn: $settings.presenceWake)
                .onChange(of: settings.presenceWake) { on in on ? model.startPresence(settings: settings) : model.stopPresence(settings: settings) }
            Stepper(value: $settings.presenceSleepMinutes, in: 1...120) {
                LabeledContent("Turn off after nobody for", value: "\(settings.presenceSleepMinutes) min")
            }
            .disabled(!settings.presenceWake)
            LabeledContent("Status") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.presenceStatus).multilineTextAlignment(.trailing)
                    if let on = model.barScreenOn { Text("Bar screen: \(on ? "on" : "off")").foregroundStyle(.secondary) }
                    // lastPresenceAt is not published (it changes with every presence line): read it every 5 s.
                    TimelineView(.periodic(from: .now, by: 5)) { _ in
                        if let t = model.lastPresenceAt { Text("Last movement \(Self.ago(t))").foregroundStyle(.secondary) }
                    }
                }.font(.callout)
            }
        } header: {
            Text("Screen")
        } footer: {
            Footnote("Uses the SenseCube's presence sensor. Without it, the bar's own screen timeout decides.")
        }
    }

    // MARK: Launcher

    private var launcher: some View {
        Section {
            Button("Restart Bar Launcher…") { confirmLauncher = true }.disabled(!adbOK)
        } header: {
            Text("Launcher")
        } footer: {
            Footnote("Fixes uploads to the cube that fail after about 100 sends, a leak in the bar's firmware. Deckhand also does this by itself when it can.")
        }
    }

    /// "42 s ago", "3 min ago".
    private static func ago(_ t: Date) -> String {
        let s = Int(Date().timeIntervalSince(t))
        return s < 120 ? "\(s) s ago" : "\(s / 60) min ago"
    }
}

/// One row of Bar software: what is on the bar, and whether the vendor's release is newer.
private struct SoftwareRow: View {
    let title: String, installed: (name: String, code: Int)?, latest: VendorRelease.Asset?, update: Bool
    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text(installed.map { "\($0.name) (\($0.code))" } ?? "Not read yet").foregroundStyle(.secondary)
                if let latest {
                    if update { Tag("Update \(latest.versionName)", .update) }
                    else if installed != nil { Tag("Up to date", .ok) }
                }
            }
        }
    }
}
