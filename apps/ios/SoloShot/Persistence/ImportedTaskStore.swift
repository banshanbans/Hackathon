import Foundation

actor ImportedTaskStore {
    let directory: URL
    let cacheURL: URL
    let tasksDirectory: URL

    init(directory: URL? = nil) {
        let resolved = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(path: "SoloShot", directoryHint: .isDirectory)
        self.directory = resolved
        cacheURL = resolved.appending(path: "imported-task.json")
        tasksDirectory = resolved.appending(path: "ImportedTasks", directoryHint: .isDirectory)
    }

    func load(now: Date = Date()) throws -> ImportedTask? {
        guard let task = try loadUnchecked() else {
            return nil
        }
        if task.expiresAt <= now {
            try clear(code: task.code)
            return nil
        }
        return task
    }

    func loadUnchecked() throws -> ImportedTask? {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            return nil
        }
        do {
            let task = try JSONDecoder.soloShot.decode(
                ImportedTask.self,
                from: Data(contentsOf: cacheURL)
            )
            return task
        } catch {
            try? FileManager.default.removeItem(at: cacheURL)
            return nil
        }
    }

    func save(_ task: ImportedTask) throws {
        try prepareDirectory()
        let data = try JSONEncoder.soloShot.encode(task)
        try writeAtomically(data, to: cacheURL)
        try writeAtomically(data, to: taskURL(code: task.code))
    }

    func loadAll(now: Date = Date()) throws -> [ImportedTask] {
        var tasksBySession: [String: ImportedTask] = [:]
        if FileManager.default.fileExists(atPath: tasksDirectory.path) {
            let entries = try FileManager.default.contentsOfDirectory(
                at: tasksDirectory,
                includingPropertiesForKeys: nil
            )
            for entry in entries where entry.pathExtension == "json" {
                do {
                    let task = try JSONDecoder.soloShot.decode(
                        ImportedTask.self,
                        from: Data(contentsOf: entry)
                    )
                    if task.expiresAt > now {
                        tasksBySession[task.sessionID] = task
                    } else {
                        try? FileManager.default.removeItem(at: entry)
                    }
                } catch {
                    try? FileManager.default.removeItem(at: entry)
                }
            }
        }
        if let active = try loadUnchecked() {
            if active.expiresAt > now {
                tasksBySession[active.sessionID] = active
            } else {
                try clear(code: active.code)
            }
        }
        return tasksBySession.values.sorted { lhs, rhs in
            if lhs.importedAt == rhs.importedAt {
                return lhs.code < rhs.code
            }
            return lhs.importedAt > rhs.importedAt
        }
    }

    func saveReference(_ data: Data, code: String) throws -> String {
        try prepareDirectory()
        let name = "reference-\(code).image"
        let destination = directory.appending(path: name)
        try data.write(to: destination, options: [.atomic, .completeFileProtection])
        return name
    }

    func saveSilhouette(_ asset: ReferenceSilhouetteAsset, code: String) throws -> String {
        try prepareDirectory()
        let name = "reference-\(code).silhouette.json"
        let destination = directory.appending(path: name)
        let data = try JSONEncoder.soloShot.encode(asset)
        try data.write(to: destination, options: [.atomic, .completeFileProtection])
        return name
    }

    func loadSilhouette(filename: String) throws -> ReferenceSilhouetteAsset {
        let url = directory.appending(path: filename)
        return try JSONDecoder.soloShot.decode(
            ReferenceSilhouetteAsset.self,
            from: Data(contentsOf: url)
        )
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for entry in entries where entry.lastPathComponent == "imported-task.json"
            || entry.lastPathComponent == "ImportedTasks"
            || entry.lastPathComponent.hasPrefix("reference-")
        {
            try FileManager.default.removeItem(at: entry)
        }
    }

    func clear(code: String) throws {
        if let active = try loadUnchecked(), active.code == code,
           FileManager.default.fileExists(atPath: cacheURL.path)
        {
            try FileManager.default.removeItem(at: cacheURL)
        }
        let indexed = taskURL(code: code)
        if FileManager.default.fileExists(atPath: indexed.path) {
            try FileManager.default.removeItem(at: indexed)
        }
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let prefix = "reference-\(code)."
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            try FileManager.default.removeItem(at: entry)
        }
    }

    func referenceURL(filename: String) -> URL {
        directory.appending(path: filename)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try FileManager.default.createDirectory(
            at: tasksDirectory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
    }

    private func taskURL(code: String) -> URL {
        let safeCode = code.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "_"
        }.joined()
        return tasksDirectory.appending(path: "task-\(safeCode).json")
    }

    private func writeAtomically(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent)-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: [.completeFileProtection])
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }
}

private extension JSONEncoder {
    static var soloShot: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var soloShot: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
