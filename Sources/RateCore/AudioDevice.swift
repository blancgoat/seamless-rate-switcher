import CoreAudio

public struct AudioDevice: Hashable {
    public let id: AudioObjectID

    public init(id: AudioObjectID) { self.id = id }

    public static var defaultOutput: AudioDevice? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? AudioDevice(id: id) : nil
    }

    public var name: String {
        var addr = Self.address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let name else { return "?" }
        return name.takeRetainedValue() as String
    }

    /// 재부팅·재연결에도 바뀌지 않는 장치 식별자 (예: "com_motu_driver_gen5_control_interface:ul5eff6f7a")
    public var uid: String {
        var addr = Self.address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &uid) == noErr, let uid else { return "" }
        return uid.takeRetainedValue() as String
    }

    public var nominalSampleRate: Double { float64(kAudioDevicePropertyNominalSampleRate) }
    public var actualSampleRate: Double { float64(kAudioDevicePropertyActualSampleRate) }

    /// 장치가 지원하는 rate 목록. 범위로 보고하는 장치도 있어서 (min, max) 쌍으로 받는다.
    public var availableSampleRateRanges: [AudioValueRange] {
        var addr = Self.address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ranges) == noErr else { return [] }
        return ranges
    }

    public func supports(_ rate: Double) -> Bool {
        availableSampleRateRanges.contains { $0.mMinimum <= rate && rate <= $0.mMaximum }
    }

    @discardableResult
    public func setNominalSampleRate(_ rate: Double) -> OSStatus {
        var addr = Self.address(kAudioDevicePropertyNominalSampleRate)
        var value = rate
        return AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Double>.size), &value)
    }

    public func onChange(_ selector: AudioObjectPropertySelector, queue: DispatchQueue = .main, _ handler: @escaping () -> Void) {
        var addr = Self.address(selector)
        AudioObjectAddPropertyListenerBlock(id, &addr, queue) { _, _ in handler() }
    }

    public static func onDefaultOutputChange(queue: DispatchQueue = .main, _ handler: @escaping () -> Void) {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue) { _, _ in handler() }
    }

    private func float64(_ selector: AudioObjectPropertySelector) -> Double {
        var addr = Self.address(selector)
        var value: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
        return value
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
}
