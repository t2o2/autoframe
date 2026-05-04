#!/usr/bin/env python3
"""
Anthropic → OpenRouter compatibility proxy.

Claude Code sends proprietary tool types (e.g. advisor_20260301) that
OpenRouter's strict validator rejects with HTTP 400. This proxy strips
those tools before forwarding so OpenRouter accepts the request.
"""

import http.server
import urllib.request
import urllib.error
import json
import ssl
import os
import sys

TARGET_BASE = os.environ.get("OR_PROXY_TARGET", "https://openrouter.ai")
PORT = int(os.environ.get("OR_PROXY_PORT", "9090"))


def strip_typed_tools(body_bytes):
    """Remove tools that carry a proprietary 'type' field OpenRouter rejects."""
    try:
        data = json.loads(body_bytes)
    except Exception:
        return body_bytes, []

    tools = data.get("tools")
    if not tools:
        return body_bytes, []

    kept, stripped_names = [], []
    for tool in tools:
        if "type" in tool and "input_schema" not in tool:
            stripped_names.append(tool.get("name", tool["type"]))
        else:
            kept.append(tool)

    if not stripped_names:
        return body_bytes, []

    data["tools"] = kept
    return json.dumps(data).encode(), stripped_names


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        body, stripped = strip_typed_tools(body)
        if stripped:
            print(f"[or-proxy] stripped tools: {stripped}", flush=True)

        target_url = TARGET_BASE + self.path
        req = urllib.request.Request(target_url, data=body, method="POST")
        for k, v in self.headers.items():
            low = k.lower()
            if low not in ("host", "content-length"):
                req.add_header(k, v)
        req.add_header("Content-Length", str(len(body)))

        ctx = ssl.create_default_context()
        try:
            resp = urllib.request.urlopen(req, context=ctx)
            self.send_response(resp.status)
            for k, v in resp.headers.items():
                if k.lower() != "transfer-encoding":
                    self.send_header(k, v)
            self.end_headers()
            while True:
                chunk = resp.read(8192)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except urllib.error.HTTPError as e:
            err_body = e.read()
            self.send_response(e.code)
            for k, v in e.headers.items():
                if k.lower() != "transfer-encoding":
                    self.send_header(k, v)
            self.end_headers()
            self.wfile.write(err_body)
        except Exception as e:
            print(f"[or-proxy] upstream error: {e}", flush=True, file=sys.stderr)
            self.send_error(502, str(e))

    def log_message(self, *_):
        pass


if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), ProxyHandler)
    print(f"[or-proxy] listening on 127.0.0.1:{PORT} → {TARGET_BASE}", flush=True)
    server.serve_forever()
