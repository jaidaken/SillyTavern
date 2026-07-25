#!/usr/bin/env python3
"""Minimal fake textgen backend for the prompt-parity harness (parity-diff.mjs).

The parity harness needs BOTH frontends (old public/ and new wasm client) to reach a
real /generate call so the ST server logs their assembled prompt. The old frontend
refuses to send unless online_status != 'no_connection', which needs a live-looking
textgen backend. This answers only what the status probe + generate forward need:

  GET  /v1/models       -> {"data":[{"id":"parity-model"}]}   (marks the frontend connected)
  POST /v1/completions   -> a one-token SSE stream, then [DONE]  (so no error toast/hang)
  GET  /props            -> {} (llama.cpp probe; harmless if hit)

It never sees or shapes the prompt: the prompt is captured from the ST server log
(text-completions.js:290 logs request.body BEFORE forwarding here). This only keeps the
frontends happy enough to fire the send. Loopback only.

Usage: python3 parity-fake-backend.py [--port 8125]
"""

import argparse
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ST forwards the full generate body (prompt verbatim for type=ooba) here, so this is the
# clean JSON capture point for the diff. /captured hands them back, /clear resets.
_LOCK = threading.Lock()
_CAPTURED = []


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):  # silence per-request stderr noise
        pass

    def _json(self, obj, code=200):
        payload = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/v1/models", "/models"):
            return self._json({"object": "list", "data": [{"id": "parity-model", "object": "model"}]})
        if path == "/props":
            return self._json({})
        if path == "/captured":
            with _LOCK:
                return self._json(list(_CAPTURED))
        if path == "/clear":
            with _LOCK:
                _CAPTURED.clear()
            return self._json({"cleared": True})
        return self._json({"ok": True})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        path = self.path.split("?", 1)[0]
        if path.endswith("/completions"):
            try:
                body = json.loads(raw) if raw else {}
            except ValueError:
                body = {}
            with _LOCK:
                _CAPTURED.append({"prompt": body.get("prompt"), "stop": body.get("stop")})
            if not body.get("stream"):
                # non-streaming: the frontend json-parses a single completion object
                return self._json({"choices": [{"text": "ok", "index": 0, "finish_reason": "stop"}]})
            # One-token SSE stream then [DONE], the OpenAI-completions shape ST pipes back.
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            frame = json.dumps({"choices": [{"text": "ok", "index": 0, "finish_reason": None}]})
            self.wfile.write(f"data: {frame}\n\n".encode())
            done = json.dumps({"choices": [{"text": "", "index": 0, "finish_reason": "stop"}]})
            self.wfile.write(f"data: {done}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
            return
        return self._json({"ok": True})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8125)
    args = parser.parse_args()
    with ThreadingHTTPServer(("127.0.0.1", args.port), Handler) as httpd:
        sys.stderr.write(f"parity fake textgen backend on http://127.0.0.1:{args.port}\n")
        sys.stderr.flush()
        httpd.serve_forever()


if __name__ == "__main__":
    main()
