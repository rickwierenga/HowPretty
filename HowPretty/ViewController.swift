//
//  ViewController.swift
//  HowPretty
//
//  Created by Rick Wierenga on 30/12/2019.
//  Copyright © 2019 Rick Wierenga. All rights reserved.
//

import AVFoundation
import Firebase
import UIKit

class ViewController: UIViewController, AVCapturePhotoCaptureDelegate {
    var captureSession: AVCaptureSession!
    var device: AVCaptureDevice?
    var cameraPreviewLayer: AVCaptureVideoPreviewLayer?
    var captureOutput: AVCapturePhotoOutput?

    var shutterButton: UIButton!

    // MARK: - View controller life cycle
    override func viewDidLoad() {
        super.viewDidLoad()

        checkPermissions()
        setupCameraLiveView()
        addShutterButton()
    }

    override func viewDidAppear(_ animated: Bool) {
        // Every time the user re-enters the app, we must be sure we have access to the camera.
        checkPermissions()
    }

    // MARK: - User interface
    override var prefersStatusBarHidden: Bool { true }

    // MARK: - Camera
    private func checkPermissions() {
        let mediaType = AVMediaType.video
        let status = AVCaptureDevice.authorizationStatus(for: mediaType)

        switch status {
        case .denied, .restricted:
            displayNotAuthorizedUI()
        case.notDetermined:
            // Prompt the user for access.
            AVCaptureDevice.requestAccess(for: mediaType) { granted in
                guard granted != true else { return }

                // The UI must be updated on the main thread.
                DispatchQueue.main.async {
                    self.displayNotAuthorizedUI()
                }
            }

        default: break
        }
    }

    private func setupCameraLiveView() {
        // Set up the camera session.
        captureSession = AVCaptureSession()
        captureSession.sessionPreset = .hd1280x720

        // Set up the video device.
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: .front)
            else { fatalError("No camera found.") }
        self.device = device

        // Set up the input and output stream.
        do {
            let captureDeviceInput = try AVCaptureDeviceInput(device: device)
            captureSession.addInput(captureDeviceInput)
        } catch {
            showAlert(withTitle: "Camera error", message: "Your camera can't be used as an input device.")
            return
        }

        // Initialize the capture output and add it to the session.
        captureOutput = AVCapturePhotoOutput()
        captureOutput!.setPreparedPhotoSettingsArray([AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])], completionHandler: nil)
        captureSession.addOutput(captureOutput!)

        // Add a preview layer.
        cameraPreviewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        cameraPreviewLayer!.videoGravity = .resizeAspectFill
        cameraPreviewLayer!.connection?.videoOrientation = .portrait
        cameraPreviewLayer?.frame = view.frame

        self.view.layer.insertSublayer(cameraPreviewLayer!, at: 0)

        // Start the capture session.
        captureSession.startRunning()
    }

    @objc func captureImage() {
        let settings = AVCapturePhotoSettings()
        captureOutput?.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let imageData = photo.fileDataRepresentation(),
            let image = UIImage(data: imageData) {
            howPretty(image)
        }
    }

    fileprivate func convertUIImageToCGImage(image: UIImage) -> CGImage? {
        guard let ciImage = CIImage(image: image) else { return nil }
        let context = CIContext(options: nil)
        return context.createCGImage(ciImage, from: ciImage.extent)!
    }

    func howPretty(_ image: UIImage) {
        // Load interpreter.
        let interpreter = ModelInterpreter.modelInterpreter(localModel: howPrettyModel)

        let ioOptions = ModelInputOutputOptions()
        do {
            try ioOptions.setInputFormat(index: 0, type: .float32, dimensions: [1, 150, 150, 3])
            try ioOptions.setOutputFormat(index: 0, type: .float32, dimensions: [1, 1])
        } catch let error as NSError {
            print("Failed to set input or output format with error: \(error.localizedDescription)")
        }

        // Load the image context.
        guard let image = convertUIImageToCGImage(image: image) else { return }
        guard let context = CGContext(
          data: nil,
          width: image.width, height: image.height,
          bitsPerComponent: 8, bytesPerRow: image.width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return }

        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let imageData = context.data else { return }

        // Preprocess image. ref: https://firebase.google.com/docs/ml-kit/ios/use-custom-models?hl=en#perform-inference-on-input-data
        let inputs = ModelInputs()
        var inputData = Data()
        do {
          for row in 0 ..< 150 {
            for col in 0 ..< 150 {
              let offset = 4 * (col * context.width + row)
              // (Ignore offset 0, the unused alpha channel)
              let red = imageData.load(fromByteOffset: offset+1, as: UInt8.self)
              let green = imageData.load(fromByteOffset: offset+2, as: UInt8.self)
              let blue = imageData.load(fromByteOffset: offset+3, as: UInt8.self)

              // Normalize channel values to [0.0, 1.0]. This requirement varies
              // by model. For example, some models might require values to be
              // normalized to the range [-1.0, 1.0] instead, and others might
              // require fixed-point values or the original bytes.
              var normalizedRed = Float32(red) / 255.0
              var normalizedGreen = Float32(green) / 255.0
              var normalizedBlue = Float32(blue) / 255.0

              // Append normalized values to Data object in RGB order.
              let elementSize = MemoryLayout.size(ofValue: normalizedRed)
              var bytes = [UInt8](repeating: 0, count: elementSize)
              memcpy(&bytes, &normalizedRed, elementSize)
              inputData.append(&bytes, count: elementSize)
              memcpy(&bytes, &normalizedGreen, elementSize)
              inputData.append(&bytes, count: elementSize)
              memcpy(&bytes, &normalizedBlue, elementSize)
              inputData.append(&bytes, count: elementSize)
            }
          }
          try inputs.addInput(inputData)
        } catch let error {
          print("Failed to add input: \(error)")
        }

        interpreter.run(inputs: inputs, options: ioOptions) { outputs, error in
            guard error == nil, let outputs = outputs else { return }
            let output = try? outputs.output(index: 0) as? [[NSNumber]]
            let probabilities = output?[0]
            if let score = probabilities?[0] {
                self.showAlert(withTitle: String(Float(truncating: score)), message: "")
            } else { self.showAlert(withTitle: "error", message: "error") }
        }
    }

    lazy var howPrettyModel: CustomLocalModel = {
        guard let path = Bundle.main.path(forResource: "model", ofType: "tflite") else {
            fatalError("Could not find model.tflite")
        }
        return CustomLocalModel(modelPath: path)
    }()

    // MARK: - User interface
    private func displayNotAuthorizedUI() {
        let label = UILabel(frame: CGRect(x: 0, y: 0, width: view.frame.width * 0.8, height: 20))
        label.textAlignment = .center
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.text = "Please grant access to the camera for scanning faces."
        label.sizeToFit()

        let button = UIButton(frame: CGRect(x: 0, y: label.frame.height + 8, width: view.frame.width * 0.8, height: 35))
        button.layer.cornerRadius = 10
        button.setTitle("Grant Access", for: .normal)
        button.backgroundColor = UIColor(displayP3Red: 4.0/255.0, green: 92.0/255.0, blue: 198.0/255.0, alpha: 1)
        button.setTitleColor(.white, for: .normal)
        button.addTarget(self, action: #selector(openSettings), for: .touchUpInside)

        let containerView = UIView(frame: CGRect(
            x: view.frame.width * 0.1,
            y: (view.frame.height - label.frame.height + 8 + button.frame.height) / 2,
            width: view.frame.width * 0.8,
            height: label.frame.height + 8 + button.frame.height
            )
        )
        containerView.addSubview(label)
        containerView.addSubview(button)
        view.addSubview(containerView)
    }

    private func addShutterButton() {
        let width: CGFloat = 75
        let height = width
        shutterButton = UIButton(frame: CGRect(x: (view.frame.width - width) / 2,
                                               y: view.frame.height - height - 32,
                                               width: width,
                                               height: height
            )
        )
        shutterButton.layer.cornerRadius = width / 2
        shutterButton.backgroundColor = UIColor.init(displayP3Red: 1, green: 1, blue: 1, alpha: 0.8)
        shutterButton.showsTouchWhenHighlighted = true
        shutterButton.addTarget(self, action: #selector(captureImage), for: .touchUpInside)
        view.addSubview(shutterButton)
    }

    // MARK: - Helper functions
    @objc private func openSettings() {
        let settingsURL = URL(string: UIApplication.openSettingsURLString)!
        UIApplication.shared.open(settingsURL) { _ in
            self.checkPermissions()
        }
    }

    private func showAlert(withTitle title: String, message: String) {
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: "OK", style: .default))
        present(alertController, animated: true)
    }
}
