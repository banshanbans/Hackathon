@preconcurrency import AVFoundation
import Foundation

enum CameraPermissionState: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

protocol CameraAuthorizationProviding: Sendable {
    func currentState() -> CameraPermissionState
    func requestAccess() async -> Bool
}

struct SystemCameraAuthorizationProvider: CameraAuthorizationProviding {
    func currentState() -> CameraPermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: .notDetermined
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }
}

enum CameraFailure: String, LocalizedError, Equatable, Sendable {
    case permissionDenied
    case permissionRestricted
    case unavailable
    case configurationFailed
    case interrupted
    case runtimeError
    case mediaServicesReset
    case thermalPressure
    case recordingFailed
    case criticalPressure
    case insufficientStorage

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "相机权限已关闭，请在系统设置中允许访问。"
        case .permissionRestricted: "当前设备限制了相机访问。"
        case .unavailable: "没有可用的后置 1× 相机。"
        case .configurationFailed: "相机初始化失败，请重试。"
        case .interrupted: "相机被系统中断，请确认后继续。"
        case .runtimeError: "相机运行异常，请重新进入。"
        case .mediaServicesReset: "相机服务已重置，请返回准备页后重新进入。"
        case .thermalPressure: "设备压力过高，实时检测已暂停。"
        case .recordingFailed: "录制未完成，可以重试或切换照片模式。"
        case .criticalPressure: "设备压力过高，短视频录制暂不可用。"
        case .insufficientStorage: "设备可用空间不足，无法安全录制短视频。"
        }
    }
}
