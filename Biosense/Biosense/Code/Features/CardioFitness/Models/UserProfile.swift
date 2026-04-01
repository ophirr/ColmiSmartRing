//
//  UserProfile.swift
//  Biosense
//
//  User profile data needed for cardio fitness estimation (age → HRmax, etc).
//  Singleton pattern: fetch with FetchDescriptor limit 1, create if missing.
//

import Foundation
import SwiftData

@Model
final class UserProfile {
    var birthYear: Int
    /// 0 = not set, 1 = male, 2 = female
    var sex: Int
    var weightKg: Double
    var heightCm: Double
    var createdAt: Date

    var age: Int {
        Calendar.current.component(.year, from: Date()) - birthYear
    }

    /// Fox formula (220 - age). Simple, widely used, sufficient for trend tracking.
    var predictedHRmax: Int {
        220 - age
    }

    /// True when minimum required fields are set for CRF estimation.
    var isComplete: Bool {
        birthYear > 1900 && birthYear < Calendar.current.component(.year, from: Date())
    }

    init(birthYear: Int = 1990, sex: Int = 0, weightKg: Double = 70, heightCm: Double = 170) {
        self.birthYear = birthYear
        self.sex = sex
        self.weightKg = weightKg
        self.heightCm = heightCm
        self.createdAt = Date()
    }

    /// Fetch the singleton profile, creating one if none exists.
    @MainActor
    static func current(in context: ModelContext) -> UserProfile {
        var descriptor = FetchDescriptor<UserProfile>()
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor).first {
            return existing
        }
        let profile = UserProfile()
        context.insert(profile)
        return profile
    }
}
