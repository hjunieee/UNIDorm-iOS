//
//  unidormApp.swift
//  unidorm
//
//  Created by 배현준 on 9/1/25.
//

import SwiftUI

@main
struct unidormApp: App {
    // AppDelegate를 등록해줌
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
