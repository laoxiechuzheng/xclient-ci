import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import urllib.request
from urllib.parse import urlsplit
import zlib

MAX_PNG = 16 * 1024 * 1024
MAX_RESPONSE = 24 * 1024 * 1024


class CaptureError(Exception):
    pass


def service_uri(text):
    candidates = set()
    for value in re.findall(r"http://[^\s<>\"']+", text):
        try:
            uri = urlsplit(value)
            if (uri.scheme == "http" and uri.hostname == "127.0.0.1"
                    and uri.username is None and uri.password is None
                    and uri.port is not None and 1 <= uri.port <= 65535
                    and not uri.query and not uri.fragment
                    and re.fullmatch(r"/(?:[A-Za-z0-9_=-]+/)?", uri.path)):
                candidates.add(value)
        except ValueError:
            continue
    if len(candidates) != 1:
        raise CaptureError("vm_service_missing_or_ambiguous")
    return candidates.pop()


def verify_listener(pid, port):
    try:
        result = subprocess.run(
            ["/usr/sbin/lsof", "-nP", "-a", f"-iTCP@127.0.0.1:{port}",
             "-sTCP:LISTEN", "-Fp"],
            capture_output=True, text=True, timeout=1, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        raise CaptureError("vm_listener_probe_failed") from None
    owners = {int(line[1:]) for line in result.stdout.splitlines()
              if re.fullmatch(r"p[1-9][0-9]*", line)}
    if result.returncode != 0 or owners != {pid}:
        raise CaptureError("vm_listener_owner_mismatch")


def png_metadata(data):
    if len(data) > MAX_PNG or data[:8] != b"\x89PNG\r\n\x1a\n":
        raise CaptureError("vm_png_invalid")
    offset = 8
    width = height = 0
    saw_idat = False
    while offset + 12 <= len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        end = offset + length + 12
        if end > len(data):
            raise CaptureError("vm_png_truncated")
        chunk = data[offset + 8:end - 4]
        crc = struct.unpack(">I", data[end - 4:end])[0]
        if zlib.crc32(kind + chunk) & 0xffffffff != crc:
            raise CaptureError("vm_png_crc_invalid")
        if offset == 8:
            if kind != b"IHDR" or length != 13:
                raise CaptureError("vm_png_invalid")
            width, height = struct.unpack(">II", chunk[:8])
            if not (300 <= width <= 16384 and 200 <= height <= 16384
                    and width * height <= 128 * 1024 * 1024):
                raise CaptureError("vm_png_size_invalid")
        elif kind == b"IHDR":
            raise CaptureError("vm_png_invalid")
        if kind == b"IDAT":
            saw_idat = True
        if kind == b"IEND":
            if length != 0 or end != len(data) or not saw_idat:
                raise CaptureError("vm_png_invalid")
            return {"width": width, "height": height, "bytes": len(data),
                    "sha256": hashlib.sha256(data).hexdigest()}
        offset = end
    raise CaptureError("vm_png_incomplete")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        raise CaptureError("vm_redirect_refused")


def validate_log(log, allow_stderr=False):
    workspace = os.environ.get("GITHUB_WORKSPACE")
    if (not workspace or (Path(workspace).resolve() / "out") not in log.parent.resolve().parents
            or log.name not in ({"app.stdout.log", "app.stderr.log"} if allow_stderr else {"app.stdout.log"})
            or log.is_symlink()
            or log.stat().st_size > 4 * 1024 * 1024):
        raise CaptureError("vm_capture_paths_invalid")


def capture(log, pid, output):
    validate_log(log)
    if (output.is_symlink()
            or output.name not in {"window-first.png", "window.png"}
            or output.parent.resolve() != log.parent.resolve()
            or output.exists()):
        raise CaptureError("vm_capture_paths_invalid")
    uri = service_uri(log.read_text(encoding="utf-8", errors="replace"))
    port = urlsplit(uri).port
    verify_listener(pid, port)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    try:
        request = urllib.request.Request(uri + "_flutter.screenshot", method="GET")
        with opener.open(request, timeout=5) as response:
            if response.status != 200:
                raise CaptureError("vm_capture_http_failed")
            body = response.read(MAX_RESPONSE + 1)
        if len(body) > MAX_RESPONSE:
            raise CaptureError("vm_capture_response_too_large")
        document = json.loads(body)
        result = document.get("result")
        if not isinstance(result, dict) or result.get("type") != "Screenshot":
            raise CaptureError("vm_capture_response_invalid")
        encoded = result.get("screenshot")
        if not isinstance(encoded, str):
            raise CaptureError("vm_capture_response_invalid")
        data = base64.b64decode(encoded, validate=True)
    except CaptureError:
        raise
    except Exception:
        raise CaptureError("vm_capture_request_or_decode_failed") from None
    metadata = png_metadata(data)
    verify_listener(pid, port)
    with output.open("xb") as target:
        target.write(data)
    return {"source": "flutter_engine", "owner_pid": pid,
            "method": "_flutter.screenshot", **metadata}


def redact_log(log):
    validate_log(log, allow_stderr=True)
    text = log.read_text(encoding="utf-8", errors="replace")
    safe = re.sub(r"(?:https?|wss?)://(?:127\.0\.0\.1|localhost|\[::1\]):[^\s<>\"']+",
                  "[VM_SERVICE_REDACTED]", text)
    log.write_text(safe, encoding="utf-8")


def main():
    if (sys.platform != "darwin" or os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("RUNNER_OS") != "macOS"
            or os.environ.get("XCLIENT_SAFE_MODE_BUILD") != "1"):
        raise CaptureError("ci_macos_safe_mode_gate_required")
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--redact-log", action="store_true")
    args = parser.parse_args()
    if args.redact_log:
        redact_log(args.log)
        return {"vm_service_log_redacted": True}
    if args.pid is None or args.pid <= 0 or args.out is None:
        raise CaptureError("vm_capture_arguments_invalid")
    return capture(args.log, args.pid, args.out)


if __name__ == "__main__":
    try:
        print(json.dumps(main(), sort_keys=True))
    except CaptureError as error:
        print(json.dumps({"error": str(error)}))
        sys.exit(75)
    except Exception:
        print(json.dumps({"error": "vm_capture_failed"}))
        sys.exit(75)
