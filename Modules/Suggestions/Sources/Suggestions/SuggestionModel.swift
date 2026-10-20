//
//  SuggestionModel.swift
//  Suggestions
//
//  Created by Simon on 10/19/26.
//

import Foundation

/// Logistic regression over hashed sparse features, trained with SGD.
struct SuggestionModel: Sendable {

	private(set) var weights: [Float]
	private(set) var positiveCount = 0
	private(set) var negativeCount = 0

	static let minimumPositives = 20
	static let minimumNegatives = 50

	init(dimension: Int = FeatureExtractor.dimension) {
		weights = [Float](repeating: 0, count: dimension)
	}

	/// True once there’s enough history for predictions to mean something.
	var isReady: Bool {
		positiveCount >= Self.minimumPositives && negativeCount >= Self.minimumNegatives
	}

	func probability(_ features: [SparseFeature]) -> Float {
		Self.sigmoid(dot(features))
	}

	/// Retrains from scratch on all examples.
	///
	/// Positives and negatives are weighted so each class counts equally in total.
	/// Readers open a small fraction of what they see, and without balancing
	/// the model would learn to predict “not opened” for everything.
	mutating func train(_ examples: [(features: [SparseFeature], label: Bool, weight: Float)], epochs: Int = 8, learningRate: Float = 0.1, l2: Float = 1e-4, seed: UInt64 = 0x5EED) {
		weights = [Float](repeating: 0, count: weights.count)
		positiveCount = examples.count(where: { $0.label })
		negativeCount = examples.count - positiveCount

		guard positiveCount > 0, negativeCount > 0 else {
			return
		}

		let positiveWeightSum = examples.filter { $0.label }.reduce(Float(0)) { $0 + $1.weight }
		let negativeWeightSum = examples.filter { !$0.label }.reduce(Float(0)) { $0 + $1.weight }
		let total = positiveWeightSum + negativeWeightSum
		let positiveScale = total / (2 * positiveWeightSum)
		let negativeScale = total / (2 * negativeWeightSum)

		var generator = SplitMix64(seed: seed)
		var order = Array(examples.indices)

		for epoch in 0..<epochs {
			order.shuffle(using: &generator)
			let rate = learningRate / (1 + Float(epoch) * 0.5)

			for index in order {
				let example = examples[index]
				let target: Float = example.label ? 1 : 0
				let scale = example.weight * (example.label ? positiveScale : negativeScale)
				let gradient = (probability(example.features) - target) * scale

				for feature in example.features {
					let weight = weights[feature.index]
					weights[feature.index] = weight - rate * (gradient * feature.value + l2 * weight)
				}
			}
		}
	}

	// MARK: - Persistence

	private static let magic: UInt32 = 0x4E4E5753 // "NNWS"

	func serialized() -> Data {
		var data = Data()
		func append(_ value: UInt32) {
			withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
		}
		append(Self.magic)
		append(FeatureExtractor.version)
		append(UInt32(weights.count))
		append(UInt32(positiveCount))
		append(UInt32(negativeCount))
		weights.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
		return data
	}

	/// Returns nil if the data is from an incompatible version or is damaged.
	init?(data: Data) {
		let headerSize = 5 * MemoryLayout<UInt32>.size
		guard data.count >= headerSize else {
			return nil
		}

		func readUInt32(at offset: Int) -> UInt32 {
			var value: UInt32 = 0
			_ = withUnsafeMutableBytes(of: &value) { data.copyBytes(to: $0, from: (data.startIndex + offset)..<(data.startIndex + offset + 4)) }
			return UInt32(littleEndian: value)
		}

		guard readUInt32(at: 0) == Self.magic,
			  readUInt32(at: 4) == FeatureExtractor.version else {
			return nil
		}

		let count = Int(readUInt32(at: 8))
		guard count == FeatureExtractor.dimension, data.count == headerSize + count * MemoryLayout<Float>.size else {
			return nil
		}

		var weights = [Float](repeating: 0, count: count)
		_ = weights.withUnsafeMutableBytes { data.copyBytes(to: $0, from: (data.startIndex + headerSize)..<data.endIndex) }

		self.weights = weights
		self.positiveCount = Int(readUInt32(at: 12))
		self.negativeCount = Int(readUInt32(at: 16))
	}
}

private extension SuggestionModel {

	func dot(_ features: [SparseFeature]) -> Float {
		features.reduce(Float(0)) { $0 + weights[$1.index] * $1.value }
	}

	static func sigmoid(_ x: Float) -> Float {
		1 / (1 + exp(-x))
	}
}

/// Deterministic generator so training is reproducible.
struct SplitMix64: RandomNumberGenerator {

	private var state: UInt64

	init(seed: UInt64) {
		state = seed
	}

	mutating func next() -> UInt64 {
		state &+= 0x9E3779B97F4A7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
		z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
		return z ^ (z >> 31)
	}
}
