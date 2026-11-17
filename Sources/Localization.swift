// 画面に出す文字の英語対応
// 日本語の文をそのままキーにして、英語の訳は Resources/en.lproj/Localizable.strings に書く。
// Mac の言語設定が英語なら英語、日本語なら日本語 (訳がない文も日本語のまま) で出る

import Foundation

/// 日本語の文 key を、Mac の言語に合わせた文にする
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// 書式付き (%@ や %d を含む) の文を、言語に合わせてから値を埋め込む
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}

/// アプリが英語で表示されているか (字幕の言語やキーボードの配列の既定に使う)
var appIsEnglish: Bool { Bundle.main.preferredLocalizations.first?.hasPrefix("en") ?? false }
