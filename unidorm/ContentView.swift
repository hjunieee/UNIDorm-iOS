//
//  ContentView.swift
//  unidorm
//
//  Created by 배현준 on 9/1/25.
//

import SwiftUI

struct ContentView: View {
    // 뷰에서 사용할 웹뷰 URL
    private let rootUrl = URL(string: "https://unidorm.inuappcenter.kr")!

    var body: some View {
        VStack {
            WebView(url: rootUrl)
                .edgesIgnoringSafeArea(.all)
        }
    }
}

#Preview {
    ContentView()
}
