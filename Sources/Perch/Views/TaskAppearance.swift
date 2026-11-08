import AppKit
import SwiftUI

extension TaskColor {
    /// Soft, chalky tones: light enough for white glyphs to sit gently on, muted enough
    /// that a day full of them reads calm rather than candy-bright.
    var color: Color {
        switch self {
        case .coral: Color(red: 0.937, green: 0.553, blue: 0.533)
        case .amber: Color(red: 0.929, green: 0.710, blue: 0.443)
        case .sage: Color(red: 0.522, green: 0.722, blue: 0.545)
        case .teal: Color(red: 0.380, green: 0.706, blue: 0.702)
        case .sky: Color(red: 0.443, green: 0.612, blue: 0.820)
        case .indigo: Color(red: 0.537, green: 0.553, blue: 0.851)
        case .lavender: Color(red: 0.702, green: 0.592, blue: 0.863)
        case .rose: Color(red: 0.910, green: 0.565, blue: 0.706)
        }
    }

    var title: String {
        switch self {
        case .coral: tr("珊瑚粉", "Coral")
        case .amber: tr("琥珀", "Amber")
        case .sage: tr("鼠尾草", "Sage")
        case .teal: tr("青瓷", "Teal")
        case .sky: tr("雾蓝", "Mist Blue")
        case .indigo: tr("靛蓝", "Indigo")
        case .lavender: tr("薰衣草", "Lavender")
        case .rose: tr("玫瑰", "Rose")
        }
    }

    /// The fallback color, from Settings.
    static var preferredDefault: TaskColor {
        UserDefaults.standard.string(forKey: Pref.taskDefaultColor).flatMap(TaskColor.init(rawValue:)) ?? .coral
    }

    /// A colored dot for menus, which would otherwise draw SF Symbols as monochrome templates.
    var swatch: NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// What sits inside a task's capsule on the timeline.
enum TaskGlyph: Equatable {
    case symbol(String)
    case text(String)
}

extension TaskItem {
    /// A hand-picked color; else one shared by every task with the same first tag; else the
    /// color of what the title is about (when that's on); else the default from Settings.
    var tint: TaskColor {
        if let color { return color }
        if let tag = tags.first { return TaskColor.allCases[Self.stableHash(tag) % TaskColor.allCases.count] }
        if UserDefaults.standard.bool(forKey: Pref.taskTopicColors), let topic = TaskTopic.match(title) { return topic.color }
        return .preferredDefault
    }

    var glyph: TaskGlyph {
        if let topic = TaskTopic.match(title) { return .symbol(topic.symbol) }
        // The first letter or character, skipping digits and punctuation ("880做题" → 做).
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if let first = trimmed.first, first.unicodeScalars.first?.properties.isEmojiPresentation == true {
            return .text(String(first))
        }
        guard let letter = trimmed.first(where: \.isLetter) ?? trimmed.first else { return .symbol("circle.fill") }
        return .text(String(letter).uppercased())
    }

    /// Swift's own hashValue changes every launch; colors must not.
    private static func stableHash(_ text: String) -> Int {
        var hash: UInt32 = 5381
        for scalar in text.unicodeScalars { hash = (hash &* 33) &+ scalar.value }
        return Int(hash)
    }
}

/// Common kinds of tasks, recognized from the title.
struct TaskTopic {
    let symbol: String
    let color: TaskColor
    /// Words without ASCII letters (Chinese, "880") match anywhere. ASCII words of five letters
    /// or more match the start of a word ("meetings" ← "meeting"); shorter ones only match whole.
    var words: [String] = []
    /// Regular expressions for phrasings a word list can't catch, such as 做…题 or 听…课.
    var patterns: [String] = []

    /// More specific topics come first: "吃药" is medicine, not a meal, and "做线代题" is
    /// practice problems before it is maths.
    static let all: [TaskTopic] = [
        // Health
        TaskTopic(symbol: "pills.fill", color: .rose, words: ["吃药", "服药", "药", "medicine", "meds", "pill", "pills", "vitamin"]),
        TaskTopic(symbol: "cross.case.fill", color: .rose, words: ["医院", "看病", "牙医", "体检", "复诊", "挂号", "doctor", "dentist", "hospital", "checkup", "clinic"]),
        TaskTopic(symbol: "drop.fill", color: .sky, words: ["喝水", "drink water", "hydrate"]),
        TaskTopic(symbol: "alarm.fill", color: .sky, words: ["起床", "wake"]),
        TaskTopic(symbol: "bed.double.fill", color: .lavender, words: ["睡觉", "午睡", "午休", "早睡", "小睡", "sleep", "nap", "bedtime"]),
        TaskTopic(symbol: "shower.fill", color: .teal, words: ["洗澡", "洗头", "shower", "bath"]),

        // Study: what you do first, then the subject.
        TaskTopic(symbol: "character.book.closed.fill", color: .indigo,
                  words: ["单词", "词汇", "生词", "vocab", "vocabulary", "flashcard", "anki"],
                  patterns: [#"^背(?!景|包|影)"#]),
        TaskTopic(symbol: "text.book.closed.fill", color: .indigo,
                  words: ["背诵", "背书", "课文", "古诗", "默写", "recite", "memorize"]),
        TaskTopic(symbol: "play.rectangle.fill", color: .indigo,
                  words: ["网课", "听课", "看课", "视频课", "公开课", "录播", "直播课", "讲座", "mooc", "coursera", "lecture", "webinar"],
                  patterns: [#"(听|看|刷|跟|补).{0,12}(课|讲|视频)"#]),
        TaskTopic(symbol: "pencil.and.list.clipboard", color: .indigo,
                  words: ["真题", "习题", "刷题", "做题", "练习题", "试卷", "卷子", "模拟题", "错题", "880", "660", "1800", "1000题", "张宇", "李永乐", "汤家凤", "武忠祥", "肖秀荣", "leetcode", "problem set", "worksheet"],
                  patterns: [#"(做|刷|练|写|改|订正|过).{0,12}(题|卷|套)"#, #"\d+\s*(道题|题|套)"#]),
        TaskTopic(symbol: "headphones", color: .lavender, words: ["听力", "播客", "精听", "泛听", "listening", "podcast", "audiobook"]),
        TaskTopic(symbol: "note.text", color: .indigo, words: ["笔记", "总结", "复盘", "notes", "summary", "recap"]),
        TaskTopic(symbol: "checkmark.seal.fill", color: .indigo, words: ["考试", "测验", "期中", "期末", "exam", "quiz", "midterm", "final exam"]),
        TaskTopic(symbol: "doc.richtext.fill", color: .indigo, words: ["论文", "开题", "文献", "paper", "thesis", "dissertation", "literature"]),
        TaskTopic(symbol: "function", color: .indigo, words: ["数学", "高数", "线代", "线性代数", "概率", "微积分", "数分", "高代", "math", "maths", "calculus", "algebra", "statistics"]),
        TaskTopic(symbol: "textformat.abc", color: .indigo, words: ["英语", "雅思", "托福", "四级", "六级", "考研英语", "english", "ielts", "toefl", "gre", "gmat", "sat"]),
        TaskTopic(symbol: "character.bubble.fill", color: .lavender, words: ["日语", "韩语", "法语", "德语", "西语", "西班牙语", "口语", "japanese", "korean", "french", "german", "spanish", "duolingo", "speaking"]),
        TaskTopic(symbol: "atom", color: .indigo, words: ["物理", "physics"]),
        TaskTopic(symbol: "flask.fill", color: .teal, words: ["化学", "实验", "chemistry", "lab"]),
        TaskTopic(symbol: "microbe.fill", color: .sage, words: ["生物", "biology"]),
        TaskTopic(symbol: "building.columns.fill", color: .amber, words: ["历史", "政治", "马原", "毛概", "史纲", "history", "politics"]),
        TaskTopic(symbol: "graduationcap.fill", color: .indigo,
                  words: ["学习", "上课", "课程", "作业", "复习", "预习", "自习", "考研", "备考", "图书馆", "study", "class", "homework", "course", "learn", "revise", "tutor"],
                  patterns: [#"^学(?!校|生|期|费)"#, #"^(预习|复习|自学)"#]),
        TaskTopic(symbol: "book.fill", color: .indigo, words: ["读书", "阅读", "看书", "读", "read", "reading", "book", "kindle"]),

        // Work
        TaskTopic(symbol: "phone.fill", color: .teal, words: ["电话", "打给", "回电", "call", "phone", "ring"]),
        TaskTopic(symbol: "video.fill", color: .coral, words: ["会议", "开会", "例会", "周会", "晨会", "组会", "面谈", "meeting", "meet", "sync", "standup", "zoom", "1:1"]),
        TaskTopic(symbol: "person.2.fill", color: .coral, words: ["面试", "约见", "见面", "聚会", "interview", "catch up", "hangout"]),
        TaskTopic(symbol: "chart.bar.fill", color: .coral, words: ["汇报", "演讲", "答辩", "分享会", "presentation", "present", "slides", "demo", "pitch"]),
        TaskTopic(symbol: "envelope.fill", color: .sky, words: ["邮件", "回信", "email", "mail", "inbox", "reply"]),
        TaskTopic(symbol: "chevron.left.forwardslash.chevron.right", color: .sky, words: ["代码", "编程", "开发", "修复", "部署", "上线", "code", "coding", "bug", "deploy", "refactor", "debug", "pr review", "ship", "commit"]),
        TaskTopic(symbol: "paintbrush.pointed.fill", color: .lavender, words: ["设计", "画画", "绘画", "原型", "design", "sketch", "draw", "figma"]),
        TaskTopic(symbol: "pencil", color: .sky, words: ["写", "周报", "日报", "报告", "文档", "方案", "write", "draft", "report", "essay", "doc", "journal", "blog"]),
        TaskTopic(symbol: "list.bullet.clipboard.fill", color: .sky, words: ["计划", "规划", "安排", "待办", "plan", "planning", "agenda", "todo"]),
        TaskTopic(symbol: "lightbulb.fill", color: .amber, words: ["想法", "构思", "头脑风暴", "brainstorm", "idea", "ideas"]),
        TaskTopic(symbol: "briefcase.fill", color: .sky, words: ["上班", "工作", "加班", "项目", "work", "project", "office"]),
        TaskTopic(symbol: "printer.fill", color: .sky, words: ["打印", "复印", "print"]),

        // Body and outdoors
        TaskTopic(symbol: "figure.run", color: .sage, words: ["跑步", "晨跑", "夜跑", "慢跑", "run", "running", "jog", "jogging"]),
        TaskTopic(symbol: "figure.yoga", color: .sage, words: ["瑜伽", "拉伸", "yoga", "stretch"]),
        TaskTopic(symbol: "figure.pool.swim", color: .teal, words: ["游泳", "swim", "swimming"]),
        TaskTopic(symbol: "pawprint.fill", color: .amber, words: ["遛狗", "喂猫", "铲屎", "宠物", "dog", "cat", "pet"]),
        TaskTopic(symbol: "figure.walk", color: .sage, words: ["散步", "走路", "walk", "walking"]),
        TaskTopic(symbol: "bicycle", color: .sage, words: ["骑车", "骑行", "单车", "bike", "cycling"]),
        TaskTopic(symbol: "dumbbell.fill", color: .sage, words: ["健身", "锻炼", "运动", "撸铁", "workout", "gym", "exercise", "training", "lift"]),
        TaskTopic(symbol: "leaf.fill", color: .sage, words: ["冥想", "浇花", "meditat", "breathe", "plants"]),

        // Food and errands
        TaskTopic(symbol: "cup.and.saucer.fill", color: .amber, words: ["咖啡", "下午茶", "coffee", "tea"]),
        TaskTopic(symbol: "fork.knife", color: .amber, words: ["早餐", "早饭", "午餐", "午饭", "晚餐", "晚饭", "吃饭", "做饭", "聚餐", "breakfast", "lunch", "dinner", "brunch", "meal", "cook", "cooking"]),
        TaskTopic(symbol: "shippingbox.fill", color: .amber, words: ["快递", "取件", "寄件", "包裹", "退货", "parcel", "package", "return"]),
        TaskTopic(symbol: "cart.fill", color: .amber, words: ["购物", "超市", "买菜", "买", "shop", "shopping", "buy", "grocer"]),
        TaskTopic(symbol: "creditcard.fill", color: .amber, words: ["付款", "缴费", "账单", "交税", "报税", "还款", "报销", "pay", "bill", "tax", "invoice", "rent"]),
        TaskTopic(symbol: "scissors", color: .rose, words: ["理发", "剪头", "haircut"]),

        // Leisure
        TaskTopic(symbol: "film.fill", color: .lavender, words: ["电影", "剪辑", "剪视频", "movie", "film", "cinema"]),
        TaskTopic(symbol: "tv.fill", color: .lavender, words: ["追剧", "看剧", "综艺", "netflix", "episode", "show"]),
        TaskTopic(symbol: "gamecontroller.fill", color: .lavender, words: ["游戏", "打游戏", "game", "gaming"]),
        TaskTopic(symbol: "music.note", color: .lavender, words: ["练琴", "钢琴", "吉他", "唱歌", "音乐", "piano", "guitar", "music", "practice", "sing"]),
        TaskTopic(symbol: "camera.fill", color: .lavender, words: ["拍照", "摄影", "photo", "shoot"]),
        TaskTopic(symbol: "airplane", color: .teal, words: ["航班", "飞机", "机场", "值机", "flight", "airport", "fly"]),
        TaskTopic(symbol: "tram.fill", color: .teal, words: ["高铁", "火车", "地铁", "train", "subway"]),
        TaskTopic(symbol: "car.fill", color: .teal, words: ["开车", "接送", "通勤", "加油", "drive", "commute", "pick up"]),
        TaskTopic(symbol: "gift.fill", color: .rose, words: ["生日", "礼物", "纪念日", "birthday", "gift", "anniversary", "party"]),
        TaskTopic(symbol: "sparkles", color: .teal, words: ["打扫", "清洁", "整理", "收拾", "大扫除", "clean", "tidy", "vacuum"]),
        TaskTopic(symbol: "washer.fill", color: .teal, words: ["洗衣", "晾衣", "laundry"]),
    ]

    private static var regexCache: [String: NSRegularExpression] = [:]

    static func match(_ title: String) -> TaskTopic? {
        let lower = title.lowercased().trimmingCharacters(in: .whitespaces)
        let words = lower.split { !$0.isLetter && !$0.isNumber && $0 != ":" }.map(String.init)
        return all.first { topic in
            topic.words.contains { matches($0, lower: lower, words: words) }
                || topic.patterns.contains { pattern in
                    let regex = regexCache[pattern] ?? (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
                    regexCache[pattern] = regex
                    return regex?.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil
                }
        }
    }

    private static func matches(_ keyword: String, lower: String, words: [String]) -> Bool {
        let isEnglish = keyword.unicodeScalars.contains { $0.isASCII && CharacterSet.letters.contains($0) }
            && keyword.unicodeScalars.allSatisfy(\.isASCII)
        guard isEnglish else { return lower.contains(keyword) }
        if keyword.contains(" ") { return lower.contains(keyword) }
        if keyword.count >= 5 { return words.contains { $0.hasPrefix(keyword) } }
        return words.contains { $0 == keyword || $0 == keyword + "s" }
    }
}
