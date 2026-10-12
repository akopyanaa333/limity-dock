// Limity Dock — стеклянная ручка у правого края экрана, по ней — панель лимитов и расхода.
// Курсор к краю, свайп или клик по ручке открывают панель; клик по подписке — её подробности.
// Цифры берёт у codeburn: лимиты раз в 5 мин, расход раз в 10 мин и при открытии панели.
// Между запросами ничего не делает: ни таймеров анимации, ни опроса.

import AppKit
import SwiftUI
import Combine
import UserNotifications

// MARK: - Данные

struct QuotaWindow: Codable, Hashable {
    let label: String
    let usedPct: Double
    let resetsAt: String?
}

struct QuotaProvider: Codable {
    let id: String
    let name: String
    let available: Bool
    let plan: String?
    let windows: [QuotaWindow]
    let error: String?
    let notes: [String]?
}

struct SessionRow: Codable { let sessionId: String; let title: String?; let cost: Double; let calls: Int }
struct LimityFile: Codable { let id: String; let ctx: Double?; let title: String?; let talk: Double?; let at: Double? }

/// Открытая сейчас сессия Claude Code: контекст из нашего мода limity, стоимость из codeburn.
struct LiveSession: Identifiable {
    let id: String
    let title: String
    let ctx: Double
    let cost: Double?
}

/// Сбросы лимита Codex, которые OpenAI держит в запасе на аккаунте.
struct Resets {
    let available: Int
    let usable: Int?
    let expires: String?      // «через 3 дн.», если OpenAI сообщил срок

    /// Разбор строки codeburn: «Limit resets · 3 available · 0 usable now · next expires in 3d».
    static func parse(_ notes: [String]?) -> Resets? {
        guard let line = notes?.first(where: { $0.hasPrefix("Limit resets") }) else { return nil }
        func int(_ pattern: String) -> Int? {
            guard let r = line.range(of: pattern, options: .regularExpression) else { return nil }
            return Int(line[r].split(separator: " ").first ?? "")
        }
        guard let available = int("[0-9]+ available") else { return nil }
        var expires: String?
        if let r = line.range(of: "next expires in [0-9]+[mhd]", options: .regularExpression) {
            let v = line[r].replacingOccurrences(of: "next expires in ", with: "")
            let n = v.dropLast(), unit = v.last
            expires = "через \(n) " + (unit == "d" ? "дн." : unit == "h" ? "ч" : "мин")
        }
        return Resets(available: available, usable: int("[0-9]+ usable now"), expires: expires)
    }
}

struct QuotaResponse: Codable { let providers: [QuotaProvider] }

struct ReportDay: Codable { let date: String; let cost: Double }
struct ReportModel: Codable { let name: String; let cost: Double }
struct ReportOverview: Codable { let cost: Double }
struct ReportResponse: Codable {
    let overview: ReportOverview
    let daily: [ReportDay]
    let models: [ReportModel]
}

struct Spend {
    var today: Double = 0
    var week: Double = 0
    var month: Double = 0
    var days: [Double] = []          // 30 значений, последнее — сегодня
    var byBrand: [Brand: [(String, Double)]] = [:]   // модели подписки за 30 дней, по убыванию
}

enum Brand: String, CaseIterable {
    case claude, codex

    var title: String {
        switch self { case .claude: "Claude"; case .codex: "Codex" }
    }
    var color: Color {
        switch self {
        case .claude: Color(red: 0.851, green: 0.467, blue: 0.341)   // #D97757
        case .codex:  Color(red: 0.204, green: 0.788, blue: 0.533)   // #34C988
        }
    }
    var logo: NSImage? {
        guard let url = Bundle.main.url(forResource: "provider-\(rawValue)", withExtension: "svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        return img
    }
    /// Чья модель: GPT — Codex, Claude-семейство (Opus, Fable, Sonnet, Haiku) — Claude, прочие не показываем.
    static func of(model: String) -> Brand? {
        let n = model.lowercased()
        if n.contains("gpt") || n.contains("codex") || n.hasPrefix("o3") || n.hasPrefix("o4") { return .codex }
        if n.contains("gemini") || n.contains("glm") || n.contains("kimi") || n.contains("grok") { return nil }
        return .claude
    }
}

struct Limit: Identifiable, Hashable {
    let id: String
    let title: String
    let used: Double            // 0…100
    let resetsAt: Date?
    let duration: TimeInterval?
    var today: Double? = nil    // сколько процентов окна ушло с начала суток

    /// Сколько процентов в день можно тратить, чтобы хватило до сброса. Только для длинных окон.
    func perDay(now: Date = Date()) -> Double? {
        guard let r = resetsAt, let d = duration, d >= 2 * 86400 else { return nil }
        let days = r.timeIntervalSince(now) / 86400
        guard days >= 0.5 else { return nil }
        return max(0, 100 - used) / days
    }

    /// Доля прошедшего времени окна, 0…1. Нет длительности — nil.
    func elapsed(now: Date = Date()) -> Double? {
        guard let r = resetsAt, let d = duration, d > 0 else { return nil }
        return min(1, max(0, 1 - r.timeIntervalSince(now) / d))
    }

    /// Когда кончится лимит при нынешнем темпе — если раньше сброса.
    func runsOut(now: Date = Date()) -> Date? {
        guard used > 0, used < 100, let r = resetsAt, let d = duration,
              let e = elapsed(now: now), e > 0.2 else { return nil }
        let spent = e * d
        let rate = used / spent
        let left = (100 - used) / rate
        let at = now.addingTimeInterval(left)
        return at < r ? at : nil
    }
}

struct ProviderState: Identifiable {
    let brand: Brand
    var plan: String?
    var limits: [Limit]
    var note: String?
    var resets: Resets? = nil
    var id: String { brand.rawValue }

    /// Самое тесное окно — его и показывает кольцо на полоске.
    var tightest: Limit? { limits.max { $0.used < $1.used } }

    /// Окно для кольца: 5 часов, если подписка его даёт (Claude), иначе самое тесное (у Codex — неделя).
    var ringLimit: Limit? { limits.first { $0.duration == 5 * 3600 } ?? tightest }
}

// MARK: - Хранилище и запросы к codeburn

final class Store: ObservableObject {
    @Published var providers: [ProviderState] = []   // до первых цифр колец нет: у кого одна подписка, пустой второй не мелькнёт
    @Published var spend: Spend?
    @Published var quotaAt: Date?
    @Published var reportAt: Date?
    @Published var problem: String?
    @Published var loading = false
    @Published var sessions: [LiveSession] = []
    /// Блок сессий имеет смысл только там, где стоит мод limity для Claude Code.
    let hasLimity = FileManager.default.fileExists(atPath:
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/limity").path)
    private var sessionCosts: [String: Double] = [:]
    private var sessionTitles: [String: String] = [:]

    private var quotaBusy = false
    private var reportBusy = false
    private let queue = DispatchQueue(label: "limity.fetch", qos: .utility)

    private static let binary: String? = {
        if let p = ["/opt/homebrew/bin/codeburn", "/usr/local/bin/codeburn"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return p }
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/zsh")
        sh.arguments = ["-lc", "command -v codeburn"]
        let out = Pipe(); sh.standardOutput = out; sh.standardError = FileHandle.nullDevice
        guard (try? sh.run()) != nil else { return nil }
        sh.waitUntilExit()
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }()
    /// Папка с node рядом с codeburn — для PATH дочернего процесса (nvm и подобные).
    private static var binDir: String { binary.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? "" }

    private func run(_ args: [String], timeout: TimeInterval) -> Data? {
        guard let bin = Store.binary else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(Store.binDir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["NO_COLOR"] = "1"
        p.environment = env
        p.qualityOfService = .utility
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return p.terminationStatus == 0 ? data : nil
    }

    func refreshQuota() {
        guard !quotaBusy else { return }
        quotaBusy = true
        loading = true
        queue.async {
            let data = self.run(["quota", "--format", "json"], timeout: 60)
            let parsed = data.flatMap { try? JSONDecoder().decode(QuotaResponse.self, from: $0) }
            DispatchQueue.main.async {
                self.quotaBusy = false
                self.loading = self.reportBusy
                guard let parsed else {
                    self.problem = Store.binary == nil ? "Не найден codeburn" : "Лимиты не получены"
                    return
                }
                self.problem = nil
                self.quotaAt = Date()
                self.providers = Brand.allCases.compactMap { brand -> ProviderState? in
                    guard let p = parsed.providers.first(where: { $0.id == brand.rawValue }),
                          p.available || p.error != nil else { return nil }   // не подключена — не показываем
                    let limits = p.windows.map { w -> Limit in
                        var l = Limit(id: w.label, title: Fmt.windowTitle(w.label), used: w.usedPct,
                                      resetsAt: w.resetsAt.flatMap(Fmt.isoDate), duration: Fmt.windowDuration(w.label))
                        l.today = Baseline.spentToday(key: "\(brand.rawValue)|\(w.label)", limit: l)
                        return l
                    }
                    var note: String?
                    if !p.available { note = p.error != nil ? "не отвечает" : "не подключён" }
                    return ProviderState(brand: brand, plan: p.plan, limits: limits, note: note,
                                         resets: Resets.parse(p.notes))
                }
                Notifier.check(providers: self.providers)
            }
        }
    }

    func refreshReport() {
        guard !reportBusy else { return }
        reportBusy = true
        loading = true
        queue.async {
            let data = self.run(["report", "--period", "30days", "--format", "json"], timeout: 120)
            let parsed = data.flatMap { try? JSONDecoder().decode(ReportResponse.self, from: $0) }
            DispatchQueue.main.async {
                self.reportBusy = false
                self.loading = self.quotaBusy
                guard let parsed else { return }
                self.reportAt = Date()
                self.spend = Store.makeSpend(parsed)
            }
            // стоимость сессий за неделю — чтобы подписать живые сессии
            if let data = self.run(["sessions", "--period", "week", "--provider", "claude", "--format", "json"], timeout: 60),
               let rows = try? JSONDecoder().decode([SessionRow].self, from: data) {
                let costs = Dictionary(rows.map { ($0.sessionId, $0.cost) }, uniquingKeysWith: +)
                let titles = Dictionary(rows.compactMap { r in r.title.map { (r.sessionId, $0) } }, uniquingKeysWith: { a, _ in a })
                DispatchQueue.main.async { self.sessionCosts = costs; self.sessionTitles = titles; self.refreshSessions() }
            }
        }
    }

    /// Живые сессии: мод limity обновляет файл каждые 30 с, свежее 3 минут — сессия открыта.
    func refreshSessions() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/limity")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let now = Date().timeIntervalSince1970 * 1000
        let live: [LiveSession] = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let f = try? JSONDecoder().decode(LimityFile.self, from: data),
                  let at = f.at, now - at < 180_000, let ctx = f.ctx else { return nil }
            // название: сначала то, что составил codeburn, иначе первый текст сессии без служебных тегов
            let raw = sessionTitles[f.id] ?? f.title ?? ""
            let title = raw.replacingOccurrences(of: "<[^>]+>[^<]*</[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return LiveSession(id: f.id, title: title.isEmpty ? "сессия после /clear" : title, ctx: ctx, cost: sessionCosts[f.id])
        }
        sessions = live.sorted { $0.ctx > $1.ctx }
        Notifier.check(sessions: sessions)
    }

    func refreshIfStale() {
        if (quotaAt.map { Date().timeIntervalSince($0) > 60 } ?? true) { refreshQuota() }
        if (reportAt.map { Date().timeIntervalSince($0) > 120 } ?? true) { refreshReport() }
    }

    private static func makeSpend(_ r: ReportResponse) -> Spend {
        let byDate = Dictionary(r.daily.map { ($0.date, $0.cost) }, uniquingKeysWith: +)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let days: [Double] = (0..<30).reversed().map { back in
            let d = cal.date(byAdding: .day, value: -back, to: today)!
            return byDate[Fmt.dayKey.string(from: d)] ?? 0
        }
        var byBrand: [Brand: [(String, Double)]] = [:]
        for m in r.models.sorted(by: { $0.cost > $1.cost }) where m.cost >= 0.01 {
            if let b = Brand.of(model: m.name) { byBrand[b, default: []].append((m.name, m.cost)) }
        }
        return Spend(today: days.last ?? 0, week: days.suffix(7).reduce(0, +),
                     month: r.overview.cost, days: days, byBrand: byBrand)
    }
}

// MARK: - Сколько ушло за сутки

/// Помнит, сколько было у окна в начале суток (или в момент сброса окна), чтобы считать «сегодня».
enum Baseline {
    private static let key = "LimityDockBaselines"

    static func spentToday(key k: String, limit: Limit) -> Double? {
        guard limit.duration ?? 0 >= 2 * 86400 else { return nil }
        let day = Fmt.dayKey.string(from: Date())
        let reset = limit.resetsAt.map { String(Int($0.timeIntervalSince1970 / 600)) } ?? ""
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Any]] ?? [:]
        if let b = all[k], b["day"] as? String == day, b["reset"] as? String == reset,
           let start = b["used"] as? Double, limit.used >= start {
            return limit.used - start
        }
        // новые сутки, новое окно или первый запуск — точка отсчёта с текущего значения
        let firstEver = all[k] == nil
        all[k] = ["day": day, "reset": reset, "used": limit.used]
        UserDefaults.standard.set(all, forKey: key)
        return firstEver ? nil : 0
    }
}

// MARK: - Уведомления

/// Одно уведомление на событие: лимит перевалил 80% и 90%, сессия раздулась выше 60%, у Codex появился сброс.
enum Notifier {
    private static let sentKey = "LimityDockNotified"
    private static var sent: Set<String> = Set(UserDefaults.standard.stringArray(forKey: sentKey) ?? [])

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private static func once(_ id: String, _ title: String, _ body: String) {
        guard !sent.contains(id) else { return }
        sent.insert(id)
        UserDefaults.standard.set(Array(sent.suffix(300)), forKey: sentKey)
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    static func check(providers: [ProviderState]) {
        for p in providers {
            for l in p.limits {
                let cycle = l.resetsAt.map { String(Int($0.timeIntervalSince1970 / 600)) } ?? "-"
                for t in [90.0, 80.0] where l.used >= t {
                    once("lim|\(p.brand.rawValue)|\(l.id)|\(cycle)|\(Int(t))",
                         "\(p.brand.title): \(l.title.lowercased()) — \(Int(l.used.rounded()))%",
                         "\(Fmt.reset(l.resetsAt).capitalizedFirst). " + (t >= 90 ? "Лимит почти кончился." : "Осталась пятая часть."))
                    break
                }
            }
            if let r = p.resets, r.available > 0 {
                once("res|\(p.brand.rawValue)|\(r.available)", "\(p.brand.title): сбросов лимита в запасе — \(r.available)",
                     r.usable.map { $0 > 0 ? "Можно применить сейчас: \($0)." : "Применить сейчас нельзя." } ?? "")
            }
        }
    }

    static func check(sessions: [LiveSession]) {
        for s in sessions where s.ctx >= 60 {
            once("ctx|\(s.id)", "Сессия раздулась: контекст \(Int(s.ctx))%",
                 "«\(s.title.prefix(60))» — каждый ход теперь дорогой. Пора начать новую сессию или сжать контекст (/compact).")
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Форматирование

enum Fmt {
    static let dayKey: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    static let weekdayTime: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "EE, HH:mm"; return f
    }()
    static let clock: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "HH:mm"; return f
    }()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso = ISO8601DateFormatter()

    static func isoDate(_ s: String) -> Date? { isoFrac.date(from: s) ?? iso.date(from: s) }

    static func windowTitle(_ label: String) -> String {
        label.replacingOccurrences(of: "5-hour", with: "5 часов")
             .replacingOccurrences(of: "Weekly", with: "Неделя")
             .replacingOccurrences(of: "Daily", with: "Сутки")
             .replacingOccurrences(of: "Monthly", with: "Месяц")
    }

    static func windowDuration(_ label: String) -> TimeInterval? {
        let l = label.lowercased()
        if l.contains("5-hour") { return 5 * 3600 }
        if l.contains("weekly") { return 7 * 86400 }
        if l.contains("daily") { return 86400 }
        if l.contains("monthly") { return 30 * 86400 }
        return nil
    }

    static func money(_ v: Double) -> String {
        if v < 10 { return String(format: "$%.1f", v).replacingOccurrences(of: ".", with: ",") }
        let n = Int(v.rounded())
        let digits = String(n)
        var out = ""
        for (i, ch) in digits.reversed().enumerated() {
            if i > 0 && i % 3 == 0 { out.append("\u{2009}") }
            out.append(ch)
        }
        return "$" + String(out.reversed())
    }

    /// «сб, 10:00» — день строчными, время округлено до минуты.
    static func day(_ d: Date) -> String {
        weekdayTime.string(from: d.addingTimeInterval(30)).lowercased()
    }

    static func budget(per: Double, today: Double?) -> String {
        let p = per >= 10 ? "\(Int(per.rounded()))" : String(format: "%.1f", per).replacingOccurrences(of: ".", with: ",")
        guard let t = today else { return "можно ~\(p)% в день" }
        let tt = t >= 10 || t == 0 ? "\(Int(t.rounded()))" : String(format: "%.1f", t).replacingOccurrences(of: ".", with: ",")
        return "сегодня \(tt)% из ~\(p)%"
    }

    static func dayMonth(daysAgo: Int) -> String {
        let d = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMMM"
        return f.string(from: d)
    }

    static func reset(_ d: Date?, now: Date = Date()) -> String {
        guard let d else { return "" }
        let s = d.timeIntervalSince(now)
        if s <= 0 { return "обнуляется" }
        if s < 3600 { return "сброс через \(max(1, Int(s / 60))) мин" }
        if s < 86400 {
            let h = Int(s / 3600), m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
            return m > 0 ? "сброс через \(h) ч \(m) мин" : "сброс через \(h) ч"
        }
        return "сброс " + day(d)
    }
}

// MARK: - Палитра и движение

enum Ink {
    static let primary = Color.primary
    static let secondary = Color.secondary
    static let tertiary = Color(nsColor: .tertiaryLabelColor)
    static let hairline = Color.primary.opacity(0.08)
    static let warn = Color(red: 0.93, green: 0.58, blue: 0.13)
    static let alarm = Color(red: 0.92, green: 0.30, blue: 0.27)
}

enum Motion {
    /// Плавное торможение без отскока.
    static let out = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.9)
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.88)
    static let quick = Animation.easeOut(duration: 0.18)
}

struct Logo: View {
    let brand: Brand
    var size: CGFloat
    var color: Color? = nil
    var body: some View {
        if let img = brand.logo {
            Image(nsImage: img).renderingMode(.template).resizable().interpolation(.high)
                .frame(width: size, height: size)
                .foregroundStyle(color ?? brand.color)
        }
    }
}

func pctColor(_ v: Double) -> Color { v >= 90 ? Ink.alarm : (v >= 75 ? Ink.warn : Ink.primary) }

enum Theme: String, CaseIterable {
    case auto, day, night
    var icon: String { ["auto": "circle.lefthalf.filled", "day": "sun.max", "night": "moon"][rawValue]! }
    var title: String { ["auto": "Авто — как в macOS", "day": "День", "night": "Ночь"][rawValue]! }
    var appearance: NSAppearance? {
        switch self {
        case .auto: nil
        case .day: NSAppearance(named: .aqua)
        case .night: NSAppearance(named: .darkAqua)
        }
    }
    func apply() { NSApp.appearance = appearance }
    var next: Theme { Theme.allCases[(Theme.allCases.firstIndex(of: self)! + 1) % Theme.allCases.count] }
}

struct ThemeButton: View {
    @ObservedObject var ui: UIState
    var body: some View {
        Button {
            withAnimation(Motion.quick) { ui.theme = ui.theme.next }
        } label: {
            Image(systemName: ui.theme.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Тема: \(ui.theme.title). Клик — следующая")
    }
}

// MARK: - Кольцо

struct WRing: View {
    let brand: Brand
    let limit: Limit?
    var size: CGFloat
    var line: CGFloat
    var fontSize: CGFloat
    var drawn: Bool
    var delay: Double = 0
    var logo = false          // в центре значок подписки вместо процента

    var body: some View {
        let used = limit?.used ?? 0
        ZStack {
            Circle().stroke(brand.color.opacity(limit == nil ? 0.12 : 0.18), lineWidth: line)
            if limit != nil {
                Circle()
                    .trim(from: 0, to: drawn ? max(0.004, min(1, used / 100)) : 0)
                    .stroke(AngularGradient(colors: [brand.color.opacity(0.7), brand.color], center: .center,
                                            startAngle: .degrees(0), endAngle: .degrees(max(18, 360 * used / 100))),
                            style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(Motion.out.delay(delay), value: drawn)
                    .animation(Motion.out, value: used)
            }
            if logo {
                Logo(brand: brand, size: size * 0.36, color: limit == nil ? Ink.tertiary : Ink.primary)
            } else {
                Pct(limit: limit, drawn: drawn, delay: delay, size: fontSize)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Процент, который при открытии отсчитывается от нуля.
struct Pct: View {
    let limit: Limit?
    let drawn: Bool
    let delay: Double
    let size: CGFloat
    var body: some View {
        let used = limit?.used ?? 0
        Group {
            if limit == nil {
                Text("—")
            } else {
                CountText(value: drawn ? used : 0, suffix: "%")
                    .animation(Motion.out.delay(delay), value: drawn)
                    .animation(Motion.out, value: used)
            }
        }
        .font(.system(size: size, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(limit.map { pctColor($0.used) } ?? Ink.tertiary)
    }
}

/// Число, которое при анимации отсчитывается плавно (каждый кадр — целое значение),
/// а не перекатывает цифры: у перекатки в середине пропадают знаки.
struct CountText: View, Animatable {
    var value: Double
    var suffix: String = ""
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View { Text("\(Int(value.rounded()))\(suffix)") }
}

/// Каскад появления: блок всплывает на 8 точек и проявляется со своей задержкой.
struct Reveal: ViewModifier {
    let shown: Bool
    let delay: Double
    let reduce: Bool
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduce ? 0 : 8)
            .animation(reduce ? .easeOut(duration: 0.15) : .timingCurve(0.22, 1, 0.36, 1, duration: 0.5).delay(delay), value: shown)
    }
}

extension View {
    func reveal(_ shown: Bool, _ delay: Double, reduce: Bool = false) -> some View {
        modifier(Reveal(shown: shown, delay: delay, reduce: reduce))
    }
}

// MARK: - Ручка у края

struct HandleView: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: UIState

    private var signal: Color? {
        let worst = store.providers.compactMap { $0.tightest?.used }.max() ?? 0
        return worst >= 90 ? Ink.alarm : (worst >= 75 ? Ink.warn : nil)
    }

    var body: some View {
        let hover = ui.handleHover
        ZStack {
            Color.clear
                .frame(width: hover ? 8 : 6, height: hover ? 70 : 54)
                .glassEffect(.regular.interactive(), in: .capsule)
                .opacity(hover || ui.panelShown ? 1 : 0.35)   // в покое — полупрозрачная, не отвлекает
            if let signal {
                Circle().fill(signal).frame(width: 4, height: 4)
            }
        }
        .frame(width: UIState.handleSize.width, height: UIState.handleSize.height, alignment: .center)
        .offset(x: UIState.handleSize.width / 2 - 6)
        .animation(Motion.spring, value: hover)
    }
}

// MARK: - Панель

struct PanelRoot: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: UIState
    @Environment(\.colorScheme) private var scheme
    @Namespace private var ns

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let b = ui.selected, let p = store.providers.first(where: { $0.brand == b }) {
                DetailView(p: p, spend: store.spend?.byBrand[b] ?? [], ui: ui, ns: ns)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: 14)).animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.32).delay(0.09)),
                        removal: .opacity.combined(with: .offset(x: 10)).animation(.easeIn(duration: 0.1))))
            } else {
                OverviewView(store: store, ui: ui, ns: ns)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: -14)).animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.32).delay(0.09)),
                        removal: .opacity.combined(with: .offset(x: -10)).animation(.easeIn(duration: 0.1))))
            }
        }
        .frame(width: UIState.panelSize.width, height: UIState.panelSize.height, alignment: .topLeading)
        // Тело — плотный ровный фон: стекло под содержимым размывает окно снизу, и проступает «туман».
        // Liquid Glass оставлен каймой в 2 точки по краю — блик и преломление видны только там.
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(scheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.12) : Color(red: 0.97, green: 0.97, blue: 0.98))
                .padding(2)
        )
        .glassEffect(.regular, in: .rect(cornerRadius: 26, style: .continuous))
        .scaleEffect(ui.panelShown || ui.reduceMotion ? 1 : 0.94, anchor: .trailing)
        .offset(x: ui.panelShown || ui.reduceMotion ? 0 : 20)
        .blur(radius: ui.panelShown || ui.reduceMotion ? 0 : 6)
        .opacity(ui.panelShown ? 1 : 0)
    }
}

struct OverviewView: View {
    @ObservedObject var store: Store
    @ObservedObject var ui: UIState
    let ns: Namespace.ID

    private var extras: [(String, Color)] {
        var out: [(String, Color)] = []
        for p in store.providers {
            for l in p.limits {
                if l.used >= 100 { out.append(("\(p.brand.title) · \(l.title.lowercased()): лимит исчерпан", Ink.alarm)); continue }
                if let at = l.runsOut() {
                    out.append(("\(p.brand.title) · \(l.title.lowercased()): в таком темпе кончится \(Fmt.day(at))", Ink.warn))
                }
            }
        }
        return Array(out.prefix(2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Лимиты").font(.system(size: 13, weight: .semibold))
                Spacer()
                ThemeButton(ui: ui)
                RefreshButton(store: store)
            }
            .reveal(ui.drawn, 0, reduce: ui.reduceMotion)
            HStack(spacing: 6) {
                ForEach(Array(store.providers.enumerated()), id: \.element.id) { i, p in
                    RingTile(p: p, ui: ui, ns: ns, delay: 0.08 + Double(i) * 0.07)
                }
            }
            .padding(.top, 10)
            .padding(.horizontal, -6)
            .reveal(ui.drawn, 0.04, reduce: ui.reduceMotion)
            if store.providers.isEmpty && store.quotaAt != nil {
                Text("Не вижу подписок. Войди в Claude Code (claude) или Codex (codex login) в Терминале — кольца появятся сами.")
                    .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 20)
            }
            if !extras.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(extras.indices, id: \.self) { i in
                        Text(extras[i].0).foregroundStyle(extras[i].1)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .padding(.top, 10)
            }
            BudgetBlock(providers: store.providers, drawn: ui.drawn).padding(.top, 12)
                .reveal(ui.drawn, 0.12, reduce: ui.reduceMotion)
            if store.hasLimity {
                Rectangle().fill(Ink.hairline).frame(height: 0.5).padding(.vertical, 14)
                SessionsBlock(sessions: store.sessions)
                    .reveal(ui.drawn, 0.18, reduce: ui.reduceMotion)
            }
            Rectangle().fill(Ink.hairline).frame(height: 0.5).padding(.vertical, 14)
            SpendSection(spend: store.spend, drawn: ui.drawn)
                .reveal(ui.drawn, 0.24, reduce: ui.reduceMotion)
            Spacer(minLength: 0)
            HStack {
                if let problem = store.problem {
                    Text(problem).foregroundStyle(Ink.warn)
                } else {
                    Text(store.quotaAt.map { "обновлено \(Fmt.clock.string(from: $0))" } ?? "загружаю…")
                        .foregroundStyle(Ink.tertiary)
                }
                Spacer()
                Text("клик по подписке — подробности").foregroundStyle(Ink.tertiary)
            }
            .font(.system(size: 10.5))
        }
        .padding(20)
    }
}

struct RefreshButton: View {
    @ObservedObject var store: Store
    var body: some View {
        Button {
            store.refreshQuota(); store.refreshReport()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Ink.secondary)
                .rotationEffect(.degrees(store.loading ? 360 : 0))
                .animation(store.loading ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                           value: store.loading)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Обновить")
    }
}

struct RingTile: View {
    let p: ProviderState
    @ObservedObject var ui: UIState
    let ns: Namespace.ID
    let delay: Double
    @State private var hover = false

    var body: some View {
        Button {
            withAnimation(Motion.spring) { ui.selected = p.brand }
        } label: {
            VStack(spacing: 7) {
                WRing(brand: p.brand, limit: p.ringLimit, size: 70, line: 8, fontSize: 16, drawn: ui.drawn, delay: delay, logo: true)
                    .matchedGeometryEffect(id: "ring-\(p.id)", in: ns)
                Pct(limit: p.ringLimit, drawn: ui.drawn, delay: delay, size: 19)
                Text(p.brand.title).font(.system(size: 11.5, weight: .semibold))
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(Ink.secondary).lineLimit(1)
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(hover ? 0.06 : 0)))
            .scaleEffect(hover ? 1.025 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.quick) { hover = h } }
    }

    private var subtitle: String {
        guard let l = p.ringLimit else { return p.note ?? "нет данных" }
        let short = l.title.hasPrefix("5") ? "5 ч" : l.title.lowercased()
        return "\(short) · \(Fmt.reset(l.resetsAt).replacingOccurrences(of: "сброс ", with: "").replacingOccurrences(of: "через ", with: ""))"
    }
}

struct SpendSection: View {
    let spend: Spend?
    let drawn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Расход").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let s = spend {
                    Text("7 дн. \(Fmt.money(s.week))  ·  30 дн. \(Fmt.money(s.month))")
                        .font(.system(size: 11)).foregroundStyle(Ink.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(spend.map { Fmt.money($0.today) } ?? "—")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("сегодня").font(.system(size: 12)).foregroundStyle(Ink.secondary)
            }
            .padding(.top, 4)
            if let s = spend {
                Spark(values: s.days, drawn: drawn).frame(height: 46).padding(.top, 8)
                let usual = s.month / 30
                Text(s.today <= usual ? "ниже обычного дня (~\(Fmt.money(usual))) · по цене API"
                                      : "выше обычного дня (~\(Fmt.money(usual))) · по цене API")
                    .font(.system(size: 11)).foregroundStyle(Ink.secondary).padding(.top, 8)
                BrandSplit(spend: s, drawn: drawn).padding(.top, 12)
            }
        }
    }
}

struct Spark: View {
    let values: [Double]
    let drawn: Bool
    @State private var hover: Int?

    var body: some View {
        GeometryReader { g in
            let mx = max(values.max() ?? 1, 0.01)
            let pts: [CGPoint] = values.indices.map { i in
                CGPoint(x: g.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1)),
                        y: (g.size.height - 6) * (1 - CGFloat(values[i] / mx)) + 3)
            }
            let line = Path { p in
                guard let first = pts.first else { return }
                p.move(to: first)
                for i in 1..<pts.count {
                    let a = pts[i - 1], b = pts[i], mid = (a.x + b.x) / 2
                    p.addCurve(to: b, control1: CGPoint(x: mid, y: a.y), control2: CGPoint(x: mid, y: b.y))
                }
            }
            ZStack(alignment: .topLeading) {
                Path { p in
                    p.addPath(line)
                    p.addLine(to: CGPoint(x: g.size.width, y: g.size.height))
                    p.addLine(to: CGPoint(x: 0, y: g.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [Brand.claude.color.opacity(0.26), Brand.claude.color.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
                .opacity(drawn ? 1 : 0)
                .animation(.easeOut(duration: 0.6).delay(0.45), value: drawn)
                line.trim(from: 0, to: drawn ? 1 : 0)
                    .stroke(Brand.claude.color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                    .animation(.easeInOut(duration: 0.9).delay(0.15), value: drawn)
                if let last = pts.last {
                    Circle().fill(Brand.claude.color).frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                        .position(last)
                        .scaleEffect(drawn ? 1 : 0.01)
                        .animation(Motion.spring.delay(0.95), value: drawn)
                }
                if let h = hover, h < pts.count {
                    Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: g.size.height)
                        .position(x: pts[h].x, y: g.size.height / 2)
                    Text("\(Fmt.dayMonth(daysAgo: values.count - 1 - h)): \(Fmt.money(values[h]))")
                        .font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                        .position(x: min(max(pts[h].x, 50), g.size.width - 50), y: -4)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    let i = Int((loc.x / max(g.size.width, 1) * CGFloat(values.count - 1)).rounded())
                    hover = min(max(i, 0), values.count - 1)
                case .ended: hover = nil
                }
            }
        }
    }
}

/// Кто сколько потратил за 30 дней: одна полоса, сегменты по подпискам.
struct BrandSplit: View {
    let spend: Spend
    let drawn: Bool

    var body: some View {
        let parts: [(Brand, Double)] = Brand.allCases.compactMap { b in
            let v = (spend.byBrand[b] ?? []).reduce(0) { $0 + $1.1 }
            return v > 0 ? (b, v) : nil
        }
        let total = max(parts.reduce(0) { $0 + $1.1 }, 0.01)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(parts.indices, id: \.self) { i in
                        Rectangle().fill(parts[i].0.color)
                            .frame(width: max(3, (g.size.width - CGFloat(parts.count - 1) * 2) * parts[i].1 / total))
                    }
                }
                .frame(width: drawn ? g.size.width : 0, alignment: .leading)
                .clipShape(Capsule())
                .animation(Motion.out.delay(0.35), value: drawn)
            }
            .frame(height: 6)
            HStack(spacing: 14) {
                ForEach(parts.indices, id: \.self) { i in
                    HStack(spacing: 5) {
                        Circle().fill(parts[i].0.color).frame(width: 6, height: 6)
                        Text(parts[i].0.title).foregroundStyle(Ink.secondary)
                        Text(Fmt.money(parts[i].1)).monospacedDigit().foregroundStyle(Ink.primary)
                    }
                }
                Spacer()
                Text("за 30 дней").foregroundStyle(Ink.tertiary)
            }
            .font(.system(size: 11, weight: .medium))
        }
    }
}

/// «Можно ~18% в день · сегодня 6%» по недельным окнам и сбросы лимита.
struct BudgetBlock: View {
    let providers: [ProviderState]
    let drawn: Bool

    var body: some View {
        let rows: [(ProviderState, Limit, Double)] = providers.flatMap { p in
            p.limits.compactMap { l in l.perDay().map { (p, l, $0) } }.prefix(1)
        }
        VStack(alignment: .leading, spacing: 9) {
            ForEach(rows.indices, id: \.self) { i in
                let (p, l, per) = rows[i]
                let today = l.today ?? 0
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(p.brand.color).frame(width: 6, height: 6)
                        Text("\(p.brand.title) · неделя").foregroundStyle(Ink.secondary)
                        Spacer()
                        Text(Fmt.budget(per: per, today: l.today))
                            .foregroundStyle(today > per ? Ink.warn : Ink.primary)
                    }
                    .font(.system(size: 11, weight: .medium))
                    // полоска: сколько сегодняшнего бюджета уже ушло
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(p.brand.color.opacity(0.15))
                            Capsule().fill(today > per ? Ink.warn : p.brand.color)
                                .frame(width: drawn ? max(3, g.size.width * min(1, today / max(per, 0.1))) : 0)
                                .animation(Motion.out.delay(0.3 + Double(i) * 0.08), value: drawn)
                        }
                    }
                    .frame(height: 3)
                }
            }
            ForEach(providers.filter { ($0.resets?.available ?? 0) > 0 }) { p in
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(p.brand.color)
                    Text("\(p.brand.title): сбросов лимита в запасе — \(p.resets!.available)")
                        .foregroundStyle(Ink.secondary)
                    Spacer()
                }
                .font(.system(size: 11, weight: .medium))
            }
        }
    }
}

struct SessionsBlock: View {
    let sessions: [LiveSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Сессии сейчас").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(sessions.isEmpty ? "нет открытых" : "\(sessions.count) открыто · контекст")
                    .font(.system(size: 11)).foregroundStyle(Ink.secondary)
            }
            ForEach(sessions.prefix(4)) { s in
                HStack(spacing: 8) {
                    ZStack {
                        Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2.5)
                        Circle().trim(from: 0, to: min(1, s.ctx / 100))
                            .stroke(ctxColor(s.ctx), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 14, height: 14)
                    Text(s.title).font(.system(size: 11.5)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 6)
                    Text("\(Int(s.ctx))%").font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(ctxColor(s.ctx))
                    if let c = s.cost {
                        Text(Fmt.money(c)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Ink.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .help(s.ctx >= 60 ? "Контекст раздут: каждый ход дорогой. Пора новую сессию или /compact." : s.title)
            }
            if sessions.contains(where: { $0.ctx >= 60 }) {
                Text("жёлтые — пора новую сессию или /compact")
                    .font(.system(size: 10.5)).foregroundStyle(Ink.warn)
            }
        }
    }

    private func ctxColor(_ v: Double) -> Color { v >= 80 ? Ink.alarm : (v >= 60 ? Ink.warn : Ink.primary) }
}

struct ResetsBlock: View {
    let r: Resets
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise.circle.fill").foregroundStyle(color)
                Text("Сбросы лимита").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(r.available) в запасе").font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            Text(usableText).font(.system(size: 11)).foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var usableText: String {
        var parts: [String] = []
        if let u = r.usable { parts.append(u > 0 ? "можно применить сейчас: \(u)" : "сейчас применить нельзя") }
        if let e = r.expires { parts.append("ближайший сгорит \(e)") }
        parts.append("сброс обнуляет недельный лимит, применяется в Codex")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Подробности подписки

struct DetailView: View {
    let p: ProviderState
    let spend: [(String, Double)]
    @ObservedObject var ui: UIState
    let ns: Namespace.ID
    @State private var shown = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.spring) { ui.selected = nil }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Все лимиты").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Ink.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 16) {
                WRing(brand: p.brand, limit: p.ringLimit, size: 84, line: 10, fontSize: 20, drawn: true)
                    .matchedGeometryEffect(id: "ring-\(p.id)", in: ns)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Logo(brand: p.brand, size: 15)
                        Text(p.brand.title).font(.system(size: 18, weight: .semibold))
                    }
                    if let plan = p.plan {
                        Text("подписка \(plan)").font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    }
                    if let l = p.tightest {
                        Text("теснее всего: \(l.title.lowercased())").font(.system(size: 11)).foregroundStyle(Ink.tertiary)
                    }
                }
            }
            .padding(.top, 14)

            Rectangle().fill(Ink.hairline).frame(height: 0.5).padding(.vertical, 14)

            if p.limits.isEmpty {
                Text(p.note ?? "Нет данных")
                    .font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(p.limits.enumerated()), id: \.element.id) { i, l in
                        DetailRow(limit: l, color: p.brand.color, shown: shown, delay: 0.12 + Double(i) * 0.06)
                    }
                }
            }

            if let r = p.resets {
                Rectangle().fill(Ink.hairline).frame(height: 0.5).padding(.vertical, 14)
                ResetsBlock(r: r, color: p.brand.color)
            }
            if !spend.isEmpty {
                Rectangle().fill(Ink.hairline).frame(height: 0.5).padding(.vertical, 14)
                ModelList(models: spend, color: p.brand.color, shown: shown)
            }

        }
        .padding(20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear { DispatchQueue.main.async { shown = true } }
    }
}

struct DetailRow: View {
    let limit: Limit
    let color: Color
    let shown: Bool
    let delay: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Ink.secondary)
                Spacer()
                Text("\(Int(limit.used.rounded()))%")
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(pctColor(limit.used))
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(0.16))
                    Capsule().fill(color)
                        .frame(width: shown ? max(5, g.size.width * min(1, limit.used / 100)) : 0)
                        .animation(Motion.out.delay(delay), value: shown)
                    if let e = limit.elapsed() {
                        Capsule().fill(Color.primary.opacity(0.65))
                            .frame(width: 1.5, height: g.size.height + 5)
                            .offset(x: g.size.width * e - 0.75)
                            .opacity(shown ? 1 : 0)
                            .animation(.easeOut(duration: 0.3).delay(delay + 0.5), value: shown)
                    }
                }
            }
            .frame(height: 5)
            .help(limit.elapsed().map { "черта — сколько времени окна прошло: \(Int(($0 * 100).rounded()))%" } ?? "")
            if let per = limit.perDay() {
                Text(Fmt.budget(per: per, today: limit.today))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle((limit.today ?? 0) > per ? Ink.warn : Ink.secondary)
            }
            HStack {
                Text(Fmt.reset(limit.resetsAt)).foregroundStyle(Ink.tertiary)
                Spacer()
                if limit.used >= 100 {
                    Text("лимит исчерпан").foregroundStyle(Ink.alarm)
                } else if let out = limit.runsOut() {
                    Text("в таком темпе кончится \(Fmt.day(out))").foregroundStyle(Ink.warn)
                }
            }
            .font(.system(size: 10.5))
        }
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 6)
        .animation(.easeOut(duration: 0.35).delay(delay), value: shown)
    }
}

struct ModelList: View {
    let models: [(String, Double)]
    let color: Color
    let shown: Bool

    var body: some View {
        let total = models.reduce(0) { $0 + $1.1 }
        let top = Array(models.prefix(4))
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Расход за 30 дней").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(Fmt.money(total)).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            ForEach(top.indices, id: \.self) { i in
                let share = top[i].1 / max(total, 0.01)
                HStack(spacing: 8) {
                    Text(top[i].0).font(.system(size: 11)).foregroundStyle(Ink.secondary)
                        .frame(width: 110, alignment: .leading).lineLimit(1)
                    GeometryReader { g in
                        Capsule().fill(color.opacity(0.85 - Double(i) * 0.18))
                            .frame(width: shown ? max(3, g.size.width * share) : 0)
                            .animation(Motion.out.delay(0.3 + Double(i) * 0.06), value: shown)
                    }
                    .frame(height: 4)
                    Text(Fmt.money(top[i].1)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Ink.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
            }
            Text("по цене API").font(.system(size: 10.5)).foregroundStyle(Ink.tertiary)
        }
    }
}

// MARK: - Состояние окон

final class UIState: ObservableObject {
    static let handleSize = CGSize(width: 18, height: 84)
    static let panelSize = CGSize(width: 360, height: 660)
    @Published var panelShown = false
    @Published var handleHover = false
    @Published var drawn = false
    @Published var selected: Brand?
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @Published var theme: Theme = Theme(rawValue: UserDefaults.standard.string(forKey: "LimityDockTheme") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "LimityDockTheme"); theme.apply() }
    }
}

final class FloatingPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class HostView<V: View>: NSHostingView<V> {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onSwipe: ((CGFloat) -> Void)?       // + палец вправо, − палец влево
    var onClick: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var handlesMouse = false

    private var swipeAcc: CGFloat = 0
    private var swipeFired = false
    private var downAt: NSPoint?
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self && $0.userInfo?["limity"] != nil }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["limity": true]))
    }

    override func mouseEntered(with e: NSEvent) { super.mouseEntered(with: e); onEnter?() }
    override func mouseExited(with e: NSEvent) { super.mouseExited(with: e); onExit?() }

    override func scrollWheel(with e: NSEvent) {
        guard e.hasPreciseScrollingDeltas, abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) || swipeAcc != 0 else {
            super.scrollWheel(with: e); return
        }
        if e.phase == .began { swipeAcc = 0; swipeFired = false }
        let finger = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
        swipeAcc += finger
        if !swipeFired && abs(swipeAcc) > 28 { swipeFired = true; onSwipe?(swipeAcc) }
        if e.phase == .ended || e.phase == .cancelled || e.momentumPhase == .ended { swipeAcc = 0; swipeFired = false }
    }

    override func mouseDown(with e: NSEvent) {
        guard handlesMouse else { super.mouseDown(with: e); return }
        downAt = NSEvent.mouseLocation; dragging = false
    }
    override func mouseDragged(with e: NSEvent) {
        guard handlesMouse, let start = downAt else { super.mouseDragged(with: e); return }
        let now = NSEvent.mouseLocation
        if !dragging && abs(now.y - start.y) > 4 { dragging = true }
        if dragging { onDrag?(now.y - start.y); downAt = now }
    }
    override func mouseUp(with e: NSEvent) {
        guard handlesMouse else { super.mouseUp(with: e); return }
        if dragging { onDragEnd?() } else { onClick?() }
        downAt = nil; dragging = false
    }
    override func rightMouseDown(with e: NSEvent) {
        if let onMenu { onMenu(e) } else { super.rightMouseDown(with: e) }
    }
}

final class Controller: NSObject {
    let store = Store()
    let ui = UIState()
    private var handle: FloatingPanel!
    private var panel: FloatingPanel!
    private var handleHost: HostView<HandleView>!
    private var panelHost: HostView<PanelRoot>!
    private var timers: [Timer] = []
    private var openWork: DispatchWorkItem?
    private var watch: Timer?
    private var outsideSince: Date?
    private var clickMonitor: Any?
    private var bag = Set<AnyCancellable>()
    private let yKey = "LimityDockCenterY"

    func start() {
        handleHost = HostView(rootView: HandleView(store: store, ui: ui))
        handleHost.handlesMouse = true
        handle = FloatingPanel(size: UIState.handleSize)
        handle.contentView = handleHost

        panelHost = HostView(rootView: PanelRoot(store: store, ui: ui))
        panel = FloatingPanel(size: UIState.panelSize)
        panel.contentView = panelHost
        panel.hasShadow = false   // тень рисует само стекло; системная по полупрозрачному стеклу даёт дымку
        panel.alphaValue = 0

        handleHost.onEnter = { [weak self] in self?.enterHandle() }
        handleHost.onExit = { [weak self] in self?.ui.handleHover = false; self?.openWork?.cancel() }
        handleHost.onSwipe = { [weak self] _ in self?.open() }
        handleHost.onClick = { [weak self] in self?.toggle() }
        handleHost.onDrag = { [weak self] dy in self?.moveHandle(by: dy) }
        handleHost.onDragEnd = { [weak self] in self?.saveY() }
        handleHost.onMenu = { [weak self] e in self?.showMenu(e) }
        panelHost.onSwipe = { [weak self] dx in if dx > 0 { self?.close() } }

        placeHandle()
        handle.orderFrontRegardless()

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.handle.invalidateShadow() } }
            .store(in: &bag)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.placeHandle() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.store.refreshQuota(); self?.store.refreshReport()
        }

        Notifier.requestPermission()
        store.refreshQuota()
        store.refreshReport()
        let q = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.store.refreshQuota() }
        let r = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.store.refreshReport() }
        // сессии: файлы limity читать дёшево — раз в минуту, чтобы уведомление о раздутом контексте не опаздывало
        let s = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.store.refreshSessions() }
        q.tolerance = 30; r.tolerance = 60; s.tolerance = 10
        timers = [q, r, s]
    }

    // MARK: размещение

    private var screen: NSScreen { NSScreen.main ?? NSScreen.screens[0] }

    private func placeHandle() {
        let size = UIState.handleSize
        let vf = screen.visibleFrame
        let saved = UserDefaults.standard.object(forKey: yKey) as? Double
        let cy = saved.map { CGFloat($0) } ?? screen.frame.midY   // по умолчанию — ровно по центру края
        let y = min(max(cy - size.height / 2, vf.minY), vf.maxY - size.height)
        handle.setFrame(NSRect(x: screen.frame.maxX - size.width, y: y, width: size.width, height: size.height), display: true)
        if panel.isVisible { placePanel() }
    }

    private func placePanel() {
        let size = UIState.panelSize
        let vf = screen.visibleFrame
        let x = screen.frame.maxX - 20 - size.width
        let y = min(max(handle.frame.midY - size.height / 2, vf.minY + 8), vf.maxY - size.height - 8)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
    }

    private func moveHandle(by dy: CGFloat) {
        var fr = handle.frame
        let vf = screen.visibleFrame
        fr.origin.y = min(max(fr.origin.y + dy, vf.minY), vf.maxY - fr.height)
        handle.setFrameOrigin(fr.origin)
        if panel.isVisible { placePanel() }
    }

    private func saveY() { UserDefaults.standard.set(Double(handle.frame.midY), forKey: yKey) }

    // MARK: открыть / закрыть

    private func enterHandle() {
        ui.handleHover = true
        guard !ui.panelShown else { return }
        let w = DispatchWorkItem { [weak self] in self?.open() }
        openWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
    }

    private func toggle() { ui.panelShown ? close() : open() }

    private func open() {
        openWork?.cancel()
        guard !ui.panelShown else { return }
        store.refreshIfStale()
        store.refreshSessions()
        ui.selected = nil
        ui.drawn = false
        placePanel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        withAnimation(ui.reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.9)) { ui.panelShown = true }
        // содержимое каскадом — когда панель уже почти на месте
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.ui.drawn = true }

        outsideSince = nil
        watch?.invalidate()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.watchCursor() }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        watch = t
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    /// Пока панель открыта, 5 раз в секунду смотрим, где курсор: событие «ушёл» macOS
    /// доставляет не всегда. Полсекунды вне панели и ручки — закрываем.
    private func watchCursor() {
        let zone = panel.frame.union(handle.frame).insetBy(dx: -8, dy: -8)
        if zone.contains(NSEvent.mouseLocation) { outsideSince = nil; return }
        if outsideSince == nil { outsideSince = Date(); return }
        if Date().timeIntervalSince(outsideSince!) > 0.5 { close() }
    }

    private func close() {
        guard ui.panelShown else { return }
        watch?.invalidate(); watch = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        withAnimation(.timingCurve(0.4, 0, 1, 1, duration: 0.18)) { ui.panelShown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !self.ui.panelShown else { return }
            self.panel.orderOut(nil)
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { self.ui.drawn = false; self.ui.selected = nil }
        }
    }

    // MARK: меню по правому клику

    private func showMenu(_ e: NSEvent) {
        let m = NSMenu()
        let refresh = NSMenuItem(title: "Обновить", action: #selector(menuRefresh), keyEquivalent: "")
        let reset = NSMenuItem(title: "Вернуть ручку на место", action: #selector(menuResetY), keyEquivalent: "")
        let quit = NSMenuItem(title: "Выйти", action: #selector(menuQuit), keyEquivalent: "")
        [refresh, reset].forEach { $0.target = self; m.addItem($0) }
        m.addItem(.separator())
        for t in Theme.allCases {
            let item = NSMenuItem(title: t.title, action: #selector(menuTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = t.rawValue
            item.state = ui.theme == t ? .on : .off
            m.addItem(item)
        }
        m.addItem(.separator())
        quit.target = self
        m.addItem(quit)
        NSMenu.popUpContextMenu(m, with: e, for: handleHost)
    }

    @objc private func menuRefresh() { store.refreshQuota(); store.refreshReport() }
    @objc private func menuResetY() { UserDefaults.standard.removeObject(forKey: yKey); placeHandle() }
    @objc private func menuTheme(_ item: NSMenuItem) {
        if let raw = item.representedObject as? String, let t = Theme(rawValue: raw) { ui.theme = t }
    }
    @objc private func menuQuit() { NSApp.terminate(nil) }
}

// MARK: - Запуск

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
controller.ui.theme.apply()
controller.start()
app.run()
