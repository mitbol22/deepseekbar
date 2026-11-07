// DeepSeekBar — a tiny macOS menu bar app showing your DeepSeek balance and
// estimated token consumption. Reads the key from ../.env (DEEPSEEK_API_KEY)
// and shares history.json with balance.mjs.

import AppKit
import SwiftUI
import Charts
import ServiceManagement
import UserNotifications

// MARK: - Config

let projectDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 && !CommandLine.arguments[1].hasPrefix("--")
    ? CommandLine.arguments[1]
    : (Bundle.main.object(forInfoDictionaryKey: "DSProjectDir") as? String ?? NSHomeDirectory()))
let envURL = projectDir.appendingPathComponent(".env")
let historyURL = projectDir.appendingPathComponent("history.json")
/// How often to check the balance: DS_REFRESH_MINUTES in .env (default 15, minimum 1).
func refreshInterval(_ env: [String: String] = loadEnv()) -> TimeInterval {
    max(1, env["DS_REFRESH_MINUTES"].flatMap(Double.init) ?? 15) * 60
}

func loadEnv() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    guard let text = try? String(contentsOf: envURL, encoding: .utf8) else { return env }
    for line in text.split(separator: "\n") {
        let s = line.trimmingCharacters(in: .whitespaces)
        guard !s.hasPrefix("#"), let eq = s.firstIndex(of: "=") else { continue }
        let k = String(s[..<eq]).trimmingCharacters(in: .whitespaces)
        var v = String(s[s.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if env[k] == nil { env[k] = v }
    }
    return env
}


func cnyPerUsd(_ env: [String: String]) -> Double {
    env["DS_CNY_PER_USD"].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? 7.1
}

// MARK: - Data

struct Snapshot: Codable {
    var at: String
    var currency: String
    var total: Double
    var granted: Double
    var toppedUp: Double
}

struct BalanceResponse: Decodable {
    struct Info: Decodable {
        let currency: String
        let total_balance: String
        let granted_balance: String
        let topped_up_balance: String
    }
    let is_available: Bool
    let balance_infos: [Info]
}

let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
func parseDate(_ s: String) -> Date? { iso.date(from: s) ?? ISO8601DateFormatter().date(from: s) }

func loadHistory() -> [Snapshot] {
    guard let d = try? Data(contentsOf: historyURL) else { return [] }
    return (try? JSONDecoder().decode([Snapshot].self, from: d)) ?? []
}
func saveHistory(_ h: [Snapshot]) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted]
    try? enc.encode(h).write(to: historyURL, options: .atomic)
}

/// Money spent (balance decreases only, top-ups ignored) since `from`.
func spent(_ h: [Snapshot], currency: String, since from: Date) -> Double {
    let rows = h.filter { $0.currency == currency }
    var total = 0.0
    for i in rows.indices.dropFirst() {
        guard let t = parseDate(rows[i].at), t >= from else { continue }
        let d = rows[i - 1].total - rows[i].total
        if d > 0 { total += d }
    }
    return total
}

/// The "100%" reference: DS_BUDGET if set, else the balance right after the latest top-up.
func reference(_ h: [Snapshot], currency: String, budget: Double?) -> Double {
    if let budget, budget > 0 { return budget }
    let rows = h.filter { $0.currency == currency }
    guard var ref = rows.first?.total else { return 0 }
    for i in rows.indices.dropFirst() where rows[i].total > rows[i - 1].total {
        ref = rows[i].total
    }
    return ref
}

func money(_ v: Double, _ cur: String) -> String {
    (cur == "CNY" ? "¥" : "$") + String(format: v < 10 ? "%.3f" : "%.2f", v)
}

/// Daily spend for the last `days` days (oldest first), top-ups ignored.
func dailySpend(_ h: [Snapshot], currency: String, days: Int, now: Date) -> [(day: Date, amount: Double)] {
    let cal = Calendar.current
    let start = cal.startOfDay(for: now)
    var buckets = (0..<days).map { (day: cal.date(byAdding: .day, value: -(days - 1 - $0), to: start)!, amount: 0.0) }
    let rows = h.filter { $0.currency == currency }
    for i in rows.indices.dropFirst() {
        guard let t = parseDate(rows[i].at) else { continue }
        let d = rows[i - 1].total - rows[i].total
        guard d > 0, let idx = buckets.firstIndex(where: { cal.isDate($0.day, inSameDayAs: t) }) else { continue }
        buckets[idx].amount += d
    }
    return buckets
}

// MARK: - Model

struct Usage {
    var currency = "USD"
    var available = true
    var total = 0.0, granted = 0.0, toppedUp = 0.0
    var reference = 0.0, pct = 0.0, isBudget = false
    var today = 0.0, week = 0.0, lastSpend: Double?
    var daily: [(day: Date, amount: Double)] = []
    var perDay: Double?
    var daysLeft: Double?
    var cnyPerUsd = 7.1
}


enum LoadState { case loading, error(String, String), loaded(Usage) }

@MainActor
final class Store: ObservableObject {
    @Published var state: LoadState = .loading
    @Published var updated: Date?
    @Published var refreshing = false
    var onChange: (() -> Void)?
    var alertPercent = 15.0

    func refresh() {
        refreshing = true
        let env = loadEnv()
        alertPercent = env["DS_ALERT_PERCENT"].flatMap(Double.init) ?? 15
        guard let key = env["DEEPSEEK_API_KEY"], !key.isEmpty, !key.contains("your-key") else {
            finish(.error("No API key", "Add DEEPSEEK_API_KEY to \(envURL.path)"))
            return
        }
        var req = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!, timeoutInterval: 15)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { data, resp, err in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let decoded = data.flatMap { try? JSONDecoder().decode(BalanceResponse.self, from: $0) }
            Task { @MainActor in
                if let err { return self.finish(.error("Network error", err.localizedDescription)) }
                guard status == 200, let decoded else {
                    return self.finish(.error("DeepSeek API error \(status)", status == 401 ? "Check your API key" : "Try again later"))
                }
                self.finish(.loaded(self.compute(decoded, env)))
            }
        }.resume()
    }

    private func finish(_ s: LoadState) {
        state = s
        updated = Date()
        refreshing = false
        if case let .loaded(u) = s { checkAlert(u) }
        onChange?()
    }

    /// One notification when the balance drops below DS_ALERT_PERCENT (default 15%)
    /// or the API gets paused. Re-arms once you're back above the line (e.g. after a top-up).
    private func checkAlert(_ u: Usage) {
        let defaults = UserDefaults.standard
        let low = !u.available || (u.reference > 0 && u.pct < alertPercent)
        guard low else { defaults.set(false, forKey: "alerted"); return }
        guard !defaults.bool(forKey: "alerted") else { return }
        defaults.set(true, forKey: "alerted")

        let title = u.available ? "DeepSeek balance low" : "DeepSeek API paused"
        let body = u.available
            ? String(format: "%.0f%% left (%@). Top up to keep using the API.", u.pct, money(u.total, u.currency))
            : "Your balance has run out. Top up to resume."
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "low-balance", content: content, trigger: nil))
        }
    }

    private func compute(_ r: BalanceResponse, _ env: [String: String]) -> Usage {
        let now = Date()
        var history = loadHistory()
        // DeepSeek can return several balances (e.g. CNY and an empty USD one) in no fixed
        // order. Use the one with money in it; on a tie prefer CNY, then the first listed.
        let picked = r.balance_infos.max { a, b in
            let ta = Double(a.total_balance) ?? 0, tb = Double(b.total_balance) ?? 0
            if ta != tb { return ta < tb }
            return a.currency != "CNY" && b.currency == "CNY"
        }
        guard let b = picked else { return Usage(available: r.is_available) }

        var u = Usage()
        u.currency = b.currency
        u.available = r.is_available
        u.total = Double(b.total_balance) ?? 0
        u.granted = Double(b.granted_balance) ?? 0
        u.toppedUp = Double(b.topped_up_balance) ?? 0
        u.cnyPerUsd = cnyPerUsd(env)

        let prev = history.last(where: { $0.currency == u.currency })
        if prev?.total != u.total {
            history.append(Snapshot(at: iso.string(from: now), currency: u.currency, total: u.total,
                                    granted: u.granted, toppedUp: u.toppedUp))
            saveHistory(history)
        }
        let rows = history.filter { $0.currency == u.currency }
        if rows.count >= 2, rows[rows.count - 2].total > rows[rows.count - 1].total {
            u.lastSpend = rows[rows.count - 2].total - rows[rows.count - 1].total
        }

        let budget = env["DS_BUDGET"].flatMap(Double.init)
        u.isBudget = (budget ?? 0) > 0
        u.reference = reference(history, currency: u.currency, budget: budget)
        u.pct = u.reference > 0 ? min(100, max(0, u.total / u.reference * 100)) : 0

        u.today = spent(history, currency: u.currency, since: Calendar.current.startOfDay(for: now))
        u.week = spent(history, currency: u.currency, since: now.addingTimeInterval(-7 * 86400))
        u.daily = dailySpend(history, currency: u.currency, days: 7, now: now)

        // Days left at your recent pace (average over the days we have data for, up to 7).
        if let first = rows.first.flatMap({ parseDate($0.at) }) {
            let span = min(7, max(1, now.timeIntervalSince(first) / 86400))
            let perDay = u.week / span
            if perDay > 0 { u.perDay = perDay; u.daysLeft = u.total / perDay }
        }

        return u
    }
}

// MARK: - Views

let accent = Color(red: 0.30, green: 0.42, blue: 0.99) // DeepSeek blue

func gaugeColor(_ pct: Double) -> Color {
    pct < 15 ? .red : pct < 40 ? .orange : accent
}

struct LogoView: View {
    var size: CGFloat
    var body: some View {
        if let path = Bundle.main.path(forResource: "deepseek", ofType: "svg"), let img = NSImage(contentsOfFile: path) {
            Image(nsImage: { img.isTemplate = true; return img }())
                .resizable().renderingMode(.template).foregroundStyle(accent)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "fish.fill").foregroundStyle(accent).font(.system(size: size * 0.8))
        }
    }
}

struct Card<Content: View>: View {
    var title: String
    var icon: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

struct Bar: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color.gradient).frame(width: max(height, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
    }
}

struct PopoverView: View {
    @ObservedObject var store: Store
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    /// "" = same as the account; otherwise "CNY" or "USD". Remembered between launches.
    @AppStorage("displayCurrency") private var displayCurrency = ""

    func shown(_ u: Usage) -> String { displayCurrency.isEmpty ? u.currency : displayCurrency }

    /// Format an amount (in the account currency) in the chosen display currency.
    func fmt(_ v: Double, _ u: Usage) -> String {
        let to = shown(u)
        if to == u.currency { return money(v, to) }
        let converted = u.currency == "CNY" ? v / u.cnyPerUsd : v * u.cnyPerUsd
        return "≈" + money(converted, to)
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            switch store.state {
            case .loading:
                ProgressView().frame(height: 160)
            case let .error(title, detail):
                Card(title: title, icon: "exclamationmark.triangle.fill") {
                    Text(detail).font(.caption).textSelection(.enabled)
                }
            case let .loaded(u):
                content(u)
            }
            footer
        }
        .padding(12)
        .frame(width: 320)
        .frame(maxHeight: (NSScreen.main?.visibleFrame.height ?? 700) - 40)
    }

    var header: some View {
        HStack(spacing: 8) {
            LogoView(size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text("DeepSeek").font(.headline)
                Text(updatedText).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if case let .loaded(u) = store.state {
                Picker("", selection: Binding(get: { shown(u) }, set: { displayCurrency = $0 })) {
                    Text("¥").tag("CNY")
                    Text("$").tag("USD")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .help("Show amounts in yuan or US dollars")
                Text(u.available ? "Active" : "Paused")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill((u.available ? Color.green : Color.red).opacity(0.18)))
                    .foregroundStyle(u.available ? .green : .red)
            }
            Button { store.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.refreshing ? 360 : 0))
                    .animation(store.refreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: store.refreshing)
            }
            .buttonStyle(.borderless).help("Refresh")
        }
    }

    var updatedText: String {
        guard let d = store.updated else { return "Updating…" }
        if Date().timeIntervalSince(d) < 60 { return "Updated just now" }
        return "Updated " + RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
    }

    @ViewBuilder func content(_ u: Usage) -> some View {
        // Balance gauge
        Card(title: "Balance left", icon: "gauge.with.dots.needle.67percent") {
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%.0f%%", u.pct))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(gaugeColor(u.pct))
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(fmt(u.total, u)).font(.body.monospacedDigit().weight(.semibold))
                    Text("of \(fmt(u.reference, u)) \(u.isBudget ? "budget" : "since top-up")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Bar(fraction: u.pct / 100, color: gaugeColor(u.pct), height: 8)
            HStack {
                Text("Topped up \(fmt(u.toppedUp, u))")
                Spacer()
                Text("Granted \(fmt(u.granted, u))")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }

        // How long it lasts — measured from your own spending, no price guesses
        Card(title: "How long it lasts", icon: "hourglass") {
            if let days = u.daysLeft, let perDay = u.perDay {
                HStack(spacing: 6) {
                    tileText(days >= 365 ? "1 year+" : String(format: "≈ %.0f days", days), "at your 7-day pace", accent)
                    tileText(fmt(perDay, u), "average per day", .purple)
                }
                if days < 365 {
                    Text("Runs out around \(Date().addingTimeInterval(days * 86400).formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("Fills in once you've used the API for a day or two.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }

        // Spending chart
        Card(title: "Spending · last 7 days", icon: "chart.bar.fill") {
            if u.week > 0 {
            Chart(u.daily, id: \.day) { d in
                BarMark(x: .value("Day", d.day, unit: .day), y: .value("Spent", d.amount))
                    .foregroundStyle(accent.gradient)
                    .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 52)
            } else {
                Text("No spending recorded yet — it fills in as you use the API.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                pill("Today", fmt(u.today, u))
                pill("7 days", fmt(u.week, u))
                if let s = u.lastSpend { pill("Last drop", "−" + fmt(s, u)) }
            }
        }
    }

    func tileText(_ value: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color.gradient).frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.callout.monospacedDigit().weight(.semibold))
                Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5).padding(.horizontal, 7)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.08)))
    }

    func pill(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit().weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var footer: some View {
        HStack {
            Button("Usage") { NSWorkspace.shared.open(URL(string: "https://platform.deepseek.com/usage")!) }
            Button("Top up") { NSWorkspace.shared.open(URL(string: "https://platform.deepseek.com/top_up")!) }
            Spacer()
            Toggle("Open at login", isOn: Binding(get: { loginOn }, set: { on in
                do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                catch { NSSound.beep() }
                loginOn = SMAppService.mainApp.status == .enabled
            }))
                .toggleStyle(.switch).controlSize(.mini)
                .help("Open at login")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit")
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}

// MARK: - Menu bar

/// Logo + gauge + text drawn into ONE template image the height of the menu bar,
/// so everything is vertically centred together (AppKit aligns a separate
/// image and title differently, which looked off).
func menuBarImage(pct: Double?, text: String) -> NSImage {
    let h = NSStatusBar.system.thickness
    let logoSize: CGFloat = 16, gaugeW: CGFloat = 18, gaugeH: CGFloat = 6, gap: CGFloat = 4
    let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
    let textW = text.isEmpty ? 0 : ceil(str.size().width)

    var width = logoSize
    if pct != nil { width += gap + gaugeW }
    if textW > 0 { width += gap + textW }

    let img = NSImage(size: NSSize(width: width, height: h), flipped: false) { _ in
        var x: CGFloat = 0
        if let path = Bundle.main.path(forResource: "deepseek", ofType: "svg"), let logo = NSImage(contentsOfFile: path) {
            logo.draw(in: NSRect(x: x, y: ((h - logoSize) / 2).rounded(), width: logoSize, height: logoSize))
        }
        x += logoSize
        if let pct {
            x += gap
            let rect = NSRect(x: x, y: ((h - gaugeH) / 2).rounded(), width: gaugeW, height: gaugeH)
            NSColor.black.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: rect, xRadius: gaugeH / 2, yRadius: gaugeH / 2).fill()
            var fill = rect
            fill.size.width = max(gaugeH, rect.width * pct / 100)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: fill, xRadius: gaugeH / 2, yRadius: gaugeH / 2).fill()
            x += gaugeW
        }
        if textW > 0 {
            x += gap
            // Centre on cap height (what digits/% occupy), not the full line box.
            let baseline = ((h - font.capHeight) / 2).rounded()
            str.draw(at: NSPoint(x: x, y: baseline + font.descender))
        }
        return true
    }
    img.isTemplate = true
    return img
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    var store: Store!
    var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        MainActor.assumeIsolated {
            store = Store()
            store.onChange = { [weak self] in
                self?.updateButton()
                self?.scheduleTimer()  // picks up a changed DS_REFRESH_MINUTES
            }
            popover.behavior = .transient
            let host = NSHostingController(rootView: PopoverView(store: store))
            host.sizingOptions = .preferredContentSize
            popover.contentViewController = host
            popover.animates = false
            store.refresh()
        }
        item.button?.image = menuBarImage(pct: nil, text: "…")
        item.button?.imagePosition = .imageOnly
        item.button?.action = #selector(toggle)
        item.button?.target = self
        scheduleTimer()
    }

    func scheduleTimer() {
        let interval = refreshInterval()
        if let timer, timer.isValid, timer.timeInterval == interval { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.store.refresh() }
        }
    }

    @MainActor func updateButton() {
        guard let button = item.button else { return }
        switch store.state {
        case .loading:
            button.image = menuBarImage(pct: nil, text: "…")
            button.contentTintColor = nil
        case .error:
            button.image = menuBarImage(pct: nil, text: "!")
            button.contentTintColor = .systemOrange
        case let .loaded(u):
            button.image = menuBarImage(pct: u.available ? u.pct : 0,
                                        text: u.available ? String(format: "%.0f%%", u.pct) : "off")
            button.contentTintColor = (u.pct < store.alertPercent || !u.available) ? .systemRed : nil
        }
    }

    @objc func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            MainActor.assumeIsolated { store.refresh() }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Demo screenshot (for the README; uses made-up numbers, no API call)
//   DeepSeekBar.app/Contents/MacOS/DeepSeekBar --render-demo out.png [light|dark]

@MainActor func renderDemo(to path: String, dark: Bool) {
    let now = Date()
    var u = Usage()
    u.currency = "CNY"
    u.total = 42.50; u.toppedUp = 42.50; u.reference = 60
    u.pct = u.total / u.reference * 100
    u.today = 0.48; u.week = 4.31; u.lastSpend = 0.12
    let amounts = [0.55, 0.92, 0.31, 0.74, 0.66, 0.65, 0.48]
    u.daily = amounts.enumerated().map { (i, a) in
        (day: Calendar.current.date(byAdding: .day, value: i - 6, to: Calendar.current.startOfDay(for: now))!, amount: a)
    }
    u.perDay = u.week / 7; u.daysLeft = u.total / u.perDay!

    let store = Store()
    store.state = .loaded(u)
    store.updated = now
    let view = PopoverView(store: store).background(Color(nsColor: .windowBackgroundColor))
    let host = NSHostingView(rootView: view)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.frame.size = host.fittingSize
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))  // let Charts finish laying out

    let scale: CGFloat = 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * scale),
                               pixelsHigh: Int(host.bounds.height * scale), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = host.bounds.size
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

/// The menu bar item on a menu-bar-like strip, tinted like the real thing.
func renderMenuBarDemo(to path: String, dark: Bool) {
    let item = menuBarImage(pct: 71, text: "71%")
    let pad: CGFloat = 14, h: CGFloat = 30
    let size = NSSize(width: item.size.width + pad * 2, height: h)
    let scale: CGFloat = 3
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let bg = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)
    bg.setFill()
    NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 8, yRadius: 8).fill()
    // Tint the template image: draw it, then fill over its pixels only.
    let tinted = NSImage(size: item.size, flipped: false) { r in
        item.draw(in: r)
        (dark ? NSColor.white : NSColor.black).set()
        r.fill(using: .sourceAtop)
        return true
    }
    tinted.draw(in: NSRect(x: pad, y: ((h - item.size.height) / 2).rounded(), width: item.size.width, height: item.size.height))
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

if let i = CommandLine.arguments.firstIndex(of: "--render-menubar"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    renderMenuBarDemo(to: CommandLine.arguments[i + 1], dark: CommandLine.arguments.dropFirst(i + 2).first == "dark")
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--render-demo"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    let dark = CommandLine.arguments.dropFirst(i + 2).first == "dark"
    MainActor.assumeIsolated { renderDemo(to: CommandLine.arguments[i + 1], dark: dark) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
