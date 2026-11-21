"""Run on macOS with python3 Tests/keep-awake-smoke.py. No pointer permission requested."""
from pathlib import Path
import subprocess
import tempfile


repository = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="hereforth-power-") as directory:
    root = Path(directory)
    stub = root / "Store.swift"
    stub.write_text("""
import Foundation
public final class Store {
    public init() throws {}
    public func setKeepAwakeStatus(mode: String?, endsAt: Date?, intervalSeconds: Int?, pointerState: String) throws {}
}
""", encoding="utf-8")
    harness = root / "Smoke.swift"
    harness.write_text("""
import Darwin
import IOKit.pwr_mgt

@main
struct Smoke {
    @MainActor
    static func main() async throws {
        let awake = KeepAwake()
        precondition(awake.mode == nil && !awake.pointerEnabled)
        awake.start(.system, seconds: 0)
        precondition(awake.mode == .system && awake.endsAt == nil)
        precondition(hasAssertion())
        awake.stop()
        precondition(awake.mode == nil && !hasAssertion())

        awake.start(.display, seconds: 1)
        precondition(awake.mode == .display && awake.endsAt != nil)
        precondition(hasAssertion())
        try await Task.sleep(for: .seconds(2))
        precondition(awake.mode == nil && awake.endsAt == nil && !hasAssertion())

        awake.start(.system, seconds: 1)
        awake.stop()
        awake.start(.system, seconds: 0)
        try await Task.sleep(for: .seconds(2))
        precondition(awake.mode == .system && hasAssertion())
        awake.stop()
        precondition(!hasAssertion() && !awake.pointerEnabled)
    }

    static func hasAssertion() -> Bool {
        var info: Unmanaged<CFDictionary>?
        precondition(IOPMCopyAssertionsByProcess(&info) == kIOReturnSuccess)
        let processes = info?.takeRetainedValue() as? [Int32: [[String: Any]]]
        return processes?[getpid()]?.contains {
            $0[kIOPMAssertionNameKey] as? String == "Hereforth Keep Awake"
        } ?? false
    }
}
""", encoding="utf-8")
    subprocess.run([
        "swiftc", "-emit-library", "-emit-module", "-module-name", "HereforthCore",
        "-emit-module-path", root / "HereforthCore.swiftmodule", stub, "-o", root / "libHereforthCore.dylib",
    ], check=True)
    subprocess.run([
        "swiftc", "-I", root, "-L", root, "-lHereforthCore", "-Xlinker", "-rpath", "-Xlinker", root,
        repository / "Sources/HereforthApp/KeepAwake.swift", harness, "-o", root / "test",
    ], check=True)
    subprocess.run([root / "test"], check=True)
print("Keep Awake assertion, expiry, and restart checks passed.")
