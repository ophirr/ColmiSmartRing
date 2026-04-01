//
//  UserProfileFormView.swift
//  Biosense
//
//  Inline form for editing user profile (age, sex, weight, height).
//  Embedded as a Section in ProfileScreenView.
//

import SwiftUI
import SwiftData

struct UserProfileFormView: View {
    @Bindable var profile: UserProfile

    private let currentYear = Calendar.current.component(.year, from: Date())

    var body: some View {
        Section {
            Picker("Birth Year", selection: $profile.birthYear) {
                ForEach((1940...currentYear - 10).reversed(), id: \.self) { year in
                    Text(String(year)).tag(year)
                }
            }
            .pickerStyle(.menu)

            Picker("Sex", selection: $profile.sex) {
                Text("Not set").tag(0)
                Text("Male").tag(1)
                Text("Female").tag(2)
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Weight")
                Spacer()
                TextField("kg", value: $profile.weightKg, format: .number.precision(.fractionLength(1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text("kg")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Height")
                Spacer()
                TextField("cm", value: $profile.heightCm, format: .number.precision(.fractionLength(0)))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text("cm")
                    .foregroundStyle(.secondary)
            }

            if profile.isComplete {
                HStack {
                    Text("Est. Max HR")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(profile.predictedHRmax) bpm")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        } header: {
            Label("Profile", systemImage: "person.fill")
        } footer: {
            Text("Used for cardio fitness estimation. Age determines your predicted max heart rate.")
        }
    }
}
