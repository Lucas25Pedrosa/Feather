//
//  DownloadManager.swift
//  Feather
//
//  Background-download engine introduced in Feather 3.6.0.
//

import Foundation
import Combine
import UIKit
import BackgroundTasks
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

class Download: Identifiable, @unchecked Sendable {
	@Published var progress: Double = 0.0
	@Published var bytesDownloaded: Int64 = 0
	@Published var totalBytes: Int64 = 0
	@Published var unpackageProgress: Double = 0.0
	@Published var isActive: Bool = false
	@Published var isPaused: Bool = false

	var overallProgress: Double {
		onlyArchiving
			? unpackageProgress
			: (0.3 * unpackageProgress) + (0.7 * progress)
	}

	var task: URLSessionDownloadTask?
	var resumeData: Data?

	let id: String
	let url: URL
	let fileName: String
	let onlyArchiving: Bool
	var sourceProvenance: SourceAppProvenance?

	init(
		id: String,
		url: URL,
		onlyArchiving: Bool = false,
		sourceProvenance: SourceAppProvenance? = nil
	) {
		self.id = id
		self.url = url
		self.onlyArchiving = onlyArchiving
		self.sourceProvenance = sourceProvenance
		self.fileName = sourceProvenance?.sourceAppName ?? url.lastPathComponent
	}
}

class DownloadManager: NSObject, ObservableObject {
	static let shared = DownloadManager()

	@Published var downloads: [Download] = []
	@Published var currentDownloadSpeed: Int64 = 0

	var manualDownloads: [Download] {
		downloads.filter { isManualDownload($0.id) }
	}

	private struct BackgroundDownloadDescriptor: Codable {
		let id: String
		let sourceProvenance: SourceAppProvenance?
	}

	private var _networkSession: URLSession!
	private var _speedTracker = DownloadSpeedTracker()
	var backgroundCompletionHandler: (() -> Void)?

	#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
	var downloadActivity: Any?

	@available(iOS 16.2, *)
	var _downloadActivity: Activity<DownloadActivityAttributes>? {
		get { downloadActivity as? Activity<DownloadActivityAttributes> }
		set { downloadActivity = newValue }
	}

	var liveActivityUpdateTime = Date.distantPast
	var isCreatingLiveActivity = false
	#endif

	override init() {
		super.init()

		let queue = OperationQueue.main
		queue.maxConcurrentOperationCount = 1

		#if targetEnvironment(macCatalyst)
		let configuration = URLSessionConfiguration.default
		configuration.timeoutIntervalForRequest = 300
		configuration.timeoutIntervalForResource = 7200
		configuration.waitsForConnectivity = true
		_networkSession = URLSession(
			configuration: configuration,
			delegate: self,
			delegateQueue: queue
		)
		#else
		let bundleID = Bundle.main.bundleIdentifier ?? "com.feather.lucas"
		let configuration = URLSessionConfiguration.background(
			withIdentifier: "\(bundleID).downloads.background"
		)
		configuration.isDiscretionary = false
		configuration.sessionSendsLaunchEvents = true
		configuration.timeoutIntervalForRequest = 300
		configuration.timeoutIntervalForResource = 7200
		configuration.httpMaximumConnectionsPerHost = 8
		configuration.allowsExpensiveNetworkAccess = true
		configuration.allowsConstrainedNetworkAccess = true
		configuration.waitsForConnectivity = true
		_networkSession = URLSession(
			configuration: configuration,
			delegate: self,
			delegateQueue: queue
		)
		#endif

		_adoptExistingBackgroundTasks()
	}

	func startDownload(
		from url: URL,
		id: String = UUID().uuidString,
		sourceProvenance: SourceAppProvenance? = nil
	) -> Download {
		let requestHasSourceProvenance = sourceProvenance != nil
		if let existingDownload = downloads.first(where: {
			$0.url == url && ($0.sourceProvenance != nil) == requestHasSourceProvenance
		}) {
			resumeDownload(existingDownload)
			return existingDownload
		}

		let download = Download(
			id: id,
			url: url,
			sourceProvenance: sourceProvenance
		)
		download.isActive = true
		downloads.append(download)

		var request = URLRequest(url: url)
		request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
		request.timeoutInterval = 300
		request.allowsExpensiveNetworkAccess = true
		request.allowsConstrainedNetworkAccess = true

		let task = _networkSession.downloadTask(with: request)
		task.taskDescription = _encodedDescriptor(for: download)
		task.priority = URLSessionTask.highPriority
		download.task = task
		task.resume()

		#if !targetEnvironment(macCatalyst)
		if #available(iOS 26.0, *) {
			BackgroundTaskManager.shared.startTask(
				for: id,
				filename: download.fileName
			)
		} else {
			BackgroundAudioManager.shared.start(owner: "downloads")
		}
		#endif

		#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
		refreshLiveActivity(force: true)
		#endif

		return download
	}

	func startArchive(
		from url: URL,
		id: String = UUID().uuidString
	) -> Download {
		let download = Download(id: id, url: url, onlyArchiving: true)
		download.isActive = true
		downloads.append(download)

		#if !targetEnvironment(macCatalyst)
		if #unavailable(iOS 26.0) {
			BackgroundAudioManager.shared.start(owner: "downloads")
		}
		#endif

		return download
	}

	func resumeDownload(_ download: Download) {
		guard !download.onlyArchiving else { return }

		let task: URLSessionDownloadTask
		if let resumeData = download.resumeData {
			task = _networkSession.downloadTask(withResumeData: resumeData)
			download.resumeData = nil
		} else {
			var request = URLRequest(url: download.url)
			request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
			request.allowsExpensiveNetworkAccess = true
			request.allowsConstrainedNetworkAccess = true
			task = _networkSession.downloadTask(with: request)
		}

		task.taskDescription = _encodedDescriptor(for: download)
		task.priority = URLSessionTask.highPriority
		download.task = task
		download.isPaused = false
		download.isActive = true
		task.resume()

		#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
		refreshLiveActivity(force: true)
		#endif
	}

	func pauseDownload(_ download: Download) {
		guard let task = download.task else { return }

		download.isPaused = true
		download.isActive = false
		task.cancel { resumeData in
			DispatchQueue.main.async {
				download.resumeData = resumeData
			}
		}

		#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
		refreshLiveActivity(force: true)
		#endif
	}

	func cancelDownload(_ download: Download) {
		download.task?.cancel()
		download.isActive = false

		if let index = downloads.firstIndex(where: { $0.id == download.id }) {
			downloads.remove(at: index)
		}

		#if !targetEnvironment(macCatalyst)
		if #available(iOS 26.0, *) {
			BackgroundTaskManager.shared.stopTask(
				for: download.id,
				success: false
			)
		} else if downloads.allSatisfy({ !$0.isActive }) {
			BackgroundAudioManager.shared.stop(owner: "downloads")
		}
		#endif

		#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
		refreshLiveActivity(force: true)
		#endif
	}

	func isManualDownload(_ string: String) -> Bool {
		string.contains("FeatherManualDownload")
	}

	func getDownload(by id: String) -> Download? {
		downloads.first(where: { $0.id == id })
	}

	func getDownloadIndex(by id: String) -> Int? {
		downloads.firstIndex(where: { $0.id == id })
	}

	func getDownloadTask(by task: URLSessionDownloadTask) -> Download? {
		if let existing = downloads.first(where: {
			$0.task?.taskIdentifier == task.taskIdentifier
		}) {
			return existing
		}
		return _recoverDownload(for: task)
	}

	private func _encodedDescriptor(for download: Download) -> String? {
		let descriptor = BackgroundDownloadDescriptor(
			id: download.id,
			sourceProvenance: download.sourceProvenance
		)
		guard let data = try? JSONEncoder().encode(descriptor) else { return nil }
		return String(data: data, encoding: .utf8)
	}

	private func _descriptor(
		from task: URLSessionTask
	) -> BackgroundDownloadDescriptor? {
		guard
			let description = task.taskDescription,
			let data = description.data(using: .utf8)
		else {
			return nil
		}
		return try? JSONDecoder().decode(
			BackgroundDownloadDescriptor.self,
			from: data
		)
	}

	private func _recoverDownload(
		for task: URLSessionDownloadTask
	) -> Download? {
		guard let url = task.originalRequest?.url ?? task.currentRequest?.url else {
			return nil
		}

		let descriptor = _descriptor(from: task)
		let id = descriptor?.id ?? "FeatherRecovered_\(task.taskIdentifier)"

		if let existing = downloads.first(where: { $0.id == id }) {
			existing.task = task
			return existing
		}

		let download = Download(
			id: id,
			url: url,
			sourceProvenance: descriptor?.sourceProvenance
		)
		download.task = task
		download.isActive = task.state == .running
		download.isPaused = task.state == .suspended
		download.bytesDownloaded = max(0, task.countOfBytesReceived)

		if task.countOfBytesExpectedToReceive > 0 {
			download.totalBytes = task.countOfBytesExpectedToReceive
		} else {
			download.totalBytes =
				descriptor?.sourceProvenance?.sourceAppSize ?? 0
		}

		if download.totalBytes > 0 {
			download.progress = min(
				1,
				Double(download.bytesDownloaded) / Double(download.totalBytes)
			)
		}

		downloads.append(download)
		return download
	}

	private func _adoptExistingBackgroundTasks() {
		_networkSession.getAllTasks { [weak self] tasks in
			DispatchQueue.main.async {
				guard let self else { return }

				for case let task as URLSessionDownloadTask in tasks {
					_ = self._recoverDownload(for: task)
				}

				#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
				if !self.downloads.isEmpty {
					self.refreshLiveActivity(force: true)
				}
				#endif
			}
		}
	}

	private func _finish(_ download: Download, success: Bool) {
		download.isActive = false

		if let index = getDownloadIndex(by: download.id) {
			downloads.remove(at: index)
		}

		#if !targetEnvironment(macCatalyst)
		if #available(iOS 26.0, *) {
			BackgroundTaskManager.shared.stopTask(
				for: download.id,
				success: success
			)
		} else if downloads.allSatisfy({ !$0.isActive }) {
			BackgroundAudioManager.shared.stop(owner: "downloads")
		}
		#endif

		#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
		refreshLiveActivity(force: true)
		#endif
	}

	func handlePackageFile(url: URL, dl: Download) throws {
		FR.handlePackageFile(url, download: dl) { err in
			if err != nil {
				UINotificationFeedbackGenerator().notificationOccurred(.error)
			}

			DispatchQueue.main.async {
				if let error = err {
					if let jobID = UpdateEngineDownloadRoute.jobID(from: dl.id) {
						Task { @MainActor in
							UpdateEngineManager.shared.fail(
								jobID: jobID,
								error: error
							)
						}
					} else if let jobID = QuickInstallDownloadRoute.jobID(from: dl.id) {
						Task { @MainActor in
							QuickInstallManager.shared.fail(
								jobID: jobID,
								error: error
							)
						}
					}
				}

				self._finish(dl, success: err == nil)
			}
		}
	}
}

extension DownloadManager: URLSessionDownloadDelegate {
	func urlSession(
		_ session: URLSession,
		downloadTask: URLSessionDownloadTask,
		didFinishDownloadingTo location: URL
	) {
		guard let download = getDownloadTask(by: downloadTask) else { return }

		let customTempDir = FileManager.default.temporaryDirectory
			.appendingPathComponent("FeatherDownloads", isDirectory: true)

		do {
			try FileManager.default.createDirectoryIfNeeded(at: customTempDir)

			let suggestedFileName =
				downloadTask.response?.suggestedFilename
				?? download.url.lastPathComponent
			let destinationURL = customTempDir
				.appendingPathComponent(suggestedFileName)

			try FileManager.default.removeFileIfNeeded(at: destinationURL)
			try FileManager.default.moveItem(
				at: location,
				to: destinationURL
			)

			download.progress = 1
			download.bytesDownloaded = max(
				download.bytesDownloaded,
				download.totalBytes
			)

			#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
			refreshLiveActivity(force: true)
			#endif

			try handlePackageFile(url: destinationURL, dl: download)
		} catch {
			if let jobID = UpdateEngineDownloadRoute.jobID(from: download.id) {
				Task { @MainActor in
					UpdateEngineManager.shared.fail(
						jobID: jobID,
						error: error
					)
				}
			} else if let jobID = QuickInstallDownloadRoute.jobID(from: download.id) {
				Task { @MainActor in
					QuickInstallManager.shared.fail(
						jobID: jobID,
						error: error
					)
				}
			}

			_finish(download, success: false)
		}
	}

	func urlSession(
		_ session: URLSession,
		downloadTask: URLSessionDownloadTask,
		didWriteData bytesWritten: Int64,
		totalBytesWritten: Int64,
		totalBytesExpectedToWrite: Int64
	) {
		guard let download = getDownloadTask(by: downloadTask) else { return }

		let expectedBytes: Int64
		if totalBytesExpectedToWrite > 0 {
			expectedBytes = totalBytesExpectedToWrite
		} else if download.totalBytes > 0 {
			expectedBytes = download.totalBytes
		} else {
			// Google Drive and other hosts can omit Content-Length.
			expectedBytes = download.sourceProvenance?.sourceAppSize ?? 0
		}

		download.bytesDownloaded = totalBytesWritten
		download.totalBytes = expectedBytes
		download.progress = expectedBytes > 0
			? min(1, Double(totalBytesWritten) / Double(expectedBytes))
			: 0
		download.isActive = true

		let totalReceived = downloads.reduce(Int64(0)) {
			$0 + $1.bytesDownloaded
		}
		currentDownloadSpeed = _speedTracker.sample(
			totalBytes: totalReceived
		)

		#if !targetEnvironment(macCatalyst)
		if #available(iOS 26.0, *) {
			BackgroundTaskManager.shared.updateProgress(
				for: download.id,
				progress: download.overallProgress
			)
		}
		#endif

		#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
		refreshLiveActivity()
		#endif
	}

	func urlSession(
		_ session: URLSession,
		task: URLSessionTask,
		didCompleteWithError error: Error?
	) {
		guard
			let error,
			let downloadTask = task as? URLSessionDownloadTask,
			let download = getDownloadTask(by: downloadTask)
		else {
			return
		}

		if download.isPaused {
			return
		}

		if let jobID = UpdateEngineDownloadRoute.jobID(from: download.id) {
			Task { @MainActor in
				UpdateEngineManager.shared.fail(
					jobID: jobID,
					error: error
				)
			}
		} else if let jobID = QuickInstallDownloadRoute.jobID(from: download.id) {
			Task { @MainActor in
				QuickInstallManager.shared.fail(
					jobID: jobID,
					error: error
				)
			}
		}

		_finish(download, success: false)
	}

	func urlSessionDidFinishEvents(
		forBackgroundURLSession session: URLSession
	) {
		DispatchQueue.main.async {
			self.backgroundCompletionHandler?()
			self.backgroundCompletionHandler = nil
		}
	}
}
