//
//  CameraManager.swift of MijickCameraView
//
//  Created by Tomasz Kurylik
//    - Twitter: https://twitter.com/tkurylik
//    - Mail: tomasz.kurylik@mijick.com
//    - GitHub: https://github.com/FulcrumOne
//
//  Copyright ©2024 Mijick. Licensed under MIT License.


import SwiftUI
import AVKit
import MetalKit
import CoreMotion
import MijickTimer

public class CameraManager: NSObject, ObservableObject { init(_ attributes: Attributes) { self.initialAttributes = attributes; self.attributes = attributes }
    // MARK: Attributes
    struct Attributes {
        var capturedMedia: MCameraMedia? = nil
        var error: Error? = nil
        var outputType: CameraOutputType = .photo
        var cameraPosition: CameraPosition = .back
        var cameraFilters: [CIFilter] = []
        var zoomFactor: CGFloat = 1.0
        var flashMode: CameraFlashMode = .off
        var torchMode: CameraTorchMode = .off
        var cameraExposure: CameraExposure = .init()
        var hdrMode: CameraHDRMode = .auto
        var resolution: AVCaptureSession.Preset = .hd1920x1080
        var frameRate: Int32 = 30
        var mirrorOutput: Bool = false
        var isGridVisible: Bool = true
        var isRecording: Bool = false
        var recordingTime: MTime = .zero
        var deviceOrientation: AVCaptureVideoOrientation = .portrait
        var userBlockedScreenRotation: Bool = false
    }
    @Published private(set) var attributes: Attributes

    // MARK: Devices
    private var frontCamera: AVCaptureDevice?
    private var backCamera: AVCaptureDevice?
    private var microphone: AVCaptureDevice?

    // MARK: Input
    private var captureSession: AVCaptureSession!
    private var frontCameraInput: AVCaptureDeviceInput?
    private var backCameraInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?

    // MARK: Output
    private var photoOutput: AVCapturePhotoOutput?
    private var videoOutput: AVCaptureMovieFileOutput?

    // MARK: Metal
    private var metalDevice: MTLDevice!
    private var metalCommandQueue: MTLCommandQueue!
    private var ciContext: CIContext!
    private var currentFrame: CIImage?
    private var firstRecordedFrame: UIImage?
    private var metalAnimation: MetalAnimation = .none

    // MARK: UI Elements
    private(set) var cameraLayer: AVCaptureVideoPreviewLayer!
    private(set) var cameraMetalView: MTKView!
    private(set) var cameraGridView: GridView!
    private(set) var cameraBlurView: UIImageView!
    private(set) var cameraFocusView: UIImageView = .create(image: .iconCrosshair, tintColor: .yellow, size: 92)

    // MARK: Other Objects
    private var motionManager: CMMotionManager = .init()
    private var timer: MTimer = .createNewInstance()

    // MARK: Other Attributes
    private(set) var isRunning: Bool = false
    private(set) var frameOrientation: CGImagePropertyOrientation = .right
    private(set) var orientationLocked: Bool = false
    private(set) var initialAttributes: Attributes
}

// MARK: - Cancellation
extension CameraManager {
    func cancel() {
        cancelProcesses()
        resetAttributes()
        resetOthers()
        removeObservers()
    }
}
private extension CameraManager {
    func cancelProcesses() {
        captureSession.stopRunning()
        motionManager.stopAccelerometerUpdates()
        timer.reset()
    }
    func resetAttributes() {
        attributes = initialAttributes
    }
    func resetOthers() {
        frontCamera = nil
        backCamera = nil
        microphone = nil
        captureSession = nil
        frontCameraInput = nil
        backCameraInput = nil
        audioInput = nil
        photoOutput = nil
        videoOutput = nil
        metalDevice = nil
        metalCommandQueue = nil
        ciContext = nil
        currentFrame = nil
        firstRecordedFrame = nil
        cameraLayer = nil
        cameraMetalView = nil
        cameraGridView = nil
        cameraBlurView = nil
        cameraFocusView = .init()
        motionManager = .init()
    }
    func removeObservers() {
        NotificationCenter.default.removeObserver(self, name: .AVCaptureSessionWasInterrupted, object: captureSession)
    }
}

// MARK: - Changing Attributes
extension CameraManager {
    func resetCapturedMedia() {
        attributes.capturedMedia = nil
    }
    func resetZoomAndTorch() {
        attributes.zoomFactor = 1.0
        attributes.torchMode = .off
    }
}

// MARK: - Initialising Camera
extension CameraManager {
    func setup(in cameraView: UIView) {
        do {
            makeCameraViewInvisible(cameraView)
            checkPermissions()
            initialiseCaptureSession()
            initialiseMetal()
            initialiseCameraLayer(cameraView)
            initialiseCameraMetalView()
            initialiseCameraGridView()
            initialiseDevices()
            initialiseInputs()
            initialiseOutputs()
            initializeMotionManager()
            initialiseObservers()

            try setupDeviceInputs()
            try setupDeviceOutput()
            try setupFrameRecorder()
            try setupCameraAttributes()
            try setupFrameRate()

            startCaptureSession()
        } catch { print("CANNOT SETUP CAMERA: \(error)") }
    }
}
private extension CameraManager {
    func makeCameraViewInvisible(_ view: UIView) {
        view.alpha = 0
    }
    func checkPermissions() { Task { @MainActor in
        do {
            try await checkPermissions(.video)
            try await checkPermissions(.audio)
            animateCameraViewEntrance()
        } catch { attributes.error = error as? Error }
    }}
    func initialiseCaptureSession() {
        captureSession = .init()
        captureSession.sessionPreset = attributes.resolution
    }
    func initialiseMetal() {
        metalDevice = MTLCreateSystemDefaultDevice()
        metalCommandQueue = metalDevice.makeCommandQueue()
        ciContext = CIContext(mtlDevice: metalDevice)
    }
    func initialiseCameraLayer(_ cameraView: UIView) {
        cameraLayer = .init(session: captureSession)
        cameraLayer.videoGravity = .resizeAspectFill
        cameraLayer.isHidden = true

        cameraView.layer.addSublayer(cameraLayer)
    }
    func initialiseCameraMetalView() {
        cameraMetalView = .init()
        cameraMetalView.delegate = self
        cameraMetalView.device = metalDevice
        cameraMetalView.isPaused = true
        cameraMetalView.enableSetNeedsDisplay = false
        cameraMetalView.framebufferOnly = false
        cameraMetalView.autoResizeDrawable = false

        cameraMetalView.contentMode = .scaleAspectFill
        cameraMetalView.clipsToBounds = true
        cameraMetalView.addToParent(cameraView)
    }
    func initialiseCameraGridView() {
        cameraGridView?.removeFromSuperview()
        cameraGridView = .init()
        cameraGridView.alpha = attributes.isGridVisible ? 1 : 0
        cameraGridView.addToParent(cameraView)
    }
    func initialiseDevices() {
        frontCamera = .default(.builtInWideAngleCamera, for: .video, position: .front)
        backCamera = .default(for: .video)
        microphone = .default(for: .audio)
    }
    func initialiseInputs() {
        frontCameraInput = .init(frontCamera)
        backCameraInput = .init(backCamera)
        audioInput = .init(microphone)
    }
    func initialiseOutputs() {
        photoOutput = .init()
        videoOutput = .init()
    }
    func initializeMotionManager() {
        motionManager.accelerometerUpdateInterval = 0.05
        motionManager.startAccelerometerUpdates(to: OperationQueue.current ?? .init(), withHandler: handleAccelerometerUpdates)
    }
    func initialiseObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleSessionWasInterrupted), name: .AVCaptureSessionWasInterrupted, object: captureSession)
    }
    func setupDeviceInputs() throws {
        try setupCameraInput(attributes.cameraPosition)
        try setupInput(audioInput)
    }
    func setupDeviceOutput() throws {
        try setupCameraOutput(attributes.outputType)
    }
    func setupFrameRecorder() throws {
        let captureVideoOutput = AVCaptureVideoDataOutput()
        captureVideoOutput.setSampleBufferDelegate(self, queue: DispatchQueue.main)

        if captureSession.canAddOutput(captureVideoOutput) { captureSession?.addOutput(captureVideoOutput) }
    }
    func setupCameraAttributes() throws { if let device = getDevice(attributes.cameraPosition) { DispatchQueue.main.async { [self] in
        attributes.cameraExposure.duration = device.exposureDuration
        attributes.cameraExposure.iso = device.iso
        attributes.cameraExposure.targetBias = device.exposureTargetBias
        attributes.cameraExposure.mode = device.exposureMode
        attributes.hdrMode = device.hdrMode
    }}}
    func setupFrameRate() throws { if let device = getDevice(attributes.cameraPosition) {
        try checkNewFrameRate(attributes.frameRate, device)
        try updateFrameRate(attributes.frameRate, device)
    }}
    func startCaptureSession() { DispatchQueue(label: "cameraSession").async { [self] in
        captureSession.startRunning()
    }}
}
private extension CameraManager {
    func checkPermissions(_ mediaType: AVMediaType) async throws { switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .denied, .restricted: throw getPermissionsError(mediaType)
        case .notDetermined: let granted = await AVCaptureDevice.requestAccess(for: mediaType); if !granted { throw getPermissionsError(mediaType) }
        default: return
    }}
    func animateCameraViewEntrance() {
        UIView.animate(withDuration: 0.3, delay: 1.2) { [self] in cameraView.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [self] in isRunning = true }
    }
    func setupCameraInput(_ cameraPosition: CameraPosition) throws { switch cameraPosition {
        case .front: try setupInput(frontCameraInput)
        case .back: try setupInput(backCameraInput)
    }}
    func setupCameraOutput(_ outputType: CameraOutputType) throws { if let output = getOutput(outputType) {
        try setupOutput(output)
    }}
}
private extension CameraManager {
    func getPermissionsError(_ mediaType: AVMediaType) -> Error { switch mediaType {
        case .audio: .microphonePermissionsNotGranted
        case .video: .cameraPermissionsNotGranted
        default: .cameraPermissionsNotGranted
    }}
    func setupInput(_ input: AVCaptureDeviceInput?) throws {
        guard let input,
              captureSession.canAddInput(input)
        else { throw Error.cannotSetupInput }

        captureSession.addInput(input)
    }
    func setupOutput(_ output: AVCaptureOutput?) throws {
        guard let output,
              captureSession.canAddOutput(output)
        else { throw Error.cannotSetupOutput }

        captureSession.addOutput(output)
    }
}

// MARK: - Locking Camera Orientation
extension CameraManager {
    func lockOrientation() {
        orientationLocked = true
    }
}

// MARK: - Camera Rotation
extension CameraManager {
    func fixCameraRotation() { if !orientationLocked {
        redrawGrid()
    }}
}
private extension CameraManager {
    func redrawGrid() {
        cameraGridView?.draw(.zero)
    }
}

// MARK: - Changing Output Type
extension CameraManager {
    func changeOutputType(_ newOutputType: CameraOutputType) throws { if newOutputType != attributes.outputType && !isChanging {
        captureCurrentFrameAndDelay(.blur) { [self] in
            removeCameraOutput(attributes.outputType)
            try setupCameraOutput(newOutputType)
            updateCameraOutputType(newOutputType)

            updateTorchMode(.off)
            removeBlur()
        }
    }}
}
private extension CameraManager {
    func removeCameraOutput(_ outputType: CameraOutputType) { if let output = getOutput(outputType) {
        captureSession.removeOutput(output)
    }}
    func updateCameraOutputType(_ cameraOutputType: CameraOutputType) {
        attributes.outputType = cameraOutputType
    }
}
private extension CameraManager {
    func getOutput(_ outputType: CameraOutputType) -> AVCaptureOutput? { switch outputType {
        case .photo: photoOutput
        case .video: videoOutput
    }}
}

// MARK: - Changing Camera Position
extension CameraManager {
    func changeCamera(_ newPosition: CameraPosition) throws { if newPosition != attributes.cameraPosition && !isChanging {
        captureCurrentFrameAndDelay(.blurAndFlip) { [self] in
            removeCameraInput(attributes.cameraPosition)
            try setupCameraInput(newPosition)
            updateCameraPosition(newPosition)
            
            updateTorchMode(.off)
            removeBlur()
        }
    }}
}
private extension CameraManager {
    func removeCameraInput(_ position: CameraPosition) { if let input = getInput(position) {
        captureSession.removeInput(input)
    }}
    func updateCameraPosition(_ position: CameraPosition) {
        attributes.cameraPosition = position
    }
}
private extension CameraManager {
    func getInput(_ position: CameraPosition) -> AVCaptureInput? { switch position {
        case .front: frontCameraInput
        case .back: backCameraInput
    }}
}

// MARK: - Changing Camera Filters
extension CameraManager {
    func changeCameraFilters(_ newCameraFilters: [CIFilter]) throws { if newCameraFilters != attributes.cameraFilters {
        attributes.cameraFilters = newCameraFilters
    }}
}

// MARK: - Camera Focusing
extension CameraManager {
    func setCameraFocus(_ touchPoint: CGPoint) throws { if let device = getDevice(attributes.cameraPosition) {
        removeCameraFocusAnimations()
        insertCameraFocus(touchPoint)

        try setCameraFocus(touchPoint, device)
    }}
}
private extension CameraManager {
    func removeCameraFocusAnimations() {
        cameraFocusView.layer.removeAllAnimations()
    }
    func insertCameraFocus(_ touchPoint: CGPoint) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [self] in
        insertNewCameraFocusView(touchPoint)
        animateCameraFocusView()
    }}
    func setCameraFocus(_ touchPoint: CGPoint, _ device: AVCaptureDevice) throws {
        let focusPoint = cameraLayer.captureDevicePointConverted(fromLayerPoint: touchPoint)
        try configureCameraFocus(focusPoint, device)
    }
}
private extension CameraManager {
    func insertNewCameraFocusView(_ touchPoint: CGPoint) {
        cameraFocusView.frame.origin.x = touchPoint.x - cameraFocusView.frame.size.width / 2
        cameraFocusView.frame.origin.y = touchPoint.y - cameraFocusView.frame.size.height / 2
        cameraFocusView.transform = .init(scaleX: 0, y: 0)
        cameraFocusView.alpha = 1

        cameraView.addSubview(cameraFocusView)
    }
    func animateCameraFocusView() {
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0) { [self] in cameraFocusView.transform = .init(scaleX: 1, y: 1) }
        UIView.animate(withDuration: 0.5, delay: 1.5) { [self] in cameraFocusView.alpha = 0.2 } completion: { _ in
            UIView.animate(withDuration: 0.5, delay: 3.5) { [self] in cameraFocusView.alpha = 0 }
        }
    }
    func configureCameraFocus(_ focusPoint: CGPoint, _ device: AVCaptureDevice) throws { try withLockingDeviceForConfiguration(device) { device in
        setFocusPointOfInterest(focusPoint, device)
        setExposurePointOfInterest(focusPoint, device)
    }}
}
private extension CameraManager {
    func setFocusPointOfInterest(_ focusPoint: CGPoint, _ device: AVCaptureDevice) { if device.isFocusPointOfInterestSupported {
        device.focusPointOfInterest = focusPoint
        device.focusMode = .autoFocus
    }}
    func setExposurePointOfInterest(_ focusPoint: CGPoint, _ device: AVCaptureDevice) { if device.isExposurePointOfInterestSupported {
        device.exposurePointOfInterest = focusPoint
        device.exposureMode = .autoExpose
    }}
}

// MARK: - Changing Zoom Factor
extension CameraManager {
    func changeZoomFactor(_ value: CGFloat) throws { if let device = getDevice(attributes.cameraPosition), !isChanging {
        let zoomFactor = calculateZoomFactor(value, device)

        try setVideoZoomFactor(zoomFactor, device)
        updateZoomFactor(zoomFactor)
    }}
}
private extension CameraManager {
    func getDevice(_ position: CameraPosition) -> AVCaptureDevice? { switch position {
        case .front: frontCamera
        case .back: backCamera
    }}
    func calculateZoomFactor(_ value: CGFloat, _ device: AVCaptureDevice) -> CGFloat {
        min(max(value, getMinZoomLevel(device)), getMaxZoomLevel(device))
    }
    func setVideoZoomFactor(_ zoomFactor: CGFloat, _ device: AVCaptureDevice) throws  { try withLockingDeviceForConfiguration(device) { device in
        device.videoZoomFactor = zoomFactor
    }}
    func updateZoomFactor(_ value: CGFloat) {
        attributes.zoomFactor = value
    }
}
private extension CameraManager {
    func getMinZoomLevel(_ device: AVCaptureDevice) -> CGFloat {
        device.minAvailableVideoZoomFactor
    }
    func getMaxZoomLevel(_ device: AVCaptureDevice) -> CGFloat {
        min(device.maxAvailableVideoZoomFactor, 3)
    }
}

// MARK: - Changing Flash Mode
extension CameraManager {
    func changeFlashMode(_ mode: CameraFlashMode) throws { if let device = getDevice(attributes.cameraPosition), device.hasFlash, !isChanging {
        updateFlashMode(mode)
    }}
}
private extension CameraManager {
    func updateFlashMode(_ value: CameraFlashMode) {
        attributes.flashMode = value
    }
}

// MARK: - Changing Torch Mode
extension CameraManager {
    func changeTorchMode(_ mode: CameraTorchMode) throws { if let device = getDevice(attributes.cameraPosition), device.hasTorch, !isChanging {
        try changeTorchMode(device, mode)
        updateTorchMode(mode)
    }}
}
private extension CameraManager {
    func changeTorchMode(_ device: AVCaptureDevice, _ mode: CameraTorchMode) throws { try withLockingDeviceForConfiguration(device) { device in
        device.torchMode = mode.get()
    }}
    func updateTorchMode(_ value: CameraTorchMode) {
        attributes.torchMode = value
    }
}

// MARK: - Changing Exposure Mode
extension CameraManager {
    func changeExposureMode(_ newExposureMode: AVCaptureDevice.ExposureMode) throws { if let device = getDevice(attributes.cameraPosition), device.isExposureModeSupported(newExposureMode), newExposureMode != attributes.cameraExposure.mode {
        try changeExposureMode(newExposureMode, device)
        updateExposureMode(newExposureMode)
    }}
}
private extension CameraManager {
    func changeExposureMode(_ newExposureMode: AVCaptureDevice.ExposureMode, _ device: AVCaptureDevice) throws { try withLockingDeviceForConfiguration(device) { device in
        device.exposureMode = newExposureMode
    }}
    func updateExposureMode(_ newExposureMode: AVCaptureDevice.ExposureMode) {
        attributes.cameraExposure.mode = newExposureMode
    }
}

// MARK: - Changing Exposure Duration
extension CameraManager {
    func changeExposureDuration(_ newExposureDuration: CMTime) throws { if let device = getDevice(attributes.cameraPosition), device.isExposureModeSupported(.custom), newExposureDuration != attributes.cameraExposure.duration {
        let newExposureDuration = min(max(newExposureDuration, device.activeFormat.minExposureDuration), device.activeFormat.maxExposureDuration)

        try changeExposureDuration(newExposureDuration, device)
        updateExposureDuration(newExposureDuration)
    }}
}
private extension CameraManager {
    func changeExposureDuration(_ newExposureDuration: CMTime, _ device: AVCaptureDevice) throws { try withLockingDeviceForConfiguration(device) { device in
        device.setExposureModeCustom(duration: newExposureDuration, iso: attributes.cameraExposure.iso)
    }}
    func updateExposureDuration(_ newExposureDuration: CMTime) {
        attributes.cameraExposure.duration = newExposureDuration
    }
}

// MARK: - Changing ISO
extension CameraManager {
    func changeISO(_ newISO: Float) throws { if let device = getDevice(attributes.cameraPosition), device.isExposureModeSupported(.custom), newISO != attributes.cameraExposure.iso {
        let newISO = min(max(newISO, device.activeFormat.minISO), device.activeFormat.maxISO)

        try changeISO(newISO, device)
        updateISO(newISO)
    }}
}
private extension CameraManager {
    func changeISO(_ newISO: Float, _ device: AVCaptureDevice) throws { try withLockingDeviceForConfiguration(device) { device in
        device.setExposureModeCustom(duration: attributes.cameraExposure.duration, iso: newISO)
    }}
    func updateISO(_ newISO: Float) {
        attributes.cameraExposure.iso = newISO
    }
}

// MARK: - Changing Exposure Target Bias
extension CameraManager {
    func changeExposureTargetBias(_ newExposureTargetBias: Float) throws { if let device = getDevice(attributes.cameraPosition), device.isExposureModeSupported(.custom), newExposureTargetBias != attributes.cameraExposure.targetBias {
        let newExposureTargetBias = min(max(newExposureTargetBias, device.minExposureTargetBias), device.maxExposureTargetBias)

        try changeExposureTargetBias(newExposureTargetBias, device)
        updateExposureTargetBias(newExposureTargetBias)
    }}
}
private extension CameraManager {
    func changeExposureTargetBias(_ newExposureTargetBias: Float, _ device: AVCaptureDevice) throws { try withLockingDeviceForConfiguration(device) { device in
        device.setExposureTargetBias(newExposureTargetBias)
    }}
    func updateExposureTargetBias(_ newExposureTargetBias: Float) {
        attributes.cameraExposure.targetBias = newExposureTargetBias
    }
}

// MARK: - Changing Camera HDR Mode
extension CameraManager {
    func changeHDRMode(_ newHDRMode: CameraHDRMode) throws { if let device = getDevice(attributes.cameraPosition), newHDRMode != attributes.hdrMode {
        try changeHDRMode(newHDRMode, device)
        updateHDRMode(newHDRMode)
    }}
}
private extension CameraManager {
    func changeHDRMode(_ newHDRMode: CameraHDRMode, _ device: AVCaptureDevice) throws { try withLockingDeviceForConfiguration(device) { device in
        device.hdrMode = newHDRMode
    }}
    func updateHDRMode(_ newHDRMode: CameraHDRMode) {
        attributes.hdrMode = newHDRMode
    }
}

// MARK: - Changing Camera Resolution
extension CameraManager {
    func changeResolution(_ newResolution: AVCaptureSession.Preset) throws { if newResolution != attributes.resolution {
        captureSession.sessionPreset = newResolution
        attributes.resolution = newResolution
    }}
}

// MARK: - Changing Frame Rate
extension CameraManager {
    func changeFrameRate(_ newFrameRate: Int32) throws { if let device = getDevice(attributes.cameraPosition), newFrameRate != attributes.frameRate {
        try checkNewFrameRate(newFrameRate, device)
        try updateFrameRate(newFrameRate, device)
        updateFrameRate(newFrameRate)
    }}
}
private extension CameraManager {
    func checkNewFrameRate(_ newFrameRate: Int32, _ device: AVCaptureDevice) throws { let newFrameRate = Double(newFrameRate), maxFrameRate = device.activeFormat.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 60
        if newFrameRate < 15 { throw Error.incorrectFrameRate }
        if newFrameRate > maxFrameRate { throw Error.incorrectFrameRate }
    }
    func updateFrameRate(_ newFrameRate: Int32, _ device: AVCaptureDevice) throws { try withLockingDeviceForConfiguration(device) { device in
        device.activeVideoMinFrameDuration = .init(value: 1, timescale: newFrameRate)
        device.activeVideoMaxFrameDuration = .init(value: 1, timescale: newFrameRate)
    }}
    func updateFrameRate(_ newFrameRate: Int32) {
        attributes.frameRate = newFrameRate
    }
}

// MARK: - Changing Mirror Mode
extension CameraManager {
    func changeMirrorMode(_ shouldMirror: Bool) { if !isChanging {
        attributes.mirrorOutput = shouldMirror
    }}
}

// MARK: - Changing Grid Mode
extension CameraManager {
    func changeGridVisibility(_ shouldShowGrid: Bool) { if !isChanging {
        animateGridVisibilityChange(shouldShowGrid)
        updateGridVisibility(shouldShowGrid)
    }}
}
private extension CameraManager {
    func animateGridVisibilityChange(_ shouldShowGrid: Bool) { UIView.animate(withDuration: 0.32) { [self] in
        cameraGridView.alpha = shouldShowGrid ? 1 : 0
    }}
    func updateGridVisibility(_ shouldShowGrid: Bool) {
        attributes.isGridVisible = shouldShowGrid
    }
}

// MARK: - Capturing Output
extension CameraManager {
    func captureOutput() { if !isChanging { switch attributes.outputType {
        case .photo: capturePhoto()
        case .video: toggleVideoRecording()
    }}}
}

// MARK: Photo
private extension CameraManager {
    func capturePhoto() {
        let settings = getPhotoOutputSettings()

        configureOutput(photoOutput)
        photoOutput?.capturePhoto(with: settings, delegate: self)
        performCaptureAnimation()
    }
}
private extension CameraManager {
    func getPhotoOutputSettings() -> AVCapturePhotoSettings {
        let settings = AVCapturePhotoSettings()
        settings.flashMode = attributes.flashMode.get()
        return settings
    }
    func performCaptureAnimation() {
        let view = createCaptureAnimationView()
        cameraView.addSubview(view)

        animateCaptureView(view)
    }
}
private extension CameraManager {
    func createCaptureAnimationView() -> UIView {
        let view = UIView()
        view.frame = cameraView.frame
        view.backgroundColor = .black
        view.alpha = 0
        return view
    }
    func animateCaptureView(_ view: UIView) {
        UIView.animate(withDuration: captureAnimationDuration) { view.alpha = 1 }
        UIView.animate(withDuration: captureAnimationDuration, delay: captureAnimationDuration) { view.alpha = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2 * captureAnimationDuration) { view.removeFromSuperview() }
    }
}
private extension CameraManager {
    var captureAnimationDuration: Double { 0.1 }
}

extension CameraManager: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Swift.Error)?) {
        attributes.capturedMedia = .create(imageData: photo, orientation: frameOrientation, filters: attributes.cameraFilters)
    }
}

// MARK: Video
private extension CameraManager {
    func toggleVideoRecording() { switch videoOutput?.isRecording {
        case false: startRecording()
        default: stopRecording()
    }}
}
private extension CameraManager {
    func startRecording() { if let url = prepareUrlForVideoRecording() {
        configureOutput(videoOutput)
        videoOutput?.startRecording(to: url, recordingDelegate: self)
        storeLastFrame()
        updateIsRecording(true)
        startRecordingTimer()
    }}
    func stopRecording() {
        presentLastFrame()
        videoOutput?.stopRecording()
        updateIsRecording(false)
        stopRecordingTimer()
    }
}
private extension CameraManager {
    func prepareUrlForVideoRecording() -> URL? {
        FileManager.prepareURLForVideoOutput()
    }
    func storeLastFrame() {
        guard let texture = cameraMetalView.currentDrawable?.texture,
              let ciImage = CIImage(mtlTexture: texture, options: nil),
              let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent)
        else { return }

        firstRecordedFrame = UIImage(cgImage: cgImage, scale: 1.0, orientation: attributes.deviceOrientation.toImageOrientation())
    }
    func updateIsRecording(_ value: Bool) {
        attributes.isRecording = value
    }
    func startRecordingTimer() {
        try? timer
            .publish(every: 1) { [self] in attributes.recordingTime = $0 }
            .start()
    }
    func presentLastFrame() {
        attributes.capturedMedia = .init(data: firstRecordedFrame)
    }
    func stopRecordingTimer() {
        timer.reset()
    }
}

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    public func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: (any Swift.Error)?) { Task { @MainActor in
        attributes.capturedMedia = await .create(videoData: outputFileURL, filters: attributes.cameraFilters)
    }}
}

// MARK: - Handling Device Rotation
private extension CameraManager {
    func handleAccelerometerUpdates(_ data: CMAccelerometerData?, _ error: Swift.Error?) { if let data, error == nil {
        let newDeviceOrientation = fetchDeviceOrientation(data.acceleration)
        updateDeviceOrientation(newDeviceOrientation)
        updateUserBlockedScreenRotation()
        updateFrameOrientation()
    }}
}
private extension CameraManager {
    func fetchDeviceOrientation(_ acceleration: CMAcceleration) -> AVCaptureVideoOrientation { switch acceleration {
        case let acceleration where acceleration.x >= 0.75: .landscapeLeft
        case let acceleration where acceleration.x <= -0.75: .landscapeRight
        case let acceleration where acceleration.y <= -0.75: .portrait
        case let acceleration where acceleration.y >= 0.75: .portraitUpsideDown
        default: attributes.deviceOrientation
    }}
    func updateDeviceOrientation(_ newDeviceOrientation: AVCaptureVideoOrientation) { if newDeviceOrientation != attributes.deviceOrientation {
        attributes.deviceOrientation = newDeviceOrientation
    }}
    func updateUserBlockedScreenRotation() {
        let newUserBlockedScreenRotation = getNewUserBlockedScreenRotation()
        updateUserBlockedScreenRotation(newUserBlockedScreenRotation)
        
    }
    func updateFrameOrientation() { if UIDevice.current.orientation != .portraitUpsideDown {
        let newFrameOrientation = getNewFrameOrientation(orientationLocked ? .portrait : UIDevice.current.orientation)
        updateFrameOrientation(newFrameOrientation)
        
    }}
}
private extension CameraManager {
    func getNewUserBlockedScreenRotation() -> Bool { switch attributes.deviceOrientation.rawValue == UIDevice.current.orientation.rawValue {
        case true: false
        case false: !orientationLocked
    }}
    func updateUserBlockedScreenRotation(_ newUserBlockedScreenRotation: Bool) { if newUserBlockedScreenRotation != attributes.userBlockedScreenRotation {
        attributes.userBlockedScreenRotation = newUserBlockedScreenRotation
    }}
    func getNewFrameOrientation(_ orientation: UIDeviceOrientation) -> CGImagePropertyOrientation { switch attributes.cameraPosition {
        case .back: getNewFrameOrientationForBackCamera(orientation)
        case .front: getNewFrameOrientationForFrontCamera(orientation)
    }}
    func updateFrameOrientation(_ newFrameOrientation: CGImagePropertyOrientation) { if newFrameOrientation != frameOrientation {
        let shouldAnimate = shouldAnimateFrameOrientationChange(newFrameOrientation) && isRunning

        animateFrameOrientationChangeIfNeeded(shouldAnimate)
        changeFrameOrientation(shouldAnimate, newFrameOrientation)
    }}
}
private extension CameraManager {
    func getNewFrameOrientationForBackCamera(_ orientation: UIDeviceOrientation) -> CGImagePropertyOrientation { switch orientation {
        case .portrait: attributes.mirrorOutput ? .leftMirrored : .right
        case .landscapeLeft: attributes.mirrorOutput ? .upMirrored : .up
        case .landscapeRight: attributes.mirrorOutput ? .downMirrored : .down
        default: attributes.mirrorOutput ? .leftMirrored : .right
    }}
    func getNewFrameOrientationForFrontCamera(_ orientation: UIDeviceOrientation) -> CGImagePropertyOrientation { switch orientation {
        case .portrait: attributes.mirrorOutput ? .right : .leftMirrored
        case .landscapeLeft: attributes.mirrorOutput ? .down : .downMirrored
        case .landscapeRight: attributes.mirrorOutput ? .up : .upMirrored
        default: attributes.mirrorOutput ? .right : .leftMirrored
    }}
    func shouldAnimateFrameOrientationChange(_ newFrameOrientation: CGImagePropertyOrientation) -> Bool {
        let backCameraOrientations: [CGImagePropertyOrientation] = [.left, .right, .up, .down],
            frontCameraOrientations: [CGImagePropertyOrientation] = [.leftMirrored, .rightMirrored, .upMirrored, .downMirrored]
        return (backCameraOrientations.contains(newFrameOrientation) && backCameraOrientations.contains(frameOrientation))
            || (frontCameraOrientations.contains(frameOrientation) && frontCameraOrientations.contains(newFrameOrientation))
    }
    func animateFrameOrientationChangeIfNeeded(_ shouldAnimate: Bool) { if shouldAnimate {
        UIView.animate(withDuration: 0.2) { [self] in cameraView.alpha = 0 }
        UIView.animate(withDuration: 0.3, delay: 0.2) { [self] in cameraView.alpha = 1 }
    }}
    func changeFrameOrientation(_ shouldAnimate: Bool, _ newFrameOrientation: CGImagePropertyOrientation) { DispatchQueue.main.asyncAfter(deadline: .now() + (shouldAnimate ? 0.1 : 0)) { [self] in
        frameOrientation = newFrameOrientation
    }}
}

// MARK: - Handling Observers
private extension CameraManager {
    @objc func handleSessionWasInterrupted() {
        attributes.torchMode = .off
        updateIsRecording(false)
        stopRecordingTimer()
    }
}

// MARK: - Capturing Live Frames
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) { switch metalAnimation {
        case .none: changeDisplayedFrame(sampleBuffer)
        default: presentCameraAnimation()
    }}
}
private extension CameraManager {
    func changeDisplayedFrame(_ sampleBuffer: CMSampleBuffer) { if let cvImageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
        let currentFrame = captureCurrentFrame(cvImageBuffer)
        let currentFrameWithFiltersApplied = applyFiltersToCurrentFrame(currentFrame)

        redrawCameraView(currentFrameWithFiltersApplied)
    }}
    func presentCameraAnimation() {
        let snapshot = createSnapshot()

        insertBlurView(snapshot)
        animateBlurFlip()
        metalAnimation = .none
    }
}
private extension CameraManager {
    func captureCurrentFrame(_ cvImageBuffer: CVImageBuffer) -> CIImage {
        let currentFrame = CIImage(cvImageBuffer: cvImageBuffer)
        return currentFrame.oriented(frameOrientation)
    }
    func applyFiltersToCurrentFrame(_ currentFrame: CIImage) -> CIImage {
        currentFrame.applyingFilters(attributes.cameraFilters)
    }
    func redrawCameraView(_ frame: CIImage) {
        currentFrame = frame
        cameraMetalView.draw()
    }
    func createSnapshot() -> UIImage? {
        guard let currentFrame else { return nil }

        let image = UIImage(ciImage: currentFrame)
        return image
    }
    func insertBlurView(_ snapshot: UIImage?) { if let snapshot {
        cameraBlurView = UIImageView(image: snapshot)
        cameraBlurView.frame = cameraView.frame
        cameraBlurView.contentMode = .scaleAspectFill
        cameraBlurView.clipsToBounds = true
        cameraBlurView.applyBlurEffect(style: .regular, animationDuration: blurAnimationDuration)

        cameraView.addSubview(cameraBlurView)
    }}
    func animateBlurFlip() { if metalAnimation == .blurAndFlip {
        UIView.transition(with: cameraView, duration: flipAnimationDuration, options: flipAnimationTransition) {}
    }}
    func removeBlur() { Task { @MainActor [self] in
        try await Task.sleep(nanoseconds: 100_000_000)
        UIView.animate(withDuration: blurAnimationDuration) { self.cameraBlurView.alpha = 0 }
    }}
}
private extension CameraManager {
    var blurAnimationDuration: Double { 0.3 }

    var flipAnimationDuration: Double { 0.44 }
    var flipAnimationTransition: UIView.AnimationOptions { attributes.cameraPosition == .back ? .transitionFlipFromLeft : .transitionFlipFromRight }
}
private extension CameraManager {
    enum MetalAnimation { case blurAndFlip, blur, none }
}

// MARK: - Metal Handlers
extension CameraManager: MTKViewDelegate {
    public func draw(in view: MTKView) {
        guard let commandBuffer = metalCommandQueue.makeCommandBuffer(),
              let ciImage = currentFrame,
              let currentDrawable = view.currentDrawable
        else { return }

        changeDrawableSize(view, ciImage)
        renderView(view, currentDrawable, commandBuffer, ciImage)
        commitBuffer(currentDrawable, commandBuffer)
    }
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
private extension CameraManager {
    func changeDrawableSize(_ view: MTKView, _ ciImage: CIImage) {
        view.drawableSize = ciImage.extent.size
    }
    func renderView(_ view: MTKView, _ currentDrawable: any CAMetalDrawable, _ commandBuffer: any MTLCommandBuffer, _ ciImage: CIImage) {
        ciContext.render(ciImage, to: currentDrawable.texture, commandBuffer: commandBuffer, bounds: .init(origin: .zero, size: view.drawableSize), colorSpace: CGColorSpaceCreateDeviceRGB())
    }
    func commitBuffer(_ currentDrawable: any CAMetalDrawable, _ commandBuffer: any MTLCommandBuffer) {
        commandBuffer.present(currentDrawable)
        commandBuffer.commit()
    }
}

// MARK: - Modifiers
extension CameraManager {
    var hasFlash: Bool { getDevice(attributes.cameraPosition)?.hasFlash ?? false }
    var hasTorch: Bool { getDevice(attributes.cameraPosition)?.hasTorch ?? false }
}

// MARK: - Helpers
private extension CameraManager {
    func captureCurrentFrameAndDelay(_ type: MetalAnimation, _ action: @escaping () throws -> ()) { Task { @MainActor in
        metalAnimation = type
        try await Task.sleep(nanoseconds: 150_000_000)

        try action()
    }}
    func configureOutput(_ output: AVCaptureOutput?) { if let connection = output?.connection(with: .video), connection.isVideoMirroringSupported {
        connection.isVideoMirrored = attributes.mirrorOutput ? attributes.cameraPosition != .front : attributes.cameraPosition == .front
        connection.videoOrientation = attributes.deviceOrientation
    }}
    func withLockingDeviceForConfiguration(_ device: AVCaptureDevice, _ action: (AVCaptureDevice) -> ()) throws {
        try device.lockForConfiguration()
        action(device)
        device.unlockForConfiguration()
    }
}
private extension CameraManager {
    var cameraView: UIView { cameraLayer.superview ?? .init() }
    var isChanging: Bool { (cameraBlurView?.alpha ?? 0) > 0 }
}


// MARK: - Errors
public extension CameraManager { enum Error: Swift.Error {
    case microphonePermissionsNotGranted, cameraPermissionsNotGranted
    case cannotSetupInput, cannotSetupOutput, capturedPhotoCannotBeFetched
    case incorrectFrameRate
}}
