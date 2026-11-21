"""Exercise the real phone server and WebAuthn verifier against a synthetic P-256 authenticator."""
import base64
import contextlib
import errno
import hashlib
import http.client
import json
import os
from pathlib import Path
import plistlib
import pty
import re
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import uuid

ORIGIN = "https://fixture-mac.fixture-tailnet.ts.net:8443"
AUTHORITY = ORIGIN.removeprefix("https://")
DOMAIN = AUTHORITY.split(":")[0]
OWNER = "fixture-owner@example.invalid"


def b64(data):
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def cbor(value):
    # Only the test authenticator needs to encode these small CBOR fixtures.
    def head(major, n):
        if n < 24:
            return bytes([major << 5 | n])
        return bytes([major << 5 | 24, n])

    if isinstance(value, int):
        return head(0 if value >= 0 else 1, value if value >= 0 else -1 - value)
    if isinstance(value, str):
        data = value.encode()
        return head(3, len(data)) + data
    if isinstance(value, bytes):
        return head(2, len(value)) + value
    return head(5, len(value)) + b"".join(cbor(k) + cbor(v) for k, v in value.items())


class Authenticator:
    def __init__(self, root):
        self.key = root / "authenticator-key"
        subprocess.run(["/usr/bin/openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", self.key],
                       capture_output=True, check=True, timeout=5)
        pub = subprocess.run(["/usr/bin/openssl", "ec", "-in", self.key, "-pubout", "-outform", "DER"],
                             capture_output=True, check=True, timeout=5).stdout[-65:]
        assert len(pub) == 65 and pub[0] == 4
        self.public = cbor({1: 2, 3: -7, -1: 1, -2: pub[1:33], -3: pub[33:]})
        self.id = os.urandom(32)
        self.count = 0

    @staticmethod
    def client(challenge, kind, origin):
        return json.dumps({"type": kind, "challenge": challenge, "origin": origin, "crossOrigin": False}).encode()

    def payload(self, start, response):
        return {"challengeId": start["challengeId"], "credential": {
            "id": b64(self.id), "rawId": b64(self.id), "type": "public-key", "response": response,
        }}

    def register(self, start, verified=True, origin=ORIGIN):
        options = start["options"]
        assert options["rp"]["id"] == DOMAIN and options["authenticatorSelection"]["userVerification"] == "required"
        self.handle = options["user"]["id"]
        data = hashlib.sha256(DOMAIN.encode()).digest() + bytes([0x45 if verified else 0x41]) + bytes(4)
        data += bytes(16) + len(self.id).to_bytes(2, "big") + self.id + self.public
        attestation = cbor({"fmt": "none", "attStmt": {}, "authData": data})
        return self.payload(start, {
            "clientDataJSON": b64(self.client(options["challenge"], "webauthn.create", origin)),
            "attestationObject": b64(attestation),
        })

    def authenticate(self, start, verified=True, origin=ORIGIN):
        options = start["options"]
        assert options["rpId"] == DOMAIN and options["userVerification"] == "required"
        self.count += 1
        data = hashlib.sha256(DOMAIN.encode()).digest() + bytes([5 if verified else 1]) + self.count.to_bytes(4, "big")
        client = self.client(options["challenge"], "webauthn.get", origin)
        signature = subprocess.run(["/usr/bin/openssl", "dgst", "-sha256", "-sign", self.key],
                                   input=data + hashlib.sha256(client).digest(), capture_output=True, check=True, timeout=5).stdout
        return self.payload(start, {"clientDataJSON": b64(client), "authenticatorData": b64(data),
                                   "signature": b64(signature), "userHandle": self.handle})


def cli(binary, env, *args, check=True):
    return subprocess.run([binary, "phone", *args], env=env, capture_output=True, text=True, check=check, timeout=8)


def pairing_code(binary, env):
    master, slave = pty.openpty()
    try:
        with subprocess.Popen([binary, "phone", "pair"], env=env, stdin=slave, stdout=slave, stderr=subprocess.PIPE) as process:
            os.close(slave)
            slave = None
            assert select.select([master], [], [], 5)[0]
            output = b""
            while len(output) < 1024:
                try:
                    part = os.read(master, 1024)
                except OSError as issue:
                    if issue.errno == errno.EIO:
                        break
                    raise
                if not part:
                    break
                output += part
            assert process.wait(timeout=5) == 0
            match = re.search(rb"Phone pairing code: ([a-f0-9]{32})", output)
            assert match is not None, "TTY pairing code unavailable"
            return match[1].decode()
    finally:
        if slave is not None:
            os.close(slave)
        os.close(master)


@contextlib.contextmanager
def listener(binary, env):
    with socket.socket() as lock:
        lock.bind(("127.0.0.1", 0))
        port = lock.getsockname()[1]
    cli(binary, env, "configure", ORIGIN, OWNER, str(port))
    with subprocess.Popen([binary, "phone", "serve"], env=env, stdin=subprocess.DEVNULL,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE) as running:
        try:
            assert select.select([running.stdout], [], [], 8)[0] and running.stdout.readline() == b"ready\n", "Phone listener not ready"
            listeners = subprocess.check_output(
                ["/usr/sbin/lsof", "-nP", "-a", "-p", str(running.pid), "-iTCP", "-sTCP:LISTEN", "-Fn"],
                text=True, timeout=5,
            )
            assert [row[1:] for row in listeners.splitlines() if row.startswith("n")] == [f"127.0.0.1:{port}"]

            def request(path, payload=None, expected=200, *, cookie=None, changes=None):
                headers = {"Host": AUTHORITY, "X-Forwarded-Host": AUTHORITY, "X-Forwarded-Proto": "https", "Tailscale-User-Login": OWNER}
                if cookie:
                    headers["Cookie"] = cookie
                if payload is not None:
                    headers.update({"Origin": ORIGIN, "Content-Type": "application/json", "Sec-Fetch-Site": "same-origin"})
                headers.update(changes or {})
                client = http.client.HTTPConnection("127.0.0.1", port, timeout=7)
                try:
                    client.request("GET" if payload is None else "POST", path,
                                   body=None if payload is None else json.dumps(payload), headers=headers)
                    response = client.getresponse()
                    data = response.read()
                    assert response.status == expected, (path, response.status, data[:500])
                    assert response.getheader("Cache-Control") == "no-store"
                    if "json" in response.getheader("Content-Type"):
                        data = json.loads(data)
                    return data, response.getheaders()
                finally:
                    client.close()

            yield request
        finally:
            running.terminate()
            running.wait(timeout=5)


def cookie(headers):
    value = next(value for name, value in headers if name.lower() == "set-cookie")
    assert value.startswith("__Host-hereforth-phone=") and "Secure" in value and "HttpOnly" in value
    assert "SameSite=Strict" in value and "Path=/" in value and "Domain" not in value
    return value.split(";", 1)[0]


def main(binary):
    with tempfile.TemporaryDirectory(prefix="hereforth-owner-phone-") as temporary:
        root = Path(temporary)
        env = {**os.environ, "HEREFORTH_HOME": str(root / "profile")}
        assert cli(binary, env, "configure", "http://example.invalid", OWNER, check=False).returncode != 0
        auth = Authenticator(root)
        with listener(binary, env) as request:
            assert request("/api/session")[0] == {"authenticated": False, "passkey": False}
            assert request("/")[0].startswith(b"<!doctype html>")
            for header, wrong in (("Tailscale-User-Login", "teammate@example.invalid"), ("Host", DOMAIN),
                                  ("X-Forwarded-Host", DOMAIN), ("X-Forwarded-Proto", "http"), ("Tailscale-Funnel-Request", "?1"),
                                  ("Authorization", "Bearer peer-fixture")):
                request("/api/session", expected=403, changes={header: wrong})
            request("/api/actions/activity", {}, expected=401)
            request("/api/auth/login/start", {}, expected=401)
            request("/api/auth/register/start?unexpected=1", {"code": "synthetic"}, expected=400)
            assert cli(binary, env, "pair", check=False).returncode != 0

            first = pairing_code(binary, env)
            state_path = Path(env["HEREFORTH_HOME"]) / "phone-auth.json"
            assert state_path.stat().st_mode & 0o077 == 0 and first.encode() not in state_path.read_bytes()
            state = json.loads(state_path.read_bytes())
            state["invitation"]["expires"] = -1
            state_path.write_text(json.dumps(state))
            request("/api/auth/register/start", {"code": first}, expected=401)

            code = pairing_code(binary, env)
            request("/api/auth/register/start", {"code": code}, expected=403, changes={"Origin": "https://cross-origin.invalid"})
            start, _ = request("/api/auth/register/start", {"code": code})
            request("/api/auth/register/start", {"code": code}, expected=401)
            request("/api/auth/register/finish", auth.register(start, verified=False), expected=401)
            request("/api/auth/register/finish", auth.register(start), expected=401)
            start, _ = request("/api/auth/register/start", {"code": pairing_code(binary, env)})
            result, headers = request("/api/auth/register/finish", auth.register(start))
            assert result["authenticated"]
            session = cookie(headers)
            assert session.split("=", 1)[1].encode() not in state_path.read_bytes()
            assert request("/api/session", cookie=session)[0] == {"authenticated": True, "passkey": True}
            request("/api/actions/activity", {}, cookie=session)
            request("/api/actions/activity", {}, expected=401, cookie=session + "; " + session)
            request("/api/actions/activity", {}, expected=403, cookie=session, changes={"Origin": "null"})
            request("/api/actions/queue_task", {}, expected=403, cookie=session)

            payload = {"request_id": str(uuid.uuid4()), "client": "codex", "kind": "text", "prompt": "Exact reviewed phone request"}
            start, _ = request("/api/auth/approve/start", {"action": "queue_task", "payload": payload}, cookie=session)
            signed = auth.authenticate(start)
            request("/api/auth/approve/finish", {**signed, "payload": {"prompt": "Replace reviewed content"}}, expected=400, cookie=session)
            task, _ = request("/api/auth/approve/finish", signed, cookie=session)
            assert task["prompt"] == payload["prompt"] and task["state"] == "pending_review"
            request("/api/auth/approve/finish", signed, expected=401, cookie=session)
            assert request("/api/actions/get_task", {"id": task["id"]}, cookie=session)[0]["prompt"] == payload["prompt"]

            login, _ = request("/api/auth/login/start", {})
            request("/api/auth/login/finish", auth.authenticate(login, origin=ORIGIN.replace(":8443", "")), expected=401)
            login, _ = request("/api/auth/login/start", {})
            _, headers = request("/api/auth/login/finish", auth.authenticate(login))
            second = cookie(headers)
            _, cleared = request("/api/auth/logout", {}, cookie=session)
            assert "Max-Age=0" in next(value for name, value in cleared if name.lower() == "set-cookie")
            request("/api/actions/activity", {}, expected=401, cookie=session)
            status = json.loads(cli(binary, env, "status").stdout)
            assert len(status["passkeys"]) == len(status["sessions"]) == 1
            cli(binary, env, "revoke-passkey", status["passkeys"][0]["id"])
            request("/api/actions/activity", {}, expected=401, cookie=second)
            request("/api/auth/login/start", {}, expected=401)

        # Preserve a signed app's complete layout when relocating its installed helper.
        relocated_app = root / "Relocated Hereforth.app"
        contents = relocated_app / "Contents"
        relocated = contents / "MacOS/hereforth"
        source_contents = binary.parent.parent
        source_app = source_contents.parent
        if binary.parent.name == "MacOS" and source_contents.name == "Contents" and source_app.suffix == ".app":
            subprocess.run(["/usr/bin/ditto", source_app, relocated_app], check=True, timeout=20)
            verify = ["/usr/bin/codesign", "--verify", "--strict"]
            if subprocess.run([*verify, source_app], capture_output=True, timeout=10).returncode == 0:
                subprocess.run([*verify, relocated_app], check=True, timeout=10)
        else:
            relocated.parent.mkdir(parents=True)
            shutil.copy2(binary, relocated)
            (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.hereforth.phone.fixture",
                                                                   "CFBundleExecutable": "hereforth", "CFBundlePackageType": "APPL"}))
            resource_bundle = "Hereforth_HereforthCore.bundle"
            source_bundle = binary.parent.parent / "Resources" / resource_bundle
            if not source_bundle.is_dir():
                source_bundle = binary.parent / resource_bundle
            shutil.copytree(source_bundle, contents / "Resources" / resource_bundle, symlinks=True)
        env["HEREFORTH_HOME"] = str(root / "relocated-profile")
        with listener(relocated, env) as request:
            for path in ("/", "/app.js", "/styles.css"):
                assert len(request(path)[0]) > 100
    print("Phone HTTP smoke passed: owner proxy, passkeys, approvals, sessions, and relocated assets.")


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve())
