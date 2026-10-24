#!/usr/bin/env python3
"""Authorized local QA only: exercise Flowmori's inline collection menus.

Flowmori opens the source status-item menu at the hidden icon's off-screen
anchor, snapshots its AX menu items, cancels the native menu, and renders those
items inside the collection panel. Selecting an item re-opens the source menu
off-screen briefly and presses the stored item path. The fixture verifies the
real action, and the sampler verifies that the status items never move.
"""
import argparse
import json
import os
import pathlib
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
APP = 'ai.flowmori.Flowmori'
FIXTURE = 'app.flowmori.MenuBarFixture2'
EXPECTED_ORDER = ['Flowmori QA Normal', 'Flowmori QA Popover', 'Flowmori QA Right']
RUN = ROOT / 'scripts/qa/run.py'
EVENTS = pathlib.Path(os.environ.get('FLOWMORI_QA_EVENTS', '/tmp/flowmori-qa-events.jsonl'))


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


def fixture_buttons():
    buttons = [node for node in panel_nodes(APP)
               if node.get('AXRole') == 'AXButton'
               and str(node.get('AXDescription', '')).startswith('直接打开 Flowmori QA')]
    return sorted(buttons, key=lambda node: (node.get('frame', [0, 0, 0, 0])[1],
                                             node.get('frame', [0, 0, 0, 0])[0]))


def press_node(node):
    return request({'op': 'press', 'bundle': APP, 'path': node['path']})


def panel_visible():
    nodes = panel_nodes(APP)
    return any(node.get('AXRole') == 'AXWindow' and node.get('frame', [0, 0, 0, 0])[2] > 0 for node in nodes)


def wait_panel_closed(timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not panel_visible():
            return
        time.sleep(.2)
    raise RuntimeError('Collection panel did not close after the menu action')


def status_item():
    for node in panel_nodes(APP):
        if node.get('AXRole') != 'AXMenuBarItem':
            continue
        frame = node.get('frame', [0, 0, 0, 0])
        if node.get('AXDescription') == 'Flowmori' or (not node.get('AXTitle') and frame[0] > 0):
            return node
    return None


def show_panel():
    if panel_visible():
        return
    for _ in range(2):
        item = status_item()
        if item:
            request({'op': 'press', 'bundle': APP, 'path': item['path']})
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if panel_visible():
                return
            time.sleep(.2)
    item = status_item()
    if item:
        x, y, width, height = item['frame']
        request({'op': 'click', 'point': [x + width / 2, y + height / 2]})
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if panel_visible():
                return
            time.sleep(.2)
    raise RuntimeError('Menu panel did not open')


def open_panel():
    show_panel()
    buttons = fixture_buttons()
    if not buttons:
        raise RuntimeError('Missing fixture buttons in collection panel')
    return buttons[0]


def wait_collapsed(timeout=36):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        current = fixture_items()
        if len(current) == 3 and all(item['frame'][0] < 0 for item in current):
            return current
        time.sleep(.25)
    raise RuntimeError(f'Fixture did not return to the collapsed collection: {fixture_items()}')


def prepare_collapsed_panel():
    show_panel()
    nodes = panel_nodes(APP)
    collapse = next((node for node in nodes if node.get('AXRole') == 'AXButton'
                     and node.get('AXDescription') == '收纳全部'), None)
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


def event_count(name):
    if not EVENTS.exists():
        return 0
    return sum(1 for line in EVENTS.read_text().splitlines()
               if line.strip() and json.loads(line).get('event') == name)


def wait_event(name, baseline, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if event_count(name) > baseline:
            return
        time.sleep(.15)
    raise RuntimeError(f'Fixture action did not run: {name}')


def wait_inline_row(text, timeout=12):
    for role in ('AXButton', 'AXMenuItem'):
        try:
            return control(APP, text, role, timeout=max(1, timeout / 2))
        except RuntimeError:
            pass
    raise RuntimeError(f'Missing scoped control: {text}')


def verify_layout(before, attempt, sampler):
    sampled = finish_layout_sampler(sampler)
    attempt['layoutSample'] = {'samples': sampled.get('samples'),
                               'duration': sampled.get('duration'),
                               'changeCount': sampled.get('changeCount'),
                               'changes': sampled.get('changes', [])}
    if sampled.get('changeCount', 0) != 0:
        raise RuntimeError(f'Status-item layout moved: {sampled.get("changes")}')
    after = fixture_items()
    attempt['after'] = after
    check_unchanged(before, after)
    time.sleep(4)
    check_unchanged(before, fixture_items())


def run_inline_action(kind, row_text):
    prepare_collapsed_panel()
    request({'op': 'activate', 'bundle': FIXTURE})
    open_panel()
    before = fixture_items()
    check_unchanged(before, before)
    attempt = {'kind': kind, 'direct': True, 'inline': True, 'before': before, 'passed': False}
    baseline = event_count('menu-action')
    sampler = start_layout_sampler()
    try:
        buttons = fixture_buttons()
        if len(buttons) != 3:
            raise RuntimeError(f'Expected 3 fixture buttons, got {len(buttons)}')
        if kind == 'Right':
            button = buttons[2]
            x, y, width, height = button['frame']
            request({'op': 'click', 'point': [x + width / 2, y + height / 2], 'right': True})
            press_text(APP, '右键操作', 'AXMenuItem')
        else:
            x, y, width, height = buttons[0]['frame']
            request({'op': 'click', 'point': [x + width / 2, y + height / 2]})
        row = wait_inline_row(row_text)
        request({'op': 'press', 'bundle': APP, 'path': row['path']})
        wait_event('menu-action', baseline)
        wait_panel_closed()
        verify_layout(before, attempt, sampler)
    finally:
        if sampler.poll() is None:
            try:
                verify_layout(before, attempt, sampler)
            except Exception as error:
                attempt['error'] = str(error)
    attempt['passed'] = True
    return attempt


def run_popover():
    prepare_collapsed_panel()
    request({'op': 'activate', 'bundle': FIXTURE})
    open_panel()
    before = fixture_items()
    check_unchanged(before, before)
    attempt = {'kind': 'Popover', 'direct': True, 'inline': False, 'before': before, 'passed': False}
    sampler = start_layout_sampler()
    try:
        buttons = fixture_buttons()
        if len(buttons) != 3:
            raise RuntimeError(f'Expected 3 fixture buttons, got {len(buttons)}')
        x, y, width, height = buttons[1]['frame']
        request({'op': 'click', 'point': [x + width / 2, y + height / 2]})
        press_text(FIXTURE, '关闭测试弹窗', 'AXButton', timeout=20)
        wait_panel_closed()
        verify_layout(before, attempt, sampler)
    finally:
        if sampler.poll() is None:
            try:
                verify_layout(before, attempt, sampler)
            except Exception as error:
                attempt['error'] = str(error)
    attempt['passed'] = True
    return attempt


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=pathlib.Path, default=ROOT / '.validation/menu-panel-acceptance.json')
    args = parser.parse_args()
    proof = []
    try:
        proof.append(run_inline_action('Normal', '普通菜单测试操作'))
        print('Normal: inline menu action executed; status items stayed collapsed', flush=True)
        proof.append(run_popover())
        print('Popover: direct popover opened and closed; status items stayed collapsed', flush=True)
        proof.append(run_inline_action('Right', '普通菜单测试操作'))
        print('Right: context menu fallback opened the inline menu and executed the action', flush=True)
    except Exception as error:
        if proof:
            proof[-1]['error'] = str(error)
        raise
    finally:
        args.output.write_text(json.dumps(proof, indent=2))


if __name__ == '__main__':
    main()
