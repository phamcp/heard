// heard-tap: the macOS stand-in for `parec` used by heard-daemon.
//
//   heard-tap default-output          print the UID of the current default output device
//   heard-tap default-input           print the UID of the current default input device
//   heard-tap list                    list audio devices (UID, name, input/output channels)
//   heard-tap them [output-UID]       capture what is played to that output (default: the default output)
//   heard-tap me [input-UID]          capture that microphone (default: the default input)
//   heard-tap supervise CMD [ARGS…]   run CMD as a child; used by the launchd agent (see below)
//
// `them` and `me` write raw 16 kHz mono signed 16-bit little-endian PCM to stdout until they are
// terminated, exactly what heard-daemon read from parec on Linux.
//
// "them" is a Core Audio process tap (macOS 14.2+): a read-only mixdown of every process's audio on its
// way to the output device. Nothing is rerouted, no virtual audio device is installed, and the tap is
// private (it does not show up in Audio MIDI Setup). "me" reads the input device directly through the HAL.
// Both need a one-time permission: System Settings → Privacy & Security → Microphone, and
// Screen & System Audio Recording → "System Audio Recording Only".
//
// `supervise` exists because macOS attributes privacy permissions to the process launchd started and
// everything under it. With `heard-tap supervise heard-daemon` as the agent's command, the prompts and
// the grants belong to heard-tap, not to `uv` or `python`.

import AVFoundation
import CoreAudio
import Foundation

let outputSampleRate = 16000.0
let watchdogSeconds = 5.0
let system = AudioObjectID(kAudioObjectSystemObject)

func warn(_ message: String) {
    FileHandle.standardError.write(("heard-tap: " + message + "\n").data(using: .utf8)!)
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    warn(message)
    exit(code)
}

func check(_ status: OSStatus, _ what: String) {
    if status != noErr {
        fail("\(what) failed (OSStatus \(status))")
    }
}

func propertyAddress(_ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ initial: T) -> T {
    var address = propertyAddress(selector, scope)
    var size = UInt32(MemoryLayout<T>.size)
    var value = initial
    check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "reading property \(selector) of object \(object)")
    return value
}

func propertyArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ zero: T) -> [T] {
    var address = propertyAddress(selector, scope)
    var size: UInt32 = 0
    check(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "sizing property \(selector) of object \(object)")
    var values = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.size)
    if values.isEmpty { return values }
    check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &values), "reading property \(selector) of object \(object)")
    return values
}

func propertyString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var address = propertyAddress(selector)
    var size = UInt32(MemoryLayout<CFString>.size)
    var value: CFString = "" as CFString
    check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "reading string \(selector) of object \(object)")
    return value as String
}

func deviceUID(_ device: AudioObjectID) -> String { propertyString(device, kAudioDevicePropertyDeviceUID) }
func deviceName(_ device: AudioObjectID) -> String { propertyString(device, kAudioObjectPropertyName) }

func allDevices() -> [AudioObjectID] {
    propertyArray(system, kAudioHardwarePropertyDevices, AudioObjectID(0))
}

func channelCount(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
    var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let list = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
    defer { list.deallocate() }
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, list) == noErr else { return 0 }
    return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
}

func inputStreams(_ device: AudioObjectID) -> [AudioStreamID] {
    propertyArray(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, AudioStreamID(0))
}

func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
    let device = property(system, selector, AudioObjectID(kAudioObjectUnknown))
    if device == kAudioObjectUnknown { fail("no default device") }
    return device
}

func findDevice(withUID uid: String, scope: AudioObjectPropertyScope) -> AudioObjectID {
    for device in allDevices() where deviceUID(device) == uid {
        if channelCount(device, scope) == 0 {
            fail("device \(uid) has no \(scope == kAudioObjectPropertyScopeInput ? "input" : "output") channels")
        }
        return device
    }
    fail("no audio device with UID \(uid) (see `heard-tap list`)")
}

func requireFloat32Streams(_ device: AudioObjectID) {
    for stream in inputStreams(device) {
        let format = property(stream, kAudioStreamPropertyVirtualFormat, AudioStreamBasicDescription())
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        if format.mFormatID != kAudioFormatLinearPCM || !isFloat || format.mBitsPerChannel != 32 {
            fail("input stream \(stream) is not 32-bit float PCM; cannot capture it")
        }
    }
}

// MARK: - Resampling to 16 kHz mono s16le on stdout

final class Emitter {
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let inputRate: Double
    private let queue = DispatchQueue(label: "heard-tap.emitter")

    init(inputRate: Double) {
        self.inputRate = inputRate
        inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false)!
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: outputSampleRate, channels: 1, interleaved: true)!
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            fail("cannot convert \(inputRate) Hz audio to \(outputSampleRate) Hz")
        }
        self.converter = converter
    }

    /// Called on the HAL's I/O thread: copy out and leave quickly.
    func push(_ mono: [Float]) {
        queue.async { self.emit(mono) }
    }

    private func emit(_ mono: [Float]) {
        let frames = AVAudioFrameCount(mono.count)
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames) else { return }
        input.frameLength = frames
        mono.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }
        let capacity = AVAudioFrameCount(Double(mono.count) * outputSampleRate / inputRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            fail("resampling failed: \(error?.localizedDescription ?? "unknown error")")
        }
        let bytes = Int(output.frameLength) * MemoryLayout<Int16>.size
        if bytes > 0 {
            if fwrite(output.int16ChannelData![0], 1, bytes, stdout) != bytes {
                exit(0)   // the reader went away
            }
            fflush(stdout)
        }
    }
}

// MARK: - Capture

final class Capture {
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var emitter: Emitter?
    private var skipLeadingBuffers = 0
    private var lastCallback = Date()
    private var signalSources: [DispatchSourceSignal] = []
    private var watchdog: DispatchSourceTimer?

    func captureOutput(uid: String?) {
        let output = uid.map { findDevice(withUID: $0, scope: kAudioObjectPropertyScopeOutput) }
            ?? defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let outputUID = deviceUID(output)

        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.name = "heard (them)"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        check(AudioHardwareCreateProcessTap(description, &tapID), "creating the system audio tap")

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "heard-tap",
            kAudioAggregateDeviceUIDKey: "heard-tap-" + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "creating the capture device")
        device = aggregateID

        // If the output device also has inputs (a USB headset), the aggregate carries those input
        // streams too, ahead of the tap's. Only the tap's buffers (the trailing ones) are "them".
        skipLeadingBuffers = inputStreams(output).count
        let tapFormat = property(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
        warn("capturing them: \(deviceName(output)) [\(outputUID)] at \(Int(tapFormat.mSampleRate)) Hz")
        start(rate: tapFormat.mSampleRate)
    }

    func captureInput(uid: String?) {
        device = uid.map { findDevice(withUID: $0, scope: kAudioObjectPropertyScopeInput) }
            ?? defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        requireFloat32Streams(device)
        let rate = property(device, kAudioDevicePropertyNominalSampleRate, Float64(0))
        warn("capturing me: \(deviceName(device)) [\(deviceUID(device))] at \(Int(rate)) Hz")
        start(rate: rate)
    }

    private func start(rate: Double) {
        let emitter = Emitter(inputRate: rate)
        self.emitter = emitter
        let skip = skipLeadingBuffers
        check(AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { [weak self] _, inputData, _, outputData, _ in
            guard let self else { return }
            self.lastCallback = Date()
            for buffer in UnsafeMutableAudioBufferListPointer(outputData) where buffer.mData != nil {
                memset(buffer.mData, 0, Int(buffer.mDataByteSize))   // never play anything
            }
            let buffers = Array(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))).dropFirst(skip)
            var frames = 0
            var channels = 0
            for buffer in buffers where buffer.mNumberChannels > 0 {
                frames = max(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / Int(buffer.mNumberChannels))
                channels += Int(buffer.mNumberChannels)
            }
            guard frames > 0, channels > 0 else { return }
            var mono = [Float](repeating: 0, count: frames)
            let gain = 1.0 / Float(channels)
            for buffer in buffers where buffer.mNumberChannels > 0 && buffer.mData != nil {
                let perChannel = Int(buffer.mNumberChannels)
                let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
                let available = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / perChannel
                for frame in 0..<min(frames, available) {
                    var sum: Float = 0
                    for channel in 0..<perChannel { sum += samples[frame * perChannel + channel] }
                    mono[frame] += sum * gain
                }
            }
            emitter.push(mono)
        }, "installing the audio callback")
        check(AudioDeviceStart(device, procID), "starting capture")
        installSignalHandlers()
        installWatchdog()
    }

    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                self?.stop()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Core Audio stops calling after some device changes (sleep/wake, an unplugged headset).
    /// Exit so heard-daemon restarts the capture on whatever the default device is now.
    private func installWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + watchdogSeconds, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastCallback) > watchdogSeconds {
                self.stop()
                fail("no audio from the device for \(Int(watchdogSeconds)) s; exiting so the capture restarts", code: 2)
            }
        }
        timer.resume()
        watchdog = timer
    }

    func stop() {
        if let procID, device != kAudioObjectUnknown {
            AudioDeviceStop(device, procID)
            AudioDeviceDestroyIOProcID(device, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }
}

// MARK: - supervise

func supervise(_ command: [String]) -> Never {
    guard let executable = command.first else { fail("supervise: nothing to run") }
    let child = Process()
    child.executableURL = URL(fileURLWithPath: executable)
    child.arguments = Array(command.dropFirst())
    child.terminationHandler = { process in
        exit(process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus)
    }
    var sources: [DispatchSourceSignal] = []
    for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler { if child.isRunning { kill(child.processIdentifier, signalNumber) } }
        source.resume()
        sources.append(source)
    }
    do {
        try child.run()
    } catch {
        fail("supervise: cannot run \(executable): \(error.localizedDescription)")
    }
    withExtendedLifetime(sources) { dispatchMain() }
}

// MARK: - main

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("usage: heard-tap default-output | default-input | list | them [output-UID] | me [input-UID] | supervise CMD…")
}

switch command {
case "default-output":
    print(deviceUID(defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)))
case "default-input":
    print(deviceUID(defaultDevice(kAudioHardwarePropertyDefaultInputDevice)))
case "list":
    let defaultOutput = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    let defaultInput = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    for device in allDevices() {
        let inputs = channelCount(device, kAudioObjectPropertyScopeInput)
        let outputs = channelCount(device, kAudioObjectPropertyScopeOutput)
        var marks: [String] = []
        if device == defaultOutput { marks.append("default output") }
        if device == defaultInput { marks.append("default input") }
        let suffix = marks.isEmpty ? "" : "  <- " + marks.joined(separator: ", ")
        print("\(deviceUID(device))\t\(deviceName(device))\tin:\(inputs) out:\(outputs)\(suffix)")
    }
case "them", "me":
    if #available(macOS 14.2, *) {
        let capture = Capture()
        let uid = arguments.count > 1 && !arguments[1].isEmpty ? arguments[1] : nil
        if command == "them" { capture.captureOutput(uid: uid) } else { capture.captureInput(uid: uid) }
        withExtendedLifetime(capture) { dispatchMain() }
    } else {
        fail("system audio capture needs macOS 14.2 or newer")
    }
case "supervise":
    supervise(Array(arguments.dropFirst()))
default:
    fail("unknown command \(command)")
}
