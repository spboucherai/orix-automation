<!--
ORIX OS Automation
File: docs/architecture/ui-contracts.md
Author: Simon-Pierre Boucher
Contact: contact@spboucher.ai
-->
# UI feature contracts

Binding for everyone writing a feature package. Read `docs/architecture/module-contracts.md` "Ground rules" first
(headers, Swift 6, no third-party code, never `pkill -f`, never commit, stay inside your package). The product brief is
`CLAUDE.md` at the repository root: §4 (design system and sections) and the sections for your feature.
`~/Desktop/Cluster/apple/CLAUDE.md` (KHAELOR) is unrelated — ignore it.

## Shape

- One Swift package per feature group under `Packages/ORIXFeature<Name>/`, depending **only** on `../ORIXAppUI`
  (`import ORIXAppUI` re-exports Core, Services, AgentRuntime, WorkflowEngine, Scheduler, Skills, Persistence,
  Security, AppleAutomation, ProviderAdapters, ToolRegistry). `platforms: [.macOS(.v15)]`, Swift 6 mode,
  `defaultLocalization: "en"`.
- Read before writing: every file in `Packages/ORIXAppUI/Sources/ORIXAppUI/` (design tokens, components, `AppModel`,
  approval/plan/question cards, `RunEventList`, `ShotRenderer`, `PreviewEnvironment`) and
  `Packages/ORIXServices/Sources/ORIXServices/*.swift` (what the UI may call: `ORIXServices`, `RunManager`,
  `WorkflowService`, `ProviderHub`, `ApprovalCenter`, `InteractionCenter`, store adapters, `AppSettings`).
  Do not edit those packages; list what you needed and did not find under "Contract requests" in your report.
- Each package exposes public root views that take no arguments beyond what is listed for it, read
  `@Environment(AppModel.self) private var model`, and reload their data with `.task(id: model.revision)` (the
  revision ticks on every store change, from this process or the background agent).
- A product `orix-preview-<name>` (executable target) renders every screen of the package with
  `ShotRenderer.render(view.environment(model), size:, dark:, to:)` on a `PreviewEnvironment.make()` model:
  `swift run orix-preview-<name> --shot <dir>` writes `<screen>-dark.png` and `<screen>-light.png`. **Open your own
  PNGs with the Read tool and iterate until the screens are genuinely good**: aligned, readable in both appearances,
  no clipped text, no empty boxes. An executable needs `_ = NSApplication.shared` and a main run loop
  (`Task { …; exit(0) }; RunLoop.main.run()`).

## Rules for every screen

- **Real state only.** Every number, list and status comes from services. No placeholder rows, no hardcoded
  metrics. Nothing to show → `EmptyState` with one sentence and, where it makes sense, the action that fixes it.
- **Every control works.** A button that says run, save, stop, retry, export, delete, enable does exactly that
  through services, shows progress while it runs, and reports failure with `model.report(error)` or an inline
  `Banner`. If a capability does not exist in services, do not draw the control; put it under "Not built" in your report.
- Destructive actions ask for confirmation (`confirmationDialog`) and say what will be lost.
- Design: use `Theme` tokens and the shared components; SF Symbols; restrained violet/blue accent; generous spacing;
  no gradients beyond the accent; no emoji. Dark and light must both look intentional. Compact window target
  1100×700, large 1600×1000: use `ViewThatFits`/adaptive grids, never a fixed width that clips.
- Motion: `Theme.spring(reduceMotion)`; nothing loops except `PulseDot` on live items.
- Accessibility: every icon-only button has `.accessibilityLabel`; meaningful groups are combined; status is never
  colour alone (use `StatusBadge`); every interactive element reachable by keyboard; add
  `.accessibilityIdentifier("<section>.<element>")` on the main controls (UI tests use them).
- Text: English in code through `LocalizedStringKey` / `String(localized:)`. Plain words, sentence case, no jargon
  about internals. Also write `Packages/<YourPackage>/Localization/fr.json`: a flat JSON object mapping every
  user-facing English string of your package (exactly as written in code, including `%@`/`%lld` placeholders for
  interpolations) to its French (Canada) translation. The lead merges these into the app's string catalog.
- Lists that can grow (runs, events, logs, files) are virtualised (`List`/`LazyVStack`) and paginated from the store.
- Known SwiftUI traps on this macOS: `.inspector` + `Table` inside `NavigationSplitView` in a narrow window can abort
  the app (use an `HSplitView`/side panel); animating Swift Charts on every sample is expensive; `ViewThatFits` picks
  the vertical layout when a child has long `fixedSize` text.
- Tests (Swift Testing): logic in view models is unit-tested against a `PreviewEnvironment` model (real services on
  a temp folder); one render test per screen asserts a non-trivial PNG. No test may need user interaction.

## Report

Public views and their initialisers, what each control does, screenshots written (paths), test counts,
"Not built" (anything in the brief for your section that you did not implement, with the reason), contract requests.
