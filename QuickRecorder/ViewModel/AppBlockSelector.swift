//
//  BundleSelector.swift
//  QuickRecorder
//
//  Created by apple on 2024/4/28.
//

import SwiftUI
import Foundation

struct BundleSelector: View {
    @State private var Bundles = [AppInfo]()
    @State private var isShowingFilePicker = false
    
    var body: some View {
        ZStack(alignment: Alignment(horizontal: .trailing, vertical: .bottom)) {
            List(Bundles, id: \.self) { item in
                HStack{
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .onTapGesture {
                            if let index = Bundles.firstIndex(of: item) {
                                _ = withAnimation { Bundles.remove(at: index) }
                            }
                        }
                    Text(item.displayName).font(.system(size: 12))
                }
            }
            Button(action: {
                self.isShowingFilePicker = true
            }) {
                Image(systemName: "plus.square.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            }.buttonStyle(.plain).offset(y: -1)
        }
        .onAppear {
            Bundles = AppSettings.hiddenApps
        }
        .onChange(of: Bundles) { bundles in
            AppSettings.hiddenApps = bundles
        }
        .fileImporter(isPresented: $isShowingFilePicker, allowedContentTypes: [.application]) { result in
            do {
                guard let appID = try Bundle(url: result.get())?.bundleIdentifier else { return }
                guard let displayName = try Bundle(url: result.get())?.fileName else { return }
                let app = AppInfo(bundleID: appID, displayName: displayName)
                if !self.Bundles.contains(app) {
                    withAnimation { Bundles.append(app) }
                }
            } catch {
                print("File selection failed: \(error.localizedDescription)")
            }
        }
    }
}

extension Bundle {
    var bundleName: String? { return object(forInfoDictionaryKey: "CFBundleName") as? String }
    var fileName: String { return self.bundleURL.lastPathComponent }
}
