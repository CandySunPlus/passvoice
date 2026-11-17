import Foundation

struct SessionFrames {
    static let limit = 15_000
    private static let reorderWindow = 4
    private static let maximumMissing = 100

    private(set) var next = 0
    private(set) var missing = 0
    private var highest = -1
    private var pending: [Int: [Int16]] = [:]

    enum Failure: LocalizedError {
        case excessiveLoss
        case invalidFinalSequence

        var errorDescription: String? {
            switch self {
            case .excessiveLoss: return "Too many missing audio frames"
            case .invalidFinalSequence: return "Invalid final audio sequence"
            }
        }
    }

    mutating func insert(sequence: Int, samples: [Int16]) -> Bool {
        guard sequence >= next, sequence < Self.limit, pending[sequence] == nil else { return false }
        pending[sequence] = samples
        highest = max(highest, sequence)
        return true
    }

    mutating func flush(
        final: Int? = nil,
        force: Bool = false,
        enqueue: ([Int16]) throws -> Void
    ) throws {
        if let final, final >= Self.limit || final < next - 1 || final < highest {
            throw Failure.invalidFinalSequence
        }

        let last = final ?? highest
        while next <= last {
            if let samples = pending.removeValue(forKey: next) {
                try enqueue(samples)
            } else {
                let allowRecentGap = final == nil && next <= highest - Self.reorderWindow
                guard force || allowRecentGap else { break }
                guard missing < Self.maximumMissing else { throw Failure.excessiveLoss }
                try enqueue(ADPCM.silence)
                missing += 1
            }
            next += 1
        }
    }
}
