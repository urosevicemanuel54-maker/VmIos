//
//  PairingStore.swift
//  Vortex
//
//  Stores the device pairing record where the StikJIT documentation specifies:
//  Documents/StikJIT/pairingFile.plist, protected at rest, excluded from backup.
//  The contents are never logged, never copied elsewhere and never sent.
//

import Foundation

enum PairingValidationError: LocalizedError, Equatable {
    case empty
    case tooLarge
    case notAPropertyList
    case notADictionary
    case missingKeys([String])

    var errorDescription: String? {
        switch self {
        case .empty:
            return "The file is empty."
        case .tooLarge:
            return "The file is larger than any device pairing record."
        case .notAPropertyList:
            return "The file is not a property list. Import the .plist pairing record your pairing tool exported."
        case .notADictionary:
            return "The property list is not a pairing record (expected a dictionary)."
        case .missingKeys(let keys):
            return "The pairing record is missing \(keys.joined(separator: ", "))."
        }
    }
}

enum PairingStatus: Equatable {
    case missing
    case invalid(reason: String)
    case present(fileName: String, updatedAt: Date?, size: Int)

    var isUsable: Bool {
        if case .present = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .missing: return "No pairing file"
        case .invalid: return "Pairing file invalid"
        case .present: return "Pairing file present"
        }
    }

    var detail: String {
        switch self {
        case .missing:
            return "Import the pairing record at Documents/\(PairingStore.directoryName)/\(PairingStore.fileName)."
        case .invalid(let reason):
            return reason
        case .present(let fileName, let updatedAt, let size):
            let stamp = updatedAt.map { DateFormatter.localizedString(from: $0,
                                                                     dateStyle: .medium,
                                                                     timeStyle: .short) } ?? "unknown date"
            return "\(fileName) · \(size) bytes · updated \(stamp)"
        }
    }
}

final class PairingStore {
    static let directoryName = "StikJIT"
    static let fileName = "pairingFile.plist"
    static let maximumSize = 1_048_576

    let directoryURL: URL
    let fileURL: URL

    private let fileManager: FileManager

    init(fileManager: FileManager = .default, documentsURL: URL? = nil) {
        self.fileManager = fileManager
        let documents = documentsURL ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directoryURL = documents.appendingPathComponent(Self.directoryName, isDirectory: true)
        fileURL = directoryURL.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    func status() -> PairingStatus {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .missing }

        do {
            let data = try Data(contentsOf: fileURL)
            try Self.validate(data)
            let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path)
            let size = (attributes?[.size] as? NSNumber)?.intValue ?? data.count
            let updated = attributes?[.modificationDate] as? Date
            return .present(fileName: Self.fileName, updatedAt: updated, size: size)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? "The pairing file could not be read."
            return .invalid(reason: reason)
        }
    }

    /// Reads the record for a consumer inside the app. The caller must not log it.
    func loadData() -> Data? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return (try? Self.validate(data)) == nil ? nil : data
    }

    @discardableResult
    func importPairing(from sourceURL: URL) throws -> PairingStatus {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: sourceURL)
        try Self.validate(data)
        try write(data)
        return status()
    }

    func deletePairing() {
        try? fileManager.removeItem(at: fileURL)
    }

    private func write(_ data: Data) throws {
        try fileManager.createDirectory(at: directoryURL,
                                        withIntermediateDirectories: true,
                                        attributes: [.protectionKey: FileProtectionType.complete])

        let temporaryURL = directoryURL.appendingPathComponent(".pairing-\(UUID().uuidString).tmp")
        try data.write(to: temporaryURL, options: [.atomic, .completeFileProtection])

        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        }

        try? fileManager.setAttributes([.protectionKey: FileProtectionType.complete],
                                       ofItemAtPath: fileURL.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = fileURL
        try? mutableURL.setResourceValues(values)
    }

    /// Structural validation only: the record must be a property list holding
    /// the lockdownd keys. No value is ever read into a log or an error.
    static func validate(_ data: Data) throws {
        guard !data.isEmpty else { throw PairingValidationError.empty }
        guard data.count <= maximumSize else { throw PairingValidationError.tooLarge }

        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data,
                                                                options: [],
                                                                format: nil)
        } catch {
            throw PairingValidationError.notAPropertyList
        }

        guard let dictionary = object as? [String: Any] else {
            throw PairingValidationError.notADictionary
        }

        guard dictionary["HostID"] != nil else {
            throw PairingValidationError.missingKeys(["HostID"])
        }

        let identityKeys = ["HostCertificate", "RootCertificate", "HostPrivateKey", "DeviceCertificate"]
        guard identityKeys.contains(where: { dictionary[$0] != nil }) else {
            throw PairingValidationError.missingKeys(["a host or device identity"])
        }
    }
}
