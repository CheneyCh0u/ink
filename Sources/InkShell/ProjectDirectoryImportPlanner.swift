import Foundation

struct ProjectDirectoryImportPlan: Equatable {
    let directoriesToAdd: [URL]
    let selectedIndex: Int?
}

enum ProjectDirectoryImportPlanner {
    static func validDirectories(from candidates: [URL]) -> [URL] {
        var seen = Set<String>()
        return candidates.compactMap { candidate in
            guard candidate.isFileURL else { return nil }
            let directory = candidate.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: directory.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue, seen.insert(directory.path).inserted else {
                return nil
            }
            return directory
        }
    }

    static func plan(
        candidates: [URL],
        existingDirectories: [URL]
    ) -> ProjectDirectoryImportPlan {
        let valid = validDirectories(from: candidates)
        var existingIndices: [String: Int] = [:]
        for (index, directory) in existingDirectories.enumerated() {
            let path = directory.standardizedFileURL.path
            if existingIndices[path] == nil {
                existingIndices[path] = index
            }
        }
        let additions = valid.filter { existingIndices[$0.path] == nil }
        if !additions.isEmpty {
            return ProjectDirectoryImportPlan(
                directoriesToAdd: additions,
                selectedIndex: existingDirectories.count
            )
        }
        let selectedIndex = valid.lazy.compactMap { existingIndices[$0.path] }.first
        return ProjectDirectoryImportPlan(
            directoriesToAdd: [],
            selectedIndex: selectedIndex
        )
    }
}
