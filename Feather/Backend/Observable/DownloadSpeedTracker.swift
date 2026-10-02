//
//  DownloadSpeedTracker.swift
//  Feather
//

import Foundation

struct DownloadSpeedTracker {
	private static let minimumInterval: TimeInterval = 0.2
	private static let maximumRate: Double = 1_073_741_824

	private var lastBytes: Int64?
	private var lastDate: Date?
	private var smoothedRate: Double = 0

	mutating func sample(totalBytes: Int64, at date: Date = Date()) -> Int64 {
		guard let lastBytes, let lastDate, totalBytes >= lastBytes else {
			self.lastBytes = totalBytes
			self.lastDate = date
			return Int64(smoothedRate.rounded())
		}

		let elapsed = date.timeIntervalSince(lastDate)
		guard elapsed >= Self.minimumInterval else {
			return Int64(smoothedRate.rounded())
		}

		let instant = min(Double(totalBytes - lastBytes) / elapsed, Self.maximumRate)
		let factor = instant < smoothedRate ? 0.7 : 0.4
		smoothedRate = smoothedRate > 0
			? smoothedRate + factor * (instant - smoothedRate)
			: instant

		self.lastBytes = totalBytes
		self.lastDate = date
		return Int64(max(0, smoothedRate).rounded())
	}

	mutating func reset() {
		lastBytes = nil
		lastDate = nil
		smoothedRate = 0
	}
}
