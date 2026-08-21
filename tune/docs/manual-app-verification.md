# Standalone app verification

`SymairaTune.app` is shipped as a standalone macOS menu-bar app. The release
DMG contains the app bundle and the `symtune` CLI binary; Homebrew installs the
app and links the CLI into `PATH`.

The standalone target is intentionally not App Sandbox-entitled. Display
brightness, gamma overlays, battery state, and AppleSMC reads use the same
system frameworks as the CLI; the app must not claim sandboxed capabilities it
cannot actually provide.

## Automated checks

CI performs these checks on every pull request:

1. Generate `SymairaTune.xcodeproj` from `project.yml` with XcodeGen.
2. Compile the `SymairaTune` target in Release configuration with Swift 6.
3. Validate the produced bundle's executable, bundle identifier, and
   `LSUIElement=true` setting.
4. Verify the code signature when the build is signed.

The release workflow additionally signs the app with Developer ID, notarizes
the DMG when the Apple credentials are configured, and publishes the cask
metadata.

## Real-host smoke test

Run this on a macOS host with the release DMG mounted or with a locally built
bundle:

```bash
open /Applications/SymairaTune.app
```

Verify:

- a slider icon appears in the menu bar and no Dock icon appears;
- opening the icon shows the popover;
- brightness, dimming, and warmth controls change the display through
  `TuneController`;
- battery, thermal, fan, and display information refreshes while the popover
  remains open;
- `Quit` terminates the app and all temporary display overrides are restored;
- `symtune doctor` and the MCP server continue to report the same capabilities
  as the app surface.

On machines without the required hardware, the UI must report unavailable or
unsupported capabilities rather than presenting them as working.
