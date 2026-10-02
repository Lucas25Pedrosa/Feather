//
//  BackgroundAudioManager.swift
//  Feather
//
//  Shared silent-audio keep-alive with owner tracking.
//

#if !targetEnvironment(macCatalyst)

import AVFoundation

final class BackgroundAudioManager {
	static let shared = BackgroundAudioManager()

	private let engine = AVAudioEngine()
	private let lock = NSLock()
	private var owners = Set<String>()

	private lazy var silenceNode = AVAudioSourceNode { _, _, _, audioBufferList -> OSStatus in
		let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
		for buffer in buffers {
			if let data = buffer.mData {
				memset(data, 0, Int(buffer.mDataByteSize))
			}
		}
		return noErr
	}

	private init() {}

	func start(owner: String = "legacy") {
		lock.lock()
		let shouldStart = owners.isEmpty
		owners.insert(owner)
		lock.unlock()

		guard shouldStart, !engine.isRunning else { return }

		do {
			let session = AVAudioSession.sharedInstance()
			try session.setCategory(.playback, options: [.mixWithOthers])
			try session.setActive(true)

			if !engine.attachedNodes.contains(silenceNode) {
				engine.attach(silenceNode)
				engine.connect(
					silenceNode,
					to: engine.mainMixerNode,
					format: nil
				)
			}

			try engine.start()
		} catch {
			lock.lock()
			owners.remove(owner)
			lock.unlock()
			print("failed to start background audio:", error)
		}
	}

	func stop(owner: String = "legacy") {
		lock.lock()
		owners.remove(owner)
		let shouldStop = owners.isEmpty
		lock.unlock()

		guard shouldStop else { return }

		engine.stop()
		try? AVAudioSession.sharedInstance().setActive(false)
	}
}

#endif
