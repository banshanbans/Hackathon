import Foundation

enum CaptureWorkStoreError: LocalizedError, Equatable {
    case invalidCandidateData
    case missingSelectedFrame
    case corrupted

    var errorDescription: String? {
        switch self {
        case .invalidCandidateData: "候选帧不是有效 JPEG。"
        case .missingSelectedFrame: "已选择的候选帧文件不存在。"
        case .corrupted: "本地拍摄任务已损坏，请重新拍摄。"
        }
    }
}

actor CaptureWorkStore {
    let directory: URL
    let cacheURL: URL

    init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appending(path: "SoloShot", directoryHint: .isDirectory)
        let resolved = root.appending(path: "CaptureWork", directoryHint: .isDirectory)
        self.directory = resolved
        cacheURL = resolved.appending(path: "capture-work.json")
    }

    func load(sessionID: String, now: Date = Date()) throws -> CaptureWork? {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return nil }
        do {
            let decoder = JSONDecoder()
            let work = try decoder.decode(CaptureWork.self, from: Data(contentsOf: cacheURL))
            guard work.sessionID == sessionID else { return nil }
            guard work.expiresAt > now else {
                try clear()
                return nil
            }
            return work
        } catch let error as CaptureWorkStoreError {
            throw error
        } catch {
            try? clear()
            throw CaptureWorkStoreError.corrupted
        }
    }

    func save(_ work: CaptureWork) throws {
        try prepareDirectory()
        let encoder = JSONEncoder()
        let data = try encoder.encode(work)
        let temporary = directory.appending(path: ".capture-work-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: [.completeFileProtection])
        if FileManager.default.fileExists(atPath: cacheURL.path) {
            _ = try FileManager.default.replaceItemAt(cacheURL, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: cacheURL)
        }
    }

    func saveCandidateJPEG(
        _ data: Data,
        roundIndex: Int,
        frameID: String
    ) throws -> String {
        guard data.count >= 4,
              data[0] == 0xFF,
              data[1] == 0xD8,
              data[data.count - 2] == 0xFF,
              data[data.count - 1] == 0xD9
        else {
            throw CaptureWorkStoreError.invalidCandidateData
        }
        try prepareDirectory()
        let filename = "round-\(roundIndex)-\(frameID).jpg"
        try data.write(
            to: directory.appending(path: filename),
            options: [.atomic, .completeFileProtection]
        )
        return filename
    }

    func selectedFrameData(_ round: CaptureRoundWork) throws -> Data {
        guard let candidate = round.selectedCandidate else {
            throw CaptureWorkStoreError.missingSelectedFrame
        }
        let url = directory.appending(path: candidate.localFilename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CaptureWorkStoreError.missingSelectedFrame
        }
        return try Data(contentsOf: url)
    }

    func candidateURL(filename: String) -> URL {
        directory.appending(path: filename)
    }

    func removeUnselected(round: CaptureRoundWork) throws {
        guard let selected = round.selectedFrameID else { return }
        for candidate in round.candidates where candidate.id != selected {
            try removeIfPresent(directory.appending(path: candidate.localFilename))
        }
        if let sourceFilename = round.sourceFilename {
            try removeIfPresent(directory.appending(path: sourceFilename))
        }
    }

    func removeSelected(round: CaptureRoundWork) throws {
        if let candidate = round.selectedCandidate {
            try removeIfPresent(directory.appending(path: candidate.localFilename))
        }
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
    }
}
