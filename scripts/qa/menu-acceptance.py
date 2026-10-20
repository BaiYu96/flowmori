#!/usr/bin/env python3
"""Authorized local QA only: exercise Flowmori's panel with its own fixture icons."""
import argparse
import json
import pathlib
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
APP = 'app.flowmori.Flowmori'
FIXTURE = 'app.flowmori.MenuBarFixture'
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

def control(bundle, text, role='AXButton', timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for node in panel_nodes(bundle):
            if node.get('AXRole') == role and node.get('frame', [0, 0, 0, 0])[2] > 0:
                if text in [node.get('AXDescription'), node.get('AXTitle')]:
                    return node
        time.sleep(.2)
    raise RuntimeError(f'Missing scoped control: {text}')

def panel_nodes(bundle):
    nodes = request({'op': 'tree', 'bundle': bundle})
    excluded = [n['path'] for n in nodes if n.get('AXRole') == 'AXWindow' and n.get('AXTitle') == 'Flowmori 设置']
    return [n for n in nodes if not any(n['path'][:len(p)] == p for p in excluded)]

def press(bundle, node):
    return request({'op': 'press', 'bundle': bundle, 'path': node['path']})

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

def collapsed_fixture():
    return [item for item in snapshot() if item['bundle'] == FIXTURE]

def panel_visible():
    nodes = panel_nodes(APP)
    return any(node.get('AXRole') == 'AXWindow' and node.get('frame', [0, 0, 0, 0])[2] > 0 for node in nodes) \
        or any(node.get('AXDescription') == '收纳全部' for node in nodes)

def show_panel():
    # Exercise the product's actual menu-bar entry without sending a global key
    # into whichever application the user has brought to the foreground.
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
    return control(APP, 'Flowmori QA, Flowmori QA Normal')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, default=ROOT / ".validation/menu-panel-acceptance.json")
    args = parser.parse_args()
    proof = []
    try:
        for kind in ['Normal', 'Popover', 'Right']:
            # The caller starts with the panel closed. Build 8 automatically
            # arranges manageable icons; no manual divider positioning is needed.
            show_panel()
            nodes = panel_nodes(APP)
            collapse = next((node for node in nodes if node.get('AXRole') == 'AXButton' and node.get('AXDescription') == '收纳全部'), None)
            if collapse:
                press_text(APP, '收纳全部', 'AXButton')
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    current = collapsed_fixture()
                    if len(current) == 3 and all(item['frame'][0] < 0 for item in current):
                        break
                    time.sleep(.3)
            # The fixture must be active for its status-item action to present a
            # native menu/popover. Activating it dismisses Flowmori's panel, so
            # reopen the panel before locating the proxy button.
            request({'op': 'activate', 'bundle': FIXTURE})
            open_panel()
            before = collapsed_fixture()
            attempt = {'kind': kind, 'before': before, 'passed': False}
            proof.append(attempt)
            if len(before) != 3 or not all(item['frame'][0] < 0 for item in before):
                raise RuntimeError('Fixture icons are not all in the collapsed collection')
            if [item.get('title') for item in before] != EXPECTED_ORDER:
                raise RuntimeError(f'Fixture order is not the expected baseline: {before}')
            button = control(APP, 'Flowmori QA, Flowmori QA ' + kind)
            if kind == 'Right':
                x, y, width, height = button['frame']
                request({'op': 'click', 'point': [x+width/2, y+height/2], 'right': True})
                press_text(APP, '右键操作', 'AXMenuItem')
            else:
                press_text(APP, 'Flowmori QA, Flowmori QA ' + kind, 'AXButton')
            if kind == 'Popover':
                press_text(FIXTURE, '关闭测试弹窗')
            else:
                action = '右键测试操作' if kind == 'Right' else '普通菜单测试操作'
                press_text(FIXTURE, action, 'AXMenuItem')
            deadline = time.monotonic() + 60
            stable_since = None
            while True:
                after = collapsed_fixture()
                attempt['after'] = after
                if [item['id'] for item in after] == [item['id'] for item in before] and all(item['frame'][0] < 0 for item in after):
                    if stable_since is None:
                        stable_since = time.monotonic()
                    # Cover at least one product refresh tick. A brief recollapse
                    # followed by automatic expansion is not a passing result.
                    if time.monotonic() - stable_since >= 4:
                        attempt['stableSeconds'] = time.monotonic() - stable_since
                        break
                else:
                    stable_since = None
                if time.monotonic() > deadline:
                    raise RuntimeError(f'{kind}: original order/collapsed state not restored: {after}')
                time.sleep(.25)
            attempt['passed'] = True
            print(kind + ': real operation and original order restored', flush=True)
    except Exception as error:
        if proof:
            proof[-1]['error'] = str(error)
        raise
    finally:
        args.output.write_text(json.dumps(proof, indent=2))


if __name__ == "__main__":
    main()
