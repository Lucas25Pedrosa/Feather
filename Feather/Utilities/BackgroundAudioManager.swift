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

	private let _engine = AVAudioEngine()
	private var _owners = Set<String>()
	private let _lock = NSLock()

	private init() {}

	func start(owner: String = "legacy") {
		_lock.lock()
		let shouldStart = _owners.isEmpty
		_owners.insert(owner)
		_lock.unlock()

		guard shouldStart else { return }

		do {
			let session = AVAudioSession.sharedInstance()
			try session.setCategory(.playback, options: [.mixWithOthers])
			try session.setActive(true)

			let silence = AVAudioSourceNode { _, _, _, audioBufferList -> OSStatus in
				let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
				for buffer in buffers {
					if let data = buffer.mData {
						memset(data, 0, Int(buffer.mDataByteSize))
					}
				}
				return noErr
			}

			_engine.attach(silence)
			_engine.connect(silence, to: _engine.mainMixerNode, format: nil)
			try _engine.start()
		} catch {
			_lock.lock()
			_owners.remove(owner)
			_lock.unlock()
			print("failed to start background audio:", error)
		}
	}

	func stop(owner: String = "legacy") {
		_lock.lock()
		_owners.remove(owner)
		let shouldStop = _owners.isEmpty
		_lock.unlock()

		guard shouldStop else { return }

		_engine.stop()
		try? AVAudioSession.sharedInstance().setActive(false)
	}
}

#endif
