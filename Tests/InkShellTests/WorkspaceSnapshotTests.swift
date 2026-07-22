import Foundation
import Testing
@testable import InkShell

@Suite("会话布局快照", .serialized)
struct WorkspaceSnapshotTests {
    @Test("schema 1 往返嵌套布局并归一化权重")
    func roundtrip() throws {
        let snapshot = WorkspaceSnapshot(
            activeProjectPath: "~/work/ink",
            projects: [
                .init(
                    path: "~/work/ink",
                    activeTabIndex: 0,
                    tabs: [
                        .init(
                            customName: "开发",
                            activePaneID: "left",
                            layout: .group(
                                axis: "leftRight",
                                weights: [2, 1],
                                children: [
                                    .leaf(
                                        paneID: "left",
                                        workingDirectory: "~/work/ink"
                                    ),
                                    .leaf(
                                        paneID: "right",
                                        workingDirectory: "~/work/ink/Tests"
                                    ),
                                ]
                            )
                        ),
                    ]
                ),
            ]
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        let valid = try #require(decoded.validated())

        #expect(valid.schemaVersion == 1)
        #expect(valid.activeProjectPath == "~/work/ink")
        #expect(valid.projects[0].tabs[0].customName == "开发")
        #expect(valid.projects[0].tabs[0].layout.weights == [2.0 / 3.0, 1.0 / 3.0])
        #expect(valid.projects[0].tabs[0].layout.paneCount == 2)
    }

    @Test("过新 schema 整份拒绝")
    func rejectsNewerSchema() {
        var snapshot = WorkspaceSnapshot(activeProjectPath: nil, projects: [])
        snapshot.schemaVersion = 2

        #expect(snapshot.validated() == nil)
    }

    @Test("局部语义错误只丢弃坏标签")
    func dropsOnlyInvalidTab() throws {
        let snapshot = WorkspaceSnapshot(
            activeProjectPath: nil,
            projects: [
                .init(
                    path: "~/work/ink",
                    activeTabIndex: 1,
                    tabs: [
                        .init(
                            customName: "坏",
                            activePaneID: "x",
                            layout: .group(
                                axis: "diagonal",
                                weights: [1, 1],
                                children: [
                                    .leaf(paneID: "x", workingDirectory: "~"),
                                    .leaf(paneID: "y", workingDirectory: "~"),
                                ]
                            )
                        ),
                        .init(
                            customName: "好",
                            activePaneID: "z",
                            layout: .leaf(paneID: "z", workingDirectory: "~")
                        ),
                    ]
                ),
            ]
        )

        let valid = try #require(snapshot.validated())

        #expect(valid.projects[0].tabs.map(\.customName) == ["好"])
        #expect(valid.projects[0].activeTabIndex == 0)
    }

    @Test("活动 pane 缺失时回退布局首叶")
    func fallsBackToFirstPane() throws {
        let snapshot = makeSnapshot(
            layout: .group(
                axis: "topBottom",
                weights: [1, 1],
                children: [
                    .leaf(paneID: "top", workingDirectory: "~"),
                    .leaf(paneID: "bottom", workingDirectory: "~"),
                ]
            ),
            activePaneID: "missing"
        )

        let valid = try #require(snapshot.validated())

        #expect(valid.projects[0].tabs[0].activePaneID == "top")
    }

    @Test("重复 pane 与非法权重只让对应标签失效")
    func rejectsInvalidTrees() throws {
        let duplicate = makeSnapshot(
            layout: .group(
                axis: "leftRight",
                weights: [1, 1],
                children: [
                    .leaf(paneID: "same", workingDirectory: "~"),
                    .leaf(paneID: "same", workingDirectory: "~"),
                ]
            )
        )
        let zeroWeight = makeSnapshot(
            layout: .group(
                axis: "leftRight",
                weights: [0, 1],
                children: [
                    .leaf(paneID: "first", workingDirectory: "~"),
                    .leaf(paneID: "second", workingDirectory: "~"),
                ]
            )
        )

        #expect(try #require(duplicate.validated()).projects[0].tabs.isEmpty)
        #expect(try #require(zeroWeight.validated()).projects[0].tabs.isEmpty)
    }

    @Test("深度、单标签 pane 和总 pane 预算均有界")
    func enforcesBudgets() throws {
        let tooDeep = makeSnapshot(layout: nestedLayout(depth: 5))
        let depthLimited = try #require(tooDeep.validated(limits: WorkspaceLimits(
            maxPanesPerTab: 64,
            maxLayoutDepth: 4
        )))
        #expect(depthLimited.projects[0].tabs.isEmpty)

        let manyLeaves = (0..<17).map {
            WorkspaceLayoutNode.leaf(paneID: "p\($0)", workingDirectory: "~")
        }
        let tooMany = makeSnapshot(layout: .group(
            axis: "leftRight",
            weights: Array(repeating: 1, count: manyLeaves.count),
            children: manyLeaves
        ))
        #expect(try #require(tooMany.validated()).projects[0].tabs.isEmpty)

        let tabs = (0..<3).map { index in
            WorkspaceSnapshot.Tab(
                customName: "\(index)",
                activePaneID: "\(index)",
                layout: .leaf(paneID: "\(index)", workingDirectory: "~")
            )
        }
        let totalLimited = try #require(WorkspaceSnapshot(
            activeProjectPath: nil,
            projects: [.init(path: "~", activeTabIndex: 2, tabs: tabs)]
        ).validated(limits: WorkspaceLimits(maxTotalPanes: 2)))
        #expect(totalLimited.projects[0].tabs.count == 2)
        #expect(totalLimited.projects[0].activeTabIndex == 1)
    }

    @Test("相对路径项目被丢弃，相对 pane 目录使标签失效")
    func rejectsRelativePaths() throws {
        let invalidProject = WorkspaceSnapshot(
            activeProjectPath: nil,
            projects: [
                .init(
                    path: "relative/project",
                    activeTabIndex: 0,
                    tabs: [
                        .init(
                            customName: nil,
                            activePaneID: "pane",
                            layout: .leaf(paneID: "pane", workingDirectory: "~")
                        ),
                    ]
                ),
            ]
        )
        let invalidPane = makeSnapshot(
            layout: .leaf(paneID: "pane", workingDirectory: "relative/pane")
        )

        #expect(try #require(invalidProject.validated()).projects.isEmpty)
        #expect(try #require(invalidPane.validated()).projects[0].tabs.isEmpty)
    }

    @Test("UserDefaults store 往返并拒绝损坏数据")
    func storeRoundtripAndCorruption() throws {
        let suiteName = "ink.workspace-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WorkspaceStore(defaults: defaults)
        let snapshot = makeSnapshot(
            layout: .leaf(paneID: "pane", workingDirectory: "~")
        )

        #expect(store.save(snapshot))
        #expect(store.load() == snapshot.validated())

        defaults.set(Data("not-json".utf8), forKey: WorkspaceStore.key)
        #expect(store.load() == nil)

        var newer = snapshot
        newer.schemaVersion = 2
        defaults.set(try JSONEncoder().encode(newer), forKey: WorkspaceStore.key)
        #expect(store.load() == nil)
    }

    @Test("128 pane 上限快照保持小体积且可重复往返")
    func maximumSnapshotRoundtripCost() throws {
        let projects = (0..<4).map { projectIndex in
            WorkspaceSnapshot.Project(
                path: "~/project-\(projectIndex)",
                activeTabIndex: 31,
                tabs: (0..<32).map { tabIndex in
                    let paneID = "p-\(projectIndex)-\(tabIndex)"
                    return WorkspaceSnapshot.Tab(
                        customName: "标签 \(tabIndex)",
                        activePaneID: paneID,
                        layout: .leaf(
                            paneID: paneID,
                            workingDirectory: "~/project-\(projectIndex)"
                        )
                    )
                }
            )
        }
        let snapshot = WorkspaceSnapshot(
            activeProjectPath: "~/project-0",
            projects: projects
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let encoded = try encoder.encode(snapshot)
        let clock = ContinuousClock()
        let start = clock.now
        var final: WorkspaceSnapshot?
        for _ in 0..<100 {
            let data = try encoder.encode(snapshot)
            final = try decoder.decode(WorkspaceSnapshot.self, from: data).validated()
        }
        let duration = start.duration(to: clock.now)
        let suiteName = "ink.workspace-cost-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WorkspaceStore(defaults: defaults)
        let storeStart = clock.now
        for _ in 0..<100 {
            #expect(store.save(snapshot))
            final = store.load()
        }
        let storeDuration = storeStart.duration(to: clock.now)

        #expect(encoded.count < 1_048_576)
        #expect(final?.projects.count == 4)
        #expect(final?.projects.flatMap(\.tabs).count == 128)
        #expect(final?.projects.flatMap(\.tabs).reduce(0) {
            $0 + $1.layout.paneCount
        } == 128)
        print("workspace snapshot: \(encoded.count) bytes, 100 roundtrips: \(duration)")
        print("workspace store: 100 save+load: \(storeDuration)")
    }

    private func makeSnapshot(
        layout: WorkspaceLayoutNode,
        activePaneID: String = "same"
    ) -> WorkspaceSnapshot {
        let fallbackActiveID: String
        if activePaneID == "same" {
            fallbackActiveID = layout.firstPaneID ?? "missing"
        } else {
            fallbackActiveID = activePaneID
        }
        return WorkspaceSnapshot(
            activeProjectPath: "~/work/ink",
            projects: [
                .init(
                    path: "~/work/ink",
                    activeTabIndex: 0,
                    tabs: [
                        .init(
                            customName: "测试",
                            activePaneID: fallbackActiveID,
                            layout: layout
                        ),
                    ]
                ),
            ]
        )
    }

    private func nestedLayout(depth: Int) -> WorkspaceLayoutNode {
        guard depth > 0 else {
            return .leaf(paneID: "root", workingDirectory: "~")
        }
        return .group(
            axis: depth.isMultiple(of: 2) ? "leftRight" : "topBottom",
            weights: [1, 1],
            children: [
                nestedLayout(depth: depth - 1),
                .leaf(paneID: "sibling-\(depth)", workingDirectory: "~"),
            ]
        )
    }
}

private extension WorkspaceLayoutNode {
    var firstPaneID: String? {
        switch self {
        case let .leaf(paneID, _): paneID
        case let .group(_, _, children): children.first?.firstPaneID
        }
    }
}
