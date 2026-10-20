#!/usr/bin/env python3
"""Execute one scoped QA request. Use JSON input; no shell interpolation."""
import json
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
request = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {"op": "status"}
with tempfile.NamedTemporaryFile(mode="w", suffix=".json", dir=root / ".validation") as file:
    json.dump(request, file, ensure_ascii=False)
    file.flush()
    result = subprocess.run([str(root / ".validation/FlowmoriQAHelper"), file.name], capture_output=True, text=True)
    if request["op"] == "tree" and result.returncode == 0:
        value = json.loads(result.stdout)
        def visit(node):
            fields = {key: val for key, val in node.items() if key not in ("children", "actions")}
            print(json.dumps(fields, ensure_ascii=False))
            for child in node.get("children", []):
                visit(child)
        visit(value)
    else:
        print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, file=sys.stderr, end="")
    sys.exit(result.returncode)
