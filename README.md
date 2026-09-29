# labelle-ios

iOS platform package for the Labelle toolkit: the `ios` target provider and
the `labelle ios` commands for
[labelle-cli](https://github.com/labelle-toolkit/labelle-cli). It wraps the
iOS build into an `.app`, runs it on the iOS Simulator or a device, signs
device builds and packages them as an `.ipa`
([RFC labelle-cli#471](https://github.com/labelle-toolkit/labelle-cli/issues/471), items I1 and I6).

## Status: v0.2.0

- **What it does:** `labelle build|run|bundle --platform=ios` through four
  target hooks, and `labelle ios doctor|devices|xcode|run` (below).
  Simulator builds as in v0.1; device builds (`"destination": "device"`)
  are built with `-Ddevice=true`, signed with your identity and profile,
  run with `devicectl` and bundled as an `.ipa`.
- **Backend:** labelle-sokol, the only backend that builds iOS
  ([labelle-sokol v0.8.1](https://github.com/labelle-toolkit/labelle-sokol/releases/tag/v0.8.1)
  or newer). Set `.backend = .sokol` in the project.
- **CLI:** labelle-cli 4.0 or newer (the `ios` namespace was the CLI's own
  until 4.0). `command_contract = ">=1.3.0 <1.7.0"`: simulator builds work
  on every wire it admits; a device build needs contract **1.6.0**
  (`build_options`, labelle-cli#522). On an older wire a device build is
  refused with an upgrade message rather than silently built for the
  simulator.
- **Host:** building needs macOS with Xcode (the sokol build finds the iOS
  SDK with `xcrun`), and so do running, signing and the commands.
  `labelle run --platform=ios` on Windows or Linux refuses with "the iOS
  simulator requires macOS". `labelle ios doctor` tells you what is missing.

## Project setup

Pin the provider in `project.labelle` and point it at its settings file:

```zig
.backend = .sokol,
.backend_package = .{ .name = "sokol", .repo = "github.com/labelle-toolkit/labelle-sokol", .version = "0.8.1" },
.plugins = .{
    .{ .name = "ios", .repo = "github.com/labelle-toolkit/labelle-ios", .version = "0.2.0" },
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
alias as `labelle_<name>`, and this package's module is `labelle_ios` (empty;
it exists because the assembler wires every plugin into the build).

## What the hooks do

| Hook | When | What it does |
|---|---|---|
| `device` | before `build` (target `ios`) | For `"destination": "device"` only: writes the hook's `env_file` with `{"build_options":[{"name":"device","value":"true"}]}`, so the core build runs `zig build -Ddevice=true` (contract 1.6.0; a lower wire refuses the build naming the CLI upgrade). A simulator build contributes nothing. |
| `app` | after `build` | Finds the single executable in `<target_dir>/zig-out/bin` and writes `<target_dir>/zig-out/ios/<AppName>.app`: the executable, `Info.plist` (`CFBundleSupportedPlatforms` `iPhoneSimulator` or `iPhoneOS`), `PkgInfo`, the project's `app_icon` and `assets/`. A simulator app is ad-hoc signed (`codesign --sign -`), as Xcode does; a device app is signed with `signing.identity` and `signing.profile` (see [Device builds](#device-builds-and-signing)). Refuses when the build produced no executable or more than one. |
| `launch` | replaces `run` | Simulator build: picks a simulator, boots it if needed (`simctl bootstatus -b`), installs the app and runs it with `simctl launch --console-pty`. Device build: installs on the connected device with `devicectl device install app` and runs it with `devicectl device process launch --console`. Either way it **blocks until the app exits**; the app's output streams to the console and `labelle run` exits with its status. |
| `bundle` | replaces `bundle` | Makes the `.app` again with `CFBundleVersion` = `--build-number` (a positive integer, default 1) and archives it into the bundle output directory (`zig-out/bundle/ios/`, or `--output`): `<AppName>-simulator.zip` for a simulator build, `<AppName>.ipa` (`Payload/<AppName>.app`, signed) for a device build. Streamed, with Unix modes so the executable bit survives. |

Outputs, under the generated target directory `.labelle/sokol_ios/`:

```
zig-out/bin/<exe>                        core build (input; the assembler names it `game`)
zig-out/ios/<AppName>.app/               `app` hook
zig-out/ios/app.json                     what the .app was made from (executable and inputs digests)
zig-out/bundle/ios/<AppName>-simulator.zip   `bundle` hook, simulator build
zig-out/bundle/ios/<AppName>.ipa             `bundle` hook, device build
```

`<AppName>` is `app_name` (else the project `.title`, which must then pass the
same rule as `app_name`) with anything but letters, digits, `-` and `_`
replaced by `_`. A failed `app` hook leaves no `.app`: the previous one is
removed first; the new app and its `app.json` are staged together and moved
into `zig-out/ios/` in one rename. An unreadable `assets/` fails the hook;
only an absent one is skipped. A symbolic link in `assets/` ships its
target's contents when it resolves inside the project; a link that dangles
or leaves the project is refused. The `launch` hook refuses an app whose
executable, settings file, app name, icon or assets changed since it was
made.

### Running

```sh
labelle run --platform=ios                          # a booted iPhone, else the newest runtime's iPhone
labelle run --platform=ios -- --device=<udid|name>  # a specific simulator (or device, for a device build)
labelle run --platform=ios --scene=intro            # run options reach the app as environment variables
labelle run --platform=ios --timeout=30s            # stop the app after 30 s
```

- **Which simulator:** `-- --device=<udid|name>`, else `simulator.device` from
  the settings (either taken as asked), else automatically among the devices
  that can install the app, an iPhone (an iPad when `device_family` is `"2"`)
  on iOS `minimum_ios` or newer: a booted one, else one of the newest runtime. An iPhone is recognised by its device type
  (`com.apple.CoreSimulator.SimDeviceType.iPhone-*`), so a renamed one counts. A name on several runtimes picks the booted one, else the
  newest. Other arguments after `--` are passed to the app.
- **Run options** (`--scene`, `--profile`, `--screenshot`, `--after`) become
  `LABELLE_*` variables in the app's environment, handed over as
  `SIMCTL_CHILD_LABELLE_*`.
- **Which device** (device build): `-- --device=<id|udid|name>`, else the
  one connected, paired iOS device (`labelle ios devices` lists them); none
  or several is refused with the list.
- **Stopping:** `--timeout`, SIGTERM, SIGINT (Ctrl-C) and SIGHUP stop the app
  with `simctl terminate` and `labelle run` exits 0, even when `simctl`
  itself reports 130 for the Ctrl-C. If `simctl terminate` fails twice while
  the app is still running, the hook says so and exits 1. The simulator stays
  booted. On a device the `devicectl` console session is interrupted
  instead. On contract 1.5.0+ a `--timeout` stop is reported through
  `run.outcome_file`, so the CLI skips the after-run hooks as its own
  watchdog would.
- **Exit status:** the app's, as `simctl launch` reports it.

## `labelle ios` commands

| Command | What it does |
|---|---|
| `labelle ios doctor [--json] [--fix]` | Checks a macOS host, `xcrun`, Xcode selected (`xcode-select -p`, not the Command Line Tools), the Xcode license (`xcodebuild -license check`), the iOS simulator and device SDKs, a simulator runtime at `minimum_ios` or newer, `codesign`, `devicectl`, the project's backend (a warning unless sokol) and, for a device build, the signing identity (in `security find-identity`) and profile. Exits 1 when a required item is missing. `--json` prints the capability object `labelle doctor --json` aggregates (`{"id":"ios","required":true,"ok":…,"items":[…]}`, the labelle-android shape). `--fix` fixes nothing itself (every fix needs `sudo`, Xcode or a large download, and the doctor never runs `sudo`): it prints the exact commands, e.g. `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, `sudo xcodebuild -license accept`, `xcodebuild -downloadPlatform iOS`. Works outside a project. |
| `labelle ios devices` | Lists the available iOS simulators (newest runtime first) and, with Xcode 15+, the physical devices from `devicectl list devices`, with the id `--device=` takes and each device's connection state. |
| `labelle ios run [--device=<udid\|name>] [app args…]` | Installs and runs the app the last `labelle build --platform=ios` made, exactly as the `launch` hook does (simulator or device by the build's destination), without building. Refuses an app that is stale against the build or the settings. |
| `labelle ios xcode [--output=DIR]` | Writes an Xcode project around the built app, `ios-xcode/<AppName>.xcodeproj` plus `ios-xcode/<AppName>/` (the executable, its `Info.plist`, icons and `assets/`), for Xcode's automatic signing (`DEVELOPMENT_TEAM` from `team_id`), the debugger or Instruments. The target has no sources: a Copy Files phase embeds the prebuilt executable. A project wrapping a simulator build is limited to simulators (`SUPPORTED_PLATFORMS`). Only the export's own two entries are replaced. |

## Device builds and signing

```json
{
  "schema_version": 1,
  "bundle_id": "com.labelle.flying-platform",
  "team_id": "ABCDE12345",
  "destination": "device",
  "signing": {
    "identity": "Apple Development: Jo Doe (ABCDE12345)",
    "profile": "signing/development.mobileprovision"
  }
}
```

1. `labelle build --platform=ios`: the `device` hook asks for
   `-Ddevice=true` (contract 1.6.0), sokol builds for `aarch64-ios`, and the
   `app` hook signs the bundle: `security cms -D -i <profile>` decodes the
   profile, its `application-identifier` must cover `bundle_id` (exactly or
   by wildcard) and belong to `team_id` when set, its `Entitlements` are
   extracted with `PlistBuddy`, the profile is embedded as
   `embedded.mobileprovision`, and `codesign --force --sign <identity>
   --entitlements <…> --generate-entitlement-der` signs the app.
2. `labelle run --platform=ios` (or `labelle ios run`) installs and runs it
   on the connected device with `devicectl` (Xcode 15+).
3. `labelle bundle --platform=ios` writes `<AppName>.ipa`.

List the identities with `security find-identity -v -p codesigning`;
download a development profile from developer.apple.com or let Xcode manage
one (`labelle ios xcode`, then open the project once). The device needs
Developer Mode on and must trust the Mac.

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
  "destination": "simulator",
  "signing": { "identity": null, "profile": null }
}
```

v0.2 extends schema v1 additively (`signing`, and `destination: "device"`
accepted): every v0.1 file stays valid and means the same. A file that uses
`signing` is refused by v0.1, which does not know the key.

| Key | Required | Default | Rule |
|---|---|---|---|
| `schema_version` | yes | | `1` |
| `bundle_id` | yes | | reverse-DNS: at least two `.`-separated segments of letters, digits and `-`, the first starting with a letter |
| `app_name` | no | project `.title` | non-empty, no control characters, not a Windows device name (CON, PRN, AUX, NUL, COM1-9, LPT1-9, any case or extension); the home-screen name. A `.title` used in its place must pass the same rules |
| `team_id` | no | | 10 characters, `A-Z0-9`. A device build's profile must belong to it; `labelle ios xcode` writes it as `DEVELOPMENT_TEAM` |
| `minimum_ios` | no | `"15.0"` | `N.N` or `N.N.N`, at least 14.0 (the storyboard-free launch screen) |
| `orientation` | no | `"all"` | `portrait`, `landscape`, `sensor_landscape` (same as `landscape` on iOS), `all` (includes upside-down portrait) |
| `device_family` | no | `"1,2"` | `"1"` iPhone, `"2"` iPad, `"1,2"` both |
| `simulator.device` | no | `null` | a simulator UDID or device name; `null` picks one |
| `destination` | no | `"simulator"` | `"simulator"` or `"device"` (needs `signing.identity` and `signing.profile`, and contract 1.6.0) |
| `signing.identity` | for `device` | | a codesigning identity name or SHA-1 |
| `signing.profile` | for `device` | | a `.mobileprovision` path, relative to the project or absolute |

The parse is strict: unknown keys (nested ones too), duplicate keys and wrong
types are errors, and the file is validated before a hook does anything. It
replaces the CLI's `project.labelle .ios` block.

## Build and test

```sh
zig build test --summary all            # provider tool + module tests
zig build install-provider              # zig-out/bin/labelle-ios
python tests/provider/stdio_e2e.py --tool zig-out/bin/labelle-ios
python tests/provider/e2e.py --cli <labelle> --zig <zig>   # fake Xcode tools, every host
python tests/ios/sim_e2e.py --cli <labelle> --out <dir>    # real simulator, macOS + Xcode
```

The host tool (`tools/`) is std-only: the CLI builds it with
`zig build --system install-provider`, which disables dependency fetching. It
strictly decodes the context the CLI passes in `LABELLE_CONTEXT`
(`tools/contract.zig`, vendored from labelle-cli with its fixtures) and routes
on `(kind, id, step, phase)`; anything `plugin.labelle` does not declare is
refused.

CI runs the unit tests on Linux, macOS and Windows; the provider through a
real labelle-cli (v4.0.0) with a fake assembler and fake Xcode tools on the
three hosts, hooks and `labelle ios` commands; and, on `macos-latest`, the
sokol fixture in `tests/ios` built with the released assembler and sokol
v0.8.1 and run on a real simulator (log lines, `LABELLE_SCENE` forwarding,
`--timeout`, and a screenshot that must show the fixture's rectangle). The
device path runs end to end in `tests/provider/e2e.py` against a CLI with
contract 1.6.0; with v4.0.0 (1.5.0) it checks the upgrade refusal.

**Needs manual acceptance** (no CI can sign or reach a device): a device
build with a real identity and profile, installing and running it with
`devicectl` (and stopping it with `--timeout`/Ctrl-C), installing the
`.ipa`, and building and running the `labelle ios xcode` project in Xcode.

## Roadmap

- **Icons:** sized renditions and an asset catalog (`actool`); the app
  copies the project icon as-is.
- **Distribution signing:** App Store / ad hoc export (`xcodebuild
  -exportArchive`); v0.2 signs development builds.
