import Foundation

struct NutritionProfile: Codable {
    var name: String
    var sex: String
    var age: Int?
    var heightCm: Double?
    var weightKg: Double?
    var targetWeightKg: Double?
    var goal: String
    var activityLevel: String

    enum CodingKeys: String, CodingKey {
        case name
        case sex
        case age
        case heightCm = "height_cm"
        case weightKg = "weight_kg"
        case targetWeightKg = "target_weight_kg"
        case goal
        case activityLevel = "activity_level"
    }
}

struct MealRecord: Codable {
    var date: String
    var mealType: String
    var foodName: String
    var caloriesKcal: Double?
    var proteinG: Double?
    var carbsG: Double?
    var fatG: Double?
    var source: String
    var note: String?

    enum CodingKeys: String, CodingKey {
        case date
        case mealType = "meal_type"
        case foodName = "food_name"
        case caloriesKcal = "calories_kcal"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case source
        case note
    }
}

struct MealPhotoAnalysisRequest: Codable {
    let imageBase64: String
    let profile: NutritionProfile
    let apiConfig: VisionAPIConfig

    enum CodingKeys: String, CodingKey {
        case imageBase64 = "image_base64"
        case profile
        case apiConfig = "api_config"
    }
}

struct VisionAPIConfig: Codable {
    var provider: String
    var apiKey: String
    var baseURL: String
    var model: String

    enum CodingKeys: String, CodingKey {
        case provider
        case apiKey = "api_key"
        case baseURL = "base_url"
        case model
    }
}

struct MealAnalysisSuggestion: Codable {
    var foodName: String?
    var caloriesKcal: Double?
    var proteinG: Double?
    var carbsG: Double?
    var fatG: Double?

    private enum CodingKeys: String, CodingKey {
        case foodName = "food_name"
        case caloriesKcal = "calories_kcal"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
    }

    init(foodName: String? = nil, caloriesKcal: Double? = nil, proteinG: Double? = nil, carbsG: Double? = nil, fatG: Double? = nil) {
        self.foodName = foodName
        self.caloriesKcal = caloriesKcal
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexibleCodingKey.self)
        foodName = container.string(for: ["food_name", "foodName", "food", "name", "食物"])
        caloriesKcal = container.double(for: ["calories_kcal", "caloriesKcal", "calories", "kcal", "energy_kcal", "热量"])
        proteinG = container.double(for: ["protein_g", "proteinG", "protein", "蛋白质", "蛋白"])
        carbsG = container.double(for: ["carbs_g", "carbsG", "carbs", "carbohydrates", "carbohydrate_g", "碳水", "碳水化合物"])
        fatG = container.double(for: ["fat_g", "fatG", "fat", "脂肪"])

        if caloriesKcal == nil, let proteinG, let carbsG, let fatG {
            caloriesKcal = proteinG * 4 + carbsG * 4 + fatG * 9
        }
    }
}

private struct FlexibleCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

private extension KeyedDecodingContainer where Key == FlexibleCodingKey {
    func string(for names: [String]) -> String? {
        for name in names {
            guard let key = FlexibleCodingKey(stringValue: name) else { continue }
            if let value = try? decodeIfPresent(String.self, forKey: key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    func double(for names: [String]) -> Double? {
        for name in names {
            guard let key = FlexibleCodingKey(stringValue: name) else { continue }
            if let value = try? decodeIfPresent(Double.self, forKey: key) {
                return value
            }
            if let intValue = try? decodeIfPresent(Int.self, forKey: key) {
                return Double(intValue)
            }
            if let textValue = try? decodeIfPresent(String.self, forKey: key) {
                let filtered = textValue.filter { "0123456789.-".contains($0) }
                if let value = Double(filtered) {
                    return value
                }
            }
        }
        return nil
    }
}

struct MealPhotoAnalysisResponse: Codable {
    var ok: Bool
    var error: String?
    var suggestion: MealAnalysisSuggestion?
}

struct PendingMealEnvelope: Codable, Identifiable {
    var id: String
    var profile: NutritionProfile
    var meal: MealRecord
    var createdAt: Date
}

struct NutritionDayResponse: Codable {
    var ok: Bool
    var date: String
    var meals: [NutritionMeal]
    var totals: NutritionTotals
}

struct CollectorHistoryResponse: Codable {
    var ok: Bool
    var source: String?
    var days: Int?
    var count: Int?
    var summaries: [CollectorHistorySummary]
}

struct CollectorHistorySummary: Codable {
    var date: String
    var updatedAt: String?
    var source: String?
    var healthData: CollectorHealthData

    enum CodingKeys: String, CodingKey {
        case date
        case updatedAt = "updated_at"
        case source
        case healthData
    }

    var dailySummary: DailyHealthSummary {
        DailyHealthSummary(
            date: date,
            steps: healthData.steps,
            activeEnergyKcal: healthData.activeEnergyKcal,
            avgHeartRate: healthData.avgHeartRate,
            restingHeartRate: healthData.restingHeartRate,
            hrvSdnn: healthData.hrvSdnn,
            sleepMinutes: healthData.sleepMinutes,
            napMinutes: healthData.napMinutes,
            workoutMinutes: healthData.workoutMinutes,
            source: source ?? "HermesHealthBridge"
        )
    }
}

struct CollectorHealthData: Codable {
    var steps: Double?
    var activeEnergyKcal: Double?
    var avgHeartRate: Double?
    var restingHeartRate: Double?
    var hrvSdnn: Double?
    var sleepMinutes: Double?
    var napMinutes: Double?
    var workoutMinutes: Double?
    var recoveryScore: Double?

    enum CodingKeys: String, CodingKey {
        case steps
        case activeEnergyKcal = "active_energy_kcal"
        case avgHeartRate = "avg_heart_rate"
        case restingHeartRate = "resting_heart_rate"
        case hrvSdnn = "hrv_sdnn"
        case sleepMinutes = "sleep_minutes"
        case napMinutes = "nap_minutes"
        case workoutMinutes = "workout_minutes"
        case recoveryScore = "recovery_score"
    }
}

struct NutritionMeal: Codable, Identifiable {
    var id: Int?
    var date: String?
    var mealType: String?
    var foodName: String
    var caloriesKcal: Double?
    var proteinG: Double?
    var carbsG: Double?
    var fatG: Double?
    var source: String?
    var note: String?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case mealType = "meal_type"
        case foodName = "food_name"
        case caloriesKcal = "calories_kcal"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case source
        case note
        case createdAt = "created_at"
    }
}

struct NutritionTotals: Codable {
    var intakeKcal: Double?
    var proteinG: Double?
    var carbsG: Double?
    var fatG: Double?
    var estimatedBmrKcal: Double?
    var activeEnergyKcal: Double?
    var estimatedTotalBurnKcal: Double?
    var calorieBalanceKcal: Double?
    var fatLossEffect: String?

    enum CodingKeys: String, CodingKey {
        case intakeKcal = "intake_kcal"
        case proteinG = "protein_g"
        case carbsG = "carbs_g"
        case fatG = "fat_g"
        case estimatedBmrKcal = "estimated_bmr_kcal"
        case activeEnergyKcal = "active_energy_kcal"
        case estimatedTotalBurnKcal = "estimated_total_burn_kcal"
        case calorieBalanceKcal = "calorie_balance_kcal"
        case fatLossEffect = "fat_loss_effect"
    }
}

enum HermesCollectorClient {
    static func post(summary: DailyHealthSummary, to endpoint: String) async throws {
        let url = try validatedURL(endpoint)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(summary)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CollectorError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "没有返回内容"
            throw CollectorError.serverError(httpResponse.statusCode, body)
        }
    }

    static func post(profile: NutritionProfile, collectorEndpoint: String) async throws {
        try await postJSON(profile, to: try serviceURL(from: collectorEndpoint, path: "/nutrition/profile"))
    }

    static func post(meal: MealRecord, collectorEndpoint: String) async throws {
        try await postJSON(meal, to: try serviceURL(from: collectorEndpoint, path: "/nutrition/meal"))
    }

    static func analyzeMealPhoto(imageData: Data, profile: NutritionProfile, apiConfig: VisionAPIConfig, collectorEndpoint: String) async throws -> MealPhotoAnalysisResponse {
        let requestBody = MealPhotoAnalysisRequest(
            imageBase64: imageData.base64EncodedString(),
            profile: profile,
            apiConfig: apiConfig
        )
        let data = try await postJSONReturningData(requestBody, to: try serviceURL(from: collectorEndpoint, path: "/nutrition/analyze-photo"))
        return try JSONDecoder().decode(MealPhotoAnalysisResponse.self, from: data)
    }

    static func analyzeMealPhotoDirect(imageData: Data, profile: NutritionProfile, apiConfig: VisionAPIConfig) async throws -> MealPhotoAnalysisResponse {
        let apiKey = apiConfig.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw CollectorError.missingAPIKey
        }
        guard apiConfig.provider != "DeepSeek" else {
            return MealPhotoAnalysisResponse(
                ok: false,
                error: "DeepSeek 当前接口不支持图片识别。请在设置里切换到阿里通义、智谱 GLM 或豆包视觉模型。",
                suggestion: nil
            )
        }

        let url = try chatCompletionsURL(from: apiConfig.baseURL)
        let prompt = """
        你是营养师。请识别照片中的这一餐，估算总热量和三大营养素。只返回 JSON，不要 Markdown。
        JSON 格式：
        {"food_name":"食物名称","calories_kcal":450,"protein_g":25,"carbs_g":60,"fat_g":12}
        用户资料：性别 \(profile.sex)，年龄 \(profile.age.map(String.init) ?? "未知")，身高 \(profile.heightCm?.formatted() ?? "未知") cm，体重 \(profile.weightKg?.formatted() ?? "未知") kg，目标 \(profile.goal)。
        """

        let body: [String: Any] = [
            "model": apiConfig.model,
            "temperature": 0.2,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:image/jpeg;base64,\(imageData.base64EncodedString())"
                            ]
                        ]
                    ]
                ]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 45

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CollectorError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "没有返回内容"
            if httpResponse.statusCode == 401 {
                throw CollectorError.serverError(
                    httpResponse.statusCode,
                    "\(apiConfig.provider) 鉴权失败：请检查设置里的 API Key 是否属于当前供应商、是否已开通对应视觉模型、是否复制完整。服务返回：\(body)"
                )
            }
            throw CollectorError.serverError(httpResponse.statusCode, body)
        }

        let content = try decodeVisionContent(from: data)
        let suggestion = try decodeMealSuggestion(from: content)
        return MealPhotoAnalysisResponse(ok: true, error: nil, suggestion: suggestion)
    }

    static func fetchNutritionDay(date: String, collectorEndpoint: String) async throws -> NutritionDayResponse {
        let url = try serviceURL(
            from: collectorEndpoint,
            path: "/nutrition/day",
            queryItems: [URLQueryItem(name: "date", value: date)]
        )
        let data = try await getData(from: url)
        return try JSONDecoder().decode(NutritionDayResponse.self, from: data)
    }

    static func fetchHealthHistory(days: Int, collectorEndpoint: String) async throws -> CollectorHistoryResponse {
        let url = try serviceURL(
            from: collectorEndpoint,
            path: "/health/history",
            queryItems: [URLQueryItem(name: "days", value: String(days))]
        )
        let data = try await getData(from: url)
        return try JSONDecoder().decode(CollectorHistoryResponse.self, from: data)
    }

    private static func validatedURL(_ endpoint: String) throws -> URL {
        guard let url = URL(string: endpoint), ["http", "https"].contains(url.scheme?.lowercased()) else {
            throw CollectorError.invalidURL
        }
        return url
    }

    private static func serviceURL(from endpoint: String, path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        let url = try validatedURL(endpoint)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw CollectorError.invalidURL
        }
        components.path = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let serviceURL = components.url else {
            throw CollectorError.invalidURL
        }
        return serviceURL
    }

    private static func chatCompletionsURL(from baseURL: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed), ["http", "https"].contains(components.scheme?.lowercased()) else {
            throw CollectorError.invalidURL
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !basePath.hasSuffix("chat/completions") {
            components.path = "/" + ([basePath, "chat/completions"].filter { !$0.isEmpty }.joined(separator: "/"))
        }
        guard let url = components.url else {
            throw CollectorError.invalidURL
        }
        return url
    }

    private static func decodeVisionContent(from data: Data) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        if let content = message?["content"] as? String {
            return content
        }
        throw CollectorError.invalidResponse
    }

    private static func decodeMealSuggestion(from content: String) throws -> MealAnalysisSuggestion {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start <= end {
            jsonText = String(trimmed[start...end])
        } else {
            jsonText = trimmed
        }
        guard let data = jsonText.data(using: .utf8) else {
            throw CollectorError.invalidResponse
        }
        return try JSONDecoder().decode(MealAnalysisSuggestion.self, from: data)
    }

    private static func getData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CollectorError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "没有返回内容"
            throw CollectorError.serverError(httpResponse.statusCode, body)
        }
        return data
    }

    private static func postJSON<T: Encodable>(_ body: T, to url: URL) async throws {
        _ = try await postJSONReturningData(body, to: url)
    }

    private static func postJSONReturningData<T: Encodable>(_ body: T, to url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CollectorError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "没有返回内容"
            throw CollectorError.serverError(httpResponse.statusCode, body)
        }
        return data
    }
}

enum CollectorError: LocalizedError {
    case invalidURL
    case invalidResponse
    case missingAPIKey
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "服务地址无效。"
        case .invalidResponse:
            return "服务返回内容无效。"
        case .missingAPIKey:
            return "还没有填写识图模型 API Key。"
        case .serverError(let status, let body):
            return "服务返回 HTTP \(status)：\(body)"
        }
    }
}

enum LocalNutritionStore {
    private static let pendingMealsKey = "pendingNutritionMeals"

    static func enqueue(profile: NutritionProfile, meal: MealRecord) {
        var items = pendingMeals()
        items.append(PendingMealEnvelope(id: UUID().uuidString, profile: profile, meal: meal, createdAt: Date()))
        save(items)
    }

    static func pendingMeals() -> [PendingMealEnvelope] {
        guard let data = UserDefaults.standard.data(forKey: pendingMealsKey) else {
            return []
        }
        return (try? JSONDecoder().decode([PendingMealEnvelope].self, from: data)) ?? []
    }

    static func remove(id: String) {
        save(pendingMeals().filter { $0.id != id })
    }

    static func pendingCount() -> Int {
        pendingMeals().count
    }

    private static func save(_ items: [PendingMealEnvelope]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: pendingMealsKey)
        }
    }
}
