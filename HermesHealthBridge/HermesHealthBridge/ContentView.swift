import SwiftUI
import PhotosUI
import UIKit

struct ContentView: View {
    @StateObject private var healthStore = HealthKitManager()
    @AppStorage("collectorURL") private var collectorURL = "http://192.168.3.7:8765/health/daily"
    @State private var isSyncing = false
    @State private var isAuthorizing = false
    @State private var isCheckingConnection = false
    @State private var isLoadingSummaries = false
    @State private var isConnected: Bool?
    @State private var status = "准备就绪"
    @State private var lastSummary: DailyHealthSummary?
    @State private var recentSummaries: [DailyHealthSummary] = []
    @State private var nutritionByDate: [String: NutritionDayResponse] = [:]
    @State private var summariesMessage = "还没有加载本机健康摘要。"

    var body: some View {
        TabView {
            HomeView(
                healthStore: healthStore,
                collectorURL: collectorURL,
                isSyncing: isSyncing,
                isAuthorizing: isAuthorizing,
                isCheckingConnection: isCheckingConnection,
                isConnected: isConnected,
                status: status,
                lastSummary: lastSummary,
                lastNutrition: lastSummary.flatMap { nutritionByDate[$0.date] },
                requestHealthAccess: { Task { await requestHealthAccess() } },
                syncRecentDays: { Task { await syncRecentDays() } },
                checkConnection: { Task { await checkConnection() } }
            )
            .tabItem {
                Label("首页", systemImage: "house.fill")
            }

            HistoryView(
                summaries: recentSummaries,
                nutritionByDate: nutritionByDate,
                isLoading: isLoadingSummaries,
                message: summariesMessage,
                refresh: { Task { await loadRecentSummaries() } }
            )
            .tabItem {
                Label("历史", systemImage: "chart.bar.xaxis")
            }

            InsightsView(
                summaries: recentSummaries,
                latestSummary: lastSummary,
                isLoading: isLoadingSummaries,
                refresh: { Task { await loadRecentSummaries() } }
            )
            .tabItem {
                Label("洞察", systemImage: "lightbulb")
            }

            NutritionView(collectorURL: collectorURL)
                .tabItem {
                    Label("饮食", systemImage: "fork.knife")
                }

            SettingsView(collectorURL: $collectorURL, status: status)
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
        }
        .tint(Color.mintGreen)
        .task {
            await checkConnection()
            await loadRecentSummaries()
        }
    }

    private func requestHealthAccess() async {
        isAuthorizing = true
        status = "正在请求健康数据权限..."
        defer { isAuthorizing = false }

        do {
            try await healthStore.requestAuthorization()
            await BackgroundSyncService.shared.configureAutomaticSync()
            status = "健康数据权限已授权，后台同步已配置。"
        } catch {
            status = "健康数据授权失败：\(error.localizedDescription)"
        }
    }

    private func syncRecentDays() async {
        isSyncing = true
        status = "正在同步最近 7 天数据到 Hermes..."
        defer { isSyncing = false }

        do {
            UserDefaults.standard.set(collectorURL, forKey: "collectorURL")
            let uploaded = try await BackgroundSyncService.shared.syncRecentDays(reason: "manual")
            await loadRecentSummaries()
            isConnected = true
            status = "已成功同步 \(uploaded) 天数据到 Hermes。最新日期：\(lastSummary?.date ?? "--")。"
        } catch {
            isConnected = false
            status = "同步失败：\(error.localizedDescription)"
        }
    }

    private func loadRecentSummaries() async {
        isLoadingSummaries = true
        defer { isLoadingSummaries = false }

        do {
            let response = try await HermesCollectorClient.fetchHealthHistory(days: 90, collectorEndpoint: collectorURL)
            let summaries = response.summaries.map(\.dailySummary)
            recentSummaries = summaries
            lastSummary = summaries.last
            summariesMessage = "已加载 \(summaries.count) 天 Hermes 历史记录。"
            await loadNutrition(for: summaries)
            isConnected = true
        } catch {
            do {
                let summaries = try await healthStore.readRecentSummaries(days: 14)
                recentSummaries = summaries
                lastSummary = summaries.last
                summariesMessage = "Mac 收集器暂时不可用，已显示最近 \(summaries.count) 天本机健康摘要。"
                await loadNutrition(for: summaries)
            } catch {
                summariesMessage = "请先授权健康数据，或确认 Mac 收集器在线：\(error.localizedDescription)"
            }
        }
    }

    private func loadNutrition(for summaries: [DailyHealthSummary]) async {
        var fetched: [String: NutritionDayResponse] = [:]
        for summary in summaries {
            if let day = try? await HermesCollectorClient.fetchNutritionDay(date: summary.date, collectorEndpoint: collectorURL) {
                fetched[summary.date] = day
            }
        }
        nutritionByDate.merge(fetched) { _, new in new }
    }

    private func checkConnection() async {
        guard let healthURL else {
            isConnected = false
            return
        }

        isCheckingConnection = true
        defer { isCheckingConnection = false }

        do {
            var request = URLRequest(url: healthURL)
            request.timeoutInterval = 5
            let (_, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            isConnected = (200..<300).contains(httpResponse?.statusCode ?? 0)
            status = isConnected == true ? "已连接到 Mac 收集器。" : "Mac 收集器没有响应。"
        } catch {
            isConnected = false
            status = "Mac 收集器离线。"
        }
    }

    private var healthURL: URL? {
        guard var components = URLComponents(string: collectorURL) else { return nil }
        components.path = "/health"
        components.query = nil
        return components.url
    }
}

private struct HomeView: View {
    @ObservedObject var healthStore: HealthKitManager
    let collectorURL: String
    let isSyncing: Bool
    let isAuthorizing: Bool
    let isCheckingConnection: Bool
    let isConnected: Bool?
    let status: String
    let lastSummary: DailyHealthSummary?
    let lastNutrition: NutritionDayResponse?
    let requestHealthAccess: () -> Void
    let syncRecentDays: () -> Void
    let checkConnection: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    connectionCard
                    quickActions
                    summarySection
                }
                .padding(.horizontal, 24)
                .padding(.top, 26)
                .padding(.bottom, 72)
            }
            .background(
                LinearGradient(
                    colors: [.white, Color(hex: 0xF7FBFA)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .navigationBarHidden(true)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Hermes Health")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.ink)
                    .minimumScaleFactor(0.75)

                Text("你的健康数据，已连接。")
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.softText)
            }

            Spacer()

            Button(action: checkConnection) {
                ZStack {
                    Circle()
                        .fill(Color.mintGreen.opacity(0.12))
                        .frame(width: 64, height: 64)
                        .shadow(color: .mintGreen.opacity(0.18), radius: 18, x: 0, y: 10)

                    if isCheckingConnection {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 27, weight: .semibold))
                            .foregroundStyle(Color.deepGreen)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("刷新连接")
        }
    }

    private var connectionCard: some View {
        SoftCard(tint: .mintGreen) {
            VStack(alignment: .leading, spacing: 20) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) {
                        ConnectionIllustration()
                        Spacer(minLength: 8)
                        collectorStatus
                    }

                    VStack(alignment: .leading, spacing: 18) {
                        ConnectionIllustration()
                        collectorStatus
                    }
                }

                Label("请先在 Mac 上运行 python3 collector.py。", systemImage: "desktopcomputer")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.softText)
            }
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("快捷操作")
                .sectionTitle()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    authorizeCard
                    syncCard
                }

                VStack(spacing: 14) {
                    authorizeCard
                    syncCard
                }
            }

            statusBanner
        }
    }

    private var collectorStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(connectionText, systemImage: "circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(connectionColor)
                .labelStyle(.titleAndIcon)

            Text("Mac 收集器")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Text(shortCollectorAddress)
                .font(.system(size: 18, weight: .regular, design: .rounded))
                .foregroundStyle(Color.softText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(minWidth: 118, alignment: .leading)
    }

    private var authorizeCard: some View {
        ActionCard(
            title: "授权\n健康数据",
            subtitle: isAuthorizing ? "正在等待 Apple\n健康授权..." : "允许读取 Apple\n健康数据。",
            icon: isAuthorizing ? "hourglass" : "heart.square",
            tint: Color(hex: 0x2F8CEF),
            isLoading: isAuthorizing,
            action: requestHealthAccess
        )
        .disabled(isAuthorizing)
    }

    private var syncCard: some View {
        ActionCard(
            title: "同步最近\n7 天",
            subtitle: isSyncing ? "正在同步数据\n到 Hermes..." : "把最新健康数据\n同步到 Hermes。",
            icon: isSyncing ? "hourglass" : "arrow.triangle.2.circlepath",
            tint: .deepGreen,
            isLoading: isSyncing,
            action: syncRecentDays
        )
        .disabled(isSyncing)
    }

    private var statusBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusIcon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 28, height: 28)
                .background(statusColor.opacity(0.12))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.ink)

                Text(status)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.softText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(statusColor.opacity(0.18), lineWidth: 1)
        )
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("最新摘要")
                    .sectionTitle()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                HStack(spacing: 8) {
                    Text(lastSummary?.date ?? "--")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    Image(systemName: "calendar")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(Color.deepGreen)
            }

            VStack(spacing: 0) {
                SummaryMetricRow(icon: "shoeprints.fill", title: "步数", value: format(lastSummary?.steps, decimals: 0), unit: "步")
                SummaryMetricRow(icon: "flame.fill", title: "活动能量", value: format(lastSummary?.activeEnergyKcal, decimals: 0), unit: "kcal")
                SummaryMetricRow(icon: "fork.knife", title: "饮食摄入", value: format(lastNutrition?.totals.intakeKcal, decimals: 0), unit: "kcal")
                SummaryMetricRow(icon: "takeoutbag.and.cup.and.straw.fill", title: "记录餐数", value: mealCountText, unit: "餐")
                SummaryMetricRow(icon: "heart.fill", title: "平均心率", value: format(lastSummary?.avgHeartRate, decimals: 1), unit: "bpm")
                SummaryMetricRow(icon: "heart.text.square.fill", title: "静息心率", value: format(lastSummary?.restingHeartRate, decimals: 1), unit: "bpm")
                SummaryMetricRow(icon: "waveform.path.ecg", title: "心率变异性", value: format(lastSummary?.hrvSdnn, decimals: 1), unit: "ms")
                SummaryMetricRow(icon: "moon.zzz.fill", title: "睡眠", value: format(lastSummary?.sleepMinutes, decimals: 0), unit: "分钟")
                SummaryMetricRow(icon: "bed.double.fill", title: "午睡", value: format(lastSummary?.napMinutes, decimals: 0), unit: "分钟")
                SummaryMetricRow(icon: "figure.run", title: "训练", value: format(lastSummary?.workoutMinutes, decimals: 0), unit: "分钟", showsDivider: shouldShowFoodLine)
                if shouldShowFoodLine {
                    LatestFoodLine(nutrition: lastNutrition)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 18)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.04), radius: 22, x: 0, y: 10)
        }
    }

    private var connectionText: String {
        switch isConnected {
        case true:
            return "已连接"
        case false:
            return "离线"
        case nil:
            return "检查中"
        }
    }

    private var connectionColor: Color {
        isConnected == false ? .orange : .deepGreen
    }

    private var statusTitle: String {
        if isAuthorizing { return "授权中" }
        if isSyncing { return "同步中" }
        if hasProblemStatus {
            return "需要处理"
        }
        if hasSuccessStatus {
            return "已完成"
        }
        return "状态"
    }

    private var statusIcon: String {
        if isAuthorizing || isSyncing { return "clock.arrow.circlepath" }
        if hasProblemStatus {
            return "exclamationmark.triangle.fill"
        }
        if hasSuccessStatus {
            return "checkmark.circle.fill"
        }
        return "info.circle.fill"
    }

    private var statusColor: Color {
        if isAuthorizing || isSyncing { return .deepGreen }
        if hasProblemStatus {
            return .orange
        }
        if hasSuccessStatus {
            return .deepGreen
        }
        return Color(hex: 0x2F8CEF)
    }

    private var hasProblemStatus: Bool {
        status.localizedCaseInsensitiveContains("failed")
            || status.localizedCaseInsensitiveContains("offline")
            || status.contains("失败")
            || status.contains("离线")
            || status.contains("没有响应")
    }

    private var hasSuccessStatus: Bool {
        status.localizedCaseInsensitiveContains("authorized")
            || status.localizedCaseInsensitiveContains("synced")
            || status.localizedCaseInsensitiveContains("connected")
            || status.contains("已授权")
            || status.contains("已成功")
            || status.contains("已连接")
    }

    private var shortCollectorAddress: String {
        guard let components = URLComponents(string: collectorURL), let host = components.host else {
            return collectorURL
        }
        if let port = components.port {
            return "\(host):\(port)"
        }
        return host
    }

    private var mealCountText: String {
        guard let lastNutrition else { return "-" }
        return "\(lastNutrition.meals.count)"
    }

    private var shouldShowFoodLine: Bool {
        guard let lastNutrition else { return false }
        return !lastNutrition.meals.isEmpty
    }

    private func format(_ value: Double?, decimals: Int) -> String {
        guard let value else { return "-" }
        return value.formatted(.number.precision(.fractionLength(decimals)))
    }
}

private struct LatestFoodLine: View {
    let nutrition: NutritionDayResponse?

    var body: some View {
        if let nutrition, !nutrition.meals.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                    .padding(.leading, 50)

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "menucard.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.deepGreen)
                        .frame(width: 38, height: 38)
                        .background(Color.mintGreen.opacity(0.16))
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 4) {
                        Text("今天吃了")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.ink)

                        Text(foodText(for: nutrition))
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.softText)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
            }
        }
    }

    private func foodText(for nutrition: NutritionDayResponse) -> String {
        let names = nutrition.meals.prefix(3).map(\.foodName).joined(separator: "、")
        return nutrition.meals.count > 3 ? "\(names) 等" : names
    }
}

private struct NutritionView: View {
    let collectorURL: String

    @AppStorage("profileName") private var profileName = ""
    @AppStorage("profileSex") private var profileSex = "男"
    @AppStorage("profileAge") private var profileAge = ""
    @AppStorage("profileHeightCm") private var profileHeightCm = ""
    @AppStorage("profileWeightKg") private var profileWeightKg = ""
    @AppStorage("profileTargetWeightKg") private var profileTargetWeightKg = ""
    @AppStorage("profileGoal") private var profileGoal = "减脂"
    @AppStorage("profileActivityLevel") private var profileActivityLevel = "普通"
    @AppStorage("visionProvider") private var visionProvider = "阿里通义"
    @AppStorage("visionAPIKey") private var visionAPIKey = ""
    @AppStorage("visionBaseURL") private var visionBaseURL = ""
    @AppStorage("visionModel") private var visionModel = ""
    @AppStorage("deepSeekAPIKey") private var deepSeekAPIKey = ""
    @AppStorage("deepSeekBaseURL") private var deepSeekBaseURL = "https://api.deepseek.com"
    @AppStorage("deepSeekModel") private var deepSeekModel = "deepseek-v4-pro"

    @State private var mealType = "早餐"
    @State private var foodName = ""
    @State private var calories = ""
    @State private var protein = ""
    @State private var carbs = ""
    @State private var fat = ""
    @State private var note = ""
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var selectedImageData: Data?
    @State private var isShowingCamera = false
    @State private var isAnalyzing = false
    @State private var isSaving = false
    @State private var status = "拍照后可识别，也可以直接手动填写。"

    private let mealTypes = ["早餐", "午餐", "晚餐", "加餐"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PageHeader(
                        title: "饮食记录",
                        subtitle: "拍照、估算热量、同步到 Hermes",
                        icon: "fork.knife",
                        isLoading: isAnalyzing || isSaving,
                        action: {}
                    )

                    photoCard
                    mealForm
                    actionButtons
                    statusCard
                }
                .padding(24)
                .padding(.bottom, 72)
            }
            .background(Color(hex: 0xF7FBFA).ignoresSafeArea())
            .navigationBarHidden(true)
            .sheet(isPresented: $isShowingCamera) {
                CameraPicker { image in
                    selectedImage = image
                    selectedImageData = image.jpegData(compressionQuality: 0.72)
                    status = "照片已加入，可以识别或手动填写。"
                }
            }
            .onChange(of: selectedItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        selectedImage = image
                        selectedImageData = image.jpegData(compressionQuality: 0.72)
                        status = "照片已加入，可以识别或手动填写。"
                    }
                }
            }
            .task {
                await syncPendingMealsSilently()
            }
        }
    }

    private var photoCard: some View {
        SoftCard(tint: .deepGreen) {
            VStack(alignment: .leading, spacing: 14) {
                if let selectedImage {
                    Image(uiImage: selectedImage)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 210)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 42, weight: .semibold))
                            .foregroundStyle(Color.deepGreen)
                        Text("给这顿饭拍张照")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.ink)
                        Text("识别结果会作为估算，保存前你可以改。")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.softText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 34)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { photoButtons }
                    VStack(spacing: 12) { photoButtons }
                }
            }
        }
    }

    @ViewBuilder
    private var photoButtons: some View {
        Button {
            isShowingCamera = true
        } label: {
            Label("拍照", systemImage: "camera.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)

        PhotosPicker(selection: $selectedItem, matching: .images) {
            Label("选照片", systemImage: "photo.on.rectangle")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private var mealForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("这一餐")
                .sectionTitle()

            VStack(spacing: 12) {
                Picker("餐次", selection: $mealType) {
                    ForEach(mealTypes, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)

                NutritionTextField(title: "食物", placeholder: "例如：牛肉饭 + 鸡蛋", text: $foodName, icon: "takeoutbag.and.cup.and.straw.fill")
                NutritionTextField(title: "热量", placeholder: "kcal", text: $calories, icon: "flame.fill", keyboard: .decimalPad)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    NutritionSmallField(title: "蛋白", suffix: "g", text: $protein)
                    NutritionSmallField(title: "碳水", suffix: "g", text: $carbs)
                    NutritionSmallField(title: "脂肪", suffix: "g", text: $fat)
                }

                NutritionTextField(title: "备注", placeholder: "可选：份量、口味、饱腹感", text: $note, icon: "note.text")
            }
            .padding(18)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
        }
    }

    private var actionButtons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { nutritionButtons }
            VStack(spacing: 12) { nutritionButtons }
        }
    }

    @ViewBuilder
    private var nutritionButtons: some View {
        Button {
            Task { await analyzePhoto() }
        } label: {
            Label(isAnalyzing ? "识别中..." : "识别照片", systemImage: isAnalyzing ? "hourglass" : "sparkles")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(isAnalyzing || selectedImageData == nil)

        Button {
            Task { await saveMeal() }
        } label: {
            Label(isSaving ? "保存中..." : "保存这一餐", systemImage: isSaving ? "hourglass" : "checkmark.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isSaving || foodName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var statusCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status.contains("成功") ? "checkmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(status.contains("成功") ? Color.deepGreen : Color(hex: 0x2F8CEF))
            Text(status)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.softText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func analyzePhoto() async {
        guard let selectedImageData else { return }
        isAnalyzing = true
        status = "正在用手机直连模型识别照片..."
        defer { isAnalyzing = false }

        do {
            let response = try await HermesCollectorClient.analyzeMealPhotoDirect(
                imageData: selectedImageData,
                profile: profile,
                apiConfig: visionConfig
            )
            if let suggestion = response.suggestion {
                apply(suggestion)
            }
            status = response.ok ? "识别完成，请检查后保存。外面也可以直接用。" : (response.error ?? "识别失败，请手动填写。")
        } catch let directError {
            do {
                status = "手机直连失败，正在尝试通过 Mac 收集器识别..."
                let response = try await HermesCollectorClient.analyzeMealPhoto(
                    imageData: selectedImageData,
                    profile: profile,
                    apiConfig: visionConfig,
                    collectorEndpoint: collectorURL
                )
                if let suggestion = response.suggestion {
                    apply(suggestion)
                }
                status = response.ok ? "识别完成，请检查后保存。" : (response.error ?? "识别失败，请手动填写。")
            } catch {
                status = "识别失败：手机直连 \(directError.localizedDescription)；Mac 中转 \(error.localizedDescription)"
            }
        }
    }

    private func saveMeal() async {
        isSaving = true
        status = "正在先保存到手机，再同步到 Hermes..."
        defer { isSaving = false }

        let record = mealRecord
        LocalNutritionStore.enqueue(profile: profile, meal: record)

        let synced = await syncPendingMeals()
        if synced {
            status = "保存成功并已同步到 Hermes：\(record.mealType) \(record.foodName)，\(record.caloriesKcal.map { "\($0.formatted(.number.precision(.fractionLength(0)))) kcal" } ?? "未填热量")。"
        } else {
            status = "已保存到手机本地。现在连不上 Mac，回家打开 App 会自动补传。待同步 \(LocalNutritionStore.pendingCount()) 餐。"
        }
        clearMealInputs()
    }

    @discardableResult
    private func syncPendingMeals() async -> Bool {
        var didSyncAll = true
        for item in LocalNutritionStore.pendingMeals() {
            do {
                try await HermesCollectorClient.post(profile: item.profile, collectorEndpoint: collectorURL)
                try await HermesCollectorClient.post(meal: item.meal, collectorEndpoint: collectorURL)
                LocalNutritionStore.remove(id: item.id)
            } catch {
                didSyncAll = false
                break
            }
        }
        return didSyncAll
    }

    private func syncPendingMealsSilently() async {
        let count = LocalNutritionStore.pendingCount()
        guard count > 0 else { return }
        if await syncPendingMeals() {
            status = "已自动补传 \(count) 餐饮食记录到 Hermes。"
        } else {
            status = "手机里还有 \(LocalNutritionStore.pendingCount()) 餐待同步；连接 Mac 后会继续补传。"
        }
    }

    private var profile: NutritionProfile {
        NutritionProfile(
            name: profileName,
            sex: profileSex,
            age: Int(profileAge),
            heightCm: Double(profileHeightCm),
            weightKg: Double(profileWeightKg),
            targetWeightKg: Double(profileTargetWeightKg),
            goal: profileGoal,
            activityLevel: profileActivityLevel
        )
    }

    private var visionConfig: VisionAPIConfig {
        VisionAPIConfig(
            provider: visionProvider,
            apiKey: resolvedVisionAPIKey,
            baseURL: resolvedVisionBaseURL,
            model: resolvedVisionModel
        )
    }

    private var resolvedVisionAPIKey: String {
        let value = visionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? deepSeekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines) : value
    }

    private var resolvedVisionBaseURL: String {
        let value = visionBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { return value }
        if visionProvider == "DeepSeek" { return deepSeekBaseURL }
        return VisionProviderDefaults.baseURL(for: visionProvider)
    }

    private var resolvedVisionModel: String {
        let value = visionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { return value }
        if visionProvider == "DeepSeek" { return deepSeekModel }
        return VisionProviderDefaults.model(for: visionProvider)
    }

    private func apply(_ suggestion: MealAnalysisSuggestion) {
        if let value = suggestion.foodName, !value.isEmpty { foodName = value }
        if let value = suggestion.caloriesKcal { calories = value.formatted(.number.precision(.fractionLength(0))) }
        if let value = suggestion.proteinG { protein = value.formatted(.number.precision(.fractionLength(1))) }
        if let value = suggestion.carbsG { carbs = value.formatted(.number.precision(.fractionLength(1))) }
        if let value = suggestion.fatG { fat = value.formatted(.number.precision(.fractionLength(1))) }
    }

    private var mealRecord: MealRecord {
        MealRecord(
            date: Self.dateFormatter.string(from: Date()),
            mealType: mealType,
            foodName: foodName.trimmingCharacters(in: .whitespacesAndNewlines),
            caloriesKcal: Double(calories),
            proteinG: Double(protein),
            carbsG: Double(carbs),
            fatG: Double(fat),
            source: "HermesHealthBridge",
            note: note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note
        )
    }

    private func clearMealInputs() {
        foodName = ""
        calories = ""
        protein = ""
        carbs = ""
        fat = ""
        note = ""
        selectedItem = nil
        selectedImage = nil
        selectedImageData = nil
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private struct SettingsView: View {
    @Binding var collectorURL: String
    let status: String

    @AppStorage("profileName") private var profileName = ""
    @AppStorage("profileSex") private var profileSex = "男"
    @AppStorage("profileAge") private var profileAge = ""
    @AppStorage("profileHeightCm") private var profileHeightCm = ""
    @AppStorage("profileWeightKg") private var profileWeightKg = ""
    @AppStorage("profileTargetWeightKg") private var profileTargetWeightKg = ""
    @AppStorage("profileGoal") private var profileGoal = "减脂"
    @AppStorage("profileActivityLevel") private var profileActivityLevel = "普通"
    @AppStorage("visionProvider") private var visionProvider = "阿里通义"
    @AppStorage("visionAPIKey") private var visionAPIKey = ""
    @AppStorage("visionBaseURL") private var visionBaseURL = ""
    @AppStorage("visionModel") private var visionModel = ""
    @AppStorage("deepSeekAPIKey") private var deepSeekAPIKey = ""
    @AppStorage("deepSeekBaseURL") private var deepSeekBaseURL = "https://api.deepseek.com"
    @AppStorage("deepSeekModel") private var deepSeekModel = "deepseek-v4-pro"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("设置")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.ink)

                    profileSection
                    visionAPISection
                    collectorSection
                }
                .padding(24)
            }
            .background(Color(hex: 0xF7FBFA).ignoresSafeArea())
            .navigationBarHidden(true)
        }
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("个人资料")
                .sectionTitle()

            VStack(spacing: 12) {
                NutritionTextField(title: "昵称", placeholder: "可选", text: $profileName, icon: "person.fill")

                Picker("性别", selection: $profileSex) {
                    Text("男").tag("男")
                    Text("女").tag("女")
                    Text("其他").tag("其他")
                }
                .pickerStyle(.segmented)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    NutritionSmallField(title: "年龄", suffix: "岁", text: $profileAge)
                    NutritionSmallField(title: "身高", suffix: "cm", text: $profileHeightCm)
                    NutritionSmallField(title: "体重", suffix: "kg", text: $profileWeightKg)
                    NutritionSmallField(title: "目标体重", suffix: "kg", text: $profileTargetWeightKg)
                }

                Picker("目标", selection: $profileGoal) {
                    Text("减脂").tag("减脂")
                    Text("维持").tag("维持")
                    Text("增肌").tag("增肌")
                }
                .pickerStyle(.segmented)

                Picker("日常活动", selection: $profileActivityLevel) {
                    Text("较少").tag("较少")
                    Text("普通").tag("普通")
                    Text("较多").tag("较多")
                }
                .pickerStyle(.segmented)
            }
            .padding(18)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
        }
    }

    private var collectorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mac 收集器地址")
                .font(.headline)
                .foregroundStyle(Color.ink)

            TextField("http://192.168.3.7:8765/health/daily", text: $collectorURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(14)
                .background(Color(hex: 0xF4F8F7))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text(status)
                .font(.footnote)
                .foregroundStyle(Color.softText)
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }

    private var visionAPISection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("识图模型 API")
                .sectionTitle()

            VStack(alignment: .leading, spacing: 12) {
                Picker("供应商", selection: $visionProvider) {
                    ForEach(VisionProviderDefaults.providers, id: \.self) { provider in
                        Text(provider).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: visionProvider) { _, newValue in
                    applyVisionDefaults(for: newValue)
                }

                NutritionTextField(title: "API Key", placeholder: "填这个供应商的 API Key", text: $visionAPIKey, icon: "key.fill")
                NutritionTextField(title: "Base URL", placeholder: VisionProviderDefaults.baseURL(for: visionProvider), text: $visionBaseURL, icon: "network")
                NutritionTextField(title: "模型", placeholder: VisionProviderDefaults.model(for: visionProvider), text: $visionModel, icon: "brain.head.profile")

                Button {
                    applyVisionDefaults(for: visionProvider)
                } label: {
                    Label("填入推荐默认值", systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Text(visionHelpText)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.softText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
        }
    }

    private var visionHelpText: String {
        switch visionProvider {
        case "阿里通义":
            return "推荐使用通义千问 VL / Qwen-VL 系列。Base URL 通常是阿里云百炼 OpenAI 兼容地址，模型可填 qwen-vl-plus、qwen-vl-max 或你控制台显示的 Qwen3-VL 模型。"
        case "智谱 GLM":
            return "推荐 GLM-4V-Flash 或 GLM-4V-Plus。适合先低成本测试拍照识别。"
        case "豆包":
            return "火山方舟通常需要先创建视觉模型接入点，模型名填你的 endpoint/model id。"
        case "百度文心":
            return "适合使用千帆/AI Studio 的多模态模型；模型名以控制台显示为准。"
        case "DeepSeek":
            return "DeepSeek 配置保留，但当前官方接口可能不支持图片输入；如果返回 400，换阿里通义或智谱。"
        default:
            return "自定义供应商需要兼容 OpenAI Chat Completions 的图片输入格式。"
        }
    }

    private func applyVisionDefaults(for provider: String) {
        visionBaseURL = VisionProviderDefaults.baseURL(for: provider)
        visionModel = VisionProviderDefaults.model(for: provider)
        if provider == "DeepSeek", visionAPIKey.isEmpty, !deepSeekAPIKey.isEmpty {
            visionAPIKey = deepSeekAPIKey
        }
    }

}

private struct HistoryView: View {
    let summaries: [DailyHealthSummary]
    let nutritionByDate: [String: NutritionDayResponse]
    let isLoading: Bool
    let message: String
    let refresh: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PageHeader(
                        title: "历史记录",
                        subtitle: "Hermes 已同步健康记录",
                        icon: "chart.bar.xaxis",
                        isLoading: isLoading,
                        action: refresh
                    )

                    if summaries.isEmpty {
                        EmptyStateCard(
                            icon: "heart.text.square",
                            title: "暂无历史记录",
                            message: message
                        )
                    } else {
                        VStack(spacing: 12) {
                            ForEach(summaries.reversed(), id: \.date) { summary in
                                HistoryDayCard(summary: summary, nutrition: nutritionByDate[summary.date])
                            }
                        }
                    }
                }
                .padding(24)
                .padding(.bottom, 72)
            }
            .background(Color(hex: 0xF7FBFA).ignoresSafeArea())
            .navigationBarHidden(true)
        }
    }

}

private struct InsightsView: View {
    let summaries: [DailyHealthSummary]
    let latestSummary: DailyHealthSummary?
    let isLoading: Bool
    let refresh: () -> Void

    private var latest: DailyHealthSummary? {
        latestSummary ?? summaries.last
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PageHeader(
                        title: "健康洞察",
                        subtitle: "恢复、睡眠和训练建议",
                        icon: "lightbulb",
                        isLoading: isLoading,
                        action: refresh
                    )

                    if let latest {
                        RecoveryScoreCard(score: recoveryScore(for: latest), summary: latest)
                        InsightGrid(insights: insights(for: latest))
                        GuidanceCard(summary: latest, score: recoveryScore(for: latest))
                    } else {
                        EmptyStateCard(
                            icon: "lightbulb",
                            title: "暂无健康洞察",
                            message: "先授权健康数据并同步一次，然后刷新本页。"
                        )
                    }
                }
                .padding(24)
                .padding(.bottom, 72)
            }
            .background(Color(hex: 0xF7FBFA).ignoresSafeArea())
            .navigationBarHidden(true)
        }
    }

    private func recoveryScore(for summary: DailyHealthSummary) -> Int {
        var score = 72.0

        if let sleep = summary.sleepMinutes {
            if sleep >= 420 { score += 10 }
            else if sleep < 360 { score -= 16 }
            else { score -= 4 }
        } else {
            score -= 8
        }

        if let hrv = summary.hrvSdnn {
            if hrv >= 80 { score += 10 }
            else if hrv < 40 { score -= 12 }
        }

        if let resting = summary.restingHeartRate {
            if resting <= 60 { score += 5 }
            else if resting >= 75 { score -= 10 }
        }

        if let energy = summary.activeEnergyKcal {
            if energy > 750 { score -= 8 }
            else if energy >= 250 { score += 4 }
        }

        if let workout = summary.workoutMinutes, workout > 70 {
            score -= 6
        }

        return Int(min(96, max(35, score)).rounded())
    }

    private func insights(for summary: DailyHealthSummary) -> [InsightItem] {
        var items: [InsightItem] = []

        let sleepText = summary.sleepMinutes.map { "\(($0 / 60).formatted(.number.precision(.fractionLength(1)))) h" } ?? "-"
        items.append(InsightItem(
            icon: "moon.zzz.fill",
            title: "睡眠",
            value: sleepText,
            note: sleepNote(summary.sleepMinutes),
            tint: Color(hex: 0x5A7FE8)
        ))

        items.append(InsightItem(
            icon: "bed.double.fill",
            title: "午睡",
            value: summary.napMinutes.map { "\($0.formatted(.number.precision(.fractionLength(0)))) 分钟" } ?? "-",
            note: napNote(summary.napMinutes),
            tint: Color(hex: 0x8E72E8)
        ))

        items.append(InsightItem(
            icon: "waveform.path.ecg",
            title: "心率变异性",
            value: format(summary.hrvSdnn, decimals: 1, fallback: "-"),
            note: hrvNote(summary.hrvSdnn),
            tint: Color.deepGreen
        ))

        items.append(InsightItem(
            icon: "flame.fill",
            title: "活动",
            value: format(summary.activeEnergyKcal, decimals: 0, fallback: "-"),
            note: activityNote(summary.activeEnergyKcal),
            tint: Color(hex: 0xF08B3E)
        ))

        items.append(InsightItem(
            icon: "heart.fill",
            title: "心率",
            value: format(summary.restingHeartRate, decimals: 0, fallback: "-"),
            note: heartNote(summary.restingHeartRate),
            tint: Color(hex: 0xE85A7C)
        ))

        return items
    }

    private func sleepNote(_ value: Double?) -> String {
        guard let value else { return "暂无睡眠记录" }
        if value < 360 { return "睡眠偏少" }
        if value >= 420 { return "恢复不错" }
        return "基本够用"
    }

    private func hrvNote(_ value: Double?) -> String {
        guard let value else { return "暂无 HRV 记录" }
        if value >= 80 { return "状态较好" }
        if value < 40 { return "恢复压力偏高" }
        return "比较稳定"
    }

    private func napNote(_ value: Double?) -> String {
        guard let value, value > 0 else { return "暂无午睡记录" }
        if value <= 30 { return "短休补能" }
        if value <= 90 { return "恢复性午睡" }
        return "午睡偏长"
    }

    private func activityNote(_ value: Double?) -> String {
        guard let value else { return "暂无活动记录" }
        if value > 750 { return "负荷偏高" }
        if value < 150 { return "活动偏少" }
        return "活动适中"
    }

    private func heartNote(_ value: Double?) -> String {
        guard let value else { return "暂无静息心率" }
        if value <= 60 { return "基础状态平稳" }
        if value >= 75 { return "留意疲劳" }
        return "范围正常"
    }
}

private struct PageHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.ink)
                    .minimumScaleFactor(0.75)

                Text(subtitle)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.softText)
            }

            Spacer()

            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(Color.mintGreen.opacity(0.13))
                        .frame(width: 54, height: 54)

                    if isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 23, weight: .semibold))
                            .foregroundStyle(Color.deepGreen)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }
}

private struct HistoryDayCard: View {
    let summary: DailyHealthSummary
    let nutrition: NutritionDayResponse?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.date)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.ink)

                    Text(dayTags)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.deepGreen)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                Spacer()

                Text("\(completeness)/8")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.deepGreen)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.mintGreen.opacity(0.13))
                    .clipShape(Capsule())
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                MiniMetric(icon: "shoeprints.fill", label: "步数", value: format(summary.steps, decimals: 0, fallback: "-"))
                MiniMetric(icon: "flame.fill", label: "能量", value: format(summary.activeEnergyKcal, decimals: 0, fallback: "-"))
                MiniMetric(icon: "heart.fill", label: "静息心率", value: format(summary.restingHeartRate, decimals: 0, fallback: "-"))
                MiniMetric(icon: "waveform.path.ecg", label: "心率变异性", value: format(summary.hrvSdnn, decimals: 1, fallback: "-"))
                MiniMetric(icon: "moon.zzz.fill", label: "睡眠", value: sleepText)
                MiniMetric(icon: "bed.double.fill", label: "午睡", value: napText)
                MiniMetric(icon: "figure.run", label: "训练", value: format(summary.workoutMinutes, decimals: 0, fallback: "-"))
            }

            HistoryFoodSummary(nutrition: nutrition)
        }
        .padding(18)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.035), radius: 18, x: 0, y: 8)
    }

    private var sleepText: String {
        guard let minutes = summary.sleepMinutes else { return "-" }
        return "\((minutes / 60).formatted(.number.precision(.fractionLength(1)))) 小时"
    }

    private var napText: String {
        guard let minutes = summary.napMinutes else { return "-" }
        return "\(minutes.formatted(.number.precision(.fractionLength(0)))) 分钟"
    }

    private var completeness: Int {
        [
            summary.steps,
            summary.activeEnergyKcal,
            summary.avgHeartRate,
            summary.restingHeartRate,
            summary.hrvSdnn,
            summary.sleepMinutes,
            summary.napMinutes,
            summary.workoutMinutes
        ].compactMap { $0 }.count
    }

    private var dayTags: String {
        var tags: [String] = []
        if let sleep = summary.sleepMinutes, sleep < 360 { tags.append("#睡眠不足") }
        if let nap = summary.napMinutes, nap > 0 { tags.append("#有午睡") }
        if let energy = summary.activeEnergyKcal, energy > 650 { tags.append("#活动负荷高") }
        if let nutrition, !nutrition.meals.isEmpty { tags.append("#有饮食记录") }
        if let hrv = summary.hrvSdnn, hrv >= 80 { tags.append("#恢复好") }
        if completeness >= 6 { tags.append("#数据完整") }
        return tags.isEmpty ? "#状态平稳" : tags.joined(separator: " ")
    }
}

private struct HistoryFoodSummary: View {
    let nutrition: NutritionDayResponse?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("饮食", systemImage: "fork.knife")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.deepGreen)

                Spacer(minLength: 8)

                Text(intakeText)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Text(detailText)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.softText)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
    }

    private var intakeText: String {
        guard let nutrition else { return "未加载" }
        let intake = nutrition.totals.intakeKcal?.formatted(.number.precision(.fractionLength(0))) ?? "-"
        return "\(intake) kcal · \(nutrition.meals.count) 餐"
    }

    private var detailText: String {
        guard let nutrition else { return "连接 Mac 收集器后刷新可查看饮食记录。" }
        guard !nutrition.meals.isEmpty else { return "当天还没有记录餐食。" }

        let names = nutrition.meals.prefix(3).map(\.foodName).joined(separator: "、")
        let protein = nutrition.totals.proteinG?.formatted(.number.precision(.fractionLength(0))) ?? "-"
        let suffix = nutrition.meals.count > 3 ? " 等" : ""
        return "\(names)\(suffix) · 蛋白 \(protein) g"
    }
}

private struct RecoveryScoreCard: View {
    let score: Int
    let summary: DailyHealthSummary

    var body: some View {
        SoftCard(tint: scoreColor) {
            HStack(spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(scoreColor.opacity(0.18), lineWidth: 12)
                        .frame(width: 104, height: 104)

                    Circle()
                        .trim(from: 0, to: CGFloat(score) / 100)
                        .stroke(scoreColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 104, height: 104)

                    VStack(spacing: 0) {
                        Text("\(score)")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.ink)
                        Text("/100")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.softText)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("今日恢复")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.ink)

                    Text(recoveryLabel)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(scoreColor)

                    Text("根据睡眠、心率变异性、静息心率和活动负荷估算。")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.softText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var scoreColor: Color {
        if score >= 78 { return .deepGreen }
        if score >= 60 { return Color(hex: 0xF0A33E) }
        return Color(hex: 0xE85A7C)
    }

    private var recoveryLabel: String {
        if score >= 78 { return "适合轻中等训练" }
        if score >= 60 { return "今天控制强度" }
        return "优先恢复休息"
    }
}

private struct InsightGrid: View {
    let insights: [InsightItem]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
            ForEach(insights) { item in
                InsightCard(item: item)
            }
        }
    }
}

private struct InsightCard: View {
    let item: InsightItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(item.tint)
                .frame(width: 42, height: 42)
                .background(item.tint.opacity(0.13))
                .clipShape(Circle())

            Text(item.title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.softText)

            Text(item.value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(Color.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.65)

            Text(item.note)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(item.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct GuidanceCard: View {
    let summary: DailyHealthSummary
    let score: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("今日建议")
                .sectionTitle()

            VStack(alignment: .leading, spacing: 12) {
                GuidanceRow(icon: "figure.walk", title: "运动", text: trainingText)
                GuidanceRow(icon: "fork.knife", title: "营养", text: nutritionText)
                GuidanceRow(icon: "bed.double.fill", title: "恢复", text: recoveryText)
            }
            .padding(18)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
        }
    }

    private var trainingText: String {
        if score >= 78 { return "可以安排轻到中等强度训练；除非体感很好，否则别冲最大强度。" }
        if score >= 60 { return "保持轻到中等强度，力量训练留 2-3 次余力。" }
        return "建议散步、拉伸或休息；今天跳过高强度训练。"
    }

    private var nutritionText: String {
        if let energy = summary.activeEnergyKcal, energy > 650 {
            return "活动负荷偏高，优先补足蛋白质、碳水、水分和电解质。"
        }
        return "保持稳定蛋白摄入，多吃不同颜色蔬果，并分散补水。"
    }

    private var recoveryText: String {
        if let sleep = summary.sleepMinutes, sleep < 360 {
            return "睡眠偏少，今晚尽量固定入睡时间，减少下午后的咖啡因。"
        }
        return "保持稳定作息，睡前增加 10 分钟放松过渡。"
    }
}

private struct GuidanceRow: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.deepGreen)
                .frame(width: 34, height: 34)
                .background(Color.mintGreen.opacity(0.13))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.ink)

                Text(text)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.softText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct MiniMetric: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.deepGreen)
                .frame(width: 24, height: 24)
                .background(Color.mintGreen.opacity(0.13))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.softText)
                    .lineLimit(1)

                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(hex: 0xF6FAF9))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct EmptyStateCard: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.deepGreen)
                .frame(width: 54, height: 54)
                .background(Color.mintGreen.opacity(0.13))
                .clipShape(Circle())

            Text(title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Color.ink)

            Text(message)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Color.softText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct InsightItem: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let value: String
    let note: String
    let tint: Color
}

private struct PlaceholderTab: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(Color.deepGreen)
                    .frame(width: 84, height: 84)
                    .background(Color.mintGreen.opacity(0.14))
                    .clipShape(Circle())

                Text(title)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.ink)

                Text(subtitle)
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.softText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 34)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(hex: 0xF7FBFA))
            .navigationBarHidden(true)
        }
    }
}

private func format(_ value: Double?, decimals: Int, fallback: String) -> String {
    guard let value else { return fallback }
    return value.formatted(.number.precision(.fractionLength(decimals)))
}

private enum VisionProviderDefaults {
    static let providers = ["阿里通义", "智谱 GLM", "豆包", "百度文心", "DeepSeek", "自定义"]

    static func baseURL(for provider: String) -> String {
        switch provider {
        case "阿里通义":
            return "https://llm-16hw05s3eoql1hu3.cn-beijing.maas.aliyuncs.com/compatible-mode/v1"
        case "智谱 GLM":
            return "https://open.bigmodel.cn/api/paas/v4"
        case "豆包":
            return "https://ark.cn-beijing.volces.com/api/v3"
        case "百度文心":
            return "https://qianfan.baidubce.com/v2"
        case "DeepSeek":
            return "https://api.deepseek.com"
        default:
            return "https://example.com/v1"
        }
    }

    static func model(for provider: String) -> String {
        switch provider {
        case "阿里通义":
            return "qwen-vl-plus"
        case "智谱 GLM":
            return "glm-4v-flash"
        case "豆包":
            return "填你的火山方舟视觉模型 Endpoint ID"
        case "百度文心":
            return "填你的千帆视觉模型名称"
        case "DeepSeek":
            return "deepseek-v4-pro"
        default:
            return "填 OpenAI-compatible 视觉模型名"
        }
    }
}

private struct NutritionTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let icon: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.deepGreen)
                .frame(width: 34, height: 34)
                .background(Color.mintGreen.opacity(0.13))
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.softText)

                TextField(placeholder, text: $text)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.ink)
                    .keyboardType(keyboard)
                    .textInputAutocapitalization(.never)
            }
        }
        .padding(12)
        .background(Color(hex: 0xF4F8F7))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct NutritionSmallField: View {
    let title: String
    let suffix: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.softText)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                TextField("0", text: $text)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.ink)
                    .keyboardType(.decimalPad)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(suffix)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.softText)
            }
        }
        .padding(12)
        .background(Color(hex: 0xF4F8F7))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, dismiss: dismiss)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImage: (UIImage) -> Void
        let dismiss: DismissAction

        init(onImage: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onImage = onImage
            self.dismiss = dismiss
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}

private struct SoftCard<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [tint.opacity(0.14), Color(hex: 0xF8FCFB)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: tint.opacity(0.09), radius: 22, x: 0, y: 12)
    }
}

private struct ActionCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 14) {
                    Text(title)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(subtitle)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.softText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Group {
                    if isLoading {
                        ProgressView()
                            .tint(tint)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(tint.opacity(0.55))
                    }
                }
                .frame(width: 24, height: 24)
                .padding(.top, 42)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
            .background(
                LinearGradient(
                    colors: [tint.opacity(0.12), Color(hex: 0xF8FCFB)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct SummaryMetricRow: View {
    let icon: String
    let title: String
    let value: String
    let unit: String
    var showsDivider = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.deepGreen)
                    .frame(width: 42, height: 42)
                    .background(Color.mintGreen.opacity(0.16))
                    .clipShape(Circle())

                Text(title)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                        .monospacedDigit()
                        .layoutPriority(2)

                    Text(unit)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.softText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .frame(minWidth: 104, alignment: .trailing)
                .layoutPriority(3)
            }
            .frame(height: 66)
            .frame(maxWidth: .infinity)

            if showsDivider {
                Rectangle()
                    .fill(Color.black.opacity(0.07))
                    .frame(height: 1)
                    .padding(.leading, 64)
            }
        }
    }
}

private struct ConnectionIllustration: View {
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.deepGreen, lineWidth: 3)
                    .frame(width: 68, height: 48)
                    .background(Color.white.opacity(0.76))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Image(systemName: "shield.checkered")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(Color.mintGreen)

                Capsule()
                    .fill(Color.deepGreen.opacity(0.5))
                    .frame(width: 76, height: 6)
                    .offset(y: 30)
            }

            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.mintGreen.opacity(0.32))

            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.deepGreen, lineWidth: 2)
                    .frame(width: 28, height: 52)
                    .background(Color.white.opacity(0.76))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Image(systemName: "heart.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.mintGreen)
            }
        }
    }
}

private extension Text {
    func sectionTitle() -> some View {
        self.font(.system(size: 24, weight: .bold, design: .rounded))
            .foregroundStyle(Color.ink)
    }
}

private extension Color {
    static let ink = Color(hex: 0x132238)
    static let softText = Color(hex: 0x6F7B8C)
    static let mintGreen = Color(hex: 0x35C2A1)
    static let deepGreen = Color(hex: 0x119D78)

    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }
}

#Preview {
    ContentView()
}
