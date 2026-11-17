// 字幕を賢くする: 確定した文を、Mac の中の AI (Apple Intelligence の Foundation Models) で校正する
// 聞き間違いによる誤変換や専門用語の表記だけを直し、言い回しは変えない。音声も文字もネットに送らない。
// macOS 26 以降で、Apple Intelligence がオンの Mac だけで使える

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum SubtitleRefinerSupport {
    /// 使えないときの理由 (使えるなら nil)
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.appleIntelligenceNotEnabled):
                return L("システム設定で Apple Intelligence をオンにすると使えます")
            case .unavailable(.modelNotReady):
                return L("Apple Intelligence の準備中です。しばらくすると使えます")
            case .unavailable(.deviceNotEligible):
                return L("この Mac は Apple Intelligence に対応していません")
            case .unavailable:
                return L("Apple Intelligence が使えません")
            }
        }
        #endif
        return L("macOS 26 以降で使えます")
    }
}

#if canImport(FoundationModels)
/// 確定した文を 1 つずつ校正する (同時には 1 つだけ。たまったら古いものは飛ばす)
@available(macOS 26.0, *)
actor SubtitleRefiner {
    private var busy = false
    private var waiting: (text: String, context: [String], terms: [String], english: Bool,
                          done: @Sendable (String?) -> Void)?

    /// text を校正して done に渡す (直せなかったら nil)。context は直前の文 (古い順)、terms は正しい表記の用語
    func refine(_ text: String, context: [String], terms: [String], english: Bool,
                done: @escaping @Sendable (String?) -> Void) async {
        if busy {
            // 前の文を校正している間に来た文は、いちばん新しいものだけ待たせる
            waiting?.done(nil)
            waiting = (text, context, terms, english, done)
            return
        }
        busy = true
        var job: (String, [String], [String], Bool, @Sendable (String?) -> Void)? = (text, context, terms, english, done)
        while let (t, c, tm, en, d) = job {
            d(await Self.correct(t, context: c, terms: tm, english: en))
            if let w = waiting {
                waiting = nil
                job = (w.text, w.context, w.terms, w.english, w.done)
            } else {
                job = nil
            }
        }
        busy = false
    }

    /// 元の文のキーの名前と英数字が、直した文にも全部残っているか
    static func keepsKeysAndNumbers(_ original: String, _ fixed: String) -> Bool {
        let patterns = ["[\\p{Katakana}ー]+キー", "[A-Za-z0-9]+"]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p) else { continue }
            let ns = original as NSString
            for m in re.matches(in: original, range: NSRange(location: 0, length: ns.length)) {
                let token = ns.substring(with: m.range)
                if !fixed.contains(token) { return false }
            }
        }
        return true
    }

    static func correct(_ text: String, context: [String], terms: [String], english: Bool) async -> String? {
        let instructions: String
        var prompt = ""
        if english {
            instructions = """
            You proofread live speech-recognition subtitles. The input is one sentence of spoken English \
            transcribed by speech recognition. Fix only recognition mistakes: misheard words, wrong homophones, \
            and the spelling of technical terms and names. Keep the wording and word order; do not summarize, \
            Never change letters, numbers or key names (such as "A key" or "Shift"). \
            rephrase, add or remove content. If nothing needs fixing, return it unchanged. \
            Output only the corrected sentence.
            """
            if !terms.isEmpty { prompt += "Correct spellings of terms: \(terms.joined(separator: ", "))\n" }
            if !context.isEmpty { prompt += "Previous sentences: \(context.joined(separator: " "))\n" }
            prompt += "Sentence to fix: \(text)"
        } else {
            instructions = """
            あなたは、話し言葉を音声認識した字幕の校正係です。入力は音声認識した 1 文です。\
            聞き間違いによる誤変換、同音異義語の誤り、専門用語や固有名詞の表記だけを直してください。\
            言い回しや語順は変えず、要約・言い換え・付け足し・削除はしないでください。\
            アルファベット・数字・キーの名前 (エーキー、シフトなど) は、話したとおりのまま変えないでください。\
            句読点は読みやすく整えてかまいません。直す必要がなければ、そのまま返してください。\
            出力は直した文だけにしてください。
            """
            if !terms.isEmpty { prompt += "正しい表記の用語: \(terms.joined(separator: "、"))\n" }
            if !context.isEmpty { prompt += "直前の文: \(context.joined())\n" }
            prompt += "直す文: \(text)"
        }
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, options: GenerationOptions(temperature: 0))
            var out = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            // 「直す文:」などを付けて返してきたときは外す
            for prefix in ["直す文:", "直す文：", "Sentence to fix:", "Corrected:", "修正後:", "修正後："] where out.hasPrefix(prefix) {
                out = String(out.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            out = out.trimmingCharacters(in: CharacterSet(charactersIn: "「」\"“”"))
            // 長さが大きく変わったら、言い換えや説明を返したとみなして使わない
            let a = Double(text.count), b = Double(out.count)
            guard !out.isEmpty, !out.contains("\n"), b >= a * 0.6, b <= a * 1.4 + 4 else { return nil }
            // キーの名前 (「ジーキー」「シフトキー」など) や、英字・数字が消えたり変わったりしたら使わない
            // (操作の説明でいちばん大事なところなので、AI の直しより聞き取ったままを信じる)
            guard keepsKeysAndNumbers(text, out) else { return nil }
            return out
        } catch {
            return nil
        }
    }
}
#endif
