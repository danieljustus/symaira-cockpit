# Roadmap

## v0.1 (shipped)

- [x] Rebrand from `mac-operator` to Symaira conventions; builds, 29 tests pass.
- [x] MCP tools: snapshot, query_ui, list_apps, list_windows, click, type_text,
      press_keys, scroll, drag, launch_app, focus_window, menu_action, wait_for,
      permissions_status.
- [x] Safety guards: destructive-control refusal, secure-field block, ephemeral
      element cache.

## v0.2 (current) — robustness

- [x] Multi-display selection (`list_displays`, screenshots/UI queries by
      display ID or index).
- [x] Window-scoped capture.
- [x] OCR fallback (`query_ui_ocr`) via Vision framework for apps with weak
      Accessibility metadata.
- [x] Stronger, configurable action-policy checks (`get_policy`/`set_policy`
      allow/deny lists).
- [x] Richer UI targeting (`find_ui` predicates by role, title, label, frame).
- [x] `version` MCP tool + CLI command; `history --json` operation log.
- [x] Notarized DMG + Homebrew cask (`danieljustus/tap/symoperate`).
- [x] Tighten to Swift 6 strict concurrency (swift-tools-version 6.0).
- 127 tests passing (114 SymOperateCoreTests + 13 SymOperateSmokeTests).

## v0.3 — ecosystem alignment

- [ ] `doctor` JSON shape + exit codes aligned with the family (consider a thin
      Swift mirror of corekit exit codes).
- [ ] Pair with `symaira-tune`: shared macOS-agent guidance / optional combined
      MCP preset (operate + tune) for "control the Mac" agents.
- [ ] Surface in `symaira-scope` discovery (registered MCP server).

## Infra

- [x] Notarized DMG + Homebrew cask in `../homebrew-tap` (mirror symaira-terminal).
- [x] CI on macOS runner (build + test).
- [ ] SwiftLint gate.
- [x] Update checker (GitHub releases), ecosystem convention.
