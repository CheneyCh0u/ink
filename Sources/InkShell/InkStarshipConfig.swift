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
        if let existing = try? String(contentsOf: url, encoding: .utf8),
           existing == managedContents {
            return false
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try managedContents.write(to: url, atomically: true, encoding: .utf8)
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
}
