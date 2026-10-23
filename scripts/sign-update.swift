// Ed25519 signing for update archives. The private key never leaves this machine.
//
//   swift scripts/sign-update.swift --generate     create a key pair, print the public key
//   swift scripts/sign-update.swift --public       print the public key for Info.plist
//   swift scripts/sign-update.swift <file>         print the base64 signature of <file>
//
// Key location: $PERCH_SIGNING_KEY, or ~/.config/perch/update_ed25519.key
import CryptoKit
import Foundation

let keyURL: URL = {
    if let path = ProcessInfo.processInfo.environment["PERCH_SIGNING_KEY"] { return URL(fileURLWithPath: path) }
    return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/perch/update_ed25519.key")
}()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadKey() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOf: keyURL, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("No signing key at \(keyURL.path). Run with --generate first.")
    }
    return key
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "--generate":
    guard !FileManager.default.fileExists(atPath: keyURL.path) else { fail("Key already exists at \(keyURL.path); refusing to overwrite.") }
    let key = Curve25519.Signing.PrivateKey()
    try FileManager.default.createDirectory(at: keyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try key.rawRepresentation.base64EncodedString().write(to: keyURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "--public":
    print(loadKey().publicKey.rawRepresentation.base64EncodedString())
case let path?:
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    print(try loadKey().signature(for: data).base64EncodedString())
case nil:
    fail("usage: sign-update.swift --generate | --public | <file>")
}
