import Foundation
import os.log

/// Reassembled BLE result containing both the reconstructed UTF-8 JSON string (for on-screen debug logging)
/// and the decoded `IncomingBLEPayload`.
struct ReassembledBLEPacket: Equatable {
    let jsonString: String
    let payload: IncomingBLEPayload
}

/// Reassembles multi-part BLE write chunks formatted as `<index>/<total>|<payloadFragment>`
/// (both 1-indexed `1/3|...` and 0-indexed `0/3|...`), as well as raw unchunked or MTU-split JSON packets,
/// into a complete UTF-8 JSON string and decodes it into `IncomingBLEPayload`.
final class BLEPacketReassembler {

    // MARK: - Nested Types

    private struct ChunkBuffer {
        let totalChunks: Int
        var isZeroIndexed: Bool
        var fragments: [Int: String]
        var updatedAt: Date

        var expectedIndices: ClosedRange<Int> {
            isZeroIndexed ? (0...(totalChunks - 1)) : (1...totalChunks)
        }

        var isComplete: Bool {
            guard totalChunks > 0 && fragments.count == totalChunks else { return false }
            for idx in expectedIndices where fragments[idx] == nil {
                return false
            }
            return true
        }

        func reconstructedString() -> String {
            expectedIndices
                .compactMap { fragments[$0] }
                .joined()
        }
    }

    private struct RawJSONStreamBuffer {
        var accumulated: String
        var updatedAt: Date
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.oswatch.companion", category: "BLEPacketReassembler")
    private let lock = NSLock()

    /// Keyed by central identifier string (or `"default"`) so multiple centrals don't interleave
    private var buffersBySource: [String: ChunkBuffer] = [:]
    private var rawStreamsBySource: [String: RawJSONStreamBuffer] = [:]

    /// Stale buffer expiration interval (seconds) if a BLE connection drops mid-transfer
    private let staleBufferTimeout: TimeInterval

    // MARK: - Initialization

    init(staleBufferTimeout: TimeInterval = 10.0) {
        self.staleBufferTimeout = staleBufferTimeout
    }

    // MARK: - Public API

    /// Ingests raw `Data` written to characteristic `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` and returns both the
    /// reconstructed JSON string and the decoded `IncomingBLEPayload` when all parts have arrived.
    @discardableResult
    func ingestPacket(data: Data, from sourceID: String = "default") throws -> ReassembledBLEPacket? {
        let rawString = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\0", with: "")
        return try ingestPacket(chunkString: rawString, from: sourceID)
    }

    /// Ingests a UTF-8 string chunk (`"1/3|..."`, `"0/3|..."`, or raw JSON) and returns a `ReassembledBLEPacket` once complete.
    @discardableResult
    func ingestPacket(chunkString: String, from sourceID: String = "default") throws -> ReassembledBLEPacket? {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        purgeExpiredBuffersLocked(now: now)

        let cleaned = chunkString.replacingOccurrences(of: "\0", with: "")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. Check if packet has a `<partIndex>/<totalParts>|<fragment>` header before the first `{`
        if let pipeIndex = cleaned.firstIndex(of: "|") {
            let headerCandidate = String(cleaned[..<pipeIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let headerComponents = headerCandidate.split(separator: "/", omittingEmptySubsequences: false)

            if headerComponents.count == 2,
               let partIndex = Int(headerComponents[0].trimmingCharacters(in: .whitespaces)),
               let totalParts = Int(headerComponents[1].trimmingCharacters(in: .whitespaces)),
               totalParts >= 1,
               partIndex >= 0,
               partIndex <= totalParts {

                let payloadStartIndex = cleaned.index(after: pipeIndex)
                let fragment = String(cleaned[payloadStartIndex...])

                // Single-chunk message (`1/1|{...}` or `0/1|{...}`)
                if totalParts == 1 {
                    buffersBySource.removeValue(forKey: sourceID)
                    rawStreamsBySource.removeValue(forKey: sourceID)
                    let payload = try IncomingBLEPayload.decode(from: fragment)
                    return ReassembledBLEPacket(jsonString: fragment, payload: payload)
                }

                let isZeroIndexed = (partIndex == 0)
                var currentBuffer: ChunkBuffer

                if let existing = buffersBySource[sourceID] {
                    let effectiveZeroIndexed = existing.isZeroIndexed || isZeroIndexed
                    let isRestart = (effectiveZeroIndexed && partIndex == 0 && existing.fragments[0] != nil) ||
                                    (!effectiveZeroIndexed && partIndex == 1 && existing.fragments[1] != nil)

                    if isRestart || existing.totalChunks != totalParts {
                        currentBuffer = ChunkBuffer(
                            totalChunks: totalParts,
                            isZeroIndexed: isZeroIndexed,
                            fragments: [partIndex: fragment],
                            updatedAt: now
                        )
                    } else {
                        currentBuffer = existing
                        if isZeroIndexed {
                            currentBuffer.isZeroIndexed = true
                        }
                        currentBuffer.fragments[partIndex] = fragment
                        currentBuffer.updatedAt = now
                    }
                } else {
                    currentBuffer = ChunkBuffer(
                        totalChunks: totalParts,
                        isZeroIndexed: isZeroIndexed,
                        fragments: [partIndex: fragment],
                        updatedAt: now
                    )
                }

                logger.debug("Buffered chunk \(partIndex)/\(totalParts) (\(currentBuffer.fragments.count)/\(totalParts) received)")

                if currentBuffer.isComplete {
                    let fullJSON = currentBuffer.reconstructedString()
                    buffersBySource.removeValue(forKey: sourceID)
                    logger.info("Completed \(totalParts)-chunk JSON reassembly (\(fullJSON.count) bytes)")
                    let payload = try IncomingBLEPayload.decode(from: fullJSON)
                    return ReassembledBLEPacket(jsonString: fullJSON, payload: payload)
                } else {
                    buffersBySource[sourceID] = currentBuffer
                    return nil
                }
            }
        }

        // 2. Fast-path: Complete unchunked JSON object in a single BLE write (`{...}`)
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") && Self.hasBalancedJSONBraces(trimmed) {
            rawStreamsBySource.removeValue(forKey: sourceID)
            let payload = try IncomingBLEPayload.decode(from: trimmed)
            return ReassembledBLEPacket(jsonString: trimmed, payload: payload)
        }

        // 3. Multi-packet MTU-split raw JSON stream (without `<part>/<total>|` headers)
        if trimmed.hasPrefix("{") {
            rawStreamsBySource[sourceID] = RawJSONStreamBuffer(accumulated: cleaned, updatedAt: now)
        } else if var existingRaw = rawStreamsBySource[sourceID] {
            existingRaw.accumulated += cleaned
            existingRaw.updatedAt = now
            rawStreamsBySource[sourceID] = existingRaw
        } else {
            throw BLEPayloadError.malformedChunkHeader(trimmed)
        }

        if let bufferedRaw = rawStreamsBySource[sourceID]?.accumulated.trimmingCharacters(in: .whitespacesAndNewlines),
           bufferedRaw.hasPrefix("{"),
           bufferedRaw.hasSuffix("}"),
           Self.hasBalancedJSONBraces(bufferedRaw) {
            rawStreamsBySource.removeValue(forKey: sourceID)
            let payload = try IncomingBLEPayload.decode(from: bufferedRaw)
            return ReassembledBLEPacket(jsonString: bufferedRaw, payload: payload)
        }

        return nil
    }

    /// Backwards-compatible convenience method returning `IncomingBLEPayload?`
    @discardableResult
    func ingest(data: Data, from sourceID: String = "default") throws -> IncomingBLEPayload? {
        try ingestPacket(data: data, from: sourceID)?.payload
    }

    /// Backwards-compatible convenience method returning `IncomingBLEPayload?`
    @discardableResult
    func ingest(chunkString: String, from sourceID: String = "default") throws -> IncomingBLEPayload? {
        try ingestPacket(chunkString: chunkString, from: sourceID)?.payload
    }

    /// Clears all partial chunk buffers.
    func resetAll() {
        lock.lock()
        defer { lock.unlock() }
        buffersBySource.removeAll()
        rawStreamsBySource.removeAll()
    }

    /// Number of currently buffered chunks for a given source (useful for UI diagnostics/tests)
    func bufferedChunkCount(for sourceID: String = "default") -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let count = buffersBySource[sourceID]?.fragments.count, count > 0 {
            return count
        }
        return rawStreamsBySource[sourceID] != nil ? 1 : 0
    }

    // MARK: - Private Helpers

    private static func hasBalancedJSONBraces(_ text: String) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false

        for char in text {
            if escaped {
                escaped = false
                continue
            }
            if char == "\\" && inString {
                escaped = true
                continue
            }
            if char == "\"" {
                inString.toggle()
                continue
            }
            if !inString {
                if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth < 0 { return false }
                }
            }
        }
        return depth == 0 && text.contains("{")
    }

    private func purgeExpiredBuffersLocked(now: Date) {
        buffersBySource = buffersBySource.filter { _, buffer in
            now.timeIntervalSince(buffer.updatedAt) <= staleBufferTimeout
        }
        rawStreamsBySource = rawStreamsBySource.filter { _, stream in
            now.timeIntervalSince(stream.updatedAt) <= staleBufferTimeout
        }
    }
}
