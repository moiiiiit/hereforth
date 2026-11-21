"""Run with python3 Tests/update-lifecycle-smoke.py. Uses a temporary profile and fake launchctl."""
from pathlib import Path
import subprocess
import tempfile


repository = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="hereforth-update-schedule-") as directory:
    root = Path(directory)
    harness = root / "main.swift"
    harness.write_text(r'''
import Foundation

let home = URL(fileURLWithPath: CommandLine.arguments[1])
let script = home.appendingPathComponent("Applications/Hereforth.app/Contents/Resources/update.sh")
let plist = home.appendingPathComponent("Library/LaunchAgents/com.hereforth.updates.plist")
var calls: [[String]] = []
var loaded = false
var loggedIn = true
func launchctl(_ args: [String]) -> Bool {
    calls.append(args)
    switch args {
    case ["print", "gui/123"]: return loggedIn
    case ["print", "gui/123/com.hereforth.updates"]: return loaded
    case ["bootstrap", "gui/123", plist.path]: loaded = true
    case ["bootout", "gui/123/com.hereforth.updates"]: loaded = false
    default: fatalError("Unexpected launchctl operation")
    }
    return true
}
func require(_ value: Bool) { precondition(value) }

let dev = UpdateAgent(home: home, script: script, stable: false, domain: "gui/123", launchctl: launchctl)
let stable = UpdateAgent(home: home, script: script, stable: true, domain: "gui/123", launchctl: launchctl)
_ = try dev.apply(choice: nil)
require(try dev.preference() == nil && calls.isEmpty)

_ = try stable.apply(choice: nil)
require(try stable.preference() == true && loaded)
let data = try Data(contentsOf: plist)
let agent = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
require(agent["ProgramArguments"] as? [String] == [script.path, "automatic"])
require(agent["StartCalendarInterval"] as? [String: Int] == ["Hour": 10, "Minute": 0])

calls.removeAll()
_ = try stable.apply(choice: nil)
require(calls == [["print", "gui/123"], ["print", "gui/123/com.hereforth.updates"]])
require(try Data(contentsOf: plist) == data)
_ = try stable.apply(choice: false)
require(try stable.preference() == false && !loaded)
require(!FileManager.default.fileExists(atPath: plist.path))
_ = try stable.apply(choice: nil)
require(try stable.preference() == false && !loaded)

loggedIn = false
require(try stable.apply(choice: true).contains("next Mac login"))
require(try stable.preference() == true && !loaded)
try Data("foreign".utf8).write(to: plist)
do {
    _ = try stable.apply(choice: false)
    fatalError("Should refuse foreign LaunchAgent")
} catch {
    require(try Data(contentsOf: plist) == Data("foreign".utf8))
    require(try stable.preference() == true)
}
''', encoding="utf-8")
    subprocess.run([
        "swiftc", "-emit-library", "-emit-module", "-module-name", "HereforthCore",
        "-emit-module-path", root / "HereforthCore.swiftmodule",
        repository / "Sources/HereforthCore/Import.swift", "-o", root / "libHereforthCore.dylib",
    ], check=True)
    subprocess.run([
        "swiftc", "-I", root, "-L", root, "-lHereforthCore", "-Xlinker", "-rpath", "-Xlinker", root,
        repository / "Sources/hereforth/UpdateLifecycle.swift", harness, "-o", root / "test",
    ], check=True)
    subprocess.run([root / "test", root / "mock-user"], check=True)
print("Update lifecycle smoke checks passed.")
