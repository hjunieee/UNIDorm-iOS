//
//  AppDeligate.swift
//  unidorm
//
//  Created by 배현준 on 9/1/25.
//

import UIKit
import FirebaseCore
import FirebaseMessaging
import UserNotifications

class AppDelegate: UIResponder, UIApplicationDelegate {
    
    // 알림 클릭 시 임시 저장될 대상 웹 뷰 라우팅 경로
    static var pendingRoute: String? = nil

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        
        // Firebase 초기화
        FirebaseApp.configure()
        
        // 알림 권한 요청 및 대리자 설정
        UNUserNotificationCenter.current().delegate = self
        
        let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
        UNUserNotificationCenter.current().requestAuthorization(
            options: authOptions, completionHandler: { _, _ in }
        )
        
        // 원격 알림 등록
        application.registerForRemoteNotifications()
        
        // Firebase Messaging 대리자 설정
        Messaging.messaging().delegate = self
        
        return true
    }
    
    // MARK: UISceneSession Lifecycle
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration",
                                    sessionRole: connectingSceneSession.role)
    }
    
    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {}
    
    // MARK: APNs 토큰 전달
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        
        // APNs 토큰을 Firebase에 전달
        Messaging.messaging().apnsToken = deviceToken
        
        // APNs 토큰 확인용 로그 (선택)
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("APNs 토큰:", tokenString)
    }
    
    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("원격 알림 등록 실패:", error)
    }
    
    
}

// MARK: Firebase Messaging Delegate
extension AppDelegate: MessagingDelegate {
    // FCM 토큰 갱신 시 로그만 출력
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        print("Firebase registration token 갱신됨: \(String(describing: fcmToken))")
    }
}

// MARK: UNUserNotificationCenter Delegate
extension AppDelegate: UNUserNotificationCenterDelegate {
    
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .badge, .sound])
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        print("🔔 알림 터치 수신 (userInfo):", userInfo)
        
        var targetPath = ""
        
        // 1. 범용 경로 스펙: path 필드가 존재하면 최우선 적용
        if let path = userInfo["path"] as? String, !path.isEmpty {
            targetPath = path
        }
        // 2. 하위 호환성 스펙: type 및 개별 ID 필드가 올 경우 매핑 적용
        else if let type = userInfo["type"] as? String {
            var idString: String? = nil
            if type == "CHAT" {
                if let idVal = userInfo["chatRoomId"] as? String {
                    idString = idVal
                } else if let idVal = userInfo["chatRoomId"] as? Int {
                    idString = String(idVal)
                }
                if let id = idString {
                    targetPath = "/chat/\(id)"
                }
            } else if type == "NOTICE" {
                if let idVal = userInfo["noticeId"] as? String {
                    idString = idVal
                } else if let idVal = userInfo["noticeId"] as? Int {
                    idString = String(idVal)
                }
                if let id = idString {
                    targetPath = "/notice/\(id)"
                }
            }
        }
        
        if !targetPath.isEmpty {
            AppDelegate.pendingRoute = targetPath
            // 이미 화면이 떠 있을 때 바로 네비게이션 시키기 위해 NotificationCenter로 알림을 보냅니다.
            NotificationCenter.default.post(name: NSNotification.Name("NavigateToRoute"), object: targetPath)
            print("📍 설정된 대기 라우트 경로:", targetPath)
        }
        
        completionHandler()
    }
}
