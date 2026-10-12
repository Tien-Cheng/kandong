"""A stand-in for `codex app-server`: answers the JSON-RPC calls Kandong makes."""
import json, sys

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    msg = json.loads(line)
    method, mid = msg.get("method"), msg.get("id")
    if method == "initialize":
        send({"id": mid, "result": {"userAgent": "fake"}})
    elif method == "account/read":
        send({"id": mid, "result": {"account": {"type": "chatgpt"}, "requiresOpenaiAuth": True}})
    elif method == "model/list":
        send({"id": mid, "result": {"data": [{"id": "fast", "displayName": "Fast", "hidden": False, "isDefault": True,
              "inputModalities": ["text", "image"], "supportedReasoningEfforts": [{"reasoningEffort": "low"}]}], "nextCursor": None}})
    elif method == "thread/start":
        send({"id": mid, "result": {"thread": {"id": "t1"}, "model": "fast"}})
    elif method == "turn/start":
        text = msg["params"]["input"][0]["text"]
        # Ask the client to approve something; it must decline and carry on.
        send({"id": 900, "method": "item/commandExecution/requestApproval", "params": {"threadId": "t1"}})
        send({"id": mid, "result": {"turn": {"id": "u1", "status": "inProgress"}}})
        if "FAIL" in text:
            send({"method": "turn/completed", "params": {"threadId": "t1", "turn": {"id": "u1", "status": "failed", "error": {"message": "boom"}}}})
            continue
        parts = [f"{i}," for i in range(300)] if "MANY" in text else ['{"translation":', '"Hello"}']
        if "EXIT" in text:
            parts = ["x" * 200000]
        for part in parts:
            send({"method": "item/agentMessage/delta", "params": {"threadId": "t1", "turnId": "u1", "itemId": "i1", "delta": part}})
        send({"method": "turn/completed", "params": {"threadId": "t1", "turn": {"id": "u1", "status": "completed"}}})
        if "EXIT" in text:
            sys.exit(0)  # exit right after the reply, as a crashing or upgraded server might
    elif mid is not None and "method" not in msg:
        pass  # reply to our approval request
