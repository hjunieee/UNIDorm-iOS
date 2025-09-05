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

struct WebView: UIViewRepresentable {
    var url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        
        // 로그인 성공 감지 (필요시)
        contentController.add(context.coordinator, name: "loginSuccess")
        // 라우트 변경 감지
        contentController.add(context.coordinator, name: "routeChange")
        
        // React Router 경로 변경 감지 스크립트
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
        let routeObserverScript = WKUserScript(source: routeObserverScriptSource,
                                               injectionTime: .atDocumentEnd,
                                               forMainFrameOnly: true)
        contentController.addUserScript(routeObserverScript)
        
        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        let request = URLRequest(url: url)
        uiView.load(request)
    }

    class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: WebView
        private var previousPath: String?
        private var isWebViewLoaded: Bool = false
        private var fcmToken: String = ""

        init(_ parent: WebView) {
            self.parent = parent
            super.init()
            // 초기화 시점에서는 FCM 토큰 발급하지 않음
        }

        // MARK: - WKScriptMessageHandler
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "routeChange", let path = message.body as? String {
                print("📍 React Router 경로 변경 감지:", path)

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
                } else {
                    message.webView?.allowsBackForwardNavigationGestures = true
                }

                previousPath = path
            }
        }

        // MARK: - FCM 토큰 발급 및 웹뷰 전달
        private func fetchFcmToken(webView: WKWebView) {
            Messaging.messaging().token { [weak self] token, error in
                guard let self = self else { return }
                if let token = token {
                    self.fcmToken = token
                    print("📌 발급된 FCM 토큰:", token)
                    self.postFcmTokenToWebView(webView: webView)
                } else if let error = error {
                    print("⚠️ FCM 토큰 발급 실패:", error)
                }
            }
        }

        private func postFcmTokenToWebView(webView: WKWebView) {
            guard !fcmToken.isEmpty else { return }
            let js = "window.onReceiveFcmToken && window.onReceiveFcmToken('\(fcmToken)');"
            webView.evaluateJavaScript(js) { result, error in
                if let error = error {
                    print("❌ FCM 토큰 전달 실패:", error)
                } else {
                    print("✅ FCM 토큰 웹뷰 전달 완료")
                }
            }
        }

        // MARK: - WKNavigationDelegate
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("✅ 페이지 로드 완료:", webView.url?.absoluteString ?? "")
            isWebViewLoaded = true
            fetchFcmToken(webView: webView) // 웹뷰 로딩 완료 후 FCM 토큰 발급
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: message, message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "확인", style: .cancel) { _ in completionHandler() })
            DispatchQueue.main.async { webView.window?.rootViewController?.present(alert, animated: true) }
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "취소", style: .default) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "확인", style: .destructive) { _ in completionHandler(true) })
            DispatchQueue.main.async { webView.window?.rootViewController?.present(alert, animated: true) }
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}
