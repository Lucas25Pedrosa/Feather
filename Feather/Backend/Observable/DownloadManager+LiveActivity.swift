//
//  DownloadManager+LiveActivity.swift
//  Feather
//

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import Foundation
import ActivityKit

extension DownloadManager {
	func refreshLiveActivity(force: Bool = false) {
		guard #available(iOS 16.2, *) else { return }
		guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

		let now = Date()
		if !force, now.timeIntervalSince(liveActivityUpdateTime) < 1.0 {
			return
		}
		liveActivityUpdateTime = now

		let unfinished = downloads.filter {
			!$0.onlyArchiving && $0.progress < 1 && ($0.isActive || $0.isPaused)
		}

		guard !unfinished.isEmpty else {
			if downloadActivity != nil {
				endLiveActivity()
			}
			return
		}

		let expected = unfinished.reduce(Int64(0)) { $0 + max(0, $1.totalBytes) }
		let received = unfinished.reduce(Int64(0)) { $0 + max(0, $1.bytesDownloaded) }

		let progress: Double
		if expected > 0 {
			progress = min(1, Double(received) / Double(expected))
		} else {
			progress = unfinished.map(\.progress).reduce(0, +) / Double(unfinished.count)
		}

		let paused = unfinished.allSatisfy(\.isPaused)
		let phase: DownloadPhase = paused ? .paused : .downloading
		let names = unfinished.map { String($0.fileName.prefix(24)) }

		let eta: Date?
		if currentDownloadSpeed > 0 && expected > received {
			eta = now.addingTimeInterval(
				Double(expected - received) / Double(currentDownloadSpeed)
			)
		} else {
			eta = nil
		}

		let state = DownloadActivityAttributes.ContentState(
			overallProgress: progress,
			appNames: names,
			totalBytesDownloaded: received,
			totalBytesExpected: expected,
			bytesPerSecond: paused ? 0 : currentDownloadSpeed,
			estimatedCompletionDate: paused ? nil : eta,
			phase: phase
		)

		if let activity = _downloadActivity {
			Task {
				await activity.update(
					ActivityContent(
						state: state,
						staleDate: now.addingTimeInterval(15)
					)
				)
			}
			return
		}

		guard !isCreatingLiveActivity else { return }
		isCreatingLiveActivity = true

		Task { @MainActor in
			defer { self.isCreatingLiveActivity = false }

			for activity in Activity<DownloadActivityAttributes>.activities {
				await activity.end(nil, dismissalPolicy: .immediate)
			}

			do {
				self._downloadActivity = try Activity.request(
					attributes: DownloadActivityAttributes(startTime: now),
					content: ActivityContent(
						state: state,
						staleDate: now.addingTimeInterval(15)
					),
					pushType: nil
				)
			} catch {
				self.downloadActivity = nil
			}
		}
	}

	func endLiveActivity() {
		guard #available(iOS 16.2, *), let activity = _downloadActivity else {
			downloadActivity = nil
			return
		}

		let old = activity.content.state
		let completed = DownloadActivityAttributes.ContentState(
			overallProgress: 1,
			appNames: old.appNames,
			totalBytesDownloaded: max(old.totalBytesDownloaded, old.totalBytesExpected),
			totalBytesExpected: max(old.totalBytesExpected, old.totalBytesDownloaded),
			bytesPerSecond: 0,
			estimatedCompletionDate: nil,
			phase: .completed
		)

		Task {
			await activity.end(
				ActivityContent(state: completed, staleDate: nil),
				dismissalPolicy: .after(Date().addingTimeInterval(8))
			)
			await MainActor.run {
				self.downloadActivity = nil
			}
		}
	}
}
#endif
