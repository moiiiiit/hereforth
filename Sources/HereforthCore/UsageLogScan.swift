import Darwin
import Foundation

final class UsageLogScan {
    private let deadline = ProcessInfo.processInfo.systemUptime + 6
    private var remaining = 192 * 1_024 * 1_024
    private let fileLimit = 64 * 1_024 * 1_024
    private let lineLimit = 2 * 1_024 * 1_024
    private var rootsFound = false
    private var filesRead = 0
    private var filesFailed = 0
    private var limited = false
    var skippedRecords = 0

    func files(in roots: [URL]) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        var candidates: [(url: URL, date: Date)] = []
        var visited = 0
        for root in roots {
            let folder = root.resolvingSymlinksInPath()
            do {
                guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                    filesFailed += 1
                    continue
                }
            } catch CocoaError.fileReadNoSuchFile {
                continue
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                filesFailed += 1
                continue
            }
            rootsFound = true
            guard let iterator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                                 errorHandler: { _, _ in
                self.filesFailed += 1
                return true
            }) else {
                filesFailed += 1
                continue
            }
            for case let url as URL in iterator {
                visited += 1
                guard visited <= 20_000, withinBudget else {
                    limited = true
                    break
                }
                do {
                    let metadata = try url.resourceValues(forKeys: Set(keys))
                    if metadata.isSymbolicLink == true {
                        iterator.skipDescendants()
                    } else if metadata.isRegularFile == true {
                        if url.pathExtension == "jsonl" {
                            candidates.append((url, metadata.contentModificationDate ?? .distantPast))
                        } else if url.lastPathComponent.hasSuffix(".jsonl.zst") || url.lastPathComponent.hasSuffix(".jsonl.gz") {
                            filesFailed += 1
                        }
                    }
                } catch {
                    filesFailed += 1
                }
            }
        }
        return candidates.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.url.path < $1.url.path
        }.map(\.url)
    }

    func read(_ file: URL, shouldContinue: () -> Bool = { true }, record: (Object) -> Void) {
        guard withinBudget else {
            limited = true
            return
        }
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            filesFailed += 1
            return
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            filesFailed += 1
            return
        }

        filesRead += 1
        var fileRemaining = min(max(0, Int(metadata.st_size)), fileLimit)
        let exceedsFileLimit = metadata.st_size > fileLimit
        var line = Data()
        var oversized = false
        do {
            while fileRemaining > 0, withinBudget, shouldContinue() {
                guard let chunk = try handle.read(upToCount: min(65_536, fileRemaining, remaining)), !chunk.isEmpty else { break }
                remaining -= chunk.count
                fileRemaining -= chunk.count
                var cursor = chunk.startIndex
                while cursor < chunk.endIndex, shouldContinue() {
                    let newline = chunk[cursor...].firstIndex(of: 10)
                    let end = newline ?? chunk.endIndex
                    if !oversized {
                        if line.count + (end - cursor) > lineLimit {
                            oversized = true
                            line.removeAll(keepingCapacity: false)
                            skippedRecords += 1
                            limited = true
                        } else {
                            line.append(contentsOf: chunk[cursor..<end])
                        }
                    }
                    if let newline {
                        if !oversized { deliver(line, record: record) }
                        line.removeAll(keepingCapacity: true)
                        oversized = false
                        cursor = newline + 1
                    } else {
                        break
                    }
                }
            }
            if shouldContinue() {
                if exceedsFileLimit || fileRemaining > 0 {
                    limited = true
                } else if !oversized {
                    deliver(line, record: record)
                }
            }
        } catch {
            filesFailed += 1
        }
    }

    private var withinBudget: Bool {
        remaining > 0 && ProcessInfo.processInfo.systemUptime < deadline && !Task<Never, Never>.isCancelled
    }

    private func deliver(_ line: Data, record: (Object) -> Void) {
        guard !line.isEmpty else { return }
        guard let row = try? JSONSerialization.jsonObject(with: line) as? Object else {
            skippedRecords += 1
            return
        }
        record(row)
    }

    func coverage(_ provider: String) -> UsageSourceCoverage {
        let state: String
        if filesFailed > 0 && filesRead == 0 { state = "unreadable" }
        else if limited || filesFailed > 0 || skippedRecords > 0 { state = "partial" }
        else { state = rootsFound ? "read" : "missing" }
        return UsageSourceCoverage(provider: provider, state: state, filesRead: filesRead, filesFailed: filesFailed,
                                   skippedRecords: skippedRecords, limited: limited)
    }
}
