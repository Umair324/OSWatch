import Foundation
import os.log

/// Reassembles multi-part BLE write chunks formatted as `<index>/<total>|<payloadFragment>`
/// (for example: `1/3|{"id":"92","appName":"Whats`, `2/3|App","title":"Alex",`, `3/3|"body":"Hey!","timestamp":1731400000000}`)
/// into a complete UTF-8 JSON string and decodes it into `IncomingBLEPayload`.
final class BLEPacketReassembler {

    // MARK: - Nested Types

    private struct ChunkBuffer {
        let totalChunks: Int
        var fragments: [Int: String]
        var updatedAt: Date

        var isComplete: Bool {
            guard totalChunks > 0 && fragments.count == totalChunks else { return false }
            for idx in 1...totalChunks where fragments[idx] == nil {
                return false
            }
            return true
        }

        func reconstructedString() -> String {
            (1...totalChunks)
                .compactMap { fragments[$0] }
                .joined()
        }
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.oswatch.companion", category: "BLEPacketReassembler")
    private let lock = NSLock()

    /// Keyed by central identifier string (or `"default"` when nil) so multiple centrals don't interleave
    private var buffersBySource: [String: ChunkBuffer] = [:]

    /// Stale buffer expiration interval (seconds) if a BLE connection drops mid-transfer
    private let staleBufferTimeout: TimeInterval

    // MARK: - Initialization

    init(staleBufferTimeout: TimeInterval = 10.0) {
        self.staleBufferTimeout = staleBufferTimeout
    }

    // MARK: - Public API

    /// Ingests raw `Data` written to characteristic `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`.
    /// - Parameters:
    ///   - data: Raw bytes from `CBATTRequest.value`
    ///   - sourceID: Optional `CBCentral.identifier.uuidString` to isolate buffers per central
    /// - Returns: A decoded `IncomingBLEPayload` when all chunks have arrived, or `nil` if waiting for remaining chunks.
    @discardableResult
    func ingest(data: Data, from sourceID: String = "default") throws -> IncomingBLEPayload? {
        guard let rawString = String(data: data, encoding: .utf8) else {
            throw BLEPayloadError.invalidUTF8
        }
        return try ingest(chunkString: rawString, from: sourceID)
    }

    /// Ingests a UTF-8 string chunk (`"1/3|..."`) or a complete unchunked JSON string (`"{...}"`).
    /// - Returns: Decoded `IncomingBLEPayload` once the final part is received, or `nil` while buffering intermediate chunks.
    @discardableResult
    func ingest(chunkString: String, from sourceID: String = "default") throws -> IncomingBLEPayload? {
        lock.lock()
        defer { lock.unlock() }

        purgeExpiredBuffersLocked(now: Date())

        let trimmed = chunkString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Fast-path: If Android sent a raw JSON object directly without a `<part>/<total>|` prefix
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") && !trimmed.contains("|") {
            logger.debug("Received unchunked complete JSON payload (\(trimmed.count) chars)")
            return try IncomingBLEPayload.decode(from: trimmed)
        }

        // Parse `<partIndex>/<totalParts>|<fragment>`
        guard let pipeIndex = chunkString.firstIndex(of: "|") else {
            // If there's no pipe delimiter, attempt to decode as raw JSON
            if trimmed.hasPrefix("{") {
                return try IncomingBLEPayload.decode(from: trimmed)
            }
            throw BLEPayloadError.malformedChunkHeader(chunkString)
        }

        let headerSubstring = chunkString[..<pipeIndex]
        let payloadStartIndex = chunkString.index(after: pipeIndex)
        let fragment = String(chunkString[payloadStartIndex...])

        let headerComponents = headerSubstring.split(separator: "/", omittingEmptySubsequences: false)
        guard
            headerComponents.count == 2,
            let partIndex = Int(headerComponents[0].trimmingCharacters(in: .whitespaces)),
            let totalParts = Int(headerComponents[1].trimmingCharacters(in: .whitespaces)),
            partIndex >= 1,
            totalParts >= 1,
            partIndex <= totalParts
        else {
            throw BLEPayloadError.malformedChunkHeader(String(headerSubstring))
        }

        // Single-chunk message (`1/1|{...}`)
        if totalParts == 1 {
            buffersBySource.removeValue(forKey: sourceID)
            logger.debug("Reassembled 1/1 packet (\(fragment.count) chars)")
            return try IncomingBLEPayload.decode(from: fragment)
        }

        let now = Date()
        var currentBuffer: ChunkBuffer

        if let existing = buffersBySource[sourceID] {
            // Reset buffer if a new packet sequence (`partIndex == 1`) arrives or `totalParts` changed
            if partIndex == 1 && existing.fragments[1] != nil {
                currentBuffer = ChunkBuffer(totalChunks: totalParts, fragments: [1: fragment], updatedAt: now)
            } else if existing.totalChunks != totalParts {
                currentBuffer = ChunkBuffer(totalChunks: totalParts, fragments: [partIndex: fragment], updatedAt: now)
            } else {
                currentBuffer = existing
                currentBuffer.fragments[partIndex] = fragment
                currentBuffer.updatedAt = now
            }
        } else {
            currentBuffer = ChunkBuffer(totalChunks: totalParts, fragments: [partIndex: fragment], updatedAt: now)
        }

        logger.debug("Buffered chunk \(partIndex)/\(totalParts) (\(currentBuffer.fragments.count)/\(totalParts) received)")

        if currentBuffer.isComplete {
            let fullJSON = currentBuffer.reconstructedString()
            buffersBySource.removeValue(forKey: sourceID)
            logger.info("Completed \(totalParts)-chunk JSON reassembly (\(fullJSON.count) bytes)")
            return try IncomingBLEPayload.decode(from: fullJSON)
        } else {
            buffersBySource[sourceID] = currentBuffer
            return nil
        }
    }

    /// Clears all partial chunk buffers.
    func resetAll() {
        lock.lock()
        defer { lock.unlock() }
        buffersBySource.removeAll()
    }

    /// Number of currently buffered chunks for a given source (useful for UI diagnostics/tests)
    func bufferedChunkCount(for sourceID: String = "default") -> Int {
        lock.lock()
        defer { lock.unlock() }
        return buffersBySource[sourceID]?.fragments.count ?? 0
    }

    // MARK: - Private Helpers

    private func purgeExpiredBuffersLocked(now: Date) {
        buffersBySource = buffersBySource.filter { _, buffer in
            now.timeIntervalSince(buffer.updatedAt) <= staleBufferTimeout
        }
    }
}
