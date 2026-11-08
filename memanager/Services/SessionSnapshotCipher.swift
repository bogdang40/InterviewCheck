import AppKit
import CryptoKit
import Foundation

enum SessionSnapshotCipher {
    private static let keychainKey = "memanager.sessionSnapshotSymmetricKey"
    private static let targetDimension: CGFloat = 960

    /// Cached key plus lock so the load/generate/save sequence runs once per
    /// process instead of hitting the Keychain on every snapshot.
    private static var cachedKey: SymmetricKey?
    private static let keyLock = NSLock()

    static func encryptSnapshot(_ image: NSImage) -> (payload: Data, width: Int, height: Int, hash: String)? {
        let resized = resize(image: image, targetDimension: targetDimension)
        guard let tiffData = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else {
            return nil
        }

        // Fail closed: never seal with a key that is not durably persisted,
        // or every snapshot from this session would be permanently
        // unreadable after relaunch. Skipping the row matches the existing
        // behavior for any other encryption failure.
        guard let key = symmetricKey() else { return nil }
        do {
            let sealedBox = try AES.GCM.seal(jpegData, using: key)
            guard let combined = sealedBox.combined else { return nil }
            // Digest the ciphertext, not the plaintext: a plaintext hash next
            // to the ciphertext lets an attacker confirm snapshot contents
            // without the key. No code path reads this column today, so old
            // rows stay valid.
            let hash = SHA256.hash(data: combined).compactMap { String(format: "%02x", $0) }.joined()
            return (
                payload: combined,
                width: Int(resized.size.width.rounded()),
                height: Int(resized.size.height.rounded()),
                hash: hash
            )
        } catch {
            return nil
        }
    }

    static func decryptSnapshot(_ record: SessionSnapshotRecord) -> NSImage? {
        guard let key = symmetricKey() else { return nil }
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: record.encryptedPayload)
            let jpegData = try AES.GCM.open(sealedBox, using: key)
            return NSImage(data: jpegData)
        } catch {
            return nil
        }
    }

    private static func symmetricKey() -> SymmetricKey? {
        keyLock.lock()
        defer { keyLock.unlock() }

        if let cached = cachedKey {
            return cached
        }

        do {
            let key = try resolveKey(
                read: { try KeychainManager.readBinaryWithoutInteraction(key: keychainKey) },
                save: { KeychainManager.saveBinary(key: keychainKey, data: $0) }
            )
            cachedKey = key
            return key
        } catch {
            NSLog("[SessionSnapshotCipher] Snapshot key could not be read: %@", error.localizedDescription)
            return nil
        }
    }

    /// Only confirmed absence permits key creation. An inaccessible or malformed
    /// existing key must stay untouched so saved snapshots remain recoverable.
    static func resolveKey(read: () throws -> Data?, save: (Data) -> Bool) throws -> SymmetricKey? {
        if let stored = try read() {
            guard stored.count == 32 else { return nil }
            return SymmetricKey(data: stored)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        guard save(data), try read() == data else {
            NSLog("[SessionSnapshotCipher] Snapshot key persistence could not be verified; snapshot skipped")
            return nil
        }
        return key
    }

    private static func resize(image: NSImage, targetDimension: CGFloat) -> NSImage {
        let original = image.size
        let ratio = min(targetDimension / max(original.width, 1), targetDimension / max(original.height, 1), 1)
        let newSize = NSSize(width: max(1, original.width * ratio), height: max(1, original.height * ratio))

        let resized = NSImage(size: newSize)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize))
        resized.unlockFocus()
        return resized
    }
}
