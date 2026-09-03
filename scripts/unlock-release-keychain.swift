import Foundation
import Security

private struct UnlockFailure: Error {
    let message: String
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: \(message)\n").utf8))
    exit(1)
}

private func run() throws {
    guard CommandLine.arguments.count == 3 else {
        throw UnlockFailure(message: "usage: unlock-release-keychain.swift <keychain> <password-file>")
    }

    let keychainPath = CommandLine.arguments[1]
    let passwordPath = CommandLine.arguments[2]
    let fileManager = FileManager.default

    guard let attributes = try? fileManager.attributesOfItem(atPath: passwordPath),
          attributes[.type] as? FileAttributeType == .typeRegular,
          (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
        throw UnlockFailure(message: "the password file must be a regular file with mode 600")
    }

    guard var passwordData = try? Data(contentsOf: URL(fileURLWithPath: passwordPath)) else {
        throw UnlockFailure(message: "could not read the password file")
    }
    defer {
        passwordData.resetBytes(in: 0..<passwordData.count)
    }

    if passwordData.last == 0x0a {
        passwordData.removeLast()
        if passwordData.last == 0x0d {
            passwordData.removeLast()
        }
    }
    guard !passwordData.isEmpty else {
        throw UnlockFailure(message: "the password file is empty")
    }
    guard passwordData.count <= Int(UInt32.max) else {
        throw UnlockFailure(message: "the password file is too large")
    }

    var keychain: SecKeychain?
    let openStatus = SecKeychainOpen(keychainPath, &keychain)
    guard openStatus == errSecSuccess, let keychain else {
        throw UnlockFailure(message: "could not open the configured keychain (OSStatus \(openStatus))")
    }

    let unlockStatus = passwordData.withUnsafeBytes { bytes in
        SecKeychainUnlock(keychain, UInt32(bytes.count), bytes.baseAddress, true)
    }
    guard unlockStatus == errSecSuccess else {
        throw UnlockFailure(message: "could not unlock the configured keychain (OSStatus \(unlockStatus))")
    }
}

do {
    try run()
} catch let error as UnlockFailure {
    fail(error.message)
} catch {
    fail(error.localizedDescription)
}
