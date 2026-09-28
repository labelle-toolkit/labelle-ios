"""A real sokol app on a real iOS simulator, through the real CLI and this provider.

python tests/ios/sim_e2e.py --cli <labelle> --out <dir>

macOS with Xcode only. Copies the `tests/ios` fixture (labelle-sokol's
`test/ios`, sokol pinned to the v0.8.1 release, this checkout as the `ios`
provider through `local:`) into a scratch directory and, with a clean HOME,
LABELLE_HOME and Zig cache:

1. makes sure an available iPhone simulator exists in that HOME's device set
   (creates one from the newest installed iOS runtime when the set is empty;
   fails with the runtime listing when the image has no iOS runtime at all);
2. `labelle build --platform=ios`: the core build and the provider's `app` hook;
3. `labelle run --platform=ios --scene=main --timeout=<t>`: the `launch` hook
   boots the simulator, installs and launches the app; the fixture's script
   logs `LABELLE_IOS_FIXTURE ...` lines to the console, the first echoing
   LABELLE_SCENE (the run option, forwarded as SIMCTL_CHILD_LABELLE_SCENE);
4. while the app runs, `xcrun simctl io <udid> screenshot`; the PNG must not be
   blank and must show the fixture's magenta rectangle;
5. `--timeout` stops the app and `labelle run` exits 0.

Everything the run printed, the screenshot and a summary land in --out.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import zlib

p = argparse.ArgumentParser()
p.add_argument('--cli', required=True)
p.add_argument('--out', required=True)
p.add_argument('--timeout', default='45s', help='labelle run --timeout')
a = p.parse_args()
cli = str(Path(a.cli).resolve())
out_dir = Path(a.out).resolve()
out_dir.mkdir(parents=True, exist_ok=True)
repo = Path(__file__).resolve().parents[2]
fixture = repo / 'tests' / 'ios'
summary = {}


def fail(message):
    summary['result'] = 'FAIL: ' + message
    (out_dir / 'summary.json').write_text(json.dumps(summary, indent=2))
    raise SystemExit('sim_e2e: ' + message)


def sh(argv, env, cwd=None, timeout=600, check=True):
    print('+', ' '.join(str(x) for x in argv), flush=True)
    r = subprocess.run([str(x) for x in argv], env=env, cwd=cwd, capture_output=True, encoding='utf-8',
                       errors='replace', timeout=timeout)
    if check and r.returncode != 0:
        print(r.stdout + r.stderr)
        fail(f'{argv[0]} {argv[1] if len(argv) > 1 else ""} exited {r.returncode}')
    return r


def ensure_iphone(env):
    """An available iPhone in this HOME's device set; created if missing."""
    listed = json.loads(sh(['xcrun', 'simctl', 'list', '-j', 'devices', 'available'], env).stdout)
    iphones = [(rt, d) for rt, ds in listed['devices'].items() if '.iOS-' in rt
               for d in ds if d.get('isAvailable', True) and d['name'].startswith('iPhone')]
    runtimes = json.loads(sh(['xcrun', 'simctl', 'list', '-j', 'runtimes', 'available'], env).stdout)['runtimes']
    ios = [r for r in runtimes if r.get('platform') == 'iOS' or r['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS-')]
    summary['ios_runtimes'] = [f"{r['name']} ({r['identifier']})" for r in ios]
    if iphones:
        summary['device_set'] = f'{len(iphones)} available iPhone(s) already present'
        return
    if not ios:
        print(json.dumps(runtimes, indent=2))
        fail('this runner image has no iOS simulator runtime (`xcrun simctl list runtimes available` lists none); '
             'install one with `xcodebuild -downloadPlatform iOS`')
    runtime = max(ios, key=lambda r: [int(x) for x in re.findall(r'\d+', r['version'])])
    types = [t for t in runtime.get('supportedDeviceTypes', []) if t['name'].startswith('iPhone')]
    if not types:
        fail(f"iOS runtime {runtime['identifier']} supports no iPhone device type")
    kind = types[-1]
    sh(['xcrun', 'simctl', 'create', 'labelle-ios CI iPhone', kind['identifier'], runtime['identifier']], env)
    summary['device_set'] = f"created '{kind['name']}' on {runtime['name']} (the clean HOME's device set was empty)"


def png_pixels(path):
    """(width, height, rows of RGB tuples) of an 8-bit, non-interlaced PNG."""
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', 'not a PNG'
    pos, idat, header = 8, b'', None
    while pos < len(data):
        length, kind = struct.unpack('>I4s', data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b'IHDR':
            header = struct.unpack('>IIBBBBB', body)
        elif kind == b'IDAT':
            idat += body
        pos += 12 + length
    width, height, depth, color, _, _, interlace = header
    if depth != 8 or interlace != 0 or color not in (2, 6):
        fail(f'screenshot PNG format not handled: depth {depth}, color type {color}, interlace {interlace}')
    bpp = 3 if color == 2 else 4
    raw = zlib.decompress(idat)
    stride = width * bpp
    rows, prev, i = [], bytearray(stride), 0
    for _ in range(height):
        f = raw[i]
        line = bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        for x in range(stride):
            left = line[x - bpp] if x >= bpp else 0
            up = prev[x]
            ul = prev[x - bpp] if x >= bpp else 0
            if f == 1:
                line[x] = (line[x] + left) & 0xff
            elif f == 2:
                line[x] = (line[x] + up) & 0xff
            elif f == 3:
                line[x] = (line[x] + ((left + up) >> 1)) & 0xff
            elif f == 4:
                pa, pb, pc = abs(up - ul), abs(left - ul), abs(left + up - 2 * ul)
                line[x] = (line[x] + (left if pa <= pb and pa <= pc else up if pb <= pc else ul)) & 0xff
        rows.append(line)
        prev = line
    return width, height, bpp, rows


def check_screenshot(path):
    width, height, bpp, rows = png_pixels(path)
    colors, magenta, total = set(), 0, 0
    for line in rows[::4]:
        for x in range(0, width * bpp, bpp * 4):
            r, g, b = line[x], line[x + 1], line[x + 2]
            colors.add((r >> 3, g >> 3, b >> 3))
            total += 1
            # The fixture's (230, 30, 200) rectangle, allowing for the
            # simulator's colour-space conversion.
            if r > 150 and g < 110 and b > 130 and r - g > 90 and b - g > 70:
                magenta += 1
    summary['screenshot'] = {'size': [width, height], 'sampled': total, 'distinct_colors': len(colors),
                             'magenta_samples': magenta}
    print('screenshot:', summary['screenshot'], flush=True)
    if len(colors) < 2:
        fail('the screenshot is blank (one colour)')
    if magenta < 20:
        fail(f'the screenshot does not show the fixture\'s magenta rectangle ({magenta} magenta samples)')


with tempfile.TemporaryDirectory(prefix='labelle-ios-sim-') as temp:
    temp = Path(temp).resolve()
    project = temp / 'ios_sim_fixture'
    shutil.copytree(fixture, project, ignore=shutil.ignore_patterns('.labelle', 'zig-out', 'labelle.lock', '*.py'))
    # `local:../..` in the fixture is this repository; the copy pins it by path.
    source = (project / 'project.labelle').read_text()
    assert '"local:../.."' in source
    (project / 'project.labelle').write_text(source.replace('"local:../.."', f'"local:{repo.as_posix()}"'))

    home = temp / 'home'
    home.mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith(('LABELLE_', 'ZIG_', 'SIMCTL_CHILD_'))}
    env.update(HOME=str(home), LABELLE_HOME=str(temp / 'labelle-home'), ZIG_GLOBAL_CACHE_DIR=str(temp / 'zig-cache'),
               # The CLI under test is a main build versioned below the
               # releases the pinned packages expect.
               LABELLE_ALLOW_OLDER_CLI='1')

    ensure_iphone(env)

    r = sh([cli, 'build', '--platform=ios'], env, cwd=project, timeout=3600, check=False)
    (out_dir / 'build.log').write_text(r.stdout + r.stderr)
    print((r.stdout + r.stderr)[-6000:], flush=True)
    if r.returncode != 0:
        fail(f'labelle build --platform=ios exited {r.returncode} (build.log)')
    apps = list((project / '.labelle').glob('*_ios/zig-out/ios/*.app'))
    if len(apps) != 1:
        fail(f'expected one .app from the app hook, found {apps}')
    summary['app'] = str(apps[0].relative_to(project))
    summary['app_files'] = sorted(f.name for f in apps[0].iterdir())
    fileinfo = subprocess.run(['file', str(apps[0] / json.loads((apps[0].parent / 'app.json').read_text())['executable'])],
                              capture_output=True, text=True).stdout.strip()
    summary['executable'] = fileinfo
    print(fileinfo, flush=True)

    log_path = out_dir / 'run.log'
    started = time.monotonic()
    run = subprocess.Popen([cli, 'run', '--platform=ios', '--scene=main', f'--timeout={a.timeout}'], env=env,
                           cwd=project, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, encoding='utf-8',
                           errors='replace')
    lines = []

    def pump():
        with open(log_path, 'w', encoding='utf-8') as log:
            for line in run.stdout:
                lines.append(line)
                log.write(line)
                log.flush()
                sys.stdout.write(line)
                sys.stdout.flush()

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()
    udid, screenshot = None, out_dir / 'screenshot.png'
    deadline = time.monotonic() + 900
    while time.monotonic() < deadline:
        text = ''.join(lines)
        if udid is None:
            m = re.search(r'labelle-ios: simulator .* \(([0-9A-F-]{36}), iOS', text)
            if m:
                udid = m.group(1)
        if 'LABELLE_IOS_FIXTURE frame 120' in text:
            break
        if run.poll() is not None:
            reader.join(5)
            fail(f'labelle run exited {run.returncode} before the fixture logged frame 120 (run.log)')
        time.sleep(0.5)
    else:
        run.kill()
        fail('the fixture never logged frame 120 (run.log)')
    summary['frame_120_after_s'] = round(time.monotonic() - started, 1)
    if udid is None:
        fail('the launch hook never named the simulator it used')
    summary['simulator'] = udid
    time.sleep(2)  # a few more frames on screen
    shot = sh(['xcrun', 'simctl', 'io', udid, 'screenshot', screenshot], env, check=False)
    print(shot.stdout + shot.stderr, flush=True)
    try:
        code = run.wait(timeout=300)
    except subprocess.TimeoutExpired:
        run.kill()
        fail('labelle run did not end after --timeout')
    reader.join(10)
    text = ''.join(lines)
    summary['run_exit'] = code
    summary['log_lines'] = [line.strip() for line in lines if 'LABELLE_IOS_FIXTURE' in line or 'labelle-ios:' in line]
    if shot.returncode != 0 or not screenshot.is_file():
        fail('`simctl io screenshot` failed')
    check_screenshot(screenshot)
    if 'LABELLE_IOS_FIXTURE first frame LABELLE_SCENE=main' not in text:
        fail('the app did not see LABELLE_SCENE=main (run option → SIMCTL_CHILD_LABELLE_SCENE)')
    if 'labelle-ios: stopped the app after --timeout' not in text:
        fail('the launch hook did not stop the app on --timeout')
    if code != 0:
        fail(f'labelle run exited {code}')
    summary['result'] = 'ok'
    (out_dir / 'summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    print('labelle-ios real-simulator e2e: ok')
