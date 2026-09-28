"""Real labelle-cli discovery, build and dispatch of the `ios` provider.

python tests/provider/e2e.py --cli <labelle> --zig <zig>

A fixture project pins this checkout as `local:` and hands the provider
`providers/ios.json` through `.provider_config`. The CLI resolves the package,
builds `bin/labelle-ios` with `zig build --system`, writes a contract 1.3.0
context and runs the hooks behind `labelle build|run|bundle --platform=ios`.

Generation is a fake assembler (the CLI suites' pattern) whose target
`build.zig` installs a marker executable, so no Xcode is needed. `xcrun` and
`codesign` are fakes on PATH (a Python script behind a `sh` shim) that log
their argv and emulate `simctl list -j`/`bootstatus`/`install`/`launch`/
`terminate`. On Windows the launch hook must refuse cleanly (the simulator
needs macOS) and never reach `xcrun`; build and bundle still run there.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import zipfile

p = argparse.ArgumentParser()
p.add_argument('--cli', required=True)
p.add_argument('--zig', required=True)
a = p.parse_args()
cli, zig = str(Path(a.cli).resolve()), str(Path(a.zig).resolve())
repo = Path(__file__).resolve().parents[2]
version = subprocess.check_output([zig, 'version'], text=True).strip()
windows = os.name == 'nt'
macos = sys.platform == 'darwin'

EXE_BYTES = 'FAKE-MACHO-EXECUTABLE'

# `generate --platform ios` writes `.labelle/<backend>_ios/` with a build.zig
# that only installs a marker executable (named by FAKE_EXES, default `game`,
# the assembler's iOS name since assembler#774) and an `assets/` tree.
FAKE_ASSEMBLER = r'''import os, sys
from pathlib import Path
argv = sys.argv[1:]
if argv and argv[0] == "--protocol-version":
    print(99)
elif argv and argv[0] == "install":
    print("FIXTURE_INSTALL_DONE", file=sys.stderr, flush=True)
elif argv and argv[0] == "generate":
    root = Path(argv[argv.index("--project-root") + 1])
    backend = argv[argv.index("--backend") + 1]
    platform_name = argv[argv.index("--platform") + 1]
    target = root / ".labelle" / f"{backend}_{platform_name}"
    target.mkdir(parents=True, exist_ok=True)
    exes = [e for e in os.environ.get("FAKE_EXES", "game").split(",") if e]
    lines = ['const std = @import("std");', 'pub fn build(b: *std.Build) void {',
             '    _ = b.standardOptimizeOption(.{});']
    for e in exes:
        (target / e).write_text("FAKE-MACHO-EXECUTABLE")
        lines.append(f'    b.getInstallStep().dependOn(&b.addInstallBinFile(b.path("{e}"), "{e}").step);')
    lines.append('}')
    (target / "build.zig").write_text("\n".join(lines) + "\n")
    (target / "assets" / "sub").mkdir(parents=True, exist_ok=True)
    (target / "assets" / "sub" / "level.json").write_text("{}")
    print("FIXTURE_GENERATE", file=sys.stderr, flush=True)
else:
    raise SystemExit("unexpected assembler invocation: " + repr(sys.argv))
'''

DEVICES = {
    'devices': {
        'com.apple.CoreSimulator.SimRuntime.watchOS-11-2': [
            {'udid': 'WATCH-0001', 'isAvailable': True, 'state': 'Booted', 'name': 'Apple Watch Series 10 (46mm)'}],
        'com.apple.CoreSimulator.SimRuntime.iOS-17-5': [
            {'udid': 'IPHONE15-OLD', 'isAvailable': True, 'state': 'Shutdown', 'name': 'iPhone 15', 'deviceTypeIdentifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-15'}],
        'com.apple.CoreSimulator.SimRuntime.iOS-18-2': [
            {'udid': 'IPAD-0001', 'isAvailable': True, 'state': 'Booted', 'name': 'iPad Air 11-inch (M2)', 'deviceTypeIdentifier': 'com.apple.CoreSimulator.SimDeviceType.iPad-Air-11-inch-M2'},
            {'udid': 'IPHONE16-0001', 'isAvailable': True, 'state': 'Shutdown', 'name': 'iPhone 16', 'deviceTypeIdentifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-16'},
        ],
    }
}

# The fake xcrun/codesign. Every call appends one JSON line to $FAKE_LOG:
# the tool, its argv, the SIMCTL_CHILD_* part of its environment and its
# parent pid (the provider tool, for the signal test).
FAKE_TOOL = r'''import json, os, sys, time
from pathlib import Path
tool = Path(sys.argv[0]).name
args = sys.argv[1:]
env = {k: v for k, v in os.environ.items() if k.startswith("SIMCTL_CHILD_")}
with open(os.environ["FAKE_LOG"], "a", encoding="utf-8") as log:
    log.write(json.dumps({"tool": tool, "argv": args, "env": env, "ppid": os.getppid(),
                          "via_provider": "LABELLE_CONTEXT" in os.environ}) + "\n")
state = Path(os.environ["FAKE_STATE"])
fail = os.environ.get("FAKE_FAIL", "")
if tool == "codesign":
    sys.exit(0)
if args[:1] != ["simctl"]:
    # Not the simulator: Zig itself asks `xcrun --sdk macosx --show-sdk-path`
    # on a macOS host. Hand it to the real xcrun.
    if os.path.exists("/usr/bin/xcrun"):
        os.execv("/usr/bin/xcrun", ["/usr/bin/xcrun", *args])
    sys.exit("fake xcrun: unexpected " + repr(args))
sub = args[1]
if sub in fail.split(","):
    print(f"fake simctl {sub}: failing on request", file=sys.stderr)
    sys.exit(2)
if sub == "list":
    assert args[2:] == ["-j", "devices", "available"], args
    print(os.environ["FAKE_DEVICES"])
elif sub == "bootstatus":
    assert args[3:] == ["-b"], args
elif sub == "install":
    app = Path(args[3])
    assert (app / "Info.plist").is_file(), app
elif sub == "terminate":
    (state / "terminated").write_text(args[3])
elif sub == "launch":
    import signal
    signal.signal(signal.SIGINT, lambda *_: (print("FAKE_APP interrupted", flush=True), os._exit(130)))
    assert args[2:4] == ["--console-pty", "--terminate-running-process"], args
    (state / "terminated").unlink(missing_ok=True)
    print("FAKE_APP started " + args[5] + " args=" + json.dumps(args[6:]), flush=True)
    for k, v in sorted(env.items()):
        print(f"FAKE_APP env {k[len('SIMCTL_CHILD_'):]}={v}", flush=True)
    if os.environ.get("FAKE_APP_HOLD"):
        (state / "launch.pid").write_text(f"{os.getpid()} {os.getppid()}")
        deadline = time.time() + 60
        while not (state / "terminated").exists() and time.time() < deadline:
            time.sleep(0.05)
        print("FAKE_APP terminated", flush=True)
    sys.exit(int(os.environ.get("FAKE_APP_EXIT", "0")))
else:
    sys.exit("fake simctl: unexpected " + repr(args))
'''


def shim(path: Path, script: Path):
    """An executable `path` that runs `script` with this Python."""
    if windows:
        path = path.with_suffix('.cmd')
        path.write_text(f'@echo off\r\n"{sys.executable}" "{script}" %*\r\nexit /b %ERRORLEVEL%\r\n')
    else:
        path.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{script}" "$@"\n')
        path.chmod(0o755)
    return path


with tempfile.TemporaryDirectory(prefix='labelle-ios-provider-') as temp:
    temp = Path(temp).resolve()
    state = temp / 'state'
    state.mkdir()
    # The script's own file name tells it which tool it is; the shim on PATH
    # carries the tool's name too.
    fakes, bin_dir = temp / 'fakes', temp / 'bin'
    bin_dir.mkdir()
    for name in ('xcrun', 'codesign'):
        (fakes / name).mkdir(parents=True)
        (fakes / name / name).write_text(FAKE_TOOL)
        shim(bin_dir / name, fakes / name / name)

    script = temp / 'fake_assembler.py'
    script.write_text(FAKE_ASSEMBLER)
    assembler = shim(temp / 'fake-assembler', script)

    # ── the fixture project ────────────────────────────────────────────────
    project = temp / 'game'
    (project / 'providers').mkdir(parents=True)
    (project / 'art').mkdir()
    (project / 'art/icon.png').write_bytes(b'\x89PNG\r\n\x1a\n' + b'FAKE-ICON')
    dep = f'.{{ .name = "ios", .repo = "local:{repo.as_posix()}", .version = "0.1.0" }}'
    (project / 'project.labelle').write_text(
        f'.{{ .name = "game", .title = "Fixture Game", .zig_version = "{version}", .backend = .sokol, '
        f'.app_icon = "art/icon.png", .plugins = .{{ {dep} }}, '
        '.provider_config = .{ .{ .package = "ios", .file = "providers/ios.json" } } }')
    (project / 'labelle.lock').write_text(f'.{{ .plugins = .{{ {dep} }} }}')
    settings = project / 'providers/ios.json'
    good = {'schema_version': 1, 'bundle_id': 'com.labelle.fixture', 'orientation': 'landscape'}
    settings.write_text(json.dumps(good))

    home = temp / 'home'
    log = temp / 'tools.log'
    env = {k: v for k, v in os.environ.items() if not k.startswith(('FAKE_', 'SIMCTL_CHILD_'))}
    env.update(LABELLE_HOME=str(home), LABELLE_ZIG=zig, LABELLE_ASSEMBLER=str(assembler),
               LABELLE_NO_PREBUILD='1', FAKE_LOG=str(log), FAKE_STATE=str(state), FAKE_DEVICES=json.dumps(DEVICES),
               PATH=os.pathsep.join([str(bin_dir), env.get('PATH', '')]))
    # A stale SIMCTL_CHILD_ in the caller's environment must not reach the app.
    env['SIMCTL_CHILD_LABELLE_STALE'] = 'leaked'

    def run(*args, cwd=project, ok=True, extra_env=None, timeout=900):
        merged = dict(env, **(extra_env or {}))
        result = subprocess.run([cli, *args], cwd=cwd, env=merged, capture_output=True, timeout=timeout,
                                encoding='utf-8', errors='replace')
        out = result.stdout + result.stderr
        if ok:
            assert result.returncode == 0, (args, result.returncode, out)
        else:
            assert result.returncode != 0, (args, out)
        return result.returncode, out

    def calls(tool=None):
        if not log.exists():
            return []
        entries = [json.loads(line) for line in log.read_text(encoding='utf-8').splitlines() if line.strip()]
        return [e for e in entries if tool is None or e['tool'] == tool]

    def simctl():
        """The `xcrun simctl` calls since the last `reset_log`."""
        return [e['argv'][1:] for e in calls('xcrun') if e['argv'][:1] == ['simctl']]

    def reset_log():
        if log.exists():
            log.unlink()

    target = project / '.labelle' / 'sokol_ios'
    ios_dir = target / 'zig-out' / 'ios'
    app = ios_dir / 'Fixture_Game.app'

    # ── discovery: no namespace, so nothing in help ────────────────────────
    _, out = run('help')
    assert 'ReservedNamespace' not in out, out

    # ── labelle build --platform=ios: the `app` hook ──────────────────────
    reset_log()
    _, out = run('build', '--platform=ios')
    assert "running after hook 'ios/app'" in out, out
    assert 'labelle-ios: app ready:' in out, out
    assert (app / 'game').read_text() == EXE_BYTES, list(app.iterdir())
    info = (app / 'Info.plist').read_text()
    for needle in ('<key>CFBundleIdentifier</key>\n    <string>com.labelle.fixture</string>',
                   '<key>CFBundleExecutable</key>\n    <string>game</string>',
                   '<key>CFBundleDisplayName</key>\n    <string>Fixture Game</string>',
                   '<key>MinimumOSVersion</key>\n    <string>15.0</string>',
                   '<key>UILaunchScreen</key>\n    <dict/>',
                   '<string>UIInterfaceOrientationLandscapeLeft</string>',
                   '<string>AppIcon60x60</string>'):
        assert needle in info, (needle, info)
    assert 'UIInterfaceOrientationPortrait' not in info, info
    assert (app / 'AppIcon60x60@2x.png').read_bytes().startswith(b'\x89PNG')
    assert (app / 'assets/sub/level.json').read_text() == '{}'
    assert (app / 'PkgInfo').read_text() == 'APPL????'
    record = json.loads((ios_dir / 'app.json').read_text())
    assert record['app'] == 'Fixture_Game.app' and record['executable'] == 'game', record
    assert not list((target / 'zig-out').glob('.ios-staging-*')), list((target / 'zig-out').iterdir())
    if macos:
        # Ad-hoc signed with the codesign on PATH, as Xcode signs simulator
        # builds, while still staged.
        assert len(calls('codesign')) == 1, calls('codesign')
        signed = calls('codesign')[0]['argv']
        assert signed[:4] == ['--force', '--sign', '-', '--timestamp=none'], signed
        assert Path(signed[4]).name == 'Fixture_Game.app' and Path(signed[4]).parent.name.startswith('.ios-staging-'), signed
        assert record['signed'] is True, record
    else:
        assert calls('codesign') == [] and record['signed'] is False, (calls('codesign'), record)
        assert 'is not signed: codesign needs a macOS host' in out, out
    assert simctl() == [], simctl()

    # The executable's name comes from the build (assembler#774), and exactly
    # one is required.
    # (A renamed executable leaves the old install behind: start clean.)
    reset_log()
    shutil.rmtree(target / 'zig-out' / 'bin')
    _, out = run('build', '--platform=ios', extra_env={'FAKE_EXES': 'sokol_ios_fixture'})
    assert '<string>sokol_ios_fixture</string>' in (app / 'Info.plist').read_text()
    shutil.rmtree(target / 'zig-out' / 'bin')
    _, out = run('build', '--platform=ios', ok=False, extra_env={'FAKE_EXES': 'game,helper'})
    assert "hook 'ios/app' failed" in out and '2 executables in' in out and 'bundles exactly one' in out, out
    assert 'left over from an older build' in out, out
    assert not app.exists(), 'a failed app hook left an older .app behind'
    shutil.rmtree(target / 'zig-out' / 'bin')

    # Settings are validated before anything is written.
    for body, reason in (
        ({'schema_version': 1, 'bundle_id': 'com.a.b', 'destination': 'device'}, 'device builds arrive in v0.2'),
        ({'schema_version': 1, 'bundle_id': 'game'}, "bundle_id 'game' is not a valid bundle identifier"),
        ({'schema_version': 1, 'bundle_id': 'com.a.b', 'package_name': 'x'}, "unknown key 'package_name'"),
        ({'schema_version': 1, 'bundle_id': 'com.a.b', 'simulator': {'udid': 'x'}}, "unknown key 'simulator.udid'"),
        ({'schema_version': 1}, 'does not match schema v1'),
    ):
        settings.write_text(json.dumps(body))
        _, out = run('build', '--platform=ios', ok=False)
        assert reason in out, (reason, out)
        assert not app.exists(), out
    settings.write_text(json.dumps(good))
    run('build', '--platform=ios')

    # ── labelle run --platform=ios: the `launch` hook ─────────────────────
    if windows:
        reset_log()
        _, out = run('run', '--platform=ios', ok=False)
        assert 'the iOS simulator requires macOS' in out, out
        assert "hook 'ios/launch' failed" in out, out
        assert simctl() == [], simctl()
    else:
        reset_log()
        code, out = run('run', '--platform=ios', '--scene=intro', '--', '--level=3')
        # Nothing booted but an iPad: the newest runtime's iPhone is booted.
        assert simctl() == [
            ['list', '-j', 'devices', 'available'],
            ['bootstatus', 'IPHONE16-0001', '-b'],
            ['install', 'IPHONE16-0001', str(app)],
            ['launch', '--console-pty', '--terminate-running-process', 'IPHONE16-0001', 'com.labelle.fixture', '--level=3'],
        ], simctl()
        launch = [e for e in calls('xcrun') if e['argv'][:2] == ['simctl', 'launch']][-1]
        assert launch['env'] == {'SIMCTL_CHILD_LABELLE_SCENE': 'intro'}, launch['env']
        assert 'FAKE_APP started com.labelle.fixture args=["--level=3"]' in out, out
        assert 'FAKE_APP env LABELLE_SCENE=intro' in out and 'LABELLE_STALE' not in out, out
        assert 'labelle-ios: the app exited (status 0)' in out, out

        # The app's exit status is the run's.
        reset_log()
        code, out = run('run', '--platform=ios', ok=False, extra_env={'FAKE_APP_EXIT': '3'})
        assert code == 3 and 'the app exited (status 3)' in out, (code, out)

        # A device by UDID on the command line beats the settings' name; a
        # booted device is not booted again.
        settings.write_text(json.dumps(dict(good, simulator={'device': 'iPhone 15'})))
        reset_log()
        run('run', '--platform=ios')
        assert simctl()[1] == ['bootstatus', 'IPHONE15-OLD', '-b'], simctl()
        reset_log()
        run('run', '--platform=ios', '--', '--device=IPAD-0001')
        assert [c[0] for c in simctl()] == ['list', 'install', 'launch'], simctl()
        assert simctl()[2][3] == 'IPAD-0001', simctl()
        settings.write_text(json.dumps(good))
        _, out = run('run', '--platform=ios', '--', '--device=iPhone 99', ok=False)
        assert "no available iOS simulator matches 'iPhone 99'" in out and 'IPHONE16-0001  iPhone 16' in out, out
        _, out = run('run', '--platform=ios', ok=False, extra_env={'FAKE_DEVICES': json.dumps({'devices': {}})})
        assert 'no iPhone simulator on iOS 15.0 or newer available: install an iOS simulator runtime' in out, out
        _, out = run('run', '--platform=ios', ok=False, extra_env={'FAKE_FAIL': 'install'})
        assert 'could not install the app' in out and 'failing on request' in out, out

        # --timeout: the app is terminated, the launch waited out, status 0.
        reset_log()
        start = time.monotonic()
        code, out = run('run', '--platform=ios', '--timeout=2s', extra_env={'FAKE_APP_HOLD': '1'})
        elapsed = time.monotonic() - start
        assert 'stopped the app after --timeout' in out and 'FAKE_APP terminated' in out, out
        assert simctl()[-1] == ['terminate', 'IPHONE16-0001', 'com.labelle.fixture'], simctl()
        assert elapsed < 120, elapsed

        def held_run(extra_env=None, args=()):
            """`labelle run` in the background with the fake app held open;
            returns the process and the provider tool's pid."""
            (state / 'launch.pid').unlink(missing_ok=True)
            proc = subprocess.Popen([cli, 'run', '--platform=ios', *args], cwd=project,
                                    env=dict(env, FAKE_APP_HOLD='1', **(extra_env or {})),
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, encoding='utf-8', errors='replace')
            deadline = time.monotonic() + 600
            while not (state / 'launch.pid').exists():
                assert proc.poll() is None and time.monotonic() < deadline, proc.communicate()[0]
                time.sleep(0.1)
            launch_pid, tool_pid = (int(x) for x in (state / 'launch.pid').read_text().split())
            return proc, launch_pid, tool_pid

        # SIGTERM to the provider tool: the same clean stop, status 0.
        reset_log()
        proc, _, tool_pid = held_run()
        os.kill(tool_pid, signal.SIGTERM)
        out = proc.communicate(timeout=120)[0]
        assert proc.returncode == 0, (proc.returncode, out)
        assert 'stopped the app on a termination signal' in out and 'FAKE_APP terminated' in out, out
        assert simctl()[-1] == ['terminate', 'IPHONE16-0001', 'com.labelle.fixture'], simctl()

        # Ctrl-C on a terminal: SIGINT to the tool AND to simctl, which passes
        # it to the app and exits 130. That is the user's stop: status 0.
        reset_log()
        proc, launch_pid, tool_pid = held_run()
        os.kill(tool_pid, signal.SIGINT)
        os.kill(launch_pid, signal.SIGINT)
        out = proc.communicate(timeout=120)[0]
        assert proc.returncode == 0, (proc.returncode, out)
        assert 'FAKE_APP interrupted' in out and 'stopped the app on a termination signal' in out, out
        assert 'the app exited (status 130)' not in out, out
        # Nothing may be left running: the app is terminated all the same.
        assert simctl()[-1] == ['terminate', 'IPHONE16-0001', 'com.labelle.fixture'], simctl()

        # `simctl terminate` failing (twice) with the app still running is
        # reported, not hidden: non-zero.
        reset_log()
        code, out = run('run', '--platform=ios', '--timeout=2s', ok=False,
                        extra_env={'FAKE_APP_HOLD': '1', 'FAKE_FAIL': 'terminate'})
        assert code == 1, (code, out)
        assert 'could not stop the app on the simulator' in out and 'may still be running' in out, out
        assert [c[0] for c in simctl()].count('terminate') == 2, simctl()

        # A renamed iPhone is still an iPhone (device type, not name), and an
        # iPad named like an iPhone is not.
        renamed = {'devices': {'com.apple.CoreSimulator.SimRuntime.iOS-18-2': [
            {'udid': 'LOOKALIKE', 'isAvailable': True, 'state': 'Shutdown', 'name': 'iPhone lookalike',
             'deviceTypeIdentifier': 'com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4'},
            {'udid': 'RENAMED', 'isAvailable': True, 'state': 'Shutdown', 'name': 'labelle CI phone',
             'deviceTypeIdentifier': 'com.apple.CoreSimulator.SimDeviceType.iPhone-16'}]}}
        reset_log()
        run('run', '--platform=ios', extra_env={'FAKE_DEVICES': json.dumps(renamed)})
        assert simctl()[1] == ['bootstatus', 'RENAMED', '-b'], simctl()

        # The automatic choice meets the app: an iPad-only app goes to the
        # (booted) iPad, and a minimum iOS no runtime meets is explained.
        settings.write_text(json.dumps(dict(good, device_family='2')))
        run('build', '--platform=ios')
        reset_log()
        run('run', '--platform=ios')
        assert [c[0] for c in simctl()] == ['list', 'install', 'launch'] and simctl()[1][1] == 'IPAD-0001', simctl()
        settings.write_text(json.dumps(dict(good, minimum_ios='19.0')))
        _, out = run('run', '--platform=ios', ok=False)
        assert 'no iPhone simulator on iOS 19.0 or newer available' in out, out
        settings.write_text(json.dumps(good))

        # No xcrun on PATH (a Linux host without the fakes): a clear refusal.
        path_without = os.pathsep.join(d for d in env['PATH'].split(os.pathsep) if Path(d) != bin_dir and d != '/usr/bin')
        if not macos:
            _, out = run('run', '--platform=ios', ok=False, extra_env={'PATH': path_without})
            assert 'xcrun not found on PATH: the iOS simulator requires macOS' in out, out

    # ── labelle bundle --platform=ios: the `bundle` hook ──────────────────
    reset_log()
    _, out = run('bundle', '--platform=ios')
    bundle_dir = target / 'zig-out' / 'bundle' / 'ios'
    archive = bundle_dir / 'Fixture_Game-simulator.zip'
    assert archive.is_file(), (out, list(bundle_dir.iterdir()) if bundle_dir.exists() else None)
    assert 'labelle-ios: bundle ready:' in out, out
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None
        names = z.namelist()
        assert names[0] == 'Fixture_Game.app/', names
        assert 'Fixture_Game.app/game' in names and 'Fixture_Game.app/Info.plist' in names, names
        assert 'Fixture_Game.app/assets/sub/level.json' in names, names
        assert z.read('Fixture_Game.app/game').decode() == EXE_BYTES
        mode = z.getinfo('Fixture_Game.app/game').external_attr >> 16
        assert mode == 0o100755, oct(mode)
        assert (z.getinfo('Fixture_Game.app/Info.plist').external_attr >> 16) == 0o100644
        info = z.read('Fixture_Game.app/Info.plist').decode()
        assert '<key>CFBundleVersion</key>\n    <string>1</string>' in info, info

    # --build-number stamps CFBundleVersion; anything but a positive integer
    # is refused.
    run('bundle', '--platform=ios', '--build-number=7')
    with zipfile.ZipFile(archive) as z:
        info = z.read('Fixture_Game.app/Info.plist').decode()
        assert '<key>CFBundleVersion</key>\n    <string>7</string>' in info, info
    assert '<string>7</string>' in (app / 'Info.plist').read_text()
    _, out = run('bundle', '--platform=ios', '--build-number=1.2', ok=False)
    assert "--build-number '1.2' is not a CFBundleVersion" in out, out

    elsewhere = temp / 'release-out'
    run('bundle', '--platform=ios', f'--output={elsewhere}')
    assert [f.name for f in elsewhere.iterdir()] == ['Fixture_Game-simulator.zip'], list(elsewhere.iterdir())

print('labelle-ios provider e2e: ok')
