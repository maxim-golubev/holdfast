//
//  ContentView.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/16.
//

import SwiftUI
import AVFoundation
import ScreenCaptureKit

struct ContentViewNew: View {
    @State private var window: NSWindow?
    @State private var xmarkGlowing = false
    @State private var infoGlowing = false
    @State private var micGlowing = false
    @State private var isPopoverShowing = false
    @State private var micList = SCContext.getMicrophone()
    @AppStorage("recordMic") private var recordMic: Bool = false
    @AppStorage("showOnDock") private var showOnDock: Bool = true
    @AppStorage("showMenubar") private var showMenubar: Bool = false

    var appDelegate = AppDelegate.shared
    
    var body: some View {
        ZStack {
            VStack {
                HStack {
                    Button(action: {
                        closeMainWindow()
                        appDelegate.createNewWindow(view: ScreenSelector(), title: "Screen Selector".local)
                    }, label: {
                        SelectorView(title: "Screen".local, symbol: "tv.inset.filled").cornerRadius(8)
                    }).buttonStyle(.plain)
                    Divider().frame(height: 70)
                    Button(action: {
                        closeMainWindow()
                        SCContext.updateAvailableContent {
                            DispatchQueue.main.async {
                                appDelegate.showAreaSelector(size: NSSize(width: 600, height: 450))
                                var currentDisplay = SCContext.getSCDisplayWithMouse()
                                mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .rightMouseDown, .leftMouseDown, .otherMouseDown]) { event in
                                    let display = SCContext.getSCDisplayWithMouse()
                                    if display != currentDisplay {
                                        currentDisplay = display
                                        closeAllWindow()
                                        appDelegate.showAreaSelector(size: NSSize(width: 600, height: 450))
                                    }
                                }
                            }
                        }
                    }, label: {
                        SelectorView(title: "Screen Area".local, symbol: "viewfinder").cornerRadius(8)
                    }).buttonStyle(.plain)
                    Divider().frame(height: 70)
                    Button(action: {
                        closeMainWindow()
                        appDelegate.createNewWindow(view: AppSelector(), title: "App Selector".local)
                    }, label: {
                        SelectorView(title: "Application".local, symbol: "app", overlayer: "App")
                            .cornerRadius(8)
                    }).buttonStyle(.plain)
                    Divider().frame(height: 70)
                    Button(action: {
                        closeMainWindow()
                        appDelegate.createNewWindow(view: WinSelector(), title: "Window Selector".local)
                    }, label: {
                        SelectorView(title: "Window".local, symbol: "macwindow").cornerRadius(8)
                    }).buttonStyle(.plain)
                }
                HStack(spacing: 27) {
                    VStack { Divider().frame(width: 100) }
                    VStack { Divider().frame(width: 100) }
                    VStack { Divider().frame(width: 100) }
                    VStack { Divider().frame(width: 100) }
                }
                HStack {
                    ZStack(alignment: Alignment(horizontal: .center, vertical: .bottom)) {
                        Button(action: {
                            if let display = SCContext.getSCDisplayWithMouse() {
                                closeMainWindow()
                                appDelegate.createCountdownPanel(screen: display) {
                                    AppDelegate.shared.prepRecord(type: "audio", screens: SCContext.getSCDisplayWithMouse(), windows: nil, applications: nil)
                                }
                            }
                        }, label: {
                            SelectorView(title: "System Audio".local, symbol: "waveform").cornerRadius(8)
                        }).buttonStyle(.plain)
                        Button {} label: {
                            HStack(spacing: -2) {
                                Button {
                                    recordMic.toggle()
                                } label: {
                                    ZStack {
                                        Image(systemName: "square.fill")
                                            .font(.system(size: 15, weight: .medium))
                                            .foregroundColor(.primary)
                                            .colorInvert()
                                            .opacity(0.2)
                                        Image(systemName: recordMic ? "checkmark.square" : "square")
                                            .font(.system(size: 16, weight: .medium))
                                    }
                                }
                                .buttonStyle(.plain)
                                .onChange(of: recordMic) { _ in  Task { await SCContext.performMicCheck() }}
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(recordMic ? .primary : .secondary)
                                    .frame(width: 24)
                                    .padding(.leading, 1)
                                MicPicker(micList: micList)
                                    .frame(width: 90)
                                    .background(
                                        ZStack {
                                            Color.primary
                                                .opacity(0.1)
                                                .cornerRadius(4)
                                                .padding(.vertical, -1)
                                                .padding(.horizontal, 3)
                                                .padding(.trailing, -16)
                                            Image(systemName: "chevron.up.chevron.down")
                                                .offset(x: 50)
                                        }
                                    )
                                    .disabled(!recordMic)
                                    .padding(.leading, -10)
                                    .frame(width: 99)
                            }.padding(.leading, -5)
                        }
                        .buttonStyle(.plain)
                        .scaleEffect(0.69)
                        .padding(.bottom, 4)
                        .frame(width: 110)
                        .background(.primary.opacity(0.00001))
                    }.frame(height: 80)
                    Divider().frame(height: 70)
                    Button(action: {
                        isPopoverShowing = true
                    }, label: {
                        SelectorView(title: "Mobile Device".local, symbol: "apps.ipad").cornerRadius(8)
                    }).buttonStyle(.plain)
                        .popover(isPresented: $isPopoverShowing, arrowEdge: .bottom) {
                            iDevicePopoverView(closePopover: { isPopoverShowing = false })
                        }
                    Divider().frame(height: 70)
                    Button(action: {
                        closeMainWindow()
                        appDelegate.openSettingPanel()
                    }, label: {
                        SelectorView(title: "Preferences".local, symbol: "gearshape").cornerRadius(8)
                    }).buttonStyle(.plain)
                    Divider().frame(height: 70)
                    Button(action: {
                        NSApp.terminate(self)
                    }, label: {
                        SelectorView(title: "Quit".local, symbol: "xmark.circle")
                            .cornerRadius(8)
                            .foregroundStyle(.darkMyRed)
                    }).buttonStyle(.plain)
                }
            }.padding(10)
        }
    }
}
