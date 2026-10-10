#!/usr/bin/env python3
"""Deterministic, dependency-free mock LLM API.

Speaks just enough of the Anthropic Messages API and the OpenAI Chat
Completions API for a coding-agent CLI to complete a turn.  Every request is
appended to REQUESTS (JSONL) so a test can assert on what the harness sent.
"""
import json, os, re, socket, sys, time
from urllib.parse import urlparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("MOCK_PORT", "18788"))
TRANSPORT = os.environ.get("MOCK_TRANSPORT", "vsock")   # vsock | tcp
REQUESTS = os.environ.get(
    "MOCK_REQUESTS", os.path.join(os.path.dirname(os.path.abspath(__file__)), "requests.jsonl")
)
REPLY = os.environ.get("MOCK_REPLY", "MOCK_OK")
DELAY = float(os.environ.get("MOCK_DELAY", "0"))


# 指令层里那条"机器可读"的规则：出现在请求正文里就说明指令层被注入了。
# 这个 mock 扮演一个**会遵守规则**的模型 —— 它从请求正文里取出令牌并照着做，
# 于是"指令层被遵守"这件事第一次有了可观测的产物（harness 的最终输出），
# 而不只是"请求里含某个字符串"。它不是真模型，测的是链路，不是模型的服从率。
RULE_RE = re.compile(rb"AH-COMPLY-[0-9]{4}")


def _rule_token(raw):
    m = RULE_RE.search(raw or b"")
    return m.group(0).decode() if m else ""


def _reply_for(raw):
    token = _rule_token(raw)
    return f"{token} {REPLY}" if token else REPLY


def record(path, body, headers, raw=b""):
    entry = {
        "ts": time.time(),
        "path": path,
        "auth_header_present": bool(headers.get("x-api-key") or headers.get("authorization")),
        "model": body.get("model"),
        "stream": bool(body.get("stream")),
        "n_messages": len(body.get("messages", [])),
        "tool_names": [t.get("name") or (t.get("function") or {}).get("name")
                       for t in body.get("tools", []) or []],
        # 保留第一个工具的原样，方便排查各家 harness 的工具描述格式差异
        "tools_sample": (body.get("tools") or [None])[0],
        "system_len": len(body.get("system") or "" if isinstance(body.get("system"), str) else ""),
        "last_user_text": _last_user_text(body),
        "rule_token": _rule_token(raw),
    }
    # 指令层验证（AGENTS.md 有没有被注入）需要能直接搜正文，所以默认留一份。
    # 截断到 200KB，避免超大请求把日志撑爆。
    if os.environ.get("MOCK_KEEP_BODY", "1") != "0":
        entry["body"] = raw[:200_000].decode("utf-8", "replace")
    with open(REQUESTS, "a") as fh:
        fh.write(json.dumps(entry, ensure_ascii=False) + "\n")


def _last_user_text(body):
    for msg in reversed(body.get("messages", []) or []):
        if msg.get("role") != "user":
            continue
        content = msg.get("content")
        if isinstance(content, str):
            return content[:400]
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    return (block.get("text") or "")[:400]
    return ""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _read_body(self):
        length = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(length) if length else b""
        self.raw_body = raw
        try:
            return json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return {}

    def _send(self, code, payload, ctype="application/json"):
        blob = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(blob)))
        self.end_headers()
        self.wfile.write(blob)

    def _sse_open(self):
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()

    def _sse(self, event, data):
        self.wfile.write(f"event: {event}\ndata: {json.dumps(data)}\n\n".encode())
        self.wfile.flush()

    def do_GET(self):
        if urlparse(self.path).path.startswith("/v1/models"):
            self._send(200, {"data": [{"id": "mock-model", "object": "model"}], "object": "list"})
        else:
            self._send(200, {"ok": True, "path": self.path})

    def do_POST(self):
        body = self._read_body()
        record(self.path, body, self.headers, getattr(self, "raw_body", b""))

        route = urlparse(self.path).path
        if route.endswith("/messages/count_tokens"):
            self._send(200, {"input_tokens": 11})
        elif route.endswith("/messages"):
            self._anthropic(body, getattr(self, "raw_body", b""))
        elif route.endswith("/chat/completions"):
            self._openai(body, getattr(self, "raw_body", b""))
        else:
            self._send(404, {"error": {"message": f"no mock route for {route}"}})

    def _anthropic(self, body, raw=b""):
        if DELAY > 0:
            time.sleep(DELAY)
        model = body.get("model") or "mock-model"
        if not body.get("stream"):
            self._send(200, {
                "id": "msg_mock", "type": "message", "role": "assistant", "model": model,
                "content": [{"type": "text", "text": _reply_for(raw)}],
                "stop_reason": "end_turn", "stop_sequence": None,
                "usage": {"input_tokens": 11, "output_tokens": 3},
            })
            return
        self._sse_open()
        self._sse("message_start", {"type": "message_start", "message": {
            "id": "msg_mock", "type": "message", "role": "assistant", "model": model,
            "content": [], "stop_reason": None, "stop_sequence": None,
            "usage": {"input_tokens": 11, "output_tokens": 0}}})
        self._sse("content_block_start", {"type": "content_block_start", "index": 0,
                                          "content_block": {"type": "text", "text": ""}})
        for chunk in _reply_for(raw).split(" "):
            self._sse("content_block_delta", {"type": "content_block_delta", "index": 0,
                                              "delta": {"type": "text_delta", "text": chunk + " "}})
        self._sse("content_block_stop", {"type": "content_block_stop", "index": 0})
        self._sse("message_delta", {"type": "message_delta",
                                    "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                                    "usage": {"output_tokens": 3}})
        self._sse("message_stop", {"type": "message_stop"})

    def _openai(self, body, raw=b""):
        if DELAY > 0:
            time.sleep(DELAY)
        model = body.get("model") or "mock-model"
        if not body.get("stream"):
            self._send(200, {"id": "cmpl_mock", "object": "chat.completion", "model": model,
                             "choices": [{"index": 0, "finish_reason": "stop",
                                          "message": {"role": "assistant", "content": _reply_for(raw)}}],
                             "usage": {"prompt_tokens": 11, "completion_tokens": 3, "total_tokens": 14}})
            return
        self._sse_open()
        for chunk in _reply_for(raw).split(" "):
            self._sse("", {"id": "cmpl_mock", "object": "chat.completion.chunk", "model": model,
                           "choices": [{"index": 0, "delta": {"content": chunk + " "}}]})
        self._sse("", {"id": "cmpl_mock", "object": "chat.completion.chunk", "model": model,
                       "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


class VSockHTTPServer(ThreadingHTTPServer):
    """HTTP over AF_VSOCK。

    guest 里没有网卡，所以 mock 只能走 vsock 被访问；guest 内的 socat 把它桥成
    127.0.0.1，harness 那边只需要改 base URL。
    """

    address_family = socket.AF_VSOCK
    daemon_threads = True

    def server_bind(self):
        self.socket.bind(self.server_address)
        self.server_name = "vsock"
        self.server_port = self.server_address[1]


if __name__ == "__main__":
    os.makedirs(os.path.dirname(REQUESTS), exist_ok=True)
    if TRANSPORT == "tcp":
        server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    else:
        server = VSockHTTPServer((socket.VMADDR_CID_ANY, PORT), Handler)
    print(f"mock llm on {TRANSPORT}:{PORT} reply={REPLY!r} log={REQUESTS}", flush=True)
    server.serve_forever()
