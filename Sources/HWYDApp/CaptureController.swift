import AVFoundation
import CoreAudio
import Foundation
import HWYDCore
import HWYDRealtime

struct CaptureFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
@MainActor final class CaptureController {
    private(set) var finalizationError: String?
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var ring: OpaquePointer?
    private var writer: AudioWriter?
    private var lockFD: Int32 = -1
    private var initialInput: AudioObjectID = 0
    private var initialOutput: AudioObjectID = 0
    /// Paused: the device is stopped, so neither the microphone nor system audio is captured.
    private(set) var isPaused = false
    var micLevel: Float { writer?.status().mic ?? 0 }
    var systemLevel: Float { writer?.status().system ?? 0 }
    var failure: String? {
        if let status = writer?.status() {
            if let error = status.error { return error }
            if !isPaused, let lastPacket = status.lastPacket, ProcessInfo.processInfo.systemUptime - lastPacket > 3 {
                return "Le périphérique ne fournit plus de données audio. La session a été arrêtée."
            }
        }
        if aggregate != 0 {
            if (try? scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, as: AudioObjectID.self)) != initialInput || (try? scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self)) != initialOutput {
                return "La route audio a changé. La session a été arrêtée pour préserver les pistes. Relancez une session avec le nouveau périphérique."
            }
        }
        return nil
    }
    func start(id: UUID, directory: URL) async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw CaptureFailure(message: "L’accès au micro est refusé. Autorisez HWYD dans Réglages Système > Confidentialité et sécurité > Microphone.") }
        lockFD = open(directory.appendingPathComponent("capture.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD); lockFD = -1 }
            throw CaptureFailure(message: "Une autre instance de HWYD enregistre déjà une session.")
        }
        do {
            initialInput = try scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, as: AudioObjectID.self)
            initialOutput = try scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self)
            guard initialInput != 0 else { throw CaptureFailure(message: "Aucun microphone disponible.") }
            let inputUID = try string(initialInput, kAudioDevicePropertyDeviceUID)
            let micStreams = try streams(initialInput)
            guard micStreams.count == 1 else { throw CaptureFailure(message: "Ce prototype prend en charge les microphones à un seul flux d’entrée. Sélectionnez le micro du Mac.") }
            let micFormat = try format(micStreams[0])
            let micChannels = micFormat.mChannelsPerFrame
            var processAddress = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            var pid = getpid(), process: AudioObjectID = 0, size = UInt32(MemoryLayout<AudioObjectID>.size)
            let processResult = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &processAddress, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process)
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: processResult == noErr && process != 0 ? [process] : [])
            description.name = "HWYD System Audio"; description.isPrivate = true; description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tap), "Création du tap audio système")
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "HWYD Capture",
                kAudioAggregateDeviceUIDKey: "dev.lepee.hwyd.capture.\(id.uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceMainSubDeviceKey: inputUID,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: inputUID]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
                // Do not wait for a tapped app to play: room conversations must start immediately.
                kAudioAggregateDeviceTapAutoStartKey: false
            ]
            try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "Création du périphérique agrégé")
            let aggregateStreams = try streams(aggregate)
            guard aggregateStreams.count == 2 else { throw CaptureFailure(message: "Le graphe audio n’expose pas les deux flux attendus. La capture est annulée, sans piste partielle.") }
            let formats = try aggregateStreams.map { try format($0) }
            // The explicitly ordered subdevice list precedes the tap. Verify its stream layout.
            let starts = try aggregateStreams.map { try scalar($0, kAudioStreamPropertyStartingChannel, as: UInt32.self) }
            try validateLayout(starts: starts, formats: formats, micChannels: micChannels, micName: (try? string(initialInput, kAudioObjectPropertyName)) ?? "le micro")
            guard let created = HWYDRingCreate(micChannels + 2) else { throw CaptureFailure(message: "Mémoire insuffisante pour préparer la capture.") }
            ring = created
            writer = try AudioWriter(ring: created, channels: Int(micChannels + 2), micChannels: Int(micChannels), sampleRate: formats[0].mSampleRate, id: id, directory: directory)
            try check(AudioDeviceCreateIOProcID(aggregate, HWYDIOProc, UnsafeMutableRawPointer(created), &ioProc), "Préparation de la capture")
            try check(AudioDeviceStart(aggregate, ioProc), "Démarrage de la capture")
            writer?.start()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while writer?.status().lastPacket == nil {
                if let error = writer?.status().error { throw CaptureFailure(message: error) }
                guard ContinuousClock.now < deadline else {
                    throw CaptureFailure(message: "Le périphérique audio a démarré mais aucun buffer n’est reçu. Vérifiez les permissions micro et audio système, puis réessayez.")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch { _ = stop(); throw error }
    }
    /// Stops the device without ending the session. Buffered audio is written first.
    /// The audio timeline skips the pause: chunks continue where the last frame ended.
    func pause() {
        guard !isPaused, let ioProc, aggregate != 0 else { return }
        AudioDeviceStop(aggregate, ioProc)
        writer?.pause()
        isPaused = true
    }
    func resume() throws {
        guard isPaused, let ioProc, aggregate != 0 else { return }
        writer?.resume()
        try check(AudioDeviceStart(aggregate, ioProc), "Reprise de la capture")
        isPaused = false
    }
    func stop() -> [AudioChunk] {
        if let ioProc, aggregate != 0 { AudioDeviceStop(aggregate, ioProc); AudioDeviceDestroyIOProcID(aggregate, ioProc) }
        ioProc = nil
        let chunks = writer?.finish() ?? []
        finalizationError = writer?.status().error
        writer = nil
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        if let ring { HWYDRingDestroy(ring); self.ring = nil }
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
        return chunks
    }
    /// Each check reports what it read, so a failure on another Mac can be diagnosed from the message alone.
    /// The ring buffer and the writer assume one interleaved frame and one sample rate for every track.
    private func validateLayout(starts: [UInt32], formats: [AudioStreamBasicDescription], micChannels: UInt32, micName: String) throws {
        let suffix = " Aucun enregistrement n’a démarré."
        guard micChannels + 2 <= 16 else {
            throw CaptureFailure(message: "\(micName) expose \(micChannels) canaux, au-delà des 16 canaux pris en charge.\(suffix)")
        }
        guard starts == [1, micChannels + 1] else {
            throw CaptureFailure(message: "Ordre des pistes inattendu : canaux de départ \(starts.map(String.init).joined(separator: ", ")), attendus 1, \(micChannels + 1).\(suffix)")
        }
        guard formats[0].mChannelsPerFrame == micChannels else {
            throw CaptureFailure(message: "\(micName) expose \(formats[0].mChannelsPerFrame) canaux dans le graphe audio, \(micChannels) attendus.\(suffix)")
        }
        guard formats[1].mChannelsPerFrame == 2 else {
            throw CaptureFailure(message: "L’audio système expose \(formats[1].mChannelsPerFrame) canaux, 2 attendus.\(suffix)")
        }
        for (label, format) in [(micName, formats[0]), ("L’audio système", formats[1])] {
            guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32, format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
                throw CaptureFailure(message: "\(label) fournit un format non pris en charge (\(fourCC(format.mFormatID)), \(format.mBitsPerChannel) bits), PCM flottant 32 bits attendu.\(suffix)")
            }
        }
        guard formats[0].mSampleRate == formats[1].mSampleRate else {
            throw CaptureFailure(message: "Fréquences différentes : \(micName) à \(hertz(formats[0].mSampleRate)), audio système à \(hertz(formats[1].mSampleRate)).\(suffix) Choisissez un autre micro ou alignez les fréquences dans Configuration audio et MIDI.")
        }
    }
    private func fourCC(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return bytes.allSatisfy({ (0x20...0x7E).contains($0) }) ? String(decoding: bytes, as: UTF8.self) : String(code)
    }
    private func hertz(_ rate: Float64) -> String { rate.rounded() == rate ? "\(Int(rate)) Hz" : "\(rate) Hz" }
    private func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw CaptureFailure(message: "\(operation) impossible (Core Audio \(status)). Vérifiez les permissions audio de HWYD dans Réglages Système.") }
    }
    private func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as type: T.Type) throws -> T {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        var prop = address(selector), size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &prop, 0, nil, &size, pointer), "Lecture de la configuration audio")
        return pointer.load(as: T.self)
    }
    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var prop = address(selector), size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<UnsafeRawPointer>.alignment)
        defer { storage.deallocate() }
        storage.storeBytes(of: Optional<UnsafeRawPointer>.none, as: Optional<UnsafeRawPointer>.self)
        try check(AudioObjectGetPropertyData(object, &prop, 0, nil, &size, storage), "Lecture du périphérique")
        guard let pointer = storage.load(as: Optional<UnsafeRawPointer>.self) else { throw CaptureFailure(message: "Identifiant audio manquant.") }
        return Unmanaged<CFString>.fromOpaque(pointer).takeRetainedValue() as String
    }
    private func streams(_ device: AudioObjectID) throws -> [AudioObjectID] {
        var prop = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput), size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &prop, 0, nil, &size), "Lecture des pistes")
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(device, &prop, 0, nil, &size, &result), "Lecture des pistes")
        return result
    }
    private func format(_ stream: AudioObjectID) throws -> AudioStreamBasicDescription { try scalar(stream, kAudioStreamPropertyVirtualFormat, as: AudioStreamBasicDescription.self) }
}

/// The writer and AVAudioFile instances are confined to one serial queue.
/// Only the status snapshot crosses queues, protected by statusLock.
private final class AudioWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.lepee.hwyd.audio-writer", qos: .userInitiated)
    private let statusLock = NSLock()
    private var state: (mic: Float, system: Float, error: String?, lastPacket: Double?) = (0, 0, nil, nil)
    private let ring: OpaquePointer
    private let channels: Int
    private let micChannels: Int
    private let sampleRate: Double
    private let directory: URL
    private let relativeDirectory: String
    private let samples: UnsafeMutablePointer<Float>
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converters: [AVAudioConverter]
    private var files: [AVAudioFile] = []
    private var timer: DispatchSourceTimer?
    private var chunks: [AudioChunk] = []
    private var outputFrames: Int64 = 0
    private var chunkFrames: Int64 = 0
    private var sequence = 0
    private let chunkLimit: Int64
    private var firstHostTime: UInt64?
    init(ring: OpaquePointer, channels: Int, micChannels: Int, sampleRate: Double, id: UUID, directory: URL, chunkSeconds: Double = 300) throws {
        chunkLimit = Int64(chunkSeconds * 16000)
        self.ring = ring; self.channels = channels; self.micChannels = micChannels; self.sampleRate = sampleRate
        relativeDirectory = "audio/\(id.uuidString.lowercased())"
        self.directory = directory.appendingPathComponent(relativeDirectory)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        samples = .allocate(capacity: 4096 * channels)
        inputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        converters = [AVAudioConverter(from: inputFormat, to: outputFormat)!, AVAudioConverter(from: inputFormat, to: outputFormat)!]
    }
    deinit { samples.deallocate() }
    func status() -> (mic: Float, system: Float, error: String?, lastPacket: Double?) { statusLock.lock(); defer { statusLock.unlock() }; return state }
    func start() {
        queue.sync {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(40))
            source.setEventHandler { [weak self] in self?.drain() }
            timer = source; source.resume()
        }
    }
    func finish() -> [AudioChunk] {
        queue.sync {
            timer?.cancel(); timer = nil
            drain()
            do { try seal() } catch { setError(error.localizedDescription) }
            return chunks
        }
    }
    /// Called after the device stopped: writes what the ring still holds and silences the meters.
    func pause() {
        queue.sync {
            drain()
            statusLock.lock(); state.mic = 0; state.system = 0; statusLock.unlock()
        }
    }
    /// Restarts the stall watchdog so the device has time to deliver its first buffer.
    func resume() {
        statusLock.lock(); state.lastPacket = ProcessInfo.processInfo.systemUptime; statusLock.unlock()
    }
    func consumeForTest() { queue.sync { drain() } }
    private func setError(_ message: String) { statusLock.lock(); state.error = message; statusLock.unlock() }
    private func drain() {
        guard status().error == nil else { return }
        if HWYDRingDropped(ring) > 0 { setError("La capture a perdu des buffers audio. La session est arrêtée pour éviter une désynchronisation silencieuse."); return }
        var host: UInt64 = 0
        while true {
            let frames = HWYDRingRead(ring, samples, &host)
            if frames == 0 { break }
            if firstHostTime == nil { firstHostTime = host }
            do {
                if files.isEmpty { try openFiles() }
                var converted: [AVAudioPCMBuffer] = []
                var levels: [Float] = []
                for source in 0..<2 {
                    let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames)!
                    input.frameLength = frames
                    let pointer = input.floatChannelData![0]
                    var peak: Float = 0
                    for f in 0..<Int(frames) {
                        let value: Float = source == 0 ? samples[f * channels] : (samples[f * channels + micChannels] + samples[f * channels + micChannels + 1]) * 0.5
                        pointer[f] = value; peak = max(peak, abs(value))
                    }
                    levels.append(min(1, peak * 3))
                    let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(ceil(Double(frames) * 16000 / sampleRate)) + 64)!
                    var supplied = false, error: NSError?
                    let result = converters[source].convert(to: output, error: &error) { _, status in
                        if supplied { status.pointee = .noDataNow; return nil }
                        supplied = true; status.pointee = .haveData; return input
                    }
                    if result == .error { throw error ?? CaptureFailure(message: "Conversion audio impossible.") as NSError }
                    converted.append(output)
                }
                guard converted[0].frameLength == converted[1].frameLength else { throw CaptureFailure(message: "Les deux pistes audio ne sont plus synchronisées.") }
                var offset = 0
                while offset < Int(converted[0].frameLength) {
                    if files.isEmpty { try openFiles() }
                    let count = min(Int(converted[0].frameLength) - offset, Int(chunkLimit - chunkFrames))
                    for i in 0..<2 {
                        let slice = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(count))!
                        slice.frameLength = AVAudioFrameCount(count)
                        slice.floatChannelData![0].update(from: converted[i].floatChannelData![0].advanced(by: offset), count: count)
                        try files[i].write(from: slice)
                    }
                    offset += count; chunkFrames += Int64(count); outputFrames += Int64(count)
                    if chunkFrames == chunkLimit { try seal(); sequence += 1 }
                }
                statusLock.lock(); state.mic = levels[0]; state.system = levels[1]; state.lastPacket = ProcessInfo.processInfo.systemUptime; statusLock.unlock()

            } catch { setError("Écriture audio interrompue : \(error.localizedDescription)"); return }
        }
    }
    private func openFiles() throws {
        let descriptor: [String: String] = ["sample_rate": "16000", "channels": "1", "start_frames": "\(outputFrames)", "host_time": "\(firstHostTime ?? 0)", "sequence": "\(sequence)"]
        try JSONEncoder().encode(descriptor).write(to: directory.appendingPathComponent(String(format: "%06d.json", sequence)), options: .atomic)
        files = try ["mic", "system"].map { source in
            try AVAudioFile(forWriting: directory.appendingPathComponent(String(format: "%@-%06d.partial.caf", source, sequence)), settings: outputFormat.settings)
        }
    }
    private func seal() throws {
        guard !files.isEmpty else { return }
        files.removeAll()
        for source in [AudioSource.mic, .system] {
            let name = String(format: "%@-%06d.caf", source.rawValue, sequence)
            let temporary = directory.appendingPathComponent(String(format: "%@-%06d.partial.caf", source.rawValue, sequence))
            let handle = try FileHandle(forWritingTo: temporary); try handle.synchronize(); try handle.close()
            try FileManager.default.moveItem(at: temporary, to: directory.appendingPathComponent(name))
            chunks.append(.init(source: source, relativePath: relativeDirectory + "/" + name, start: Double(outputFrames - chunkFrames) / 16000, duration: Double(chunkFrames) / 16000))
        }
        try JSONEncoder().encode(chunks).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        chunkFrames = 0
    }
}


extension CaptureController {
    static func verifySyntheticCapture(directory: URL, seconds: Double = 2) throws {
        let id = UUID()
        guard let ring = HWYDRingCreate(3) else { throw CaptureFailure(message: "Ring allocation") }
        defer { HWYDRingDestroy(ring) }
        let writer = try AudioWriter(ring: ring, channels: 3, micChannels: 1, sampleRate: 48000, id: id, directory: directory, chunkSeconds: seconds > 10 ? 300 : 0.5)
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: 480 * 3)
        defer { samples.deallocate() }
        for i in 0..<480 { samples[i * 3] = 0.2; samples[i * 3 + 1] = 0.6; samples[i * 3 + 2] = 0.6 }
        var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 3, mDataByteSize: UInt32(480 * 3 * 4), mData: samples))
        var time = AudioTimeStamp()
        for block in 0..<Int(seconds * 100) {
            time.mHostTime = UInt64(block * 10_000_000)
            var inputTime = time, outputTime = time
            withUnsafeMutablePointer(to: &input) { pointer in
                _ = HWYDIOProc(0, &time, pointer, &inputTime, pointer, &outputTime, UnsafeMutableRawPointer(ring))
            }
            writer.consumeForTest()
            // A pause mid-capture must not drop, duplicate or desynchronize frames.
            if block == Int(seconds * 50) { writer.pause(); writer.resume() }
        }
        let chunks = writer.finish()
        guard writer.status().error == nil, HWYDRingDropped(ring) == 0, chunks.count >= (seconds > 10 ? 2 : 6) else { throw CaptureFailure(message: "Synthetic capture failed: \(writer.status().error ?? "missing chunks")") }
        for source in [AudioSource.mic, .system] {
            let track = chunks.filter { $0.source == source }
            guard track.reduce(0, { $0 + $1.duration }) > seconds - 0.1 else { throw CaptureFailure(message: "Synthetic duration") }
            for chunk in track {
                let file = try AVAudioFile(forReading: directory.appendingPathComponent(chunk.relativePath))
                guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1, file.length > 0 else { throw CaptureFailure(message: "Invalid CAF format") }
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 64)!
                file.framePosition = file.length / 2
                try file.read(into: buffer)
                let middle = buffer.floatChannelData![0][Int(buffer.frameLength) / 2]
                let expected: Float = source == .mic ? 0.2 : 0.6
                guard abs(middle - expected) < 0.015 else { throw CaptureFailure(message: "Channels mixed: \(middle), expected \(expected)") }
            }
        }
    }
}
