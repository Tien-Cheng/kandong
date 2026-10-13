"""A stand-in for LM Studio's local server: its model lists, downloads, and streaming chat completions.

Usage: python3 fake_lmstudio.py PORT [--reject-schema] [--reject-reasoning] [--v0-only] [--no-memory]
Replies are canned by request type (learn / reverse / explain / transcribe) so tests can assert on them.
A system prompt containing LOOP gets a reply that repeats forever, THINK one that thinks first, and
SLOW one that only starts after 5 seconds.
"""
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
REJECT_SCHEMA = "--reject-schema" in sys.argv
REJECT_REASONING = "--reject-reasoning" in sys.argv
V0_ONLY = "--v0-only" in sys.argv
NO_MEMORY = "--no-memory" in sys.argv
LOG = []
JOBS = {}

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
        elif self.path == "/api/v1/models" and not V0_ONLY:
            self.send_json(200, {"models": [
                {"type": "llm", "key": "fake-vlm", "loaded_instances": [{"id": "fake-vlm"}],
                 "capabilities": {"vision": True, "reasoning": {"allowed_options": ["off", "on"], "default": "on"}}},
                {"type": "llm", "key": "fake-plain", "loaded_instances": [], "capabilities": {"vision": False}},
                {"type": "embedding", "key": "fake-embed", "loaded_instances": [], "capabilities": None},
            ]})
        elif self.path.startswith("/api/v1/models/download/status/"):
            job = self.path.rsplit("/", 1)[1]
            JOBS[job] += 1
            done = JOBS[job] >= 3
            self.send_json(200, {"job_id": job, "status": "completed" if done else "downloading",
                                 "downloaded_bytes": 6_000_000_000 if done else 2_000_000_000 * JOBS[job],
                                 "total_size_bytes": 6_000_000_000})
        elif self.path == "/v1/models":
            self.send_json(200, {"data": [{"id": "fake-vlm"}]})
        elif self.path == "/log":
            self.send_json(200, LOG)
        else:
            self.send_json(404, {"error": "Unexpected endpoint or method."})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/api/v1/models/download":
            if V0_ONLY:
                return self.send_json(404, {"error": "Unexpected endpoint or method."})
            if request["model"] == "fake-vlm":
                return self.send_json(200, {"status": "already_downloaded"})
            JOBS["job_1"] = 0
            return self.send_json(200, {"job_id": "job_1", "status": "downloading", "total_size_bytes": 6_000_000_000})
        if self.path == "/api/v1/models/load":
            if NO_MEMORY:
                return self.send_json(500, {"error": {"message": "Model loading was stopped due to insufficient system resources."}})
            return self.send_json(200, {"type": "llm", "instance_id": request["model"], "status": "loaded"})

        system = request["messages"][0]["content"]
        user = request["messages"][1]["content"]
        has_image = isinstance(user, list)
        LOG.append({key: request.get(key) for key in ["model", "reasoning_effort", "temperature", "max_tokens"]}
                   | {"schema": "response_format" in request, "image": has_image})
        if REJECT_SCHEMA and "response_format" in request:
            return self.send_json(400, {"error": "response_format not supported"})
        if REJECT_REASONING and "reasoning_effort" in request:
            return self.send_json(400, {"error": {"message": "Unrecognized request argument supplied: reasoning_effort"}})
        if "SLOW" in system:
            time.sleep(5)
        thinking = ""
        if "LOOP" in system:
            reply = "我们一起去吧，" * 500
        elif "THINK" in system:
            thinking, reply = "Let me think about this. " * 3, "Hello, world"
        elif "Transcribe" in system:
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
        try:
            for i in range(0, len(thinking), 7):
                self.send_chunk({"reasoning_content": thinking[i:i + 7]})
            for i in range(0, len(reply), 7):
                self.send_chunk({"content": reply[i:i + 7]})
            self.wfile.write(b"data: [DONE]\n\n")
        except BrokenPipeError:
            pass

    def send_chunk(self, delta):
        chunk = {"choices": [{"delta": delta}]}
        self.wfile.write(f"data: {json.dumps(chunk, ensure_ascii=False)}\n\n".encode())
        self.wfile.flush()

ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
