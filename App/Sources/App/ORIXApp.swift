// ORIX OS Automation
// File: App/Sources/App/ORIXApp.swift
// Description: The app: service bootstrap, main window, menu-bar item, commands (command palette, emergency stop), launch options for tests and self-screenshots.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import ORIXAppUI
import SwiftUI

/// Options read from the launch arguments. Used by UI tests and by the screenshot script; harmless otherwise.
struct LaunchOptions {
    let defaults = UserDefaults.standard
    var dataDirectory: String? { defaults.string(forKey: "ORIXDataDir") }
    var section: AppSection? { defaults.string(forKey: "ORIXSection").flatMap(AppSection.init(rawValue:)) }
    var shotPath: String? { defaults.string(forKey: "ORIXShot") }
    var shotDelay: Double { defaults.object(forKey: "ORIXShotDelay") as? Double ?? 3 }
    var windowSize: CGSize? {
        guard let s = defaults.string(forKey: "ORIXWindowSize") else { return nil }
        let p = s.lowercased().split(separator: "x").compactMap { Double($0) }
        return p.count == 2 ? CGSize(width: p[0], height: p[1]) : nil
    }
    /// `dark` or `light`: overrides the appearance for this launch only (screenshots).
    var appearance: String? { defaults.string(forKey: "ORIXAppearance") }
    var skipOnboarding: Bool { defaults.bool(forKey: "ORIXSkipOnboarding") }
    var isTest: Bool { defaults.bool(forKey: "ORIXUITest") }
    /// Debug builds only: accept provider keys from ORIX_DEV_*_API_KEY when the Keychain has none.
    var developmentKeys: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["ORIX_DEV_KEYS"] == "1"
        #else
        return false
        #endif
    }
}

@MainActor
@Observable
final class AppBoot {
    enum State { case starting, ready(AppModel), failed(String) }
    var state: State = .starting
    let launch = LaunchOptions()
    let backgroundAgent = BackgroundAgentRegistration()

    func start() async {
        guard case .starting = state else { return }
        do {
            var options = ServiceOptions()
            options.interactive = true
            options.allowDevelopmentCredentials = launch.developmentKeys
            if launch.isTest { options.keychainService = "ai.spboucher.orix.automation.uitests" }
            let paths = launch.dataDirectory.map { ORIXPaths(root: URL(fileURLWithPath: $0)) } ?? .default
            let services = try await ORIXServices.bootstrap(paths: paths, options: options)
            let model = AppModel(services: services)
            await model.start()
            if launch.skipOnboarding { model.showOnboarding = false }
            if let s = launch.section { model.section = s }
            let interrupted = await services.runs.recoverInterrupted(startedAt: services.processStart)
            if !interrupted.isEmpty {
                model.notice(String(localized: "\(interrupted.count) run(s) were interrupted when ORIX last closed. Open Runs to review them."), kind: .warning)
            }
            // The app also runs the scheduler; a lease makes sure only one process (app or background agent) fires.
            await services.workflows.startScheduler(owner: "app-\(ProcessInfo.processInfo.processIdentifier)")
            AgentNotifier.shared.start(services: services)
            state = .ready(model)
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

struct ORIXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var boot = AppBoot()

    var body: some Scene {
        WindowGroup("ORIX OS Automation", id: "main") {
            BootView(boot: boot)
                .frame(minWidth: 980, minHeight: 620)
                .task { await boot.start() }
        }
        .defaultSize(width: boot.launch.windowSize?.width ?? 1320, height: boot.launch.windowSize?.height ?? 840)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Automation") {
                Button("Command Palette…") { model?.showCommandPalette = true }.keyboardShortcut("k", modifiers: .command)
                Divider()
                ForEach(Array(AppSection.allCases.prefix(9).enumerated()), id: \.element) { i, s in
                    Button { model?.section = s } label: { Text(s.title) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
                Divider()
                Button("Emergency Stop") { model?.emergencyStop() }.keyboardShortcut(".", modifiers: [.command, .option, .control])
            }
        }

        MenuBarExtra {
            MenuBarContent(boot: boot)
        } label: {
            MenuBarLabel(boot: boot)
        }
        .menuBarExtraStyle(.window)
    }

    private var model: AppModel? { if case .ready(let m) = boot.state { return m }; return nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { sender.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
        return true
    }
}

struct BootView: View {
    @Bindable var boot: AppBoot

    private func scheme(_ name: String) -> ColorScheme? { name == "dark" ? .dark : name == "light" ? .light : nil }

    var body: some View {
        switch boot.state {
        case .starting:
            VStack(spacing: Theme.Space.m) { ProgressView(); Text("Starting…").font(Theme.Font.caption).foregroundStyle(Theme.textSecondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.canvas)
        case .failed(let message):
            VStack(spacing: Theme.Space.l) {
                EmptyState(symbol: "exclamationmark.triangle", title: "ORIX could not start", message: "The data folder could not be opened. Nothing was changed.")
                Text(message).font(Theme.Font.monoSmall).foregroundStyle(Theme.textSecondary).textSelection(.enabled).padding(.horizontal, Theme.Space.xl)
                Button("Reveal data folder") { NSWorkspace.shared.open(ORIXPaths.default.root) }.buttonStyle(SecondaryButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.canvas)
        case .ready(let model):
            RootView(backgroundAgent: boot.backgroundAgent)
                .environment(model)
                .preferredColorScheme(scheme(boot.launch.appearance ?? model.settings.appearance))
                .task { await SelfShot.runIfRequested(boot.launch) }
        }
    }
}

/// When launched with `-ORIXShot <file>`, the app writes a PNG of its own main window and quits. This photographs the
/// real running app (for the README) without needing Screen Recording permission.
@MainActor
enum SelfShot {
    static func runIfRequested(_ launch: LaunchOptions) async {
        guard let path = launch.shotPath else { return }
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(nanoseconds: UInt64(launch.shotDelay * 1_000_000_000))
        if let w = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) {
            // The window number lets a script photograph the composited window (`screencapture -l`), which includes
            // vibrancy that an in-process view snapshot cannot capture. `-ORIXShotHold` keeps the app open meanwhile.
            print("ORIX_WINDOW_ID \(w.windowNumber)"); fflush(stdout)
            let hold = UserDefaults.standard.double(forKey: "ORIXShotHold")
            if hold > 0 { try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000)); exit(0) }
        }
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }), let view = window.contentView?.superview ?? window.contentView else { exit(2) }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { exit(2) }
        do { try data.write(to: URL(fileURLWithPath: path)) } catch { exit(2) }
        exit(0)
    }
}
