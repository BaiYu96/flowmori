#!/usr/bin/env python3
"""Scoped native recovery checks; requires the installed build's diagnostics."""
import argparse
import importlib.util
import json
import pathlib
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('menu_acceptance', ROOT / 'scripts/qa/menu-acceptance.py')
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--case', choices=['exit', 'timeout'], required=True)
    parser.add_argument('--heartbeat', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    proof = {'case': args.case, 'passed': False}
    expected_pid = None
    opened = False

    def heartbeat():
        value = json.loads(args.heartbeat.read_text())
        if time.time() - value['timestamp'] > 30:
            raise RuntimeError('Diagnostic heartbeat is stale')
        if expected_pid is not None and value['pid'] != expected_pid:
            raise RuntimeError('Product restarted during recovery check')
        return value

    try:
        initial = heartbeat()
        expected_pid = initial['pid']
        if not initial['accessibility'] or not initial['screenCapture']:
            raise RuntimeError('Product permissions are not granted')
        if 'lastOperationOutcome' not in initial['menuLayout']:
            raise RuntimeError('This build cannot distinguish cancellation from timeout')
        qa.show_panel()
        collapse = next((n for n in qa.panel_nodes(qa.APP) if n.get('AXDescription') == '收纳全部'), None)
        if collapse:
            qa.press_text(qa.APP, '收纳全部', 'AXButton')
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                current = qa.fixture_items()
                if len(current) == 3 and all(n['frame'][0] < 0 for n in current):
                    break
                time.sleep(.3)
        before = qa.fixture_items()
        if len(before) != 3 or not all(n['frame'][0] < 0 for n in before):
            raise RuntimeError('Prepare all three fixture icons in the collapsed collection first')
        proof['before'] = before
        qa.show_panel()
        buttons = qa.fixture_buttons()
        deadline = time.monotonic() + 12
        while len(buttons) != 3 and time.monotonic() < deadline:
            time.sleep(.25)
            qa.show_panel()
            buttons = qa.fixture_buttons()
        if len(buttons) != 3:
            raise RuntimeError(f'Expected 3 fixture buttons, got {len(buttons)}')
        x, y, width, height = buttons[1]['frame']
        qa.request({'op': 'click', 'point': [x + width / 2, y + height / 2]})
        qa.control(qa.FIXTURE, '关闭测试弹窗')
        opened = True
        started = time.time()
        proof['openedAt'] = started
        print('Dedicated popover opened; waiting for recovery', flush=True)
        if args.case == 'exit':
            source_pid = next(n['ownerPID'] for n in before if n['title'] == 'Flowmori QA Popover')
            # Terminate only the observed fixture PID after checking its identity.
            code = ('import AppKit; '
                    f'if let app = NSRunningApplication(processIdentifier: {int(source_pid)}), '
                    'app.bundleIdentifier == "app.flowmori.MenuBarFixture2" '
                    '{ print(app.terminate()) }')
            result = subprocess.run(['swift', '-e', code], capture_output=True, text=True, check=True)
            if result.stdout.strip() != 'true':
                raise RuntimeError('Fixture termination was not accepted')
        expected = 'sourceTerminated' if args.case == 'exit' else 'timedOut'
        deadline = time.monotonic() + (30 if args.case == 'exit' else 150)
        while time.monotonic() < deadline:
            value = heartbeat()
            if value['timestamp'] > started and not value['menuOperating']:
                outcome = value['menuLayout']['lastOperationOutcome']
                proof['result'] = {key: value[key] for key in
                                   ['timestamp', 'pid', 'menuOperating', 'menuExpanded', 'menuItems', 'menuLayout']}
                proof['elapsedSeconds'] = time.time() - started
                if outcome != expected:
                    raise RuntimeError(f'Expected {expected}, observed {outcome}; recovery is not established')
                if value['menuExpanded'] != (args.case == 'timeout'):
                    raise RuntimeError('Unexpected menu expansion state after recovery')
                if args.case == 'timeout' and proof['elapsedSeconds'] < 115:
                    raise RuntimeError('Timeout occurred earlier than the two-minute limit')
                message = value['menuLayout']['message']
                # Successful source exit returns to the normal collection summary.
                # The stable outcome/stage proves completion; only failures pin a message.
                required = [] if args.case == 'exit' else ['展开', '两分钟']
                if args.case == 'exit' and value['menuLayout']['operationStage'] != 'source-terminated':
                    raise RuntimeError('Source exit did not reach its completion stage')
                if any(word not in message for word in required):
                    raise RuntimeError('Missing Chinese recovery explanation')
                if args.case == 'exit':
                    scoped = qa.request({'op': 'menuProbe', 'bundle': qa.APP})['scoped']
                    if any(n['bundle'] == qa.FIXTURE for n in scoped):
                        raise RuntimeError('Exited fixture icons remain present')
                    proof['after'] = scoped
                proof['passed'] = True
                break
            time.sleep(.5)
        else:
            raise RuntimeError('Recovery did not finish before the acceptance deadline')
    except Exception as error:
        proof['error'] = str(error)
        raise
    finally:
        args.output.write_text(json.dumps(proof, indent=2, ensure_ascii=False))
        if opened and args.case == 'timeout':
            try:
                qa.press_text(qa.FIXTURE, '关闭测试弹窗', 'AXButton', timeout=2)
            except Exception:
                pass  # Locked desktop or a dismissed popover: do not force input.
        print(json.dumps(proof, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
