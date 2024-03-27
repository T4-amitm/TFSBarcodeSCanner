//
//  ScannerUtils.swift
//  LuminousBarcodeCamera
//
//  Created by Jyoti on 15/03/24.
//

import Foundation
import AVFoundation

open class ScannerUtils {
    
    static func cameraIsPresent() -> Bool {
        return AVCaptureDevice.default(for: .video) != nil
    }

    static func oppositeCameraOf(camera: LuminousCamera) -> LuminousCamera {
        switch camera {
        case .back:
            return .front
        case .front:
            return .back
        }
    }

    static func scanningIsProhibited() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            return true
        default:
            return false
        }
    }

    public static func requestCameraPermissionWithSuccess(successBlock: @escaping (Bool) -> Void) {
        guard cameraIsPresent() else {
            successBlock(false)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            successBlock(true)
        case .denied, .restricted:
            successBlock(false)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    successBlock(granted)
                }
            }
        @unknown default:
            successBlock(false)
        }
    }
}

