import SwiftUI
import UIKit
import WebKit
import FirebaseMessaging

struct WebView: UIViewRepresentable {
    let url: URL
    
    // 뒤로가기 제스처가 제한되는 경로 상수화
    private let restrictedPaths: Set<String> = [
        "/", "/home", "/roommate", "/groupPurchase",
        "/groupPurchase/comingsoon", "/chat", "/mypage"
    ]

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        
        // 1. 브릿지 핸들러 등록
        contentController.add(context.coordinator, name: "loginSuccess")
        contentController.add(context.coordinator, name: "routeChange")
        contentController.add(context.coordinator, name: "requestAppUpdate") // ✅ 추가된 브릿지
        
        // 2. JS 스크립트 주입 (경로 감지)
        let script = WKUserScript(source: WebViewScripts.routeObserver,
                                 injectionTime: .atDocumentEnd,
                                 forMainFrameOnly: true)
        contentController.addUserScript(script)
        
        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 이미 로드된 경우 중복 로드 방지 (선택 사항)
        if uiView.url == nil {
            uiView.load(URLRequest(url: url))
        }
    }

    // MARK: - Coordinator
    class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler, WKDownloadDelegate {
        var parent: WebView
        private var fcmToken: String = ""
        private var isWebViewLoaded: Bool = false
        
        init(_ parent: WebView) {
            self.parent = parent
        }

        // JS -> Swift 메시지 처리
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "routeChange":
                handleRouteChange(message)
            case "requestAppUpdate":
                handleAppUpdate(message.webView)
            case "loginSuccess":
                print("🔑 로그인 성공 메시지 수신")
            default:
                break
            }
        }

        // 경로 변경 처리
        private func handleRouteChange(_ message: WKScriptMessage) {
            guard let path = message.body as? String else { return }
            print("📍 경로 변경:", path)
            message.webView?.allowsBackForwardNavigationGestures = !parent.restrictedPaths.contains(path)
        }

        // ✅ 앱 최적화(캐시 삭제) 처리
        private func handleAppUpdate(_ webView: WKWebView?) {
            AlertHelper.showConfirm(
                title: "화면 업데이트",
                message: "로그인 정보는 유지되며, 최신 화면으로 업데이트를 진행합니다."
            ) { [weak self] in
                self?.clearCacheAndReload(webView)
            }
        }

        // ✅ 세션 유지형 캐시 삭제 로직
        private func clearCacheAndReload(_ webView: WKWebView?) {
            // 삭제할 데이터 타입 정의 (쿠키, 로컬스토리지 제외)
            let dataTypes = Set([WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeDiskCache])
            let dateFrom = Date(timeIntervalSince1970: 0)
            
            WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: dateFrom) {
                DispatchQueue.main.async {
                    webView?.reload()
                    print("✅ iOS 캐시 삭제 및 새로고침 완료")
                }
            }
        }

        // FCM 토큰 처리
        private func fetchFcmToken(for webView: WKWebView, retry: Int = 0) {
            Messaging.messaging().token { [weak self] token, error in
                guard let self = self, let token = token else {
                    if retry < 3 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self?.fetchFcmToken(for: webView, retry: retry + 1)
                        }
                    }
                    return
                }
                self.fcmToken = token
                self.postToken(webView)
            }
        }

        private func postToken(_ webView: WKWebView) {
            guard isWebViewLoaded, !fcmToken.isEmpty else { return }
            let js = "window.onReceiveFcmToken && window.onReceiveFcmToken('\(fcmToken)');"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isWebViewLoaded = true
            fetchFcmToken(for: webView)
        }

        // UI 처리 (Alert, Confirm, 새 창)
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            AlertHelper.showAlert(message: message, completion: completionHandler)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            AlertHelper.showConfirm(message: message, completion: completionHandler)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, !url.absoluteString.contains("unidorm.inuappcenter.kr") {
                UIApplication.shared.open(url)
                return nil
            }
            webView.load(action.request)
            return nil
        }
        
        // 다운로드 로직은 기존 기능과 동일하게 유지 (생략 가능하나 가독성을 위해 구조 유지 가능)
        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }
        
        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(suggestedFilename)
            completionHandler(path)
        }
        
        func downloadDidFinish(_ download: WKDownload) {
            AlertHelper.showAlert(title: "다운로드 완료", message: "파일이 저장되었습니다.")
        }
    }
}

// MARK: - 지원용 구조체 (Scripts & Helpers)

struct WebViewScripts {
    static let routeObserver = """
    (function() {
        function notifyPath() {
            if (window.webkit?.messageHandlers?.routeChange) {
                window.webkit.messageHandlers.routeChange.postMessage(window.location.pathname);
            }
        }
        window.addEventListener('popstate', notifyPath);
        ['pushState', 'replaceState'].forEach(event => {
            const original = history[event];
            history[event] = function() {
                original.apply(this, arguments);
                notifyPath();
            };
        });
        notifyPath();
    })();
    """
}

struct AlertHelper {
    static func showAlert(title: String? = nil, message: String, completion: (() -> Void)? = nil) {
        let alert = UIAlertController(title: title ?? message, message: title == nil ? nil : message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "확인", style: .cancel) { _ in completion?() })
        present(alert)
    }

    static func showConfirm(title: String? = nil, message: String, completion: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "취소", style: .default) { _ in completion(false) })
        alert.addAction(UIAlertAction(title: "확인", style: .destructive) { _ in completion(true) })
        present(alert)
    }
    
    // 오버로딩: 최적화 확인용
    static func showConfirm(title: String, message: String, onConfirm: @escaping () -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "취소", style: .cancel))
        alert.addAction(UIAlertAction(title: "확인", style: .default) { _ in onConfirm() })
        present(alert)
    }

    private static func present(_ alert: UIAlertController) {
        DispatchQueue.main.async {
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = scene.windows.first?.rootViewController {
                rootVC.present(alert, animated: true)
            }
        }
    }
}
