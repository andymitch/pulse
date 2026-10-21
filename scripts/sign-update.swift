import CryptoKit
import Foundation

let args = CommandLine.arguments
if args.count > 1 && args[1] == "keygen" {
    let key = Curve25519.Signing.PrivateKey()
    print(key.rawRepresentation.base64EncodedString())
    FileHandle.standardError.write(Data("public: \(key.publicKey.rawRepresentation.base64EncodedString())\n".utf8))
    exit(0)
}
guard args.count > 1, let raw = ProcessInfo.processInfo.environment["PULSE_UPDATE_KEY"].flatMap({ Data(base64Encoded: $0) }) else {
    FileHandle.standardError.write(Data("usage: PULSE_UPDATE_KEY=<base64> swift sign-update.swift <file>\n".utf8))
    exit(1)
}
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
print(try key.signature(for: data).base64EncodedString())
