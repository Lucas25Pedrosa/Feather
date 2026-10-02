//
//  DownloadProgressAttributes.swift
//  Feather
//

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import Foundation
import ActivityKit

enum DownloadPhase: String, Codable, Hashable {
	case downloading
	case paused
	case completed

	var icon: String {
		switch self {
		case .downloading: return "arrow.down"
		case .paused: return "pause.fill"
		case .completed: return "checkmark"
		}
	}
}

struct DownloadActivityAttributes: ActivityAttributes {
	struct ContentState: Codable, Hashable {
		var overallProgress: Double
		var appNames: [String]
		var totalBytesDownloaded: Int64
		var totalBytesExpected: Int64
		var bytesPerSecond: Int64
		var estimatedCompletionDate: Date?
		var phase: DownloadPhase
	}

	var startTime: Date
}
#endif
