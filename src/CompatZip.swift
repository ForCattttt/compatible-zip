import AppKit
import Foundation

struct CompatError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct PackResult {
    let output: URL
    let repairedNestedCount: Int
    let fileCount: Int
}

enum CompatPack {
    static let fm = FileManager.default
    static func metadata(_ name: String) -> Bool {
        name == ".DS_Store" || name == "__MACOSX" || name.hasPrefix("._")
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let log = fm.temporaryDirectory.appendingPathComponent("CompatZip-log-" + UUID().uuidString)
        fm.createFile(atPath: log.path, contents: nil)
        defer { try? fm.removeItem(at: log) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let result = String(data: try Data(contentsOf: log), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw CompatError(message: "压缩或校验失败，原文件未修改。\n" + String(result.suffix(2500)))
        }
        return result
    }

    static func windowsComponent(_ name: String) throws {
        let forbidden = CharacterSet(charactersIn: "<>:\"\\|?*").union(.controlCharacters)
        let reserved = ["CON", "PRN", "AUX", "NUL", "CLOCK$"]
            + (1...9).map { "COM\($0)" } + (1...9).map { "LPT\($0)" }
            + ["COM¹", "COM²", "COM³", "LPT¹", "LPT²", "LPT³"]
        let base = name.components(separatedBy: ".").first!.uppercased()
        if name.unicodeScalars.contains(where: { forbidden.contains($0) })
            || name.hasSuffix(".") || name.hasSuffix(" ") || reserved.contains(base) {
            throw CompatError(message: "Windows 不支持这个文件名：\n\(name)\n\n请先改名，再使用兼容压缩。原文件未修改。")
        }
    }

    static func key(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func validateArchiveNames(_ names: [String]) throws {
        var seenFiles = Set<String>()
        var seenPaths: [String: String] = [:]
        var directories = Set<String>()
        for name in names {
            guard !name.hasPrefix("/") else { throw CompatError(message: "压缩包含有绝对路径，请重新打包。") }
            let components = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
            guard !components.contains("..") else { throw CompatError(message: "压缩包含有上级目录路径，请重新打包。") }
            guard !components.isEmpty else { continue }
            var prefix = ""
            for (index, component) in components.enumerated() {
                try windowsComponent(component)
                prefix += (prefix.isEmpty ? "" : "/") + component
                let normalized = key(prefix)
                if let old = seenPaths[normalized], old != prefix {
                    throw CompatError(message: "压缩包内有在 Windows 上会冲突的名称：\n\(old)\n\(prefix)\n\n请先改名后再打包。")
                }
                seenPaths[normalized] = prefix
                if index < components.count - 1 || name.hasSuffix("/") {
                    guard !seenFiles.contains(normalized) else { throw CompatError(message: "压缩包内有同名的文件与文件夹：\n\(prefix)") }
                    directories.insert(normalized)
                } else {
                    guard !directories.contains(normalized), seenFiles.insert(normalized).inserted else {
                        throw CompatError(message: "压缩包含有重复文件名：\n\(prefix)\n\n请重新打包。")
                    }
                }
            }
        }
    }

    static func normalize(_ paths: [String]) throws -> [URL] {
        var roots: [URL] = []
        for path in paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard fm.fileExists(atPath: url.path) else { throw CompatError(message: "找不到文件：\n\(url.path)") }
            guard !roots.contains(where: { $0.path == url.path }) else { continue }
            roots.append(url)
        }
        return roots.filter { url in
            !roots.contains { other in
                other.path != url.path && url.path.hasPrefix(other.path + "/")
                    && (try? other.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
        }
    }

    static func scan(_ roots: [URL]) throws -> [(URL, String)] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        var seen = Set<String>()
        var zips: [(URL, String)] = []
        for root in roots {
            let top = root.lastPathComponent
            guard !metadata(top) else { throw CompatError(message: "这个项目是 Mac 系统附加文件，无需发送。") }
            let check: (URL, String) throws -> Void = { url, rel in
                try windowsComponent(url.lastPathComponent)
                guard seen.insert(key(rel)).inserted else {
                    throw CompatError(message: "有文件名在 Windows 上会发生冲突：\n\(rel)\n\n请改名后再压缩。原文件未修改。")
                }
                let values = try url.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true else {
                    throw CompatError(message: "文件夹含有符号链接：\n\(rel)\n\n请用实际文件替换链接后再压缩。原文件未修改。")
                }
                if values.isDirectory != true && url.pathExtension.lowercased() == "zip" {
                    zips.append((url, rel))
                }
            }
            try check(root, top)
            if try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                var enumerationError: Error?
                guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                    errorHandler: { _, error in enumerationError = error; return false }) else {
                    throw CompatError(message: "无法读取文件夹：\n\(root.path)")
                }
                for case let url as URL in enumerator {
                    if metadata(url.lastPathComponent) {
                        if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                            enumerator.skipDescendants()
                        }
                        continue
                    }
                    // Foundation may enumerate /private/var for a /var input.
                    // Use tree depth instead of slicing paths with different prefixes.
                    let rel = ([top] + url.pathComponents.suffix(enumerator.level)).joined(separator: "/")
                    try check(url, rel)
                }
                if let error = enumerationError { throw error }
            }
        }
        return zips
    }

    static func uniqueOutput(roots: [URL]) -> URL {
        let root = roots[0]
        let isDirectory = (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let stem = roots.count == 1 ? (isDirectory ? root.lastPathComponent : root.deletingPathExtension().lastPathComponent) : "微信文件"
        let parent = root.deletingLastPathComponent()
        var output = parent.appendingPathComponent(stem + "_兼容版.zip")
        var number = 2
        while fm.fileExists(atPath: output.path) {
            output = parent.appendingPathComponent(stem + "_兼容版（\(number)）.zip")
            number += 1
        }
        return output
    }

    static func archiveArguments(_ output: URL) -> [String] {
        ["-c", "-f", output.path, "--format", "zip", "--options",
         "zip:hdrcharset=UTF-8,zip:compression=deflate", "--no-mac-metadata",
         // Keep ./ on input to protect -/@ names, but never store it in ZIP names.
         // Windows Explorer can display such an archive as empty (libarchive #2489).
         "-s", "|^\\./||"]
    }

    static func needsPathRepair(_ inspection: ZipMetadata.Inspection) -> Bool {
        inspection.entryNames.contains { $0.hasPrefix("./") }
    }

    static func repairArchive(_ source: URL, to destination: URL) throws {
        let tagged = destination.deletingLastPathComponent()
            .appendingPathComponent("tagged-" + UUID().uuidString + ".zip")
        defer { try? fm.removeItem(at: tagged) }
        let before = try ZipMetadata.inspect(source)
        try validateArchiveNames(before.entryNames)
        _ = try run("/usr/bin/unzip", ["-tqq", source.path])
        _ = try ZipMetadata.repairUTF8Copy(source: source, destination: tagged)
        if needsPathRepair(before) {
            // Read archive entries directly; do not extract untrusted paths to disk.
            _ = try run("/usr/bin/tar", archiveArguments(destination) + ["@" + tagged.path])
        } else {
            try fm.copyItem(at: tagged, to: destination)
        }
        let after = try ZipMetadata.inspect(destination)
        try validateArchiveNames(after.entryNames)
        guard after.entryCount == before.entryCount,
              !after.needsUTF8Repair, !needsPathRepair(after) else {
            throw CompatError(message: "压缩包的文件数量、编码或路径校验失败，已取消输出。")
        }
        _ = try run("/usr/bin/unzip", ["-tqq", destination.path])
    }

    static func create(_ paths: [String], outputOverride: URL? = nil) throws -> PackResult {
        let roots = try normalize(paths)
        guard !roots.isEmpty else { throw CompatError(message: "请选择需要发送的文件或文件夹。") }
        let output = outputOverride ?? uniqueOutput(roots: roots)
        guard !fm.fileExists(atPath: output.path) else { throw CompatError(message: "目标压缩包已存在，请换一个名称。") }
        guard !roots.contains(where: { output.path == $0.path || output.path.hasPrefix($0.path + "/") }) else {
            throw CompatError(message: "请把压缩包保存到源文件夹外面。")
        }
        let temp = fm.temporaryDirectory.appendingPathComponent("CompatZip-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let archive = temp.appendingPathComponent("result.zip")
        var repairedCount = 0
        // Repair both UTF-8 metadata and Explorer-incompatible ./ paths in old ZIPs.
        let firstIsDirectory = try roots[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        if roots.count == 1 && roots[0].pathExtension.lowercased() == "zip" && !firstIsDirectory {
            let source = roots[0]
            try repairArchive(source, to: archive)
        } else {
            let zips = try scan(roots)
            var repairs: [(URL, String)] = []
            for (url, rel) in zips {
                do {
                    let inspection = try ZipMetadata.inspect(url)
                    try validateArchiveNames(inspection.entryNames)
                    if inspection.needsUTF8Repair || needsPathRepair(inspection) {
                        repairs.append((url, rel))
                    }
                } catch {
                    throw CompatError(message: "内含压缩包需要先解压成中文名称正常的文件夹：\n\(rel)\n\n\(error.localizedDescription)")
                }
            }
            var packingRoots = roots
            if !repairs.isEmpty {
                let staging = temp.appendingPathComponent("files", isDirectory: true)
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                packingRoots = try roots.map { root in
                    let destination = staging.appendingPathComponent(root.lastPathComponent)
                    try fm.copyItem(at: root, to: destination)
                    return destination
                }
                for (source, rel) in repairs {
                    let fixed = temp.appendingPathComponent(UUID().uuidString + ".zip")
                    try repairArchive(source, to: fixed)
                    let destination = staging.appendingPathComponent(rel)
                    try fm.removeItem(at: destination)
                    try fm.moveItem(at: fixed, to: destination)
                }
                repairedCount = repairs.count
            }
            var arguments = archiveArguments(archive) +
                ["--exclude", ".DS_Store", "--exclude", "._*", "--exclude", "__MACOSX"]
            for root in packingRoots {
                // Prefix ./ avoids both option parsing and bsdtar's @archive syntax.
                arguments += ["-C", root.deletingLastPathComponent().path, "./" + root.lastPathComponent]
            }
            _ = try run("/usr/bin/tar", arguments)
            let inspection = try ZipMetadata.inspect(archive)
            try validateArchiveNames(inspection.entryNames)
            guard !inspection.needsUTF8Repair else { throw CompatError(message: "中文文件名编码校验失败，请保留原文件并联系修复。") }
            _ = try run("/usr/bin/unzip", ["-tqq", archive.path])
        }
        let finalInspection = try ZipMetadata.inspect(archive)
        guard !needsPathRepair(finalInspection), !finalInspection.needsUTF8Repair else {
            throw CompatError(message: "Windows 文件名兼容性校验失败，已取消输出。")
        }
        let fileCount = finalInspection.entryNames.filter { !$0.hasSuffix("/") }.count
        guard fileCount > 0 else {
            throw CompatError(message: "所选文件夹内没有可打包的文件，未生成空压缩包。\n请确认选择的是包含文档的文件夹。")
        }
        // Copy only after all checks pass. Never replace any existing source/output file.
        try fm.copyItem(at: archive, to: output)
        return PackResult(output: output, repairedNestedCount: repairedCount, fileCount: fileCount)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var started = false
    var busy = false
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let item = NSMenuItem()
        menu.addItem(item)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出兼容压缩", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        NSApp.mainMenu = menu
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            if !started { chooseFiles() }
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        started = true
        if busy { sender.reply(toOpenOrPrint: .failure); return }
        sender.reply(toOpenOrPrint: .success)
        pack(filenames)
    }

    func chooseFiles() {
        started = true
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "兼容压缩 · 发微信"
        panel.message = "选择要发送的文件或文件夹。新 ZIP 保存在原文件旁边，中文名称可供 Windows 正确读取。"
        panel.prompt = "生成兼容 ZIP"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { pack(panel.urls.map(\.path)) }
        else { NSApp.terminate(nil) }
    }

    func pack(_ paths: [String]) {
        busy = true
        NSApp.activate(ignoringOtherApps: true)
        let progressWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 140),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        progressWindow.title = "兼容压缩 · 发微信"
        progressWindow.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "正在打包并校验，请稍候…")
        label.font = .systemFont(ofSize: 16)
        label.frame = NSRect(x: 28, y: 83, width: 364, height: 24)
        let sub = NSTextField(labelWithString: "新 ZIP 将保存在原文件旁边。")
        sub.textColor = .secondaryLabelColor
        sub.frame = NSRect(x: 28, y: 56, width: 364, height: 20)
        let bar = NSProgressIndicator(frame: NSRect(x: 28, y: 29, width: 364, height: 12))
        bar.style = .bar
        bar.isIndeterminate = true
        progressWindow.contentView?.addSubview(label)
        progressWindow.contentView?.addSubview(sub)
        progressWindow.contentView?.addSubview(bar)
        bar.startAnimation(nil)
        progressWindow.center()
        progressWindow.makeKeyAndOrderFront(nil)
        window = progressWindow
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result { try CompatPack.create(paths) }
            DispatchQueue.main.async { [self] in
                progressWindow.close()
                window = nil
                let alert = NSAlert()
                switch result {
                case .success(let packed):
                    alert.messageText = "兼容压缩包已生成"
                    alert.informativeText = packed.output.lastPathComponent
                        + "\n\n包含 \(packed.fileCount) 个文件，已完成完整性、中文编码和 Windows 路径检查。"
                        + "\n请发送这个新 ZIP；接收方下载后解压打开。"
                        + (packed.repairedNestedCount > 0 ? "\n已同步修复 \(packed.repairedNestedCount) 个内层压缩包的兼容性。" : "")
                    alert.addButton(withTitle: "在访达中显示")
                    alert.addButton(withTitle: "完成")
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.activateFileViewerSelecting([packed.output])
                    }
                case .failure(let error):
                    alert.alertStyle = .warning
                    alert.messageText = "暂时无法生成压缩包"
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: "好")
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
                NSApp.terminate(nil)
            }
        }
    }
}

@main
struct CompatZipApplication {
static func main() {
if CommandLine.arguments.dropFirst().first == "--cli" {
    var inputs = Array(CommandLine.arguments.dropFirst(2))
    var output: URL?
    if let index = inputs.firstIndex(of: "--output") {
        guard inputs.indices.contains(index + 1) else { fputs("缺少输出路径\n", stderr); exit(2) }
        output = URL(fileURLWithPath: inputs[index + 1])
        inputs.removeSubrange(index...(index + 1))
    }
    do {
        let result = try CompatPack.create(inputs, outputOverride: output)
        print(result.output.path)
        exit(0)
    } catch {
        fputs(error.localizedDescription + "\n", stderr)
        exit(1)
    }
} else {
    let delegate = AppDelegate()
    let application = NSApplication.shared
    application.delegate = delegate
    application.run()
}
}
}
