import CryptoKit
import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: \(message)\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    fail("usage: sparkle-public-key.swift <private-key-file>")
}

let privateKeyURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let encodedData = try? Data(contentsOf: privateKeyURL),
      var encodedKey = String(data: encodedData, encoding: .utf8) else {
    fail("could not read the Sparkle private-key file")
}
if encodedKey.hasSuffix("\n") {
    encodedKey.removeLast()
    if encodedKey.hasSuffix("\r") {
        encodedKey.removeLast()
    }
}

guard let seed = Data(base64Encoded: encodedKey), seed.count == 32 else {
    fail("the Sparkle private-key file is not a base64-encoded Ed25519 seed")
}

do {
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    print(privateKey.publicKey.rawRepresentation.base64EncodedString())
} catch {
    fail("could not derive the Sparkle public key")
}
