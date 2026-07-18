import Foundation

actor ImportedTaskStore {
    let directory: URL
    let cacheURL: URL

    init(directory: URL? = nil) {
        let resolved = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(path: "SoloShot", directoryHint: .isDirectory)
        self.directory = resolved
        cacheURL = resolved.appending(path: "imported-task.json")
    }

    func load(now: Date = Date()) throws -> ImportedTask? {
        guard let task = try loadUnchecked() else {
            return nil
        }
        if task.expiresAt <= now {
            try clear()
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
            try? clear()
            return nil
        }
    }

    func save(_ task: ImportedTask) throws {
        try prepareDirectory()
        let data = try JSONEncoder.soloShot.encode(task)
        let temporary = directory.appending(path: ".imported-task-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: [.completeFileProtection])
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            _ = try FileManager.default.replaceItemAt(cacheURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: cacheURL)
        }
    }

    func saveReference(_ data: Data, code: String) throws -> String {
        try prepareDirectory()
        let name = "reference-\(code).image"
        let destination = directory.appending(path: name)
        try data.write(to: destination, options: [.atomic, .completeFileProtection])
        return name
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for entry in entries where entry.lastPathComponent == "imported-task.json" || entry.lastPathComponent.hasPrefix("reference-") {
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
