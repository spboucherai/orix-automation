// ORIX OS Automation
// File: App/Sources/App/main.swift
// Description: Entry point. The same signed executable is the app and, when launchd starts it with --background-agent, the headless scheduler.
//
// Author: Simon-Pierre Boucher
// Contact: contact@spboucher.ai
import AppKit
import ORIXAppUI

if CommandLine.arguments.contains("--background-agent") {
    BackgroundAgent.runForever()
} else {
    ORIXApp.main()
}

/// The headless half of the product. No window, nobody to answer approvals: anything not already granted parks as
/// WAITING_APPROVAL and a notification says so.
enum BackgroundAgent {
    static func runForever() -> Never {
        // An accessory app: no Dock icon, but a main run loop for workspace, power and file-system observers.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                var options = ServiceOptions()
                options.interactive = false
                let services = try await ORIXServices.bootstrap(options: options)
                let settings = await services.runs.settings()
                guard settings.backgroundAgentEnabled else { exit(0) }   // disabled in Settings: leave quietly, launchd does not restart a clean exit
                _ = await services.runs.recoverInterrupted(startedAt: services.processStart)
                await services.workflows.startScheduler(owner: "agent-\(ProcessInfo.processInfo.processIdentifier)")
                AgentNotifier.shared.start(services: services)
            } catch {
                NSLog("ORIX background agent could not start: %@", error.localizedDescription)
                exit(1)
            }
        }
        app.run()
        exit(0)
    }
}
