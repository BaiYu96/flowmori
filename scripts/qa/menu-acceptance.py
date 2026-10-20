#!/usr/bin/env python3
"""Authorized local QA only: exercise Flowmori's panel with its own fixture icons.

The collection interaction is direct activation, not temporary drag-out. The
Normal and Popover fixture items must open their real UI while the status items
stay collapsed for at least four seconds. Right-click direct activation is
reported as unsupported because the fixture's AX item exposes only AXPress;
the explicit "展开菜单栏" exit is verified instead of faking success.
"""
import argparse
import json
import pathlib
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
APP = 'app.flowmori.Flowmori'
FIXTURE = 'app.flowmori.MenuBarFixture2'
EXPECTED_ORDER = ['Flowmori QA Normal', 'Flowmori QA Popover', 'Flowmori QA Right']
RUN = ROOT / 'scripts/qa/run.py'

def request(value):
    result = subprocess.run(['python3', str(RUN), json.dumps(value)], capture_output=True, text=True, check=True)
    if value['op'] == 'tree':
        return [json.loads(line) for line in result.stdout.splitlines()]
    parsed = json.loads(result.stdout)
    if parsed.get('errorCode', 0) != 0:
        raise RuntimeError(parsed)
    return parsed

def panel_nodes(bundle):
    nodes = request({'op': 'tree', 'bundle': bundle})
    excluded = [n['path'] for n in nodes if n.get('AXRole') == 'AXWindow' and n.get('AXTitle') == 'Flowmori 设置']
    return [n for n in nodes if not any(n['path'][:len(p)] == p for p in excluded)]

def control(bundle, text, role='AXButton', timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for node in panel_nodes(bundle):
            if node.get('AXRole') == role and node.get('frame', [0, 0, 0, 0])[2] > 0:
                if text in [node.get('AXDescription'), node.get('AXTitle')]:
                    return node
        time.sleep(.2)
    raise RuntimeError(f'Missing scoped control: {text}')

def press_text(bundle, text, role='AXButton', timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result = request({'op': 'pressDescription', 'bundle': bundle, 'role': role, 'text': text})
            if result.get('errorCode', 0) == 0:
                return result
        except (RuntimeError, subprocess.CalledProcessError):
            pass
        time.sleep(.2)
    raise RuntimeError(f'Missing scoped control: {text}')

def snapshot():
    return request({'op': 'menuProbe'})['scoped']

def fixture_items():
    return [item for item in snapshot() if item['bundle'] == FIXTURE]

def panel_visible():
    nodes = panel_nodes(APP)
    return any(node.get('AXRole') == 'AXWindow' and node.get('frame', [0, 0, 0, 0])[2] > 0 for node in nodes) \
        or any(node.get('AXDescription') == '收纳全部' for node in nodes)

def show_panel():
    if panel_visible():
        return
    for _ in range(2):
        press_text(APP, 'Flowmori', 'AXMenuBarItem')
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if panel_visible():
                return
            time.sleep(.2)
    item = next((node for node in panel_nodes(APP)
                 if node.get('AXRole') == 'AXMenuBarItem' and node.get('AXDescription') == 'Flowmori'), None)
    if item:
        x, y, width, height = item['frame']
        request({'op': 'click', 'point': [x+width/2, y+height/2]})
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if panel_visible():
                return
            time.sleep(.2)
    raise RuntimeError('Menu panel did not open')

def open_panel():
    show_panel()
    return control(APP, '直接打开 Flowmori QA Normal')

def wait_collapsed(timeout=36):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        current = fixture_items()
        if len(current) == 3 and all(item['frame'][0] < 0 for item in current):
            return current
        time.sleep(.25)
    raise RuntimeError(f'Fixture did not return to the collapsed collection: {fixture_items()}')

def wait_expanded(timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        current = fixture_items()
        if len(current) == 3 and all(item['frame'][0] > 0 for item in current):
            return current
        time.sleep(.2)
    raise RuntimeError(f'Explicit menu-bar exit did not expand the fixture: {fixture_items()}')

def prepare_collapsed_panel():
    show_panel()
    nodes = panel_nodes(APP)
    collapse = next((node for node in nodes if node.get('AXRole') == 'AXButton' and node.get('AXDescription') == '收纳全部'), None)
    if collapse:
        press_text(APP, '收纳全部', 'AXButton')
    return wait_collapsed()

def start_layout_sampler(duration=8):
    return subprocess.Popen(
        ['python3', str(RUN), json.dumps({'op': 'sampleLayout', 'duration': duration, 'intervalMs': 50})],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

def finish_layout_sampler(process):
    out, err = process.communicate(timeout=15)
    if not out.strip():
        raise RuntimeError(f'Layout sampler produced no output: {err}')
    result = json.loads(out)
    if result.get('error'):
        raise RuntimeError(f'Layout sampler failed: {result["error"]}')
    return result

def check_unchanged(before, after):
    if [item['id'] for item in after] != [item['id'] for item in before]:
        raise RuntimeError(f'Fixture identity/order changed: before={before} after={after}')
    if not all(item['frame'][0] < 0 for item in after):
        raise RuntimeError(f'Fixture escaped the collapsed collection: {after}')
    if [item.get('title') for item in after] != EXPECTED_ORDER:
        raise RuntimeError(f'Fixture order is not the expected baseline: {after}')

def hold_stable(before, attempt, seconds=4):
    deadline = time.monotonic() + 60
    stable_since = None
    while True:
        after = fixture_items()
        attempt['after'] = after
        check_unchanged(before, after)
        if stable_since is None:
            stable_since = time.monotonic()
        if time.monotonic() - stable_since >= seconds:
            attempt['stableSeconds'] = time.monotonic() - stable_since
            return
        if time.monotonic() > deadline:
            raise RuntimeError(f'Collapsed layout did not stay stable: {after}')
        time.sleep(.25)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, default=ROOT / ".validation/menu-panel-acceptance.json")
    args = parser.parse_args()
    proof = []
    try:
        # Left-click and popover direct activation must really open the fixture UI.
        for kind in ['Normal', 'Popover']:
            prepare_collapsed_panel()
            # The fixture must be active for its status-item action to present UI.
            request({'op': 'activate', 'bundle': FIXTURE})
            open_panel()
            before = fixture_items()
            check_unchanged(before, before)
            attempt = {'kind': kind, 'direct': True, 'before': before, 'passed': False}
            proof.append(attempt)
            sampler = start_layout_sampler()
            try:
                press_text(APP, '直接打开 Flowmori QA ' + kind, 'AXButton')
                if kind == 'Popover':
                    press_text(FIXTURE, '关闭测试弹窗', 'AXButton', timeout=20)
                else:
                    press_text(FIXTURE, '普通菜单测试操作', 'AXMenuItem', timeout=20)
                hold_stable(before, attempt)
            finally:
                sampled = finish_layout_sampler(sampler)
                attempt['layoutSample'] = {'samples': sampled.get('samples'),
                                           'duration': sampled.get('duration'),
                                           'changeCount': sampled.get('changeCount'),
                                           'changes': sampled.get('changes', [])}
                if sampled.get('changeCount', 0) != 0:
                    raise RuntimeError(f'{kind}: layout moved during direct activation: {sampled.get("changes")}')
            attempt['passed'] = True
            print(kind + ': real UI opened, icons stayed collapsed and unchanged', flush=True)

        # Right-click direct activation is not supported by the fixture AX item.
        # Verify that the product disables it and offers the explicit exit.
        prepare_collapsed_panel()
        request({'op': 'activate', 'bundle': FIXTURE})
        open_panel()
        before = fixture_items()
        attempt = {'kind': 'Right', 'before': before, 'direct': False, 'supported': False}
        proof.append(attempt)
        button = control(APP, '直接打开 Flowmori QA Right')
        x, y, width, height = button['frame']
        request({'op': 'click', 'point': [x+width/2, y+height/2], 'right': True})
        time.sleep(.5)
        nodes = panel_nodes(APP)
        right_item = next((node for node in nodes
                           if node.get('AXRole') == 'AXMenuItem'
                           and '右键操作' in [node.get('AXDescription'), node.get('AXTitle')]), None)
        attempt['contextItemFound'] = right_item is not None
        attempt['contextItemEnabled'] = bool(right_item and right_item.get('AXEnabled'))
        if attempt['contextItemEnabled']:
            raise RuntimeError('Right direct activation unexpectedly became available; rerun the full right-click acceptance')
        request({'op': 'key', 'keyCode': 53})
        time.sleep(.3)
        press_text(APP, '展开菜单栏', 'AXButton')
        expanded = wait_expanded()
        attempt['expandedExit'] = expanded
        attempt['verifiedExit'] = True
        attempt['unsupportedReason'] = 'AXShowMenu is unsupported; the item exposes only AXPress'
        attempt['passed'] = False
        # Return the fixture to the collapsed state for the next run. The panel
        # can still be animating closed after the explicit exit, so retry.
        time.sleep(1)
        for _ in range(5):
            show_panel()
            try:
                press_text(APP, '收纳全部', 'AXButton', timeout=5)
                break
            except RuntimeError:
                time.sleep(1)
        else:
            raise RuntimeError('Could not reopen the collection panel to restore the fixture')
        after = wait_collapsed()
        check_unchanged(before, after)
        print('Right: direct right-click unsupported; explicit 展开菜单栏 exit verified', flush=True)
    except Exception as error:
        if proof:
            proof[-1]['error'] = str(error)
        raise
    finally:
        args.output.write_text(json.dumps(proof, indent=2))

if __name__ == '__main__':
    main()
