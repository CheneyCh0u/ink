import Darwin
import Foundation
import InkConfig

enum InkStarshipConfig {
    static var defaultURL: URL {
        InkConfig.defaultURL.deletingLastPathComponent()
            .appendingPathComponent("starship.toml")
    }

    static let managedContents = #"""
    # 由 Ink 管理；更新 Ink 时可能覆盖本文件。
    "$schema" = "https://starship.rs/config-schema.json"

    format = """
    [░▒▓](bright-purple)\
    $os\
    [  ](bg:bright-purple fg:black)\
    [](fg:bright-purple bg:bright-black)\
    $directory\
    [](fg:bright-black bg:purple)\
    $git_branch\
    $git_status\
    [](fg:purple bg:black)\
    $nodejs\
    $python\
    $rust\
    $golang\
    $java\
    $conda\
    $docker_context\
    $time\
    [](fg:black)\
    $cmd_duration\
    $line_break\
    $character"""

    [os]
    disabled = false
    style = "bg:bright-purple fg:black"

    [os.symbols]
    Macos = "󰀵"
    Linux = "󰌽"
    Windows = ""

    [directory]
    style = "bg:bright-black fg:bright-white"
    format = '[  $path ]($style)'
    truncation_length = 3
    truncate_to_repo = false

    [git_branch]
    symbol = ""
    style = "bg:purple fg:black"
    format = '[ $branch ]($style)'

    [git_status]
    style = "bg:purple fg:black"
    format = '[($all_status$ahead_behind )]($style)'

    [nodejs]
    symbol = ""
    style = "bg:black fg:yellow"
    format = '[  ($version) ]($style)'

    [python]
    symbol = ""
    style = "bg:black fg:yellow"
    format = '[  ($version)(\($virtualenv\)) ]($style)'

    [rust]
    symbol = ""
    style = "bg:black fg:red"
    format = '[  ($version) ]($style)'

    [golang]
    symbol = ""
    style = "bg:black fg:green"
    format = '[  ($version) ]($style)'

    [java]
    symbol = ""
    style = "bg:black fg:red"
    format = '[  ($version) ]($style)'

    [conda]
    symbol = ""
    style = "bg:black fg:yellow"
    format = '[  $environment ]($style)'
    ignore_base = false

    [docker_context]
    symbol = ""
    style = "bg:black fg:cyan"
    format = '[  $context ]($style)'

    [time]
    disabled = false
    time_format = "%H:%M"
    style = "bg:black fg:bright-white"
    format = '[ 󱑍 $time ]($style)'

    [cmd_duration]
    format = ' [took $duration](yellow)'

    [line_break]
    disabled = false

    [character]
    success_symbol = '[󱞩](bold bright-purple)'
    error_symbol = '[󱞩](bold red)'
    vimcmd_symbol = '[󱞩](bold purple)'
    """# + "\n"

    @discardableResult
    static func install(at url: URL = defaultURL) throws -> Bool {
        let directoryURL = url.deletingLastPathComponent()
        try ensureDirectoryExists(at: directoryURL)

        let directoryDescriptor = open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw installError("打开托管目录", path: directoryURL.path)
        }
        defer { close(directoryDescriptor) }

        guard fchmod(directoryDescriptor, 0o700) == 0 else {
            throw installError("收紧托管目录权限", path: directoryURL.path)
        }

        let fileName = url.lastPathComponent
        guard !fileName.isEmpty, fileName != ".", fileName != ".." else {
            throw InkStarshipInstallError.invalidFileName(fileName)
        }
        let managedData = Data(managedContents.utf8)
        if let existing = try existingData(
            named: fileName,
            in: directoryDescriptor,
            path: url.path
        ), existing == managedData {
            return false
        }

        try replaceFile(
            named: fileName,
            in: directoryDescriptor,
            path: url.path,
            with: managedData
        )
        return true
    }

    static func environmentOverrides(
        for source: InkConfig.PromptThemeSource,
        configURL: URL = defaultURL
    ) throws -> [String: String] {
        guard source == .ink else { return [:] }
        try install(at: configURL)
        return ["STARSHIP_CONFIG": configURL.path]
    }

    private static func ensureDirectoryExists(at url: URL) throws {
        var information = stat()
        if lstat(url.path, &information) == 0 {
            guard information.st_mode & S_IFMT == S_IFDIR else {
                throw InkStarshipInstallError.unsafeParent(url.path)
            }
            return
        }

        let errorCode = errno
        guard errorCode == ENOENT else {
            throw installError("检查托管目录", path: url.path, code: errorCode)
        }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private static func existingData(
        named fileName: String,
        in directoryDescriptor: Int32,
        path: String
    ) throws -> Data? {
        let descriptor = openat(
            directoryDescriptor,
            fileName,
            O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        )
        if descriptor < 0 {
            let errorCode = errno
            if errorCode == ENOENT { return nil }
            throw installError("打开托管提示符文件", path: path, code: errorCode)
        }
        defer { close(descriptor) }

        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw installError("检查托管提示符文件", path: path)
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            throw InkStarshipInstallError.unsafeFile(path)
        }
        guard information.st_nlink == 1 else {
            throw InkStarshipInstallError.unsafeFile(path)
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw installError("收紧托管提示符文件权限", path: path)
        }
        return try readAll(from: descriptor, path: path)
    }

    private static func readAll(from descriptor: Int32, path: String) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw installError("读取托管提示符文件", path: path)
            }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func replaceFile(
        named fileName: String,
        in directoryDescriptor: Int32,
        path: String,
        with data: Data
    ) throws {
        let temporaryName = ".\(fileName).ink-\(UUID().uuidString)"
        let descriptor = openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw installError("创建托管提示符临时文件", path: path)
        }
        var shouldRemoveTemporaryFile = true
        defer {
            close(descriptor)
            if shouldRemoveTemporaryFile {
                unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }

        guard fchmod(descriptor, 0o600) == 0 else {
            throw installError("设置托管提示符文件权限", path: path)
        }
        try writeAll(data, to: descriptor, path: path)
        guard renameat(
            directoryDescriptor,
            temporaryName,
            directoryDescriptor,
            fileName
        ) == 0 else {
            throw installError("替换托管提示符文件", path: path)
        }
        shouldRemoveTemporaryFile = false
    }

    private static func writeAll(_ data: Data, to descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw installError("写入托管提示符文件", path: path)
                }
                offset += count
            }
        }
    }

    private static func installError(
        _ operation: String,
        path: String,
        code: Int32 = errno
    ) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey: "\(operation)失败",
                NSFilePathErrorKey: path,
            ]
        )
    }
}

private enum InkStarshipInstallError: Error {
    case invalidFileName(String)
    case unsafeParent(String)
    case unsafeFile(String)
}
