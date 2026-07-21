import Foundation
import Testing

@Suite("发布流水线")
struct ReleaseWorkflowTests {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("标签校验不抓取并覆盖 checkout 的当前 tag")
    func tagValidationDoesNotClobberCheckoutTag() throws {
        let workflow = try String(
            contentsOf: projectRoot.appendingPathComponent(".github/workflows/release.yml"),
            encoding: .utf8
        )

        #expect(!workflow.contains("git fetch origin main --tags"))
        #expect(workflow.contains("git fetch origin main"))
        #expect(workflow.contains("git ls-remote --exit-code --tags origin"))
    }

    @Test("Shell 变量与中文标点之间必须有明确边界")
    func shellVariablesHaveExplicitBoundaries() throws {
        let scripts = ["package-app.sh", "tag-release.sh"]
        let unsafeVariable = try NSRegularExpression(
            pattern: #"\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]"#
        )

        for script in scripts {
            let source = try String(
                contentsOf: projectRoot.appendingPathComponent("scripts/\(script)"),
                encoding: .utf8
            )
            let range = NSRange(source.startIndex..., in: source)
            #expect(
                unsafeVariable.firstMatch(in: source, range: range) == nil,
                "脚本 \(script) 存在未用花括号分隔的变量和中文字符"
            )
        }
    }

    @Test("应用签名携带 iCloud KVS entitlement")
    func packageIncludesKVSContainer() throws {
        let entitlementURL = projectRoot.appendingPathComponent("Resources/Ink.entitlements")
        let data = try Data(contentsOf: entitlementURL)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )
        #expect(
            plist["com.apple.developer.ubiquity-kvstore-identifier"] as? String
                == "FS3WL6385L.com.cheneychou.ink"
        )

        let script = try String(
            contentsOf: projectRoot.appendingPathComponent("scripts/package-app.sh"),
            encoding: .utf8
        )
        #expect(script.contains("entitlements_path=\"$project_root/Resources/Ink.entitlements\""))
        #expect(script.contains("--entitlements \"$entitlements_path\""))
    }
}
