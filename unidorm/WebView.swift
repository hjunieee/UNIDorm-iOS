import SwiftUI
import UIKit
import WebKit
import FirebaseMessaging

struct WebView: UIViewRepresentable {
    let url: URL
    
    // 뒤로가기 제스처가 제한되는 경로 상수화
    private let restrictedPaths: Set<String> = [
        "/", "/home", "/roommate","/roommate/my", "/groupPurchase",
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
        contentController.add(context.coordinator, name: "enterDetailView") // ✅ 상세 화면 진입 브릿지 추가
        
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
        
        // Coordinator가 WebView를 참조할 수 있도록 설정
        context.coordinator.webView = webView
        
        // ✨ [추가] 앱 실행 시 자동 캐시 삭제 후 첫 로드
        context.coordinator.clearCacheAndLoad(webView, request: URLRequest(url: url))
        
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 초기 로드는 makeUIView에서 처리하므로 비워둡니다.
    }

    // MARK: - Coordinator
    class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler, WKDownloadDelegate {
        var parent: WebView
        private var fcmToken: String = ""
        private var isWebViewLoaded: Bool = false
        
        // WebView에 대한 약한 참조 추가 (evaluateJavaScript 등을 처리하기 위함)
        weak var webView: WKWebView?
        
        init(_ parent: WebView) {
            self.parent = parent
            super.init()
            // 알림 클릭 시 전달받은 라우팅 이동 이벤트를 수신하도록 옵저버 등록
            NotificationCenter.default.addObserver(self, selector: #selector(handleRouteNotification(_:)), name: NSNotification.Name("NavigateToRoute"), object: nil)
        }
        
        deinit {
            NotificationCenter.default.removeObserver(self)
        }
        
        @objc private func handleRouteNotification(_ notification: Notification) {
            guard let path = notification.object as? String,
                  let webView = self.webView else { return }
            
            DispatchQueue.main.async {
                self.navigateToPendingRouteWithRetry(webView: webView, route: path)
                print("📲 NotificationCenter 수신에 의해 라우팅 강제 이동 실행: \(path)")
            }
        }
        
        // ✅ 웹앱의 window.navigateToPath 함수가 마운트될 때까지 재시도하며 이동하는 헬퍼 메서드
        private func navigateToPendingRouteWithRetry(webView: WKWebView, route: String, retryCount: Int = 0) {
            let checkJs = "typeof window.navigateToPath === 'function' ? 'ready' : 'not_ready'"
            webView.evaluateJavaScript(checkJs) { [weak self] (result, error) in
                if let status = result as? String, status == "ready" {
                    let navigateJs = "window.navigateToPath('\(route)'); void(0);"
                    webView.evaluateJavaScript(navigateJs) { (_, navigateError) in
                        if let navigateError = navigateError {
                            print("❌ [라우팅 실행] evaluateJavaScript 에러:", navigateError.localizedDescription)
                        } else {
                            print("✅ [라우팅 실행] JS 실행 및 화면 이동 성공 (경로: \(route))")
                            AppDelegate.pendingRoute = nil
                        }
                    }
                } else {
                    if retryCount < 30 { // 최대 3초 (100ms * 30) 동안 확인하며 대기
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            self?.navigateToPendingRouteWithRetry(webView: webView, route: route, retryCount: retryCount + 1)
                        }
                    } else {
                        print("⚠️ [라우팅 대기] 실패: 3초 대기했으나 웹앱에 window.navigateToPath가 정의되지 않음")
                    }
                }
            }
        }

        // ✨ [추가] 캐시 삭제 후 페이지 로드하는 통합 메서드
        func clearCacheAndLoad(_ webView: WKWebView, request: URLRequest) {
            let dataTypes = Set([WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeDiskCache])
            let dateFrom = Date(timeIntervalSince1970: 0)
            
            WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: dateFrom) {
                DispatchQueue.main.async {
                    webView.load(request)
                    print("✅ 앱 실행: 캐시 삭제 및 초기 로드 완료")
                }
            }
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
            case "enterDetailView":
                handleEnterDetailView(message)
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
            
            // 대기 중인 라우팅 경로가 존재할 경우 마운트 시점까지 재시도하며 즉시 이동 처리
            if let pendingRoute = AppDelegate.pendingRoute {
                DispatchQueue.main.async {
                    self.navigateToPendingRouteWithRetry(webView: webView, route: pendingRoute)
                }
            }
        }
        
        // ✅ 상세 화면 진입 브릿지 메시지 핸들러
        private func handleEnterDetailView(_ message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            
            let path = body["path"] as? String
            let type = body["type"] as? String
            let id = body["id"] as? String
            
            print("👁️ 상세 화면 진입 브릿지 수신 (path: \(path ?? "nil"), type: \(type ?? "nil"), id: \(id ?? "nil"))")
            removeSpecificNotifications(type: type, id: id, path: path)
        }
        
        // ✅ 특정 채팅방 또는 공지사항 알림 일괄 삭제 로직 (경로 매칭 & 레거시 방식 호환)
        private func removeSpecificNotifications(type: String?, id: String?, path: String?) {
            let center = UNUserNotificationCenter.current()
            center.getDeliveredNotifications { notifications in
                let targetIdentifiers = notifications.filter { notification in
                    let userInfo = notification.request.content.userInfo
                    
                    // 1. 새 스펙: path 기준 삭제 매칭
                    if let reqPath = path {
                        // 푸시 페이로드 자체에 path가 있으면 바로 비교
                        if let pushPath = userInfo["path"] as? String {
                            return reqPath == pushPath
                        }
                        
                        // 하위 호환성: 푸시에는 path가 없지만 레거시 정보로 로컬 복원한 경로와 같은지 비교
                        var pushCalculatedPath = ""
                        if let pushType = userInfo["type"] as? String {
                            if pushType == "CHAT" {
                                if let chatRoomId = userInfo["chatRoomId"] as? String {
                                    pushCalculatedPath = "/chat/\(chatRoomId)"
                                } else if let chatRoomId = userInfo["chatRoomId"] as? Int {
                                    pushCalculatedPath = "/chat/\(chatRoomId)"
                                }
                            } else if pushType == "NOTICE" {
                                if let noticeId = userInfo["noticeId"] as? String {
                                    pushCalculatedPath = "/notice/\(noticeId)"
                                } else if let noticeId = userInfo["noticeId"] as? Int {
                                    pushCalculatedPath = "/notice/\(noticeId)"
                                }
                            }
                        }
                        if !pushCalculatedPath.isEmpty {
                            return reqPath == pushCalculatedPath
                        }
                    }
                    
                    // 2. 레거시 스펙: type 및 id 기준 매칭 (하위 호환성)
                    if let reqType = type, let reqId = id {
                        let pushType = userInfo["type"] as? String
                        if reqType == "CHAT" {
                            if let chatRoomId = userInfo["chatRoomId"] as? String {
                                return pushType == "CHAT" && chatRoomId == reqId
                            } else if let chatRoomId = userInfo["chatRoomId"] as? Int {
                                return pushType == "CHAT" && String(chatRoomId) == reqId
                            }
                        } else if reqType == "NOTICE" {
                            if let noticeId = userInfo["noticeId"] as? String {
                                return pushType == "NOTICE" && noticeId == reqId
                            } else if let noticeId = userInfo["noticeId"] as? Int {
                                return pushType == "NOTICE" && String(noticeId) == reqId
                            }
                        }
                    }
                    
                    return false
                }.map { $0.request.identifier }
                
                if !targetIdentifiers.isEmpty {
                    center.removeDeliveredNotifications(withIdentifiers: targetIdentifiers)
                    print("🧹 알림 센터에서 매칭 알림 제거 완료: \(targetIdentifiers)")
                }
            }
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
