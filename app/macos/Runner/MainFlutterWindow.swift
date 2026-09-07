import AVFoundation
import Cocoa
import FlutterMacOS
import Vision

class MainFlutterWindow: NSWindow {
  private var airGrab: AirGrabPlugin?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    airGrab = AirGrabPlugin(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

/// Built-in webcam, no preview. Vision hand pose on macOS 11+; RGB skin
/// compactness otherwise. Frames are never saved.
final class AirGrabPlugin: NSObject, FlutterStreamHandler, AVCaptureVideoDataOutputSampleBufferDelegate {
  private let methods: FlutterMethodChannel
  private let events: FlutterEventChannel
  private let session = AVCaptureSession()
  private let output = AVCaptureVideoDataOutput()
  private let queue = DispatchQueue(label: "one.aml.onedrop.airgrab")
  private var sink: FlutterEventSink?
  private var running = false
  private var skip = 0

  init(messenger: FlutterBinaryMessenger) {
    methods = FlutterMethodChannel(name: "one.aml.onedrop/air_grab", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "one.aml.onedrop/air_grab/frames", binaryMessenger: messenger)
    super.init()
    events.setStreamHandler(self)
    methods.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(false)
        return
      }
      switch call.method {
      case "hasCamera":
        result(self.hasCamera())
      case "start":
        self.start(result: result)
      case "stop":
        self.stop()
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private func hasCamera() -> Bool {
    !AVCaptureDevice.devices(for: .video).isEmpty
  }

  private func start(result: @escaping FlutterResult) {
    guard hasCamera() else {
      result(false)
      return
    }
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      result(bind())
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        DispatchQueue.main.async {
          result(granted ? (self?.bind() ?? false) : false)
        }
      }
    default:
      result(false)
    }
  }

  private func bind() -> Bool {
    if running { return true }
    session.beginConfiguration()
    session.sessionPreset = .low
    session.inputs.forEach { session.removeInput($0) }
    session.outputs.forEach { session.removeOutput($0) }
    guard let device = AVCaptureDevice.default(for: .video),
          let input = try? AVCaptureDeviceInput(device: device),
          session.canAddInput(input)
    else {
      session.commitConfiguration()
      return false
    }
    session.addInput(input)
    output.alwaysDiscardsLateVideoFrames = true
    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ]
    output.setSampleBufferDelegate(self, queue: queue)
    guard session.canAddOutput(output) else {
      session.commitConfiguration()
      return false
    }
    session.addOutput(output)
    session.commitConfiguration()
    running = true
    skip = 0
    session.startRunning()
    return true
  }

  private func stop() {
    running = false
    skip = 0
    if session.isRunning {
      session.stopRunning()
    }
  }

  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard running else { return }
    skip += 1
    if skip % 2 != 0 { return }
    if #available(macOS 11.0, *) {
      emitVision(sampleBuffer)
    } else {
      emitSkin(sampleBuffer)
    }
  }

  @available(macOS 11.0, *)
  private func emitVision(_ sampleBuffer: CMSampleBuffer) {
    guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      emitSkin(sampleBuffer)
      return
    }
    let handler = VNImageRequestHandler(cvPixelBuffer: pixel, orientation: .up, options: [:])
    let request = VNDetectHumanHandPoseRequest()
    request.maximumHandCount = 1
    do {
      try handler.perform([request])
    } catch {
      emit(["shape": "none", "inFrame": false])
      return
    }
    guard let observation = request.results?.first else {
      emit(["shape": "none", "inFrame": false])
      return
    }
    let names: [VNHumanHandPoseObservation.JointName] = [
      .wrist,
      .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
      .indexMCP, .indexPIP, .indexDIP, .indexTip,
      .middleMCP, .middlePIP, .middleDIP, .middleTip,
      .ringMCP, .ringPIP, .ringDIP, .ringTip,
      .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]
    var points: [[Double]] = []
    points.reserveCapacity(21)
    for name in names {
      guard let point = try? observation.recognizedPoint(name), point.confidence > 0.2 else {
        emit(["shape": "none", "inFrame": true])
        return
      }
      points.append([Double(point.location.x), Double(1 - point.location.y)])
    }
    emit(["points": points, "inFrame": true])
  }

  private func emitSkin(_ sampleBuffer: CMSampleBuffer) {
    guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      emit(["shape": "none", "inFrame": false])
      return
    }
    CVPixelBufferLockBaseAddress(pixel, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixel) else {
      emit(["shape": "none", "inFrame": false])
      return
    }
    let width = CVPixelBufferGetWidth(pixel)
    let height = CVPixelBufferGetHeight(pixel)
    let stride = CVPixelBufferGetBytesPerRow(pixel)
    let data = base.assumingMemoryBound(to: UInt8.self)
    if width < 16 || height < 16 {
      emit(["shape": "none", "inFrame": false])
      return
    }
    let stepX = max(width / 80, 2)
    let stepY = max(height / 60, 2)
    var skin = 0
    var total = 0
    var minX = width
    var minY = height
    var maxX = 0
    var maxY = 0
    var y = 0
    while y < height {
      var x = 0
      while x < width {
        total += 1
        let i = y * stride + x * 4
        let b = Int(data[i])
        let g = Int(data[i + 1])
        let r = Int(data[i + 2])
        let luma = (299 * r + 587 * g + 114 * b + 500) / 1000
        let cb = 128 + (-169 * r - 331 * g + 500 * b + 500) / 1000
        let cr = 128 + (500 * r - 419 * g - 81 * b + 500) / 1000
        if luma >= 50 && luma <= 245 && cr >= 133 && cr <= 173 && cb >= 77 && cb <= 127 {
          skin += 1
          if x < minX { minX = x }
          if y < minY { minY = y }
          if x > maxX { maxX = x }
          if y > maxY { maxY = y }
        }
        x += stepX
      }
      y += stepY
    }
    if total <= 0 || skin < Int(Double(total) * 0.035) {
      emit(["shape": "none", "inFrame": false])
      return
    }
    let bw = max(maxX - minX, 1)
    let bh = max(maxY - minY, 1)
    let box = (bw / stepX) * (bh / stepY)
    let solidity = box <= 0 ? 0.0 : Double(skin) / Double(box)
    let aspect = Double(bw) / Double(bh)
    var shape = "none"
    if solidity >= 0.62 && aspect >= 0.55 && aspect <= 1.45 {
      shape = "fist"
    } else if solidity <= 0.52 && bh > Int(Double(bw) * 0.85) {
      shape = "palm"
    }
    emit(["shape": shape, "inFrame": shape != "none" || solidity > 0.35])
  }

  private func emit(_ event: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.sink?(event)
    }
  }
}
