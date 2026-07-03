import CoreAudio
import Foundation

enum CoreAudioError: LocalizedError {
    case osStatus(OSStatus, String)
    case noDefaultDevice

    var errorDescription: String? {
        switch self {
        case .osStatus(let s, let msg):
            return "\(msg) (OSStatus: \(s))"
        case .noDefaultDevice:
            return "Varsayılan ses çıkış cihazı bulunamadı."
        }
    }
}

func caCheck(_ status: OSStatus, _ msg: @autoclosure () -> String) throws {
    guard status == noErr else { throw CoreAudioError.osStatus(status, msg()) }
}

func getDefaultOutputDeviceID() throws -> AudioObjectID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try caCheck(
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            0, nil, &size, &deviceID
        ),
        "Default output device sorgulanamadı"
    )
    guard deviceID != kAudioObjectUnknown else { throw CoreAudioError.noDefaultDevice }
    return deviceID
}

private func copyDeviceCFStringProperty(
    _ deviceID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    label: String
) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<CFString?>.size)
    var cfString: Unmanaged<CFString>? = nil
    try withUnsafeMutablePointer(to: &cfString) { ptr in
        try caCheck(
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr),
            label
        )
    }
    guard let result = cfString?.takeRetainedValue() else {
        throw CoreAudioError.osStatus(noErr, label + " (boş döndü)")
    }
    return result as String
}

func getDeviceUID(_ deviceID: AudioObjectID) throws -> String {
    try copyDeviceCFStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID, label: "Cihaz UID alınamadı")
}

func getDeviceName(_ deviceID: AudioObjectID) throws -> String {
    try copyDeviceCFStringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString, label: "Cihaz adı alınamadı")
}

/// Returns true if the given output device is the Mac's BUILT-IN SPEAKERS specifically.
/// The same hardware AudioObjectID is used for both the speakers and the 3.5mm headphone
/// jack on Apple Silicon Macs; we disambiguate via `kAudioDevicePropertyDataSource`,
/// which switches between the four-char codes 'ispk' (internal speakers) and
/// 'hdpn' (external headphones) when the user plugs/unplugs.
func outputIsBuiltinSpeaker(_ deviceID: AudioObjectID) -> Bool {
    // 1. Must be built-in transport.
    var transportAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var transport: UInt32 = 0
    var transportSize = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &transportAddr, 0, nil, &transportSize, &transport) == noErr,
          transport == kAudioDeviceTransportTypeBuiltIn
    else { return false }

    // 2. Read the current data source — 'ispk' = speakers, 'hdpn' = headphones.
    var sourceAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDataSource,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var sourceID: UInt32 = 0
    var sourceSize = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(deviceID, &sourceAddr, 0, nil, &sourceSize, &sourceID)
    if status != noErr {
        // No data-source property → some built-in devices (older Macs, virtual) don't expose it.
        // In that case assume speakers — safer to bypass EQ than to apply Chu II correction
        // to a device whose nature we can't confirm.
        return true
    }
    return sourceID == fourCharCode("ispk")
}

private func fourCharCode(_ s: String) -> UInt32 {
    var result: UInt32 = 0
    for char in s.utf8 { result = (result << 8) | UInt32(char) }
    return result
}

/// True if the device is the Mac's built-in audio currently routed to the 3.5mm headphone
/// jack — i.e. transport=BuiltIn AND data source='hdpn'. This is the ONLY case where
/// our Chu II EQ should be active. Everything else (speakers, AirPods, USB DAC, generic
/// Bluetooth, unknown) gets bypassed so audio passes through Apple's own DSP unchanged.
func outputIsBuiltinHeadphoneJack(_ deviceID: AudioObjectID) -> Bool {
    var transportAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyTransportType,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var transport: UInt32 = 0
    var transportSize = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &transportAddr, 0, nil, &transportSize, &transport) == noErr,
          transport == kAudioDeviceTransportTypeBuiltIn
    else { return false }

    var sourceAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDataSource,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var sourceID: UInt32 = 0
    var sourceSize = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &sourceAddr, 0, nil, &sourceSize, &sourceID) == noErr
    else { return false }

    return sourceID == fourCharCode("hdpn")
}

/// Look up our own process's AudioObjectID so we can exclude it from a global tap.
/// Without this, the muted tap would silence our own AVAudioEngine output → no audio at all.
func getOwnProcessAudioObjectID() -> AudioObjectID {
    var translateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var myPID = ProcessInfo.processInfo.processIdentifier
    var myProcessObjectID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &translateAddress,
        UInt32(MemoryLayout<pid_t>.size), &myPID,
        &size, &myProcessObjectID
    )
    return status == noErr ? myProcessObjectID : kAudioObjectUnknown
}
