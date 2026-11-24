# QA and state ledger — Symaira Cockpit

## Verified in OpenDesign

- Browser QA at 1440×1000 and 390×844: project hub, component/token previews, and `symaira-cockpit-reference.html`; no overflow, broken images, console errors, or page errors.
- Read-only overview and MCP-row details now open a read-only sheet with the confirmation action hidden. Tune/Operate mutations retain an explicit confirmation path; both branches were exercised independently.
- Reference states include overview, Tune, Scope, Operate, menu-bar popover, probe loading/failure/success, offline mode, permissions, unsupported/unavailable integration, light/dark, increased contrast and reduced transparency.
- Current OpenDesign render: `render-check/symaira-cockpit-reference.png`.
- OpenDesign linter: 0 P0, 0 P1, 0 P2.

## Production handoff gate

Capture release screenshots from the signed app with synthetic machine facts. Verify Accessibility, Screen Recording, unsupported hardware and destructive-confirmation behavior against the real services before publication.
