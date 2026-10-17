import Foundation
import CryptoKit

// Independent verification uses only the public key embedded in the app.
// Sparkle 2.10 signs the exact XML bytes before its final signature comment.
enum VerificationError: Error { case invalid(String) }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw VerificationError.invalid(message) }
}
do {
    guard CommandLine.arguments.count == 3 else { throw VerificationError.invalid("Expected release directory and Info.plist") }
    let folder = URL(fileURLWithPath: CommandLine.arguments[1])
    let plist = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    let info = try PropertyListSerialization.propertyList(from: plist, format: nil) as! [String: Any]
    guard let rawKey = Data(base64Encoded: info["SUPublicEDKey"] as! String) else { throw VerificationError.invalid("Missing update public key") }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
    let feed = try Data(contentsOf: folder.appendingPathComponent("appcast.xml"))
    let marker = Data("<!-- sparkle-signatures:\n".utf8)
    guard let range = feed.range(of: marker, options: .backwards),
          let block = String(data: feed[range.upperBound...], encoding: .utf8) else { throw VerificationError.invalid("Missing signed feed block") }
    let fields = Dictionary(uniqueKeysWithValues: block.split(separator: "\n").compactMap { line -> (String, String)? in
        let parts = line.split(separator: ":", maxSplits: 1)
        return parts.count == 2 ? (String(parts[0]), parts[1].trimmingCharacters(in: .whitespaces)) : nil
    })
    guard let feedSignature = fields["edSignature"].flatMap({ Data(base64Encoded: $0) }),
          let length = fields["length"].flatMap(Int.init) else { throw VerificationError.invalid("Invalid signed feed metadata") }
    let content = feed.prefix(range.lowerBound)
    try require(length == content.count && key.isValidSignature(feedSignature, for: content), "Feed signature failed")
    let xml = try XMLDocument(data: feed, options: [.nodeLoadExternalEntitiesNever])
    guard let enclosure = try xml.nodes(forXPath: "/rss/channel/item/enclosure").first as? XMLElement,
          let signatureText = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue,
          let signature = Data(base64Encoded: signatureText) else { throw VerificationError.invalid("Missing archive signature") }
    let archive = try Data(contentsOf: folder.appendingPathComponent("EVB-Shot-macOS-arm64.zip"), options: .mappedIfSafe)
    try require(key.isValidSignature(signature, for: archive), "Archive signature failed")
    print("PASS independent CryptoKit Ed25519 verification of feed and archive against bundled public key")
} catch {
    fputs("Update verification failed: \(error)\n", stderr)
    exit(1)
}
