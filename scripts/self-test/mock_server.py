#!/usr/bin/env python3
"""Tiny routed HTTP mock server for staleness-check.sh's self-test.

Serves the three upstreams the script talks to (GitHub releases API, the
platform fleet endpoint, Discord) from a single process so the self-test
harness only has to manage one server per scenario. Routes are provided as a
JSON config: {"METHOD path": {"status": int, "body": <any-json-value-or-string>}}.
Every received POST body is appended to --log-file as one JSON line per
request, so the harness can assert e.g. "a Discord POST happened" and
inspect its content.
"""
import http.server
import json
import sys


def build_handler(routes, log_file):
    class Handler(http.server.BaseHTTPRequestHandler):
        def _respond(self, method):
            length = int(self.headers.get("Content-Length", 0) or 0)
            raw_body = self.rfile.read(length) if length else b""
            path = self.path.split("?")[0]
            key = f"{method} {path}"
            route = routes.get(key)

            if log_file and raw_body:
                try:
                    parsed = json.loads(raw_body.decode("utf-8"))
                except json.JSONDecodeError:
                    parsed = raw_body.decode("utf-8", errors="replace")
                with open(log_file, "a", encoding="utf-8") as fh:
                    fh.write(json.dumps({"method": method, "path": path, "body": parsed}) + "\n")

            if route is None:
                self.send_response(404)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"error": f"no fixture route for {key}"}).encode())
                return

            status = route["status"]
            body = route["body"]
            if isinstance(body, (dict, list)):
                payload = json.dumps(body).encode("utf-8")
            else:
                payload = str(body).encode("utf-8")

            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):
            self._respond("GET")

        def do_POST(self):
            self._respond("POST")

        def log_message(self, fmt, *args):
            pass

    return Handler


def main():
    config_path = sys.argv[1]
    port = int(sys.argv[2])
    log_file = sys.argv[3] if len(sys.argv) > 3 else None

    if log_file:
        open(log_file, "w", encoding="utf-8").close()

    with open(config_path, encoding="utf-8") as fh:
        routes = json.load(fh)

    handler = build_handler(routes, log_file)
    server = http.server.HTTPServer(("127.0.0.1", port), handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
