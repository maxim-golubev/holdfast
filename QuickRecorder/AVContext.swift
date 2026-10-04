//
//  AVContext.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/27.
//
import AppKit
import Foundation
import AVFoundation
import UserNotifications

extension AppDelegate {
    func recordingCamera(with device: AVCaptureDevice) {
        SCContext.captureSession = AVCaptureSession()
        
        guard let input = try? AVCaptureDeviceInput(device: device),
              SCContext.captureSession.canAddInput(input) else {
            print("Failed to set up camera")
            SCContext.requestCameraPermission()
            return
        }
        SCContext.captureSession.addInput(input)
        
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.setSampleBufferDelegate(self, queue: .global())
        
        if SCContext.captureSession.canAddOutput(videoOutput) {
            SCContext.captureSession.addOutput(videoOutput)
        }
        
        SCContext.captureSession.startRunning()
        DispatchQueue.main.async { self.startCameraOverlayer() }
    }
    
    func closeCamera() {
        if SCContext.isCameraRunning() {
            //SCContext.previewType = nil
            if camWindow.isVisible { camWindow.close() }
            SCContext.captureSession.stopRunning()
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        /* 保留后续以作他用
        if !SCContext.isPaused && ud.string(forKey: "recordCam") != "" {
            if sampleBuffer.isValid { SCContext.isCameraReady = true }
            if sampleBuffer.imageBuffer != nil { SCContext.frameCache = sampleBuffer }
        }*/
    }
}

class AVOutputClass: NSObject, AVCaptureFileOutputRecordingDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = AVOutputClass()
    var output: AVCaptureMovieFileOutput!
    var dataOutput: AVCaptureVideoDataOutput!
    /// Main thread. True from the start of an iDevice recording until its file has been closed (`didFinishRecordingTo`).
    private(set) var isWritingFile = false
    private var closedHandlers = [() -> Void]()
    
    /// Main thread. Runs `handler` once the movie file of an iDevice recording has been closed; at once when none
    /// is being written. Quitting waits for it. A file output that does not report back is given 10 seconds.
    func whenFileClosed(_ handler: @escaping () -> Void) {
        guard isWritingFile else { return handler() }
        closedHandlers.append(handler)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.fileClosed() }
    }
    
    private func fileClosed() {
        isWritingFile = false
        let handlers = closedHandlers
        closedHandlers = []
        handlers.forEach { $0() }
    }
    //var captureSession: AVCaptureSession!
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        //print(sampleBuffer.nsImage?.size)
    }
    
    public func startRecording(with device: AVCaptureDevice, mute: Bool = false, preset: AVCaptureSession.Preset = .high, didOutput: Bool = true) {
        output = AVCaptureMovieFileOutput()
        dataOutput = AVCaptureVideoDataOutput()
        dataOutput.setSampleBufferDelegate(self, queue: .global())
        SCContext.captureSession = AVCaptureSession()
        SCContext.previewSession = AVCaptureSession()
        SCContext.captureSession.sessionPreset = preset
        SCContext.previewSession.sessionPreset = preset
        
        guard let input = try? AVCaptureDeviceInput(device: device),
              let preview = try? AVCaptureDeviceInput(device: device),
              SCContext.captureSession.canAddInput(input),
              SCContext.previewSession.canAddInput(preview),
              SCContext.captureSession.canAddOutput(output),
              SCContext.previewSession.canAddOutput(dataOutput) else {
            print("Failed to set up camera or device")
            SCContext.requestCameraPermission()
            return
        }
        
        SCContext.captureSession.addInput(input)
        SCContext.captureSession.addOutput(output)
        SCContext.previewSession.addInput(preview)
        SCContext.previewSession.addOutput(dataOutput)
        
        if mute {
            if let audioConnection = output.connection(with: .audio) {
                SCContext.captureSession.removeConnection(audioConnection)
                /*DispatchQueue.main.async {
                    let alert = createAlert(title: "No Audio Connection",
                                                               message: "Unable to get audio stream on this device, only screen content will be recorded!",
                                                               button1: "OK")
                    alert.runModal()
                }*/
            }
        }
        
        if didOutput {
            let encoderIsH265 = ud.string(forKey: "encoder") == Encoder.h265.rawValue
            let videoSettings: [String: Any] = [ AVVideoCodecKey: encoderIsH265 ? AVVideoCodecType.hevc : AVVideoCodecType.h264 ]
            guard let connection = output.connection(with: .video) else { return }
            output.setOutputSettings(videoSettings, for: connection)
            let fileEnding = ud.string(forKey: "videoFormat") ?? ""
            let fileURL = "\(SCContext.getFilePath()).\(fileEnding)".url
            SCContext.captureSession.startRunning()
            output.startRecording(to: fileURL, recordingDelegate: self)
            isWritingFile = true
            SCContext.streamType = StreamType.idevice
            SCContext.startTime = Date.now
        }
        
        SCContext.previewSession.startRunning()
        DispatchQueue.main.async {
            closeAllWindow(except: "Area Overlayer".local)
            updateStatusBar()
            AppDelegate.shared.startDeviceOverlayer(size: NSSize(width: 300, height: 500))
        }
    }

    public func stopRecording() {
        if SCContext.captureSession.isRunning {
            output.stopRecording()
            SCContext.captureSession.stopRunning()
            SCContext.previewSession.stopRunning()
            SCContext.streamType = nil
            SCContext.startTime = nil
            DispatchQueue.main.async {
                controlPanel.close()
                deviceWindow.close()
                updateStatusBar()
            }
        }
    }
    
    func closePreview() {
        if SCContext.isCameraRunning() {
            //SCContext.previewType = nil
            if deviceWindow.isVisible { deviceWindow.close() }
            if let preview = SCContext.previewSession { preview.stopRunning() }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let path = outputFileURL.path
        DispatchQueue.main.async {
            if let error = error as NSError? {
                // The recording ended on its own, for example because the device was unplugged. AVFoundation says
                // whether the file was closed all the same.
                let saved = (error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) == true && fd.fileExists(atPath: path)
                let rest = saved ? String(format: "The recording up to that point is saved as: %@".local, path)
                                 : String(format: "The file is incomplete and may not open: %@".local, path)
                print("Device recording ended with an error: \(error)")
                // Takes down the session and the controls when the recording was not stopped by the user
                if SCContext.streamType == .idevice { SCContext.stopRecording() }
                SCContext.reportFailure(title: "Recording Stopped Early".local, message: error.localizedDescription + " " + rest)
            } else {
                SCContext.showNotification(title: "Recording Completed".local, body: String(format: "File saved to: %@".local, path), id: "quickrecorder.completed.\(UUID().uuidString)")
            }
            self.fileClosed()
        }
    }
}
