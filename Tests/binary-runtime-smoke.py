"""Run with python3 Tests/binary-runtime-smoke.py PATH_TO_HEREFORTH. Uses no actual assistant profile."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parent.parent
helper = Path(sys.argv[1]).resolve()


def run(*args, success=True, env=None):
    result = subprocess.run(args, text=True, capture_output=True, env=env, timeout=30)
    assert (result.returncode == 0) == success, (args, result.stderr)
    return result


with tempfile.TemporaryDirectory(prefix="hereforth-binary-test-") as directory:
    root = Path(directory)
    app = root / "Hereforth.app/Contents"
    binary = app / "MacOS/hereforth"
    binary.parent.mkdir(parents=True)
    shutil.copy2(helper, binary)
    (app / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.hereforth.app", "CFBundlePackageType": "APPL",
        "CFBundleExecutable": "HereforthApp", "CFBundleShortVersionString": "0.2.0",
        "HereforthUpdateChannel": "binary", "HereforthBinaryUpdateTrack": "production"
    }))
    source_updater = app / "Resources/update.sh"
    source_updater.parent.mkdir()
    unexpected = root / "ran-source-updater"
    source_updater.write_text(f'#!/bin/bash\n: > "{unexpected}"\n')
    source_updater.chmod(0o755)
    env = dict(os.environ, PATH="/usr/bin:/bin", HEREFORTH_HOME=str(root / "library"))
    assert "0.2.0 (production)" in run(binary, "update", "status", env=env).stdout
    for operation in ("check", "install", "enable", "disable", "configure"):
        message = run(binary, "update", operation, success=False, env=env).stderr
        assert "Check for Updates" in message, message
    assert not unexpected.exists()
    # A mounted disk image or a checkout cannot write a persistent connector that points to itself.
    refusal = run(binary, "connect", "claude-desktop", success=False, env=env).stderr
    assert "Move Hereforth to Applications" in refusal, refusal

    main = root / "main.swift"
    main.write_text("""
import Foundation

let args = CommandLine.arguments
do {
    let client = ConnectorSetup.Client(rawValue: args[1])!
    try ConnectorSetup.connect(client, helper: args[2], home: URL(fileURLWithPath: args[3]),
        selectedExecutable: args.count > 4 ? URL(fileURLWithPath: args[4]) : nil)
} catch {
    FileHandle.standardError.write(Data(error.localizedDescription.utf8))
    exit(1)
}
""")
    fixture = root / "connector-fixture"
    run("/usr/bin/swiftc", repo / "Sources/hereforth/ConnectorSetup.swift", main, "-o", fixture)

    profile = root / "Profile"
    desktop = profile / "Library/Application Support/Claude"
    desktop.mkdir(parents=True)
    config = desktop / "claude_desktop_config.json"
    unrelated = {"command": "/usr/bin/true", "args": []}
    config.write_text(json.dumps({"mcpServers": {"existing": unrelated}, "unrelated": 23}))
    installed = "/Applications/Hereforth.app/Contents/MacOS/hereforth"
    run(fixture, "claude-desktop", installed, profile, env=env)
    saved = config.read_bytes()
    document = json.loads(saved)
    assert document == {
        "mcpServers": {"hereforth": {"command": installed, "args": ["mcp"]}, "existing": unrelated},
        "unrelated": 23
    }
    assert "already connected" in run(fixture, "claude-desktop", installed, profile, env=env).stdout
    assert config.read_bytes() == saved
    alternate = "/Users/example/Applications/Hereforth.app/Contents/MacOS/hereforth"
    conflict = run(fixture, "claude-desktop", alternate, profile, success=False, env=env)
    assert "different server named hereforth" in conflict.stderr and config.read_bytes() == saved

    cli = root / "fake-assistant-cli"
    cli.write_text("""#!/bin/bash
if [[ "$2" == get ]]; then
    if [[ -f "$HEREFORTH_TEST_EXISTING" ]]; then
        /bin/cat "$HEREFORTH_TEST_EXISTING"
    else
        printf "No MCP server named 'hereforth' found.\\n" >&2
        exit 1
    fi
else
    printf '%s\\n' "$@" > "$HEREFORTH_TEST_ARGUMENTS"
fi
""")
    cli.chmod(0o755)
    arguments = root / "args"
    existing = root / "existing"
    env.update(CLAUDE_CONFIG_DIR=str(profile), HEREFORTH_TEST_EXISTING=str(existing),
               HEREFORTH_TEST_ARGUMENTS=str(arguments))
    run(fixture, "claude-code", alternate, profile, cli, env=env)
    assert arguments.read_text().splitlines() == [
        "mcp", "add", "--scope", "user", "--transport", "stdio", "hereforth", "--", alternate, "mcp"
    ]
    run(fixture, "codex", installed, profile, cli, env=env)
    assert arguments.read_text().splitlines() == ["mcp", "add", "hereforth", "--", installed, "mcp"]
    arguments.unlink()
    existing.write_text(json.dumps({"transport": {"type": "stdio", "command": alternate, "args": ["mcp"]}}))
    conflict = run(fixture, "codex", installed, profile, cli, success=False, env=env)
    assert "different server named hereforth" in conflict.stderr and not arguments.exists()

    kimi_profile = profile / ".kimi-code"
    kimi_profile.mkdir()
    kimi_config = kimi_profile / "mcp.json"
    kimi_preferences = kimi_profile / "config.toml"
    kimi_preferences.write_bytes(b'default_model = "fixture-only"\n')
    default_kimi_env = {key: value for key, value in env.items() if key != "KIMI_CODE_HOME"}
    run(fixture, "kimi-code", installed, profile, env=default_kimi_env)
    assert json.loads(kimi_config.read_bytes()) == {"mcpServers": {"hereforth": {"command": installed, "args": ["mcp"]}}}
    assert kimi_config.stat().st_mode & 0o077 == 0
    assert kimi_preferences.read_bytes() == b'default_model = "fixture-only"\n'

    isolated_kimi = root / "Kimi Profile"
    isolated_kimi.mkdir()
    modified_env = dict(env, KIMI_CODE_HOME=str(isolated_kimi))
    config = isolated_kimi / "mcp.json"
    remote = {"url": "https://example.invalid/mcp", "transport": "sse", "bearerTokenEnvVar": "FIXTURE_KEY"}
    config.write_text(json.dumps({"mcpServers": {"existing": remote}, "otherSetting": 42}))
    run(fixture, "kimi-code", installed, profile, env=modified_env)
    saved = config.read_bytes()
    document = json.loads(saved)
    assert document == {"mcpServers": {"hereforth": {"command": installed, "args": ["mcp"]}, "existing": remote},
                        "otherSetting": 42}
    assert "already connected" in run(fixture, "kimi-code", installed, profile, env=modified_env).stdout
    assert config.read_bytes() == saved
    assert "different server" in run(fixture, "kimi-code", alternate, profile, success=False, env=modified_env).stderr
    assert config.read_bytes() == saved
    document["mcpServers"]["hereforth"]["environment_id"] = "different-machine"
    config.write_text(json.dumps(document))
    unsafe = config.read_bytes()
    assert "different server" in run(fixture, "kimi-code", installed, profile, success=False, env=modified_env).stderr
    assert config.read_bytes() == unsafe
    config.write_bytes(b'{"mcpServers":')
    assert "valid JSON" in run(fixture, "kimi-code", installed, profile, success=False, env=modified_env).stderr
    assert config.read_bytes() == b'{"mcpServers":'
    config.unlink()
    config.symlink_to(kimi_config)
    assert "regular file" in run(fixture, "kimi-code", installed, profile, success=False, env=modified_env).stderr
    assert config.is_symlink()

print("Binary runtime smoke passed: source updater bypass, connector paths, and preserved settings.")
