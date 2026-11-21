<!--
ORIX OS Automation
File: CHANGELOG.md
Author: Simon-Pierre Boucher
Contact: contact@spboucher.ai
-->
# Changelog

## 1.0.0 — 2026-11-21

First version.

- Native macOS app (SwiftUI + AppKit): Dashboard, Agent, Workflow Studio, Code Studio, Runs, Scheduler, Agents,
  Skills, Watch & Learn, Permissions, Settings, onboarding, menu-bar item, command palette, emergency stop.
- Agent runtime: plan, act through tools, observe, verify postconditions, receipts; budgets, cancel, pause,
  guided plan review, delegation, compaction, crash recovery.
- Providers: Anthropic, OpenAI (Chat Completions), OpenRouter; keys in the login Keychain.
- 77 tools: filesystem, shell, git, HTTP, documents, Python, scripts, system, AppleScript/JXA, Accessibility,
  screen capture and OCR, clipboard, notifications, browser (WebKit), skills.
- Policy engine with scoped, revocable grants and four approval tiers; hash-chained audit log; Seatbelt
  confinement of scripts and skills.
- Workflow engine with a YAML/JSON language, validation, dry run, debugger, checkpoints; 15 built-in examples.
- Scheduler with cron (time zones, daylight saving), file and system triggers, missed-run policies, optional
  background agent.
- `orixctl` command-line front end.

See `docs/implementation-status.md` for what was verified and what is not built.
