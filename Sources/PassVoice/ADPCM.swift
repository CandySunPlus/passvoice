import Foundation

// IMA ADPCM frame format from the AI Passport BLE V1 protocol.
enum ADPCM {
    static let samplesPerFrame = 320
    static let sampleRate: Double = 16_000
    static let silence = [Int16](repeating: 0, count: samplesPerFrame)

    private static let steps = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
        50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209,
        230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
        876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499,
        2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845,
        8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350,
        22385, 24623, 27086, 29794, 32767,
    ]
    private static let indexChanges = [-1, -1, -1, -1, 2, 4, 6, 8]

    static func decode(_ data: Data) -> [Int16]? {
        let bytes = [UInt8](data)
        guard bytes.count == 166, Int(bytes[3]) | (Int(bytes[4]) << 8) == samplesPerFrame,
              bytes[2] < steps.count, bytes[5] == 0, bytes[165] & 0xf0 == 0 else { return nil }

        var predictor = Int(Int16(bitPattern: UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)))
        var stepIndex = Int(bytes[2])
        var samples = [Int16](repeating: 0, count: samplesPerFrame)
        samples[0] = Int16(predictor)
        for index in 0..<(samplesPerFrame - 1) {
            let byte = bytes[6 + index / 2]
            let code = Int(index.isMultiple(of: 2) ? byte & 0x0f : byte >> 4)
            let step = steps[stepIndex]
            var delta = step >> 3
            if code & 4 != 0 { delta += step }
            if code & 2 != 0 { delta += step >> 1 }
            if code & 1 != 0 { delta += step >> 2 }
            predictor += code & 8 != 0 ? -delta : delta
            samples[index + 1] = Int16(clamping: predictor)
            predictor = Int(samples[index + 1])
            stepIndex = min(88, max(0, stepIndex + indexChanges[code & 7]))
        }
        return samples
    }
}
