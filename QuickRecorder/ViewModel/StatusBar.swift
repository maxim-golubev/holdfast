//
//  StatusBarItem.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/16.
//

import SwiftUI

class PopoverState: ObservableObject {
    static let shared = PopoverState()
    @Published var isShowing: Bool = false
    @Published var isPaused: Bool = false
}

struct StatusBarItem: View {
    @State private var deviceWindowIsShowing = true
    @State private var isMainMenuShowing = false
    @State private var isHovering = false
    @State private var recordingLength = SCContext.getRecordingLength()
    //@State private var isPassed = SCContext.isPaused
    @StateObject private var popoverState = PopoverState.shared
    @ObservedObject private var health = RecordingHealth.shared
    //@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("miniStatusBar") private var miniStatusBar: Bool = false
    //@AppStorage("highlightMouse") private var highlightMouse: Bool = false
    private var appDelegate = AppDelegate.shared
    
    var body: some View {
        HStack(spacing: 0) {
            if health.saving {
                // The recording was stopped and is being closed and post-processed. Nothing can be clicked: the
                // pill goes away when the file is final.
                ZStack {
                    Rectangle()
                        .fill(Color.mypurple)
                        .shadow(color: .black.opacity(0.3), radius: 4)
                        .cornerRadius(4)
                    Text(health.mixProgress.map { "Finishing… \(Int($0 * 100))%" } ?? "Saving…")
                        .foregroundStyle(.white)
                        .font(.system(size: 13))
                }
                .help(health.mixProgress == nil ? "The recording is being saved. A new one can be started when this is gone." : "The audio tracks of the recording are being mixed. A new one can be started when this is gone.")
                .padding([.leading,.trailing], 4)
                .onReceive(updateTimer) { _ in
                    // Where the menu bar is not visible the floating controller shows this pill
                    resizeStatusBar()
                    updateFloatingController()
                }
            } else if SCContext.streamType != nil {
                ZStack {
                    Rectangle()
                        // Orange while a track is not being recorded
                        .fill(health.warning == nil ? Color.mypurple : Color.orange)
                        .shadow(color: .black.opacity(0.3), radius: 4)
                        .cornerRadius(4)
                    HStack(spacing: 4) {
                        if miniStatusBar {
                            if isHovering {
                                Button(action: {
                                    SCContext.stopRecording()
                                }, label: {
                                    ZStack {
                                        Image(systemName: "circle.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.red)
                                            .frame(width: 10, alignment: .center)
                                        Image(systemName: "stop.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.white)
                                            .frame(width: 16, alignment: .center)
                                    }
                                }).buttonStyle(.plain)
                                if SCContext.streamType != .idevice {
                                    Button(action: {
                                        SCContext.pauseRecording()
                                    }, label: {
                                        Image(systemName: popoverState.isPaused ? "play.circle.fill" : "pause.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.white)
                                            .frame(width: 16, alignment: .center)
                                    }).buttonStyle(.plain)
                                } else {
                                    Button(action:{
                                        DispatchQueue.main.async {
                                            if deviceWindow.isVisible { deviceWindow.close() } else { deviceWindow.orderFront(nil) }
                                            deviceWindowIsShowing = deviceWindow.isVisible
                                        }
                                    }, label: {
                                        Image(systemName: "eye.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.white)
                                            .frame(width: 16, alignment: .center)
                                            .opacity(deviceWindowIsShowing ? 1 : 0.7)
                                    }).buttonStyle(.plain)
                                }
                                if SCContext.streamType != .systemaudio && SCContext.streamType != .idevice && SCContext.streamType != .window {
                                    Button(action:{
                                        popoverState.isShowing = true
                                    }, label: {
                                        Image(systemName: "camera.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.white)
                                            .frame(width: 16, alignment: .center)
                                    }).buttonStyle(.plain)
                                }
                            } else {
                                Text(recordingLength)
                                    .foregroundStyle(.white)
                                    .font(.system(size: 15).monospaced())
                                    .offset(x: 0.5)
                            }
                        } else {
                            Group {
                                Button(action: {
                                    SCContext.stopRecording()
                                }, label: {
                                    ZStack {
                                        Image(systemName: "circle.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.red)
                                            .frame(width: 10, alignment: .center)
                                        Image(systemName: "stop.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.white)
                                            .frame(width: 16, alignment: .center)
                                    }
                                }).buttonStyle(.plain)
                                if SCContext.streamType != .idevice {//&& SCContext.streamType != .systemaudio {
                                    Button(action: {
                                        SCContext.pauseRecording()
                                    }, label: {
                                        Image(systemName: popoverState.isPaused ? "play.circle.fill" : "pause.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.white)
                                            .frame(width: 16, alignment: .center)
                                    }).buttonStyle(.plain)
                                }
                                Text(recordingLength)
                                    .foregroundStyle(.white)
                                    .font(.system(size: 15).monospaced())
                                    .offset(x: 0.5)
                            }
                        }
                    }
                }
                // Microphone activity: grey without signal, green with sound. Drawn over the corner, so the layout stays as it is.
                .overlay(alignment: .topTrailing) {
                    if let level = health.micLevel {
                        Circle()
                            .fill(level == 0 ? Color.white.opacity(0.4) : Color.green.opacity(level == 1 ? 0.6 : 1))
                            .frame(width: 5, height: 5)
                            .padding(2)
                            .allowsHitTesting(false)
                    }
                }
                .help(health.warning ?? "")
                .padding([.leading,.trailing], 4)
                .popover(isPresented: $popoverState.isShowing, arrowEdge: .bottom) {
                    CameraPopoverView(closePopover: { popoverState.isShowing = false })
                }
                .onReceive(updateTimer) { t in
                    recordingLength = SCContext.getRecordingLength()
                    // The timer gets longer at the first hour
                    resizeStatusBar()
                    let timePassed = Date.now.timeIntervalSince(SCContext.startTime ?? t)
                    if SCContext.autoStop != 0 && timePassed / 60 >= CGFloat(SCContext.autoStop) { SCContext.stopRecording() }
                    updateFloatingController()
                }
                if !miniStatusBar {
                    if SCContext.streamType != .systemaudio {
                        if SCContext.streamType != .idevice {
                            Button(action:{
                                popoverState.isShowing = true
                            }, label: {
                                ZStack {
                                    Rectangle()
                                        .fill(SCContext.isCameraRunning() ? Color.mygreen : .gray)
                                        .shadow(color: .black.opacity(0.3), radius: 4)
                                        .cornerRadius(4)
                                    Image("camera")
                                        .foregroundStyle(.white)
                                }.frame(width: 36).padding([.leading,.trailing], 4)
                            }).buttonStyle(.plain)
                        } else {
                            Button(action:{
                                DispatchQueue.main.async {
                                    if deviceWindow.isVisible { deviceWindow.close() } else { deviceWindow.orderFront(nil) }
                                }
                            }, label: {
                                ZStack {
                                    Rectangle()
                                        .fill(deviceWindow.isVisible ? Color.myblue : .gray.opacity(0.7))
                                        .shadow(color: .black.opacity(0.3), radius: 4)
                                        .cornerRadius(4)
                                    Image(systemName: "apps.ipad")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.white)
                                }.frame(width: 36).padding([.leading,.trailing], 4)
                            })
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if SCContext.showsRecovery {
                // A recording left by an earlier run is being mixed. Shown so that the app does not look hung when
                // quitting waits for it.
                ZStack {
                    Rectangle()
                        .fill(Color.mypurple)
                        .shadow(color: .black.opacity(0.3), radius: 4)
                        .cornerRadius(4)
                    Text(health.recoveryProgress.map { "Recovering… \(Int($0 * 100))%" } ?? "Recovering…")
                        .foregroundStyle(.white)
                        .font(.system(size: 13))
                }
                .help("A recording that an earlier run of QuickRecorder did not finish is being mixed. Quitting waits for it.")
                .padding([.leading,.trailing], 4)
            } else if ud.bool(forKey: "showMenubar") {
                Button(action: {
                    popoverState.isShowing = true
                }, label: {
                    ZStack {
                        Color.white.opacity(0.0001)
                        Image(systemName: "dot.circle.and.hand.point.up.left.fill")
                            .font(.system(size: 14, weight: .medium))
                            .offset(y: 1)
                    }
                })
                .buttonStyle(.plain)
                .popover(isPresented: $popoverState.isShowing, arrowEdge: .bottom) {
                    ContentViewNew().onAppear{ closeAllWindow() }
                }
            }
        }
        .onTapGesture {}
        .onHover { hovering in
            isHovering = hovering
            hideMousePointer = hovering
            hideScreenMagnifier = hovering
        }
    }
}

/// Main thread. Gives the status item, and the floating controller when it is shown, the width the pill needs now,
/// without building them anew.
func resizeStatusBar() {
    let width = getStatusBarWidth()
    if let button = statusBarItem.button, let iconView = button.subviews.first, iconView.frame.width != width {
        iconView.frame.size.width = width
        button.frame = iconView.frame
    }
    if controlPanel.isVisible, controlPanel.frame.width != width {
        var frame = controlPanel.frame
        frame.origin.x -= (width - frame.width) / 2
        frame.size.width = width
        controlPanel.setFrame(frame, display: true)
    }
}

/// Main thread. While a recording runs or is being saved and the status item cannot be seen (a full-screen app, a
/// hidden menu bar), the same pill is shown in a floating panel; it goes when the status item is visible again.
func updateFloatingController() {
    guard let visible = statusBarItem.button?.window?.occlusionState.contains(.visible) else { return }
    if visible || (SCContext.streamType == nil && !SCContext.isSaving) {
        controlPanel.close()
        return
    }
    if controlPanel.isVisible { return }
    guard let screen = SCContext.getScreenWithMouse() else { return }
    let width = getStatusBarWidth()
    let wX = (screen.frame.width - width) / 2
    let contentView = NSHostingView(rootView: StatusBarItem())
    contentView.frame = NSRect(x: wX, y: screen.visibleFrame.maxY, width: width, height: 24)
    controlPanel.setFrame(contentView.frame, display: true)
    controlPanel.contentView = contentView
    controlPanel.makeKeyAndOrderFront(nil)
}

func updateStatusBar() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        if SCContext.streamType == nil && !SCContext.isSaving && !SCContext.showsRecovery && !ud.bool(forKey: "showMenubar") {
            statusBarItem.isVisible = false
            return
        }
        guard let button = statusBarItem.button else { return }
        //let width = SCContext.streamType == nil ? 36 : ((SCContext.streamType == .idevice || SCContext.streamType == .systemaudio) ? 138 : 158)
        let iconView = NSHostingView(rootView: StatusBarItem().padding(.top, -1))
        iconView.frame = NSRect(x: 0, y: 1, width: getStatusBarWidth(), height: 21)
        button.subviews = [iconView]
        button.frame = iconView.frame
        button.setAccessibilityLabel("QuickRecorder")
        statusBarItem.isVisible = true
    }
}
