"""Forward a private guest vsock port to the loopback SSH tunnel; never handle provider credentials."""
import http.client
import socket
from http.server import BaseHTTPRequestHandler
from mock.mock_llm import VSockHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        size = int(self.headers.get("Content-Length", "0"))
        if self.path != "/v1/chat/completions" or not 0 < size <= 8192:
            self.send_error(400)
            return
        connection = http.client.HTTPConnection("127.0.0.1", 28812, timeout=43)
        try:
            connection.request("POST", self.path, self.rfile.read(size), {"Content-Type": "application/json"})
            response = connection.getresponse()
            body = response.read()
            self.send_response(response.status)
            self.send_header("Content-Type", response.getheader("Content-Type", "application/json"))
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        finally:
            connection.close()


if __name__ == "__main__":
    print("observer-vsock-ready", flush=True)
    VSockHTTPServer((socket.VMADDR_CID_ANY, 28812), Handler).serve_forever()
