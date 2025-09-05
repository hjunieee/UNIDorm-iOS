//
//  ContentView.swift
//  unidorm
//
//  Created by 배현준 on 9/1/25.
//

import SwiftUI
import SystemConfiguration

struct ContentView: View {
    private let rootUrl = URL(string: "https://unidorm.inuappcenter.kr")!
    @State private var showAlert = false
    @State private var isConnected = false

    var body: some View {
        Group {
            if isConnected {
                WebView(url: rootUrl)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                Color.clear
            }
        }
        .onAppear { checkNetwork() }
        .alert("네트워크 연결 실패",
               isPresented: $showAlert) {
            Button("재시도") {
                // alert를 잠깐 닫았다가 다시 열도록 처리
                showAlert = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    checkNetwork()
                }
            }
            Button("앱 종료", role: .cancel) {
                exit(0)
            }
        } message: {
            Text("네트워크가 연결되어 있지 않습니다. 연결 후 다시 시도해주세요.")
        }
    }

    // 네트워크 체크
    private func checkNetwork() {
        if isConnectedToNetwork() {
            isConnected = true
            showAlert = false
        } else {
            isConnected = false
            showAlert = true
        }
    }

    // 네트워크 연결 여부 확인
    private func isConnectedToNetwork() -> Bool {
        var zeroAddress = sockaddr_in()
        zeroAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        zeroAddress.sin_family = sa_family_t(AF_INET)

        guard let defaultRouteReachability = withUnsafePointer(to: &zeroAddress, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                SCNetworkReachabilityCreateWithAddress(nil, $0)
            }
        }) else { return false }

        var flags = SCNetworkReachabilityFlags()
        if !SCNetworkReachabilityGetFlags(defaultRouteReachability, &flags) { return false }

        let isReachable = flags.contains(.reachable)
        let needsConnection = flags.contains(.connectionRequired)
        return isReachable && !needsConnection
    }
}

#Preview {
    ContentView()
}
