//
//  ContentView.swift
//  unidorm
//
//  Created by 배현준 on 9/1/25.
//

import SwiftUI

struct ContentView: View {
    private let rootUrl = URL(string: "https://unidorm.inuappcenter.kr")!

    var body: some View {
        WebView(url: rootUrl)
            .ignoresSafeArea(edges: .bottom) // ⬅️ 하단 SafeArea만 무시
    }
}

#Preview {
    ContentView()
}
