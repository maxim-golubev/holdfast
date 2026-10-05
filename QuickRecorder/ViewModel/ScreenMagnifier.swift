//
//  ScreenMagnifier.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/25.
//
import SwiftUI

/// The magnified piece of the screen under the pointer, three times its size.
struct ScreenMagnifier: View {
    let screenShot: NSImage
    
    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .overlay(
                    Rectangle()
                        .stroke(style: StrokeStyle(lineWidth: 2))
                        .padding(1)
                        .foregroundColor(.blue.opacity(0.5))
                )
                .background(
                    Image(nsImage: screenShot)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: screenShot.size.width * 3, height: screenShot.size.height * 3)
                )
        }
    }
}
