import AVFoundation
import CoreAudio
import Foundation

/// An audio input device (Core Audio), for Settings › Listen To.
struct InputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let channels: Int

    /// Every device with at least one input channel.
    static func all() -> [InputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let ch = inputChannels(id)
            guard ch > 0, let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return InputDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid, channels: ch)
        }
    }

    static func deviceID(uid: String) -> AudioDeviceID? { all().first { $0.uid == uid }?.id }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }
}

/// Mono mixing and resampling to the analyzer's 44.1 kHz.
enum PCM {
    /// Channel `channel` (1-based) of a deinterleaved buffer, or all channels averaged (0, or a
    /// channel the device doesn't have).
    static func mono(_ channels: [UnsafeBufferPointer<Float>], channel: Int) -> [Float] {
        guard let first = channels.first else { return [] }
        if channel >= 1 && channel <= channels.count { return Array(channels[channel - 1]) }
        if channels.count == 1 { return Array(first) }
        let n = channels.map(\.count).min() ?? 0
        var out = [Float](repeating: 0, count: n)
        let scale = 1 / Float(channels.count)
        for c in channels { for i in 0..<n { out[i] += c[i] * scale } }
        return out
    }

    static func mono(_ buffer: AVAudioPCMBuffer, channel: Int) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        let fmt = buffer.format
        if fmt.isInterleaved {
            let ch = Int(fmt.channelCount)
            let all = UnsafeBufferPointer(start: data[0], count: frames * ch)
            if channel >= 1 && channel <= ch { return stride(from: channel - 1, to: all.count, by: ch).map { all[$0] } }
            return (0..<frames).map { f in (0..<ch).reduce(Float(0)) { $0 + all[f * ch + $1] } / Float(ch) }
        }
        let chans = (0..<Int(fmt.channelCount)).map { UnsafeBufferPointer(start: data[$0], count: frames) }
        return mono(chans, channel: channel)
    }
}

/// Mono float32 at any rate -> 44.1 kHz (AVAudioConverter keeps its filter state between calls,
/// so the pieces join without clicks). Pass-through when the rate already matches.
final class Resampler {
    private let converter: AVAudioConverter?
    private let inFormat: AVAudioFormat
    private let outFormat: AVAudioFormat

    init?(from rate: Double, to target: Double = Double(LiveProcess.sampleRate)) {
        guard let i = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let o = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: target, channels: 1, interleaved: false)
        else { return nil }
        inFormat = i; outFormat = o
        converter = rate == target ? nil : AVAudioConverter(from: i, to: o)
        if rate != target && converter == nil { return nil }
    }

    func process(_ samples: [Float]) -> [Float] {
        guard let conv = converter, !samples.isEmpty else { return samples }
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return [] }
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let cap = AVAudioFrameCount(Double(samples.count) * outFormat.sampleRate / inFormat.sampleRate) + 64
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return [] }
        var fed = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return inBuf
        }
        guard err == nil, let d = outBuf.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: d[0], count: Int(outBuf.frameLength)))
    }
}

/// What to do after an input's engine stopped or changed format while Listen was on (the device
/// dropped out, or its format changed). Pure; InputCapture follows it. Event-driven and bounded:
/// one restart right away, one more after `retryDelay`, then the capture reports the input gone
/// (LiveController falls back to Mac audio). Never an open-ended loop, never a timer that polls.
enum InputRecovery: Equatable {
    case restarted
    case retry(after: TimeInterval)
    case giveUp

    static let maxAttempts = 2
    static let retryDelay: TimeInterval = 1

    /// `attempt` = 1 for the restart made right away, 2 for the retry; `ok` = it came back.
    static func next(attempt: Int, ok: Bool) -> InputRecovery {
        if ok { return .restarted }
        return attempt < maxAttempts ? .retry(after: retryDelay) : .giveUp
    }

    /// A config change needs a restart when the engine stopped, or kept running with another
    /// format than the tap was made for (the resampler would be wrong). Not otherwise: our own
    /// restart must never cause another one.
    static func needsRestart(engineRunning: Bool, tapRate: Double, tapChannels: Int,
                             nowRate: Double, nowChannels: Int) -> Bool {
        !engineRunning || tapRate != nowRate || tapChannels != nowChannels
    }
}

/// A mid-listen drop of the capture's source, reported to the controller. Not an error: the
/// controller shows a calm notice, or falls back to Mac audio (LiveSourcePlan).
enum CaptureDrop: Equatable {
    /// The restart didn't take at once; one more try is coming. The LCD says it is waiting for music.
    case waiting
    /// Nothing more to try on this input (`why` = for the log).
    case gone(why: String)
}

/// The mic or any input device (and one of its channels) through AVAudioEngine. Asks for
/// microphone access first (NSMicrophoneUsageDescription). Nothing is recorded: each tap buffer is
/// mixed to mono, resampled and handed on. When the device drops out or changes format
/// (AVAudioEngineConfigurationChange) it restarts itself on the same device (InputRecovery).
final class InputCapture: AudioCapture {
    let deviceUID: String?
    let channel: Int
    var onDrop: ((CaptureDrop) -> Void)?
    private let engine = AVAudioEngine()
    private var running = false
    private var configObserver: NSObjectProtocol?
    private var sink: (([Float]) -> Void)?
    private var tapRate = 0.0
    private var tapChannels = 0

    static let deniedText = "ALLOW MICROPHONE ACCESS IN SYSTEM SETTINGS › PRIVACY & SECURITY › MICROPHONE"

    init(deviceUID: String?, channel: Int) {
        self.deviceUID = deviceUID
        self.channel = channel
    }

    func start(onSamples: @escaping ([Float]) -> Void, onError: @escaping (String) -> Void) {
        switch SystemPermissions.shared.state(.microphone) {
        case .granted:
            begin(onSamples, onError)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async {
                    if ok { self.begin(onSamples, onError); return }
                    AppLog.log("input capture: microphone refused at the system prompt; opening the permission guide")
                    PermissionGuide.shared.need(.microphone, why: "Listen on an input")
                    onError(InputCapture.deniedText)
                }
            }
        case .denied:
            AppLog.log("input capture: microphone not allowed; opening the permission guide")
            PermissionGuide.shared.need(.microphone, why: "Listen on an input")
            onError(InputCapture.deniedText)
        }
    }

    private func begin(_ onSamples: @escaping ([Float]) -> Void, _ onError: @escaping (String) -> Void) {
        sink = onSamples
        if let why = openEngine() { onError(why); return }
        running = true
        // Unplugged, or its format changed: AVAudioEngine stops by itself. Not an error: restart
        // on the same device; if it won't come back, the controller falls back to Mac audio.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.configChanged()
        }
    }

    /// Points the engine at the device, taps it and starts it. nil = running; else the LCD sentence
    /// for why not (everything is logged). Used at the start and again to restart after a change.
    private func openEngine() -> String? {
        let input = engine.inputNode
        if let uid = deviceUID {
            guard var id = InputDevice.deviceID(uid: uid), let unit = input.audioUnit else {
                AppLog.log("input capture: device uid \(uid) not connected (or no audio unit)")
                return "THAT INPUT IS NOT CONNECTED · PICK ANOTHER IN SETTINGS"
            }
            let st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard st == noErr else {
                AppLog.log("input capture: AudioUnitSetProperty(CurrentDevice) for uid \(uid) failed, OSStatus \(st)")
                return "COULDN'T OPEN THAT INPUT (\(st))"
            }
        }
        let fmt = input.inputFormat(forBus: 0)
        guard fmt.channelCount > 0, fmt.sampleRate > 0, let resampler = Resampler(from: fmt.sampleRate) else {
            AppLog.log("input capture: no usable input format (\(fmt.channelCount) ch, \(fmt.sampleRate) Hz)")
            return "NO AUDIO INPUT FOUND"
        }
        let ch = channel
        let out = sink
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { buf, _ in
            out?(resampler.process(PCM.mono(buf, channel: ch)))
        }
        engine.prepare()
        do {
            try engine.start()
            tapRate = fmt.sampleRate; tapChannels = Int(fmt.channelCount)
            return nil
        } catch {
            input.removeTap(onBus: 0)
            AppLog.log("input capture: engine start failed: \(error)")
            return "COULDN'T START THE INPUT: \(error.localizedDescription.uppercased())"
        }
    }

    private var deviceLabel: String {
        deviceUID.map { u in InputDevice.all().first { $0.uid == u }?.name ?? u } ?? "the default input"
    }

    private func configChanged() {
        guard running else { return }
        let fmt = engine.inputNode.inputFormat(forBus: 0)
        AppLog.log("input capture: audio configuration changed (device dropped out or its format changed); engine running \(engine.isRunning); format \(fmt.channelCount) ch \(fmt.sampleRate) Hz (was \(tapChannels) ch \(tapRate) Hz)")
        guard InputRecovery.needsRestart(engineRunning: engine.isRunning, tapRate: tapRate, tapChannels: tapChannels,
                                         nowRate: fmt.sampleRate, nowChannels: Int(fmt.channelCount)) else {
            AppLog.log("input capture: config change -> engine still running on the same format; left alone")
            return
        }
        recover(attempt: 1)
    }

    /// Restart on the same device (the engine stopped, or needs the new format). A failure waits
    /// `InputRecovery.retryDelay` and tries once more, then gives the input up (`onDrop(.gone)`).
    private func recover(attempt: Int) {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let failure = openEngine()
        switch InputRecovery.next(attempt: attempt, ok: failure == nil) {
        case .restarted:
            AppLog.log("input capture: config change -> restarted on \(deviceLabel) (attempt \(attempt))")
        case .retry(let after):
            AppLog.log("input capture: config change -> restart on \(deviceLabel) failed (\(failure ?? "?")); trying once more in \(after) s")
            if attempt == 1 { onDrop?(.waiting) }
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
                self?.recover(attempt: attempt + 1)
            }
        case .giveUp:
            AppLog.log("input capture: config change -> failed: \(failure ?? "?")")
            onDrop?(.gone(why: failure ?? "restart failed"))
        }
    }

    /// The error when nothing at all can capture after a drop (no Mac audio to fall back to).
    static let lostText = "THE INPUT WENT AWAY · CHECK IT AND START LISTENING AGAIN"

    func stop() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
