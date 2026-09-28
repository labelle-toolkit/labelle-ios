# labelle-ios

iOS platform package for the Labelle toolkit: the `ios` target provider for
[labelle-cli](https://github.com/labelle-toolkit/labelle-cli). It wraps the
iOS build into an `.app`, runs it on the iOS Simulator and zips it for
distribution ([RFC labelle-cli#471](https://github.com/labelle-toolkit/labelle-cli/issues/471), item I1).

## Status: v0.1.0, simulator only

- **What it does:** `labelle build|run|bundle --platform=ios` through three
  target hooks (below). The app runs on the iOS Simulator.
- **Not yet (v0.2):** physical devices, code signing with a team, `.ipa`
  bundles, the `labelle ios …` commands and the Xcode project export. See the
  [roadmap](#roadmap-v02).
- **Backend:** labelle-sokol, the only backend that builds iOS
  ([labelle-sokol v0.8.1](https://github.com/labelle-toolkit/labelle-sokol/releases/tag/v0.8.1)
  or newer). Set `.backend = .sokol` in the project.
- **CLI:** labelle-cli with provider contract 1.3.0 (`command_contract =
  ">=1.3.0 <1.4.0"`): labelle-cli 2.1.0 or newer, the first release that
  carries it (until it ships, a build of `main`; v2.0.x speaks 1.2.0 and
  refuses this provider). No CLI change is needed: a provider's `replace run`
  hook takes precedence over the CLI's legacy iOS branch.
- **Host:** building needs macOS with Xcode (the sokol build finds the iOS
  SDK with `xcrun`), and so does running. `labelle run --platform=ios` on
  Windows or Linux refuses with "the iOS simulator requires macOS".

## Project setup

Pin the provider in `project.labelle` and point it at its settings file:

```zig
.backend = .sokol,
.backend_package = .{ .name = "sokol", .repo = "github.com/labelle-toolkit/labelle-sokol", .version = "0.8.1" },
.plugins = .{
    .{ .name = "ios", .repo = "github.com/labelle-toolkit/labelle-ios", .version = "0.1.0" },
},
.provider_config = .{ .{ .package = "ios", .file = "providers/ios.json" } },
```

Then pin the release:

```sh
labelle providers resolve            # preview: release, commit, sha256, targets
labelle providers resolve --accept   # verify the archive and write labelle.providers.lock
```

Commit `labelle.providers.lock`. To develop the provider itself, pin a local
checkout instead: `.{ .name = "ios", .repo = "local:../labelle-ios" }`.

The name must be `ios` everywhere: the assembler derives a plugin's module
alias as `labelle_<name>`, and this package's module is `labelle_ios` (empty
in v0.1; it exists because the assembler wires every plugin into the build).

## What the hooks do

| Hook | When | What it does |
|---|---|---|
| `app` | after `build` (target `ios`) | Finds the single executable in `<target_dir>/zig-out/bin` and writes `<target_dir>/zig-out/ios/<AppName>.app`: the executable, `Info.plist`, `PkgInfo`, the project's `app_icon` and `assets/`. On macOS it ad-hoc signs the bundle (`codesign --sign -`), as Xcode does for simulator builds. Refuses when the build produced no executable or more than one. |
| `launch` | replaces `run` | Picks a simulator, boots it if needed (`simctl bootstatus -b`), installs the app and runs it with `simctl launch --console-pty`, **blocking until the app exits**; the app's output streams to the console and `labelle run` exits with its status. |
| `bundle` | replaces `bundle` | Makes the `.app` again with `CFBundleVersion` = `--build-number` (a positive integer, default 1) and zips it into the bundle output directory (`zig-out/bundle/ios/`, or `--output`) as `<AppName>-simulator.zip`, streamed, with Unix modes so the executable bit survives. |

Outputs, under the generated target directory `.labelle/sokol_ios/`:

```
zig-out/bin/<exe>                        core build (input; the assembler names it `game`)
zig-out/ios/<AppName>.app/               `app` hook
zig-out/ios/app.json                     what the .app was made from (executable and inputs digests)
zig-out/bundle/ios/<AppName>-simulator.zip   `bundle` hook
```

`<AppName>` is `app_name` (else the project `.title`, which must then pass the
same rule as `app_name`) with anything but letters, digits, `-` and `_`
replaced by `_`. A failed `app` hook leaves no `.app`: the previous one is
removed first and the new one is staged. An unreadable `assets/` fails the
hook; only an absent one is skipped. The `launch` hook refuses an app whose
executable, settings file, app name or icon changed since it was made.

### Running

```sh
labelle run --platform=ios                          # a booted iPhone, else the newest runtime's iPhone
labelle run --platform=ios -- --device=<udid|name>  # a specific simulator
labelle run --platform=ios --scene=intro            # run options reach the app as environment variables
labelle run --platform=ios --timeout=30s            # stop the app after 30 s
```

- **Which simulator:** `-- --device=<udid|name>`, else `simulator.device` from
  the settings, else a booted iPhone, else an iPhone of the newest installed
  iOS runtime. An iPhone is recognised by its device type
  (`com.apple.CoreSimulator.SimDeviceType.iPhone-*`), so a renamed one counts. A name on several runtimes picks the booted one, else the
  newest. Other arguments after `--` are passed to the app.
- **Run options** (`--scene`, `--profile`, `--screenshot`, `--after`) become
  `LABELLE_*` variables in the app's environment, handed over as
  `SIMCTL_CHILD_LABELLE_*`.
- **Stopping:** `--timeout`, SIGTERM, SIGINT (Ctrl-C) and SIGHUP stop the app
  with `simctl terminate` and `labelle run` exits 0, even when `simctl`
  itself reports 130 for the Ctrl-C. If `simctl terminate` fails twice while
  the app is still running, the hook says so and exits 1. The simulator stays
  booted.
- **Exit status:** the app's, as `simctl launch` reports it.

## `providers/ios.json` (schema v1)

```json
{
  "schema_version": 1,
  "app_name": "Flying Platform",
  "bundle_id": "com.labelle.flying-platform",
  "team_id": "ABCDE12345",
  "minimum_ios": "15.0",
  "orientation": "landscape",
  "device_family": "1,2",
  "simulator": { "device": null },
  "destination": "simulator"
}
```

| Key | Required | Default | Rule |
|---|---|---|---|
| `schema_version` | yes | | `1` |
| `bundle_id` | yes | | reverse-DNS: at least two `.`-separated segments of letters, digits and `-`, the first starting with a letter |
| `app_name` | no | project `.title` | non-empty, no control characters; the home-screen name |
| `team_id` | no | | 10 characters, `A-Z0-9`. Validated now, used by device signing in v0.2 |
| `minimum_ios` | no | `"15.0"` | `N.N` or `N.N.N`, at least 14.0 (the storyboard-free launch screen) |
| `orientation` | no | `"all"` | `portrait`, `landscape`, `sensor_landscape` (same as `landscape` on iOS), `all` |
| `device_family` | no | `"1,2"` | `"1"` iPhone, `"2"` iPad, `"1,2"` both |
| `simulator.device` | no | `null` | a simulator UDID or device name; `null` picks one |
| `destination` | no | `"simulator"` | `"simulator"`. `"device"` is refused: device builds arrive in v0.2 |

The parse is strict: unknown keys (nested ones too), duplicate keys and wrong
types are errors, and the file is validated before a hook does anything. It
replaces the CLI's `project.labelle .ios` block.

## Build and test

```sh
zig build test --summary all            # provider tool + module tests
zig build install-provider              # zig-out/bin/labelle-ios
python tests/provider/stdio_e2e.py --tool zig-out/bin/labelle-ios
python tests/provider/e2e.py --cli <labelle> --zig <zig>   # fake xcrun, every host
python tests/ios/sim_e2e.py --cli <labelle> --out <dir>    # real simulator, macOS + Xcode
```

The host tool (`tools/`) is std-only: the CLI builds it with
`zig build --system install-provider`, which disables dependency fetching. It
strictly decodes the context the CLI passes in `LABELLE_CONTEXT`
(`tools/contract.zig`, vendored from labelle-cli with its fixtures) and routes
on `(kind, id, step, phase)`; anything `plugin.labelle` does not declare is
refused.

CI runs the unit tests on Linux, macOS and Windows; the provider through a
real labelle-cli (`main` at e2e0e85, contract 1.3.0) with a fake assembler and
fake `xcrun`/`codesign` on the three hosts; and, on `macos-latest`, the sokol
fixture in `tests/ios` built with the released assembler and sokol v0.8.1 and
run on a real simulator (log lines, `LABELLE_SCENE` forwarding, `--timeout`,
and a screenshot that must show the fixture's rectangle).

## Roadmap (v0.2)

- **Devices:** `destination: "device"` builds `-Ddevice=true` through the
  contract 1.4 `build_options` (RFC #471 D3), installs with `xcrun devicectl`.
- **Signing:** `signing.{identity, profile}` settings, `codesign` with the
  team, and an `.ipa` from `labelle bundle`.
- **`labelle ios …` commands:** `doctor` (Xcode, license, runtimes, backend),
  `devices`, `run`, `xcode`, once the CLI unreserves the `ios` namespace
  (RFC #471 I5).
- **Xcode project export** (`labelle ios xcode`), ported from the CLI's
  pbxproj generator.
- **Icons:** sized renditions and an asset catalog (`actool`); v0.1 copies the
  project icon as-is.
