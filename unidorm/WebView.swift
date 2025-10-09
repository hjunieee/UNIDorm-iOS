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

// MARK: - SwiftUI에서 UIKit의 WKWebView를 사용하기 위한 래퍼(Wrapper) 뷰
struct WebView: UIViewRepresentable {
    var url: URL

    // MARK: - Coordinator 생성
    // SwiftUI 뷰와 UIKit 뷰 간의 통신을 담당할 Coordinator 객체를 생성합니다.
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - UIView 생성 (WKWebView 초기 설정)
    // 뷰가 처음 생성될 때 호출되며, WKWebView의 초기 구성을 담당합니다.
    func makeUIView(context: Context) -> WKWebView {
        // --- JavaScript와 Swift 간의 통신 설정 ---
        let contentController = WKUserContentController()
        // 웹에서 "loginSuccess", "routeChange" 메시지를 보내면 Swift(Coordinator)에서 받을 수 있도록 핸들러를 추가합니다.
        contentController.add(context.coordinator, name: "loginSuccess")
        contentController.add(context.coordinator, name: "routeChange")

        // --- 웹페이지 경로 변경 감지를 위한 JavaScript 주입 ---
        let routeObserverScriptSource = """
        (function() {
            // 현재 경로를 Swift로 보내는 함수
            function notifyPath() {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.routeChange) {
                    window.webkit.messageHandlers.routeChange.postMessage(window.location.pathname);
                }
            }
            // 브라우저 history 변경 이벤트를 감지하여 notifyPath 함수를 호출
            window.addEventListener('popstate', notifyPath);
            window.addEventListener('pushState', notifyPath);
            window.addEventListener('replaceState', notifyPath);
            notifyPath(); // 최초 로드 시 경로 전송
            // pushState, replaceState 이벤트가 기본적으로 없으므로 이벤트를 직접 발생시키는 코드
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
        // 위 스크립트를 웹뷰에 주입하도록 설정
        let routeObserverScript = WKUserScript(source: routeObserverScriptSource,
                                               injectionTime: .atDocumentEnd, // 문서 로드가 끝난 후 주입
                                               forMainFrameOnly: true)
        contentController.addUserScript(routeObserverScript)

        // --- WKWebView 최종 설정 ---
        let config = WKWebViewConfiguration()
        config.userContentController = contentController // 위에서 설정한 contentController를 적용

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator // 페이지 로드 관련 델리게이트
        webView.uiDelegate = context.coordinator       // alert, 새 창 열기 등 UI 관련 델리게이트
        webView.allowsBackForwardNavigationGestures = true // 스와이프로 뒤로/앞으로 가기 제스처 활성화
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never // Safe Area에 의해 콘텐츠가 밀리는 현상 방지
        return webView
    }

    // MARK: - UIView 업데이트
    // SwiftUI 뷰의 상태가 변경될 때 호출되며, WKWebView에 변경사항을 반영합니다.
    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 전달받은 url로 웹뷰를 로드합니다.
        uiView.load(URLRequest(url: url))
    }

    // MARK: - Coordinator 클래스
    // WKWebView의 델리게이트(Delegate) 역할을 수행하며, 웹뷰의 이벤트를 처리합니다.
    class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: WebView
        private var fcmToken: String = ""
        private var isWebViewLoaded: Bool = false

        init(_ parent: WebView) {
            self.parent = parent
        }

        // MARK: - (JS -> Swift) JavaScript로부터 메시지 수신
        // `contentController.add()`로 등록한 핸들러가 호출되는 부분입니다.
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            // 웹뷰의 경로가 변경될 때마다 호출됩니다.
            if message.name == "routeChange", let path = message.body as? String {
                print("📍 React Router 경로 변경 감지:", path)

                // 특정 경로에서는 뒤로가기 제스처를 비활성화합니다.
                let restrictedPaths: Set<String> = [
                    "/", "/home", "/roommate", "/groupPurchase",
                    "/groupPurchase/comingsoon", "/chat", "/mypage"
                ]

                if restrictedPaths.contains(path) {
                    message.webView?.allowsBackForwardNavigationGestures = false
                } else {
                    message.webView?.allowsBackForwardNavigationGestures = true
                }
            }
        }

        // MARK: - FCM 토큰 가져오기
        private func fetchFcmToken(for webView: WKWebView) {
            Messaging.messaging().token { [weak self] token, error in
                guard let self = self else { return }
                if let token = token {
                    self.fcmToken = token
                    self.postFcmTokenToWebView(webView) // 토큰을 가져온 후 웹뷰로 전달
                } else if let error = error {
                    print("⚠️ FCM 토큰 발급 실패:", error)
                }
            }
        }

        // MARK: - (Swift -> JS) FCM 토큰을 웹뷰로 전달
        private func postFcmTokenToWebView(_ webView: WKWebView) {
            // 웹뷰 로드가 완료되고 FCM 토큰이 있을 때만 실행
            guard isWebViewLoaded, !fcmToken.isEmpty else { return }
            // 웹페이지의 `window.onReceiveFcmToken` 함수를 호출하여 토큰을 전달
            let js = "window.onReceiveFcmToken && window.onReceiveFcmToken('\(fcmToken)'); void(0);"
            webView.evaluateJavaScript(js) { result, error in
                if let error = error {
                    print("❌ FCM 토큰 전달 실패:", error)
                } else {
                    print("✅ FCM 토큰 웹뷰 전달 완료")
                    print(self.fcmToken)
                }
            }
        }

        // MARK: - WKNavigationDelegate: 페이지 로드 완료
        // 웹페이지 콘텐츠 로드가 완료되었을 때 호출됩니다.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("✅ 페이지 로드 완료:", webView.url?.absoluteString ?? "")
            isWebViewLoaded = true
            fetchFcmToken(for: webView) // 로드 완료 후 FCM 토큰을 가져와 웹뷰로 전달
        }

        // MARK: - WKUIDelegate: JavaScript Alert 처리
        // 웹페이지의 `alert()` 함수를 네이티브 UIAlertController로 표시합니다.
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: message, message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "확인", style: .cancel) { _ in completionHandler() })
            DispatchQueue.main.async { webView.window?.rootViewController?.present(alert, animated: true) }
        }

        // MARK: - WKUIDelegate: JavaScript Confirm 처리
        // 웹페이지의 `confirm()` 함수를 네이티브 UIAlertController로 표시합니다.
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "취소", style: .default) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "확인", style: .destructive) { _ in completionHandler(true) })
            DispatchQueue.main.async { webView.window?.rootViewController?.present(alert, animated: true) }
        }

        // MARK: - WKUIDelegate: 새 창 열기 처리
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {

            guard let url = navigationAction.request.url else {
                return nil
            }

            // 외부 도메인 -> Safari 열기
            if !url.absoluteString.contains("unidorm.inuappcenter.kr") {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                return nil
            }

            // 내부 도메인 -> 현재 웹뷰에서 열기
            webView.load(URLRequest(url: url))
            return nil
        }

    }
}
