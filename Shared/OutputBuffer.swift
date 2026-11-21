import Foundation

final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int

    init(limit: Int = 65_536) { self.limit = limit }

    func append(_ chunk: Data) {
        lock.withLock {
            if data.count < limit { data.append(chunk.prefix(limit - data.count)) }
        }
    }

    var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
