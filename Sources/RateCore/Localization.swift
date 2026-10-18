import Foundation

/// 영어 문구를 키로 쓰는 로컬라이즈 헬퍼. 앱 번들의 <lang>.lproj/Localizable.strings에서 찾고, 없으면 키(영어) 그대로.
/// CLI는 번들이 없어서 항상 영어로 나온다.
/// 숫자는 %ld(Int), 문자열은 %@로 쓴다.
public func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    return args.isEmpty ? format : String(format: format, arguments: args)
}
