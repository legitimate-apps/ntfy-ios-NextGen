"""Accepts one POST on 127.0.0.1 and writes 'X-Encoding header\\nbody' to the file in argv[2].
Prints the port it listens on, then exits after the first request."""
import http.server, sys

out = sys.argv[1]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        with open(out, "w") as f:
            f.write((self.headers.get("X-Encoding") or "") + "\n" + body)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *args):
        pass

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.handle_request()
