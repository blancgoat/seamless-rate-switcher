import AppKit
import Foundation
import RateCore

/// 설정 창의 "업데이트 확인" 버튼을 누르면 GitHub의 최신 릴리스와 지금 버전을 비교한다.
/// 저절로 확인하지 않고, 서명되지 않은 앱이라 스스로 교체하지도 않는다 (릴리스 페이지로 안내만 한다).
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Release: Equatable {
        let version: String
        let url: URL
    }

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    var available: Release? {
        if case let .available(release) = status { return release }
        return nil
    }

    static let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    private static let latestURL = URL(string: "https://api.github.com/repos/blancgoat/seamless-rate-switcher/releases/latest")!

    private init() {}

    func check() {
        guard status != .checking else { return }
        status = .checking
        var request = URLRequest(url: Self.latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SeamlessRateSwitcher/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let result = Self.parse(data: data, response: response, error: error)
            DispatchQueue.main.async { self?.status = result }
        }.resume()
    }

    private static func parse(data: Data?, response: URLResponse?, error: Error?) -> Status {
        if let error { return .failed(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return .failed("HTTP \(code)")
        }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return isNewer(version, than: currentVersion) ? .available(Release(version: version, url: page)) : .upToDate
    }

    /// "1.10.0" > "1.9.2". 숫자가 아닌 꼬리(-beta 등)는 무시한다
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    func openReleasePage() {
        let url = available?.url ?? URL(string: "https://github.com/blancgoat/seamless-rate-switcher/releases/latest")!
        NSWorkspace.shared.open(url)
    }
}
