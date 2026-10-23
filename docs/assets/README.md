# Documentation artwork

## Native workspace previews

`workspace-preview-light.png` and `workspace-preview-dark.png` are native
component renders from `CockpitDesignPreview`, using the production SwiftUI
components at source revision `003239b43890605d7490815bcd77ef3b0d0b6af5`.
The in-image **PREVIEW · Beispieldaten · Keine Hardwarezugriffe** notice is
intentional: the battery, CPU, fan and display values are explicit fixtures.
These images are not live hardware measurements or full-window screenshots.

Reproduce the original RGBA exports with the existing passive test:

```sh
COCKPIT_RENDER_DIR=/absolute/output/path swift test \
  --filter CockpitDesignRenderTests/testPassiveWorkspaceRendersBothAppearancesAndCompactLoading
```

For documentation, RGBA transparency is composited onto the canonical
Liquid Topography sidebar color (`#E1E0DA` light, `#171716` dark), leaving
all foreground content unchanged. `NSHostingView.cacheDisplay` does not
capture WindowServer's native glass or live shader compositing. No fake
replacement glass or topography is painted into the preview.

The render and passive-preview contract tests each executed one test with
zero failures. The original images were inspected at their real 2160×1520
size; the visible viewport ends partway through the scrollable content.

## Brand artwork

`social-preview.png` is a marketing illustration, not an application
screenshot. Its shared source is Symaira AppKit's `Brand/Marketing` kit.
The native app icon remains the approved A3 foreground composition; its
background follows the shared neutral light/dark palette. The native
`.icon` source, ICNS fallback and source hashes are vendored together.
