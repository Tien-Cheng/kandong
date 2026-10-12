"""A stand-in for LM Studio's local server: the native model list plus streaming chat completions.

Usage: python3 fake_lmstudio.py PORT [--reject-schema]
Replies are canned by request type (learn / reverse / explain / transcribe) so tests can assert on them.
"""
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
REJECT_SCHEMA = "--reject-schema" in sys.argv
LOG = []

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_json(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/api/v0/models":
            self.send_json(200, {"data": [
                {"id": "fake-vlm", "type": "vlm", "state": "loaded"},
                {"id": "fake-embed", "type": "embeddings", "state": "not-loaded"},
            ]})
        elif self.path == "/v1/models":
            self.send_json(200, {"data": [{"id": "fake-vlm"}]})
        elif self.path == "/log":
            self.send_json(200, LOG)
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        system = request["messages"][0]["content"]
        user = request["messages"][1]["content"]
        has_image = isinstance(user, list)
        LOG.append({"model": request.get("model"), "schema": "response_format" in request, "image": has_image})
        if REJECT_SCHEMA and "response_format" in request:
            return self.send_json(400, {"error": "response_format not supported"})
        if "Transcribe" in system:
            reply = "今天下午三点上中文课"
        elif "readingCorrections" in system:
            reply = '<think>checking</think>{"translation": "[local] Chinese class at three this afternoon", "readingCorrections": []}'
        elif '"chinese"' in system:
            reply = '{"chinese": "这个周末我们一起练习口语吧？", "note": ""}'
        else:
            reply = "**Structure**: 今天 + 下午 + 三点 + 上 + 中文课."
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for i in range(0, len(reply), 7):
            chunk = {"choices": [{"delta": {"content": reply[i:i + 7]}}]}
            self.wfile.write(f"data: {json.dumps(chunk, ensure_ascii=False)}\n\n".encode())
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")

ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
