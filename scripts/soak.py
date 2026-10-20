#!/usr/bin/env python3
"""Observe a real Flowmori process without reading or writing clipboard content.

Launch app with --diagnostics /absolute/path/heartbeat.json, then run this script.
"""
import argparse
import json
import pathlib
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("--heartbeat", required=True, type=pathlib.Path)
parser.add_argument("--output", required=True, type=pathlib.Path)
parser.add_argument("--seconds", type=int, default=7200)
parser.add_argument("--interval", type=int, default=30)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
started = time.time()
samples = []
failures = []
expected_pid = None
last_polls = None
# Keep this bounded acceptance run awake without changing system preferences.
# The assertion is released in finally, including a failed check.
awake = subprocess.Popen(["/usr/bin/caffeinate", "-i", "-t", str(args.seconds + 120)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    while True:
        now = time.time()
        heartbeat = json.loads(args.heartbeat.read_text())
        pid = heartbeat["pid"]
        if expected_pid is None:
            expected_pid = pid
        if pid != expected_pid:
            raise RuntimeError("App restarted during continuous-run check")
        if now - heartbeat["timestamp"] > 90:
            raise RuntimeError("Main-runloop heartbeat has not advanced for 90 seconds")
        result = subprocess.run(["ps", "-p", str(pid), "-o", "%cpu=,rss="], capture_output=True, text=True, check=True)
        cpu, rss = result.stdout.split()
        sample = {**heartbeat, "heartbeatTimestamp": heartbeat["timestamp"], "timestamp": now,
                  "elapsed": now-started, "cpuPercent": float(cpu), "rssKB": int(rss)}
        if last_polls is not None and heartbeat["clipboardPolls"] <= last_polls and samples and now-samples[-1]["timestamp"] > 20:
            raise RuntimeError("Clipboard polling heartbeat stopped")
        last_polls = heartbeat["clipboardPolls"]
        samples.append(sample)
        with (args.output / "samples.jsonl").open("a") as stream:
            stream.write(json.dumps(sample) + "\n")
        if now-started >= args.seconds:
            break
        time.sleep(min(args.interval, max(1, args.seconds-(now-started))))
except Exception as error:
    failures.append(str(error))
finally:
    if awake.poll() is None:
        awake.terminate()
        awake.wait(timeout=5)
    rss = [item["rssKB"] for item in samples]
    cpu = [item["cpuPercent"] for item in samples]
    steady = samples[2:] if len(samples) > 2 else samples
    sustained_high_cpu = len(steady) >= 10 and all(item["cpuPercent"] > 10 for item in steady[-10:])
    growth = (steady[-1]["rssKB"]-steady[0]["rssKB"]) if steady else 0
    if sustained_high_cpu:
        failures.append("CPU stayed above 10% for the last 10 samples")
    if growth > 150*1024:
        failures.append("Resident memory grew by more than 150 MiB after warm-up; investigate")
    complete = time.time()-started >= args.seconds and bool(samples)
    report = {"startedAt":started,"endedAt":time.time(),"requestedSeconds":args.seconds,
              "elapsedSeconds":time.time()-started,"sampleCount":len(samples),"pid":expected_pid,
              "completed":complete,"passed":complete and not failures,"failures":failures,
              "rssMinKB":min(rss) if rss else None,"rssMaxKB":max(rss) if rss else None,
              "rssGrowthKB":growth,"cpuMax":max(cpu) if cpu else None,
              "scope":"Process liveness, main-runloop and clipboard polling liveness, CPU and RSS. Does not establish screenshot/menu interaction correctness."}
    (args.output / "report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2), flush=True)
if not report["passed"]:
    raise SystemExit(1)
