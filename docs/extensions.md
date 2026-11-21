# Quick Look and Finder extensions

`Symaira Cockpit.app` embeds two app extensions under `Contents/PlugIns`. They have no Xcode
project: `scripts/build-extensions.sh` builds them with `swiftc` (called by `scripts/build-app.sh`,
skipped with `SKIP_EXTENSIONS=1`) and signs them with the same identity as the app.

| Extension | Bundle id | Does |
| :--- | :--- | :--- |
| `SymCockpitQuickLook.appex` | `com.symaira.cockpit.quicklook` | Previews folders (level by level) and ZIP, TAR and 7z archives through `crates/symcockpit-ffi`. Limits for entries, depth, declared size and time; nothing is unpacked; a limit hit shows a partial list with a notice. |
| `SymCockpitFinderSync.appex` | `com.symaira.cockpit.findersync` | Context menu: Copy Path, New File Here, Open in Terminal. A click writes `jobs/<uuid>.json` into the app group container; the app agent validates and runs it (`symcockpit-core::finder`). |

Both are sandboxed with minimal entitlements (Quick Look: `files.user-selected.read-only`;
FinderSync: nothing beyond the sandbox). The app group `<TEAM>.group.com.symaira.cockpit`
is added only when `EXPECTED_TEAM_ID` is set; without it FinderSync has no `jobs/` directory
and logs an error instead of writing a job. `.tar.gz` is not listed (it would need decompression).

## Not done by the build

Nothing is registered or enabled. To try a local build (all commands by hand, nothing automatic):

```bash
make build-app && make smoke-app
pluginkit -m -v | grep symaira.cockpit            # before: no match
open "build/app/Symaira Cockpit.app"              # LaunchServices learns the extensions
pluginkit -m -v | grep symaira.cockpit            # after: both ids
# System Settings > General > Login Items & Extensions > Finder / Quick Look: switch them on
qlmanage -p some.zip                              # preview
pluginkit -e ignore -i com.symaira.cockpit.quicklook   # to switch off again
```

Open questions only a real run answers (spike S6, risk K5): whether `pkd` loads the extensions
signed ad hoc or with an Apple Development identity and no provisioning profile; whether macOS
prefers its own preview for `public.zip-archive` and `public.folder`; whether the sandbox lets the
Quick Look extension list a previewed folder's contents (fallback: a read exception for `/`,
Developer ID builds only); whether the team-prefixed app group works without a profile.
