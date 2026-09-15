#!/usr/bin/env python3
"""Exercise the installed CLI against a local deterministic Responses server.

No credentials, Node.js, or external model requests are used. All commands
operate in an explicitly provided scratch output directory.
"""

import argparse
import copy
import http.server
import json
import os
from pathlib import Path
import subprocess
import threading
import zlib


def specs(tools, namespace=None):
    for tool in tools:
        if tool.get("type") == "namespace":
            yield from specs(tool.get("tools", []), tool["name"])
        else:
            yield namespace, tool


def run_case(args, mode):
    root = args.output / mode
    root.mkdir(parents=True, exist_ok=False)
    work = root / "work"
    work.mkdir()
    config_home = root / "config"
    config_home.mkdir()
    scratch = root / "tmp"
    scratch.mkdir()
    catalog = json.loads(args.catalog.read_text())
    model = copy.deepcopy(catalog["models"][0])
    model.update(slug="solaris-smoke", display_name="Solaris smoke",
                 tool_mode=mode, prefer_websockets=False, use_responses_lite=False)
    catalog_path = root / "models.json"
    catalog_path.write_text(json.dumps({"models": [model]}))
    requests = []
    failures = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_POST(self):
            try:
                raw = self.rfile.read(int(self.headers["Content-Length"]))
                if self.headers.get("Content-Encoding") == "gzip":
                    raw = zlib.decompress(raw, 16 + zlib.MAX_WBITS)
                body = json.loads(raw)
                if not self.path.endswith("/responses"):
                    data = b'{"turns":[]}'
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                    return
                requests.append(body)
                index = len(requests)
                (root / f"request-{index}.json").write_text(json.dumps(body, indent=2))
                available = list(specs(body.get("tools", [])))
                names = {tool.get("name") for _, tool in available}
                use_v8 = args.expect_v8 and mode != "direct"
                if use_v8:
                    assert "exec" in names, names
                else:
                    assert "exec" not in names and "wait" not in names, names
                    assert names.intersection({"shell", "shell_command", "exec_command"}), names

                if index == 1:
                    if use_v8:
                        namespace, tool = next((ns, t) for ns, t in available if t.get("name") == "exec")
                        payload = "text('V8_OK_' + (6 * 7));"
                        item = dict(type="custom_tool_call", call_id="smoke-call", name="exec", input=payload)
                    else:
                        namespace, tool = next((ns, t) for ns, t in available if t.get("name") == "apply_patch")
                        payload = "*** Begin Patch\n*** Add File: smoke.txt\n+SPARC_TOOL_OK\n*** End Patch"
                        if tool["type"] == "custom":
                            item = dict(type="custom_tool_call", call_id="smoke-call", name="apply_patch", input=payload)
                        else:
                            item = dict(type="function_call", call_id="smoke-call", name="apply_patch", arguments=json.dumps({"patch": payload}))
                elif index == 2 and not use_v8:
                    assert (work / "smoke.txt").read_text() == "SPARC_TOOL_OK\n"
                    namespace, tool = next((ns, t) for ns, t in available if t.get("name") in {"shell", "shell_command", "exec_command"})
                    name = tool["name"]
                    command = "pwd; /usr/gnu/bin/grep SPARC_TOOL_OK smoke.txt"
                    params = {"cmd": command} if name == "exec_command" else {"command": ["/usr/bin/bash", "-c", command] if name == "shell" else command}
                    item = dict(type="function_call", call_id="smoke-shell", name=name, arguments=json.dumps(params))
                else:
                    expected = "V8_OK_42" if use_v8 else "SPARC_TOOL_OK"
                    outputs = [item for item in body.get("input", []) if item.get("type") in {"function_call_output", "custom_tool_call_output"}]
                    assert expected in json.dumps(outputs), outputs
                    namespace = None
                    item = dict(type="message", role="assistant", id="smoke-answer", content=[dict(type="output_text", text="SMOKE_COMPLETE")])
                if namespace:
                    item["namespace"] = namespace
                events = [
                    dict(type="response.created", response=dict(id=f"response-{index}")),
                    dict(type="response.output_item.done", item=item),
                    dict(type="response.completed", response=dict(id=f"response-{index}", usage=dict(input_tokens=0, output_tokens=0, total_tokens=0))),
                ]
                data = "".join("data: " + json.dumps(event) + "\n\n" for event in events).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except Exception as error:
                failures.append(repr(error))
                (root / "server-errors.log").write_text("\n".join(failures))
                self.send_error(500, str(error))

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    config = {
        "model_provider": "solaris_smoke",
        "model_providers.solaris_smoke.name": "Local smoke test",
        "model_providers.solaris_smoke.base_url": f"http://127.0.0.1:{server.server_port}/v1",
        "model_providers.solaris_smoke.wire_api": "responses",
        "model_providers.solaris_smoke.requires_openai_auth": False,
        "model_catalog_json": str(catalog_path),
        "features.code_mode": mode != "direct",
        "features.code_mode_only": mode == "code_mode_only",
        "features.code_mode_host.enabled": True,
        "features.code_mode_prewarm": True,
        "features.code_mode_host.disable_in_process_fallback": True,
        "features.shell_snapshot": False,
        "features.enable_request_compression": False,
        "features.local_thread_store_compression": False,
        "check_for_update_on_startup": False,
        "analytics.enabled": False,
    }
    # Solaris' ordinary CLI has no platform sandbox. Only the fixed local
    # fixture above supplies calls, all confined to this fresh scratch tree.
    command = [str(args.codex), "exec", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules", "--json", "-m", "solaris-smoke", "-C", str(work), "-s", "danger-full-access"]
    for key, value in config.items():
        command.extend(["-c", key + "=" + json.dumps(value)])
    command.append("Perform the local smoke check using the available tools.")
    env = dict(os.environ, CODEX_HOME=str(config_home), TMPDIR=str(scratch), NO_PROXY="127.0.0.1,localhost", no_proxy="127.0.0.1,localhost")
    for key in ["OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_API_KEY"]:
        env.pop(key, None)
    try:
        result = subprocess.run(command, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=180)
        (root / "stdout.log").write_text(result.stdout)
        (root / "stderr.log").write_text(result.stderr)
        assert result.returncode == 0, result.stderr[-3000:]
        assert not failures, failures
        assert "SMOKE_COMPLETE" in result.stdout, result.stdout[-3000:]
        assert len(requests) == (2 if args.expect_v8 and mode != "direct" else 3), len(requests)
        assert list(config_home.rglob("rollout-*.jsonl")), "missing persisted session"
        print(f"PASS {mode}: {'V8' if args.expect_v8 and mode != 'direct' else 'direct tools'}", flush=True)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", type=Path, required=True)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--expect-v8", action="store_true")
    options = parser.parse_args()
    for selected_mode in ["direct", "code_mode", "code_mode_only"]:
        run_case(options, selected_mode)
