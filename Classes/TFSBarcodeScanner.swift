//
//  MTBBarcodeScanner.swift
//  MTBBarcodeScannerExample
//
//  Created by Jyoti on 13/03/24.
//

import UIKit
import AVFoundation
import Foundation
import QuartzCore


public enum TFSCamera {
    case back
    case front
}


public enum TFSTorchMode {
    case on
    case off
}

protocol TFSBarcodeScannerProtocol {
    func stopScanning()

    func isScanning() -> Bool

    func flipCamera()
}


@available(iOS 10.0, *)
open class TFSBarcodeScanner: NSObject, AVCaptureMetadataOutputObjectsDelegate, AVCapturePhotoCaptureDelegate {
    let kFocalPointOfInterestX: CGFloat = 0.5
    let kFocalPointOfInterestY: CGFloat = 0.5
    let kErrorDomain = "TFSBarcodeScannerError"
    // Error Codes
    let kErrorCodeStillImageCaptureInProgress = 1000
    let kErrorCodeSessionIsClosed = 1001
    let kErrorCodeNotScanning = 1002
    let kErrorCodeSessionAlreadyActive = 1003
    let kErrorCodeTorchModeUnavailable = 1004
    let kErrorMethodNotAvailableOnIOSVersion = 1005
    var privateSessionQueue: DispatchQueue!
    
    var session: AVCaptureSession!
    var captureDevice: AVCaptureDevice!
    var capturePreviewLayer: AVCaptureVideoPreviewLayer!
    var currentCaptureDeviceInput: AVCaptureDeviceInput!
    var captureOutput: AVCaptureMetadataOutput!
    var metaDataObjectTypes: [AVMetadataObject.ObjectType]!
    
    var previewView: UIView!
    var initialAutoFocusRangeRestriction: AVCaptureDevice.AutoFocusRangeRestriction!
    var initialFocusPoint: CGPoint!
    var stillImageOutput: AVCaptureStillImageOutput!
    var gestureRecognizer: UITapGestureRecognizer!
    var stillImageCaptureBlock: ((UIImage?, Error?) -> Void)?
    @available(iOS 10.0, *)
    var output: AVCapturePhotoOutput!
    var didStartScanningBlock: (() -> Void)?
    var allowTapToFocus: Bool = false
    var preferredAutoFocusRangeRestriction: AVCaptureDevice.AutoFocusRangeRestriction!
    private(set) var camera: TFSCamera!
    var resultBlock: ([AVMetadataMachineReadableCodeObject]?) -> Void = { _ in}
    var scanRect = CGRect.zero
    var didTapToFocusBlock: ((_ point: CGPoint) -> Void)?
   
    private var torchMode: TFSTorchMode = .off
    
    func defaultMetaDataObjectTypes() -> [AVMetadataObject.ObjectType] {
        var types: [AVMetadataObject.ObjectType] = [
            .qr,
            .upce,
            .code39,
            .code39Mod43,
            .ean13,
            .ean8,
            .code93,
            .code128,
            .pdf417,
            .aztec
        ]
        if floor(NSFoundationVersionNumber) > NSFoundationVersionNumber_iOS_7_1 {
            types.append(contentsOf: [
                .interleaved2of5,
                .itf14,
                .dataMatrix
            ])
        }
        return types
    }
    
    
    
   public init?(previewView: UIView) {
        super.init()
        self.metaDataObjectTypes = defaultMetaDataObjectTypes()
        self.previewView = previewView
        self.preferredAutoFocusRangeRestriction = .near
        self.allowTapToFocus = true
        setupSessionQueue()
        addObservers()
    }
    
    public init?(metaDataObjectTypes: [AVMetadataObject.ObjectType], previewView: UIView) {
        self.metaDataObjectTypes = metaDataObjectTypes
        self.previewView = previewView
        self.allowTapToFocus = true
        self.preferredAutoFocusRangeRestriction = .near
        super.init()
        setupSessionQueue()
        addObservers()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    static func hasCamera(camera: TFSCamera) -> Bool {
        let position = self.devicePosition(for: camera)
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
        return (device != nil)
    }

    func startScanningWithError(_ error: inout NSError?) -> Bool {
        return startScanningWithResultBlock(resultBlock, error: &error)
    }

    func startScanningWithResultBlock(_ resultBlock: @escaping ([AVMetadataMachineReadableCodeObject]?) -> Void, error: inout NSError?) -> Bool {
        return startScanningWithCamera(camera: .back, resultBlock: resultBlock, error: &error)
    }

   public func startScanningWithCamera(camera: TFSCamera, resultBlock: @escaping ([AVMetadataMachineReadableCodeObject]?) -> Void, error: inout NSError?) -> Bool {
        if self.session != nil {
            error = NSError(domain: kErrorDomain, code: kErrorCodeSessionAlreadyActive, userInfo: [NSLocalizedDescriptionKey: "Do not start scanning while another session is in use."])
            return false
        }
        // Configure the session
        self.camera = camera
        self.captureDevice = self.newCaptureDevice(with: camera)
        guard let session = self.newSession(with: self.captureDevice, error: &error) else {
            // we rely on newSessionWithCaptureDevice:error: to populate the error
            return false
        }
        self.session = session
        // Configure the preview layer
        self.capturePreviewLayer.cornerRadius = self.previewView.layer.cornerRadius
        self.previewView.layer.insertSublayer(self.capturePreviewLayer, at: 0) // Insert below all other views
        self.refreshVideoOrientation()
        // Configure 'tap to focus' functionality
        self.configureTapToFocus()
        self.resultBlock = resultBlock
        self.privateSessionQueue.async {
            // Configure the rect of interest
            self.captureOutput.rectOfInterest = self.rectOfInterestFromScanRect(scanRect: self.scanRect)
            // Start the session after all configurations:
            // Must be dispatched as it is blocking
            self.session.startRunning()
            if let didStartScanningBlock = self.didStartScanningBlock {
                // Call that block now that we've started scanning:
                // Dispatch back to main
                DispatchQueue.main.async {
                    didStartScanningBlock()
                }
            }
        }
        return true
    }
    
   public func stopScanning() {
        if self.session == nil {
            return
        }
        // Turn the torch off
        self.torchMode = .off
        // Remove the preview layer
        self.capturePreviewLayer.removeFromSuperlayer()
        // Stop recognizing taps for the 'Tap to Focus' feature
        stopRecognizingTaps()
        //self.resultBlock = nil
        self.capturePreviewLayer.session = nil
        self.capturePreviewLayer = nil
        let session = self.session
        let deviceInput = self.currentCaptureDeviceInput
        self.session = nil
        DispatchQueue.global().async {
            // When we're finished scanning, reset the settings for the camera
            // to their original states
            // Must be dispatched as it is blocking
            self.removeDeviceInput(deviceInput!, session: session!)
            for output in session?.outputs ?? [] {
                session?.removeOutput(output)
            }
            // Must be dispatched as it is blocking
            session?.stopRunning()
        }
    }

    public func isScanning() -> Bool {
        return self.session.isRunning
    }

    func hasOppositeCamera() -> Bool {
        let otherCamera = ScannerUtils.oppositeCameraOf(camera: self.camera)
        return TFSBarcodeScanner.hasCamera(camera: otherCamera)
    }

    func getError() -> NSError? {
        
        return NSError()
    }
   public func flipCamera() {
        var error = getError()
        if !flipCameraWithError(&error) {
            print(String(describing: error))
        }
    }

    func flipCameraWithError(_ error: inout NSError?) -> Bool {
        if !self.isScanning() {
            error = NSError(domain: kErrorDomain,
                            code: kErrorCodeNotScanning,
                            userInfo: [NSLocalizedDescriptionKey : "Camera cannot be flipped when isScanning is NO"])
           return false
        }
        let otherCamera = ScannerUtils.oppositeCameraOf(camera:  self.camera)
        return setCamera(otherCamera, error: &error)
    }

    func configureTapToFocus() {
        if self.allowTapToFocus {
            let tapGesture = UITapGestureRecognizer(target: self, action: #selector(focusTapped(_:)))
            self.previewView.addGestureRecognizer(tapGesture)
            self.gestureRecognizer = tapGesture
        }
    }

    @objc func focusTapped(_ tapGesture: UITapGestureRecognizer) {
        let tapPoint = self.gestureRecognizer.location(in: self.gestureRecognizer.view)
        let devicePoint = self.capturePreviewLayer.captureDevicePointConverted(fromLayerPoint: tapPoint)
        let device = self.captureDevice
        do {
            try device?.lockForConfiguration()
            if device?.isFocusPointOfInterestSupported == true && ((device?.isFocusModeSupported(.continuousAutoFocus)) != nil) {
                device?.focusPointOfInterest = devicePoint
                device?.focusMode = .continuousAutoFocus
            }
            device?.unlockForConfiguration()
            if let didTapToFocusBlock = self.didTapToFocusBlock {
                didTapToFocusBlock(tapPoint)
            }

        } catch {
            
        }
    }

    func stopRecognizingTaps() {
        if let gestureRecognizer = self.gestureRecognizer {
            self.previewView.removeGestureRecognizer(gestureRecognizer)
        }
    }
    
    public func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        var codes = [AVMetadataMachineReadableCodeObject]()
        for metaData in metadataObjects {
            if let barCodeObject = self.capturePreviewLayer.transformedMetadataObject(for: metaData as! AVMetadataMachineReadableCodeObject) {
                codes.append(barCodeObject as! AVMetadataMachineReadableCodeObject)
            }
        }
        self.resultBlock(codes)
    }

    func captureOutput(_ captureOutput: AVCaptureOutput, didOutputMetadataObjects metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        var codes = [AVMetadataMachineReadableCodeObject]()
        for metaData in metadataObjects {
            if let barCodeObject = self.capturePreviewLayer.transformedMetadataObject(for: metaData as! AVMetadataMachineReadableCodeObject) {
                codes.append(barCodeObject as! AVMetadataMachineReadableCodeObject)
            }
        }
        self.resultBlock(codes)
    }

    public func handleApplicationDidChangeStatusBarNotification() {
        refreshVideoOrientation()
    }

    func refreshVideoOrientation() {
        let orientation = UIApplication.shared.statusBarOrientation
        self.capturePreviewLayer.frame = self.previewView.bounds
        if self.capturePreviewLayer.connection?.isVideoStabilizationSupported == true {
            if #available(iOS 17.0, *) {
                self.capturePreviewLayer.connection?.videoRotationAngle = captureOrientation(for: orientation)
            } else {
                // Fallback on earlier versions
            }
        }
    }

    func captureOrientation(for interfaceOrientation: UIInterfaceOrientation) -> CGFloat {
        switch interfaceOrientation {
        case .portrait:
            return 0
        case .portraitUpsideDown:
            return 180
        case .landscapeLeft:
            return 90
        case .landscapeRight:
            return -90
        default:
            return 0
        }
    }

    public func applicationWillEnterForegroundNotification() {
        // the torch is switched off when the app is backgrounded so we restore the
        // previous state once the app is foregrounded again
        var error: Error? = getError()
        updateForTorchMode(self.torchMode, error: &error)
    }

    func newSession(with captureDevice: AVCaptureDevice, error: inout NSError?) -> AVCaptureSession? {
        guard let input = try? AVCaptureDeviceInput(device: captureDevice) else {
            // we rely on deviceInputWithDevice:error: to populate the error
            return nil
        }
        let newSession = AVCaptureSession()
        setDeviceInput(input, session: newSession)
        // Set an optimized preset for barcode scanning
        newSession.sessionPreset = .high
        self.captureOutput = AVCaptureMetadataOutput()
        self.captureOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        newSession.addOutput(self.captureOutput)
        self.captureOutput.metadataObjectTypes = self.metaDataObjectTypes

        newSession.beginConfiguration()
        self.output = AVCapturePhotoOutput()
        self.output.isHighResolutionCaptureEnabled = true
        if newSession.canAddOutput(self.output) {
            newSession.addOutput(self.output)
        }
        DispatchQueue.global().async {
            self.captureOutput.rectOfInterest = self.rectOfInterestFromScanRect(scanRect: self.scanRect)
        }
        self.capturePreviewLayer = AVCaptureVideoPreviewLayer(session: newSession)
        self.capturePreviewLayer.videoGravity = .resizeAspectFill
        self.capturePreviewLayer.frame = self.previewView.bounds
        newSession.commitConfiguration()
        return newSession
    }
    
    func newCaptureDevice(with camera: TFSCamera) -> AVCaptureDevice? {
        var newCaptureDevice: AVCaptureDevice? = nil
        let position = Self.devicePosition(for: camera)
        let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: position)
        newCaptureDevice = device
        // If the front camera is not available, use the back camera
        if newCaptureDevice == nil {
            newCaptureDevice = AVCaptureDevice.default(for: .video)
        }
        // Using AVCaptureFocusModeContinuousAutoFocus helps improve scan times
        do {
            try newCaptureDevice?.lockForConfiguration()
            if newCaptureDevice?.isFocusModeSupported(.continuousAutoFocus) ?? false {
                newCaptureDevice?.focusMode = .continuousAutoFocus
            }
            newCaptureDevice?.unlockForConfiguration()
        } catch {
            print("Failed to acquire lock for initial focus mode: \(error)")
        }
        return newCaptureDevice
    }

    static func devicePosition(for camera: TFSCamera) -> AVCaptureDevice.Position {
        switch camera {
        case .front:
            return .front
        case .back:
            return .back
        }
    }
    
    func addObservers() {
//        NotificationCenter.default.addObserver(self, selector: #selector(handleApplicationDidChangeStatusBarNotification(_:)), name: NSNotification.Name.UIApplicationDidChangeStatusBarOrientation, object: nil)
//        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillEnterForegroundNotification(_:)), name: NSNotification.Name.UIApplicationWillEnterForeground, object: nil)
    }
    

    func setupSessionQueue() {
        if privateSessionQueue != nil {
            return
        }
        privateSessionQueue = DispatchQueue(label: "com.mikebuss.TFSBarcodeScanner.captureSession", qos: .default, attributes: [], autoreleaseFrequency: .inherit, target: nil)
    }

    func setDeviceInput(_ deviceInput: AVCaptureDeviceInput, session: AVCaptureSession) {
      
        if currentCaptureDeviceInput != nil {
            removeDeviceInput(currentCaptureDeviceInput, session: session)
        }
        currentCaptureDeviceInput = deviceInput
        updateFocusPreferencesOfDevice(deviceInput.device, reset: false)
        session.addInput(deviceInput)
    }

    func removeDeviceInput(_ deviceInput: AVCaptureDeviceInput, session: AVCaptureSession) {
     
        // Restore focus settings to the previously saved state
        updateFocusPreferencesOfDevice(deviceInput.device, reset: true)
        session.removeInput(deviceInput)
        currentCaptureDeviceInput = nil
    }

    func updateFocusPreferencesOfDevice(_ inputDevice: AVCaptureDevice, reset: Bool) {
     
        var lockError: Error?
        do {
            try inputDevice.lockForConfiguration()
        } catch {
            lockError = error
        }
        if let error = lockError {
            print("Failed to acquire lock to (re)set focus options: \(error)")
            return
        }
        // Prioritize the focus on objects near to the device
        if inputDevice.isAutoFocusRangeRestrictionSupported {
            if !reset {
                initialAutoFocusRangeRestriction = inputDevice.autoFocusRangeRestriction
                inputDevice.autoFocusRangeRestriction = preferredAutoFocusRangeRestriction
            } else {
                inputDevice.autoFocusRangeRestriction = initialAutoFocusRangeRestriction
            }
        }
        // Focus on the center of the image
        if inputDevice.isFocusPointOfInterestSupported {
            if !reset {
                initialFocusPoint = inputDevice.focusPointOfInterest
                inputDevice.focusPointOfInterest = CGPoint(x: kFocalPointOfInterestX, y: kFocalPointOfInterestY)
            } else {
                inputDevice.focusPointOfInterest = initialFocusPoint
            }
        }
        inputDevice.unlockForConfiguration()
        // this method will acquire its own lock
        var error: Error? = getError()
        let success = updateForTorchMode(torchMode, error: &error)
        if !success {
            print(String(describing: error))
        }
    }

    // Torch Control
    func setTorchMode(_ torchMode: TFSTorchMode) {
        var error: Error? = getError()

        let success = setTorchMode(torchMode, error: &error)
        if !success {
            print(String(describing: error))
        }
    }

    func setTorchMode(_ torchMode: TFSTorchMode, error: inout Error?) -> Bool {
        if updateForTorchMode(torchMode, error: &error) {
            // we only update our internal state if setting the torch mode was successful
            self.torchMode = torchMode
            return true
        }
        return false
    }

    func toggleTorch() {
        switch torchMode {
        case .on:
            torchMode = .off
        case .off:
            torchMode = .on

        }
    }

    func updateForTorchMode(_ preferredTorchMode: TFSTorchMode, error: inout Error?) -> Bool {
        let backCamera = AVCaptureDevice.default(for: .video)
        let avTorchMode = avTorchModeForTFSTorchMode(preferredTorchMode)
        if !(backCamera?.isTorchAvailable ?? false) || !(backCamera?.isTorchModeSupported(avTorchMode) ?? false) {
                error = NSError(domain: kErrorDomain, 
                                code: kErrorCodeTorchModeUnavailable,
                                userInfo: [NSLocalizedDescriptionKey : "Torch unavailable or mode not supported."])
            return false
        }
        do {
            try backCamera?.lockForConfiguration()
            backCamera?.torchMode = avTorchMode
            backCamera?.unlockForConfiguration()

        } catch {
            
        }
        return true
    }

    func hasTorch() -> Bool {
        guard let captureDevice = newCaptureDevice(with: camera) else {
            return false
        }
        let input = try? AVCaptureDeviceInput(device: captureDevice)
        return input?.device.hasTorch ?? false
    }

    func avTorchModeForTFSTorchMode(_ torchMode: TFSTorchMode) -> AVCaptureDevice.TorchMode {
        switch torchMode {
        case .on:
            return .on
        case .off:
            return .off
        }
    }

    // Capture
    func freezeCapture() {
        // we must access the layer on the main thread, but manipulating
        // the capture connection is blocking and should be dispatched
        let connection = capturePreviewLayer.connection
        privateSessionQueue.async {
            connection?.isEnabled = false
            self.session?.stopRunning()
        }
    }

    func unfreezeCapture() {
        if session == nil {
            return
        }
        let connection = capturePreviewLayer.connection
        if !session.isRunning {
            setDeviceInput(currentCaptureDeviceInput, session: session)
            privateSessionQueue.async {
                self.session.startRunning()
                connection?.isEnabled = true
            }
        }
    }
    
    func captureStillImage(_ captureBlock: @escaping (UIImage?, Error?) -> Void) {
        if isCapturingStillImage() {
            let error = NSError(domain: kErrorDomain, code: kErrorCodeStillImageCaptureInProgress, userInfo: [NSLocalizedDescriptionKey : "Still image capture is already in progress. Check with isCapturingStillImage"])
            captureBlock(nil, error)
            return
        }
        if #available(iOS 10.0, *) {
            let settings = AVCapturePhotoSettings()
            settings.isAutoStillImageStabilizationEnabled = false
            settings.flashMode = .off
            settings.isHighResolutionPhotoEnabled = true
            DispatchQueue.global().async {
                [weak self] in
                guard let self = self else { return }
                self.output.capturePhoto(with: settings, delegate: self)
                self.stillImageCaptureBlock = captureBlock
            }
        } else {
            guard let stillConnection = self.stillImageOutput.connection(with: .video) else {
                let error = NSError(domain: kErrorDomain, code: kErrorCodeSessionIsClosed, userInfo: [NSLocalizedDescriptionKey : "AVCaptureConnection is closed"])
                captureBlock(nil, error)
                return
            }
            self.stillImageOutput.captureStillImageAsynchronously(from: stillConnection) {
                (imageDataSampleBuffer, error) in
                if let error = error {
                    captureBlock(nil, error)
                    return
                }
                guard let imageDataSampleBuffer = imageDataSampleBuffer else { return }
                if let jpegData = AVCaptureStillImageOutput.jpegStillImageNSDataRepresentation(imageDataSampleBuffer) {
                    let image = UIImage(data: jpegData)
                    captureBlock(image, nil)
                }
            }
        }
    }

    @available(iOS 11.0, *)
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if #available(iOS 11.0, *) {
            let data = photo.fileDataRepresentation()
            var image: UIImage? = nil
            if let data = data {
                image = UIImage(data: data)
            }
            stillImageCaptureBlock?(image, error)
        } else {
            let error = NSError(domain: kErrorDomain, code: kErrorMethodNotAvailableOnIOSVersion, userInfo: [NSLocalizedDescriptionKey : "Unable to capture still image: the method is not available on this device."])
            stillImageCaptureBlock?(nil, error)
        }
    }

    public func photoOutput(_ captureOutput: AVCapturePhotoOutput, didFinishProcessingPhoto photoSampleBuffer: CMSampleBuffer?, previewPhoto previewPhotoSampleBuffer: CMSampleBuffer?, resolvedSettings: AVCaptureResolvedPhotoSettings, bracketSettings: AVCaptureBracketedStillImageSettings?, error: Error?) {
        if photoSampleBuffer == nil {
            return
        }
        guard let photoSampleBuffer = photoSampleBuffer else { return }
        let data = AVCapturePhotoOutput.jpegPhotoDataRepresentation(forJPEGSampleBuffer: photoSampleBuffer, previewPhotoSampleBuffer: previewPhotoSampleBuffer)
        var image: UIImage? = nil
        if let data = data {
            image = UIImage(data: data)
        }
        stillImageCaptureBlock?(image, error)
    }

    func isCapturingStillImage() -> Bool {
        return stillImageOutput.isCapturingStillImage
    }

    func setCamera(_ camera: TFSCamera) {
        var error = getError()
        if !setCamera(camera, error: &error) {
            print("Error")
        }
    }

    func setCamera(_ camera: TFSCamera, error: inout NSError?) -> Bool {
        if camera == self.camera {
            return true
        }
        if !isScanning() {
            error = NSError(domain: kErrorDomain, code: kErrorCodeNotScanning, userInfo: [NSLocalizedDescriptionKey : "Camera cannot be set when isScanning is NO"])
            return false
        }
        guard let captureDevice = newCaptureDevice(with: camera) else {
            return false
        }
        guard let input = try? AVCaptureDeviceInput(device: captureDevice) else {
            return false
        }
        setDeviceInput(input, session: session)
        self.camera = camera
        return true
    }

    func setScanRect(_ scanRect: CGRect) {
        if !isScanning() {
            return
        }
        refreshVideoOrientation()
        self.scanRect = scanRect
        DispatchQueue.global().async {
            [weak self] in
            guard let self = self else { return }
            self.captureOutput.rectOfInterest = self.capturePreviewLayer.metadataOutputRectConverted(fromLayerRect: self.scanRect)
        }
    }
    
    
    func setPreferredAutoFocusRangeRestriction(preferredAutoFocusRangeRestriction: AVCaptureDevice.AutoFocusRangeRestriction) {
        if preferredAutoFocusRangeRestriction == self.preferredAutoFocusRangeRestriction {
            return
        }
        self.preferredAutoFocusRangeRestriction = preferredAutoFocusRangeRestriction
        guard let currentCaptureDeviceInput = self.currentCaptureDeviceInput else {
            // the setting will be picked up once a new session incl. device input is created
            return
        }
        updateFocusPreferencesOfDevice(currentCaptureDeviceInput.device, reset: false)
    }

    // MARK: - Getters
    var previewLayer: CALayer {
        return self.capturePreviewLayer
    }

    // MARK: - Helper Methods
    func rectOfInterestFromScanRect(scanRect: CGRect) -> CGRect {
        var rect = CGRect.zero
        if !self.scanRect.isEmpty {
            rect = self.capturePreviewLayer.metadataOutputRectConverted(fromLayerRect: self.scanRect)
        } else {
            rect = CGRect(x: 0, y: 0, width: 1, height: 1) // Default rectOfInterest for AVCaptureMetadataOutput
        }
        return rect
    }



}

