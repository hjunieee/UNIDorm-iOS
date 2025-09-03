//
//  WebView.swift
//  unidorm
//
//  Created by 배현준 on 9/1/25.
//

import SwiftUI
import UIKit
import WebKit
import FirebaseMessaging

// WKWebView를 SwiftUI 뷰로 래핑
struct WebView: UIViewRepresentable {
    // URL을 외부에 노출하여 필요에 따라 변경 가능하게 함
    var url: URL

    // Coordinator 클래스를 사용하여 WKWebView와 SwiftUI 간의 통신을 관리
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // UIKit의 WKWebView를 생성하고 초기화
    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        
        // 로그인 성공 감지
        contentController.add(context.coordinator, name: "loginSuccess")
        // 라우트 변경 감지
        contentController.add(context.coordinator, name: "routeChange")
        
        // React Router 라우트 변경 감지 스크립트 주입
        let routeObserverScriptSource = """
        (function() {
            function notifyPath() {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.routeChange) {
                    window.webkit.messageHandlers.routeChange.postMessage(window.location.pathname);
                }
            }
            window.addEventListener('popstate', notifyPath);
            window.addEventListener('pushState', notifyPath);
            window.addEventListener('replaceState', notifyPath);
            notifyPath();
            (function(history){
                var pushState = history.pushState;
                history.pushState = function(state) {
                    pushState.apply(history, arguments);
                    window.dispatchEvent(new Event('pushState'));
                };
                var replaceState = history.replaceState;
                history.replaceState = function(state) {
                    replaceState.apply(history, arguments);
                    window.dispatchEvent(new Event('replaceState'));
                };
            })(window.history);
        })();
        """
        let routeObserverScript = WKUserScript(source: routeObserverScriptSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        contentController.addUserScript(routeObserverScript)
        
        // 초기 로딩 시 localStorage에서 토큰 확인
        let loginScriptSource = """
        if (window.localStorage.getItem('tokenInfo')) {
            window.webkit.messageHandlers.loginSuccess.postMessage('ok');
        }
        """
        let loginScript = WKUserScript(source: loginScriptSource, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        contentController.addUserScript(loginScript)

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        
        // ✅ 뒤로가기 제스처 허용
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    // UIKit 뷰가 업데이트될 때 호출
    func updateUIView(_ uiView: WKWebView, context: Context) {
        let request = URLRequest(url: url)
        uiView.load(request)
    }

    // WKWebViewDelegate 역할을 수행하는 Coordinator 클래스
    class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: WebView
        private var previousPath: String?
        
        init(_ parent: WebView) {
            self.parent = parent
        }
        
        // JavaScript 메시지 처리
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "routeChange", let path = message.body as? String {
                print("📍 React Router 경로 변경 감지:", path)
                
                // ✅ 뒤로가기 제스처를 제한할 경로 목록
                let restrictedPaths: Set<String> = [
                    "/",
                    "/home",
                    "/roommate",
                    "/groupPurchase",
                    "/groupPurchase/comingsoon",
                    "/chat",
                    "/mypage"
                ]
                
                if restrictedPaths.contains(path) {
                    message.webView?.allowsBackForwardNavigationGestures = false
                    print("🚫 뒤로가기 제스처 차단됨 (\(path))")
                } else {
                    message.webView?.allowsBackForwardNavigationGestures = true
                    print("✅ 뒤로가기 제스처 허용됨 (\(path))")
                }
                
                // 로그인 → 홈 이동 시 FCM 처리
                if previousPath == "/login" && path == "/home" {
                    print("🎉 로그인 완료 후 홈으로 이동 감지됨")
                    self.postFcmTokenAfterLogin(webView: message.webView)
                }
                previousPath = path
            }
        }

        
        // 로그인 성공 후 FCM 토큰 처리
        func postFcmTokenAfterLogin(webView: WKWebView?) {
            guard let webView = webView else { return }
            
            let js = "window.localStorage.getItem('accessToken');"
            webView.evaluateJavaScript(js) { result, error in
                if let accessToken = result as? String,
                   !accessToken.isEmpty {
                    print("✅ accessToken 존재:", accessToken.prefix(10), "…")
                    Task {
                        await self.issueFcmTokenAndPost(accessToken: accessToken)
                    }
                } else {
                    print("⚠️ accessToken 없음")
                }
            }
        }

        // FCM 토큰 발급 및 서버 전송
        private func issueFcmTokenAndPost(accessToken: String) async {
            do {
                try await Messaging.messaging().deleteToken()
                let newToken = try await Messaging.messaging().token()
                print("📌 발급된 FCM 토큰:", newToken)
                await postFcmTokenToServer(fcmToken: newToken, accessToken: accessToken)
            } catch {
                print("FCM 토큰 처리 실패:", error)
            }
        }

        private func postFcmTokenToServer(fcmToken: String, accessToken: String) async {
            guard let url = URL(string: "https://unidorm-server.inuappcenter.kr/fcm/token") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") // ✅ accessToken 헤더 추가

            let body: [String: String] = ["fcmToken": fcmToken]
            request.httpBody = try? JSONEncoder().encode(body)
            
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    print("✅ FCM 토큰 등록 성공")
                } else {
                    print("❌ FCM 토큰 등록 실패")
                }
            } catch {
                print("서버 전송 오류:", error)
            }
        }


    
        // JavaScript alert 처리
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alertController = UIAlertController(title: message, message: nil, preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: "확인", style: .cancel) { _ in completionHandler() })
            DispatchQueue.main.async {
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootViewController = windowScene.windows.first?.rootViewController {
                    rootViewController.present(alertController, animated: true)
                }
            }

        }

        // JavaScript confirm 처리
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alertController = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: "취소", style: .default) { _ in completionHandler(false) })
            alertController.addAction(UIAlertAction(title: "확인", style: .destructive) { _ in completionHandler(true) })
            DispatchQueue.main.async {
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let rootViewController = windowScene.windows.first?.rootViewController {
                    rootViewController.present(alertController, animated: true)
                }
            }

        }

        // 새 창 열기 처리
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            return nil
        }
    }
}
