//
//  HaloApp.swift  (MODIFIED — adds Gym tab)
//  Halo
//
//  Replace the original HaloApp.swift with this version.
//  Changes:
//    1. Added StoredGymSession and GymHRSample to SwiftData schema
//    2. Added GymSessionManager as @State
//    3. Added Gym tab to TabView
//

import SwiftUI
import SwiftData

@main
struct HaloApp: App {
    @State private var ringSessionManager = RingSessionManager()
    @State private var ringDataPersistenceCoordinator: RingDataPersistenceCoordinator?

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            StoredSleepDay.self,
            StoredSleepPeriod.self,
            StoredHeartRateLog.self,
            StoredActivitySample.self,
            StoredHRVSample.self,
            StoredBloodOxygenSample.self,
            StoredStressSample.self,
            // Gym mode models
            StoredGymSession.self,
            GymHRSample.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentRootView(ringSessionManager: ringSessionManager)
                .onAppear {
                    if ringDataPersistenceCoordinator == nil {
                        let coordinator = RingDataPersistenceCoordinator(
                            modelContext: sharedModelContainer.mainContext,
                            ringSessionManager: ringSessionManager
                        )
                        coordinator.start()
                        ringDataPersistenceCoordinator = coordinator
                        debugPrint("[AutoPersist] RingDataPersistenceCoordinator started")
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }
}

/// Root view that owns the GymSessionManager (non-optional, stable).
/// Separated from HaloApp so we can initialize gymManager with the ringSessionManager reference.
struct ContentRootView: View {
    var ringSessionManager: RingSessionManager
    @State private var gymManager: GymSessionManager

    init(ringSessionManager: RingSessionManager) {
        self.ringSessionManager = ringSessionManager
        self._gymManager = State(initialValue: GymSessionManager(ringManager: ringSessionManager))
    }

    var body: some View {
        TabView {
            HomeScreenView(ringSessionManager: ringSessionManager)
                .tabItem { Label(L10n.Tab.home, systemImage: "house.fill") }

            GymScreenView(gymManager: gymManager, ringSessionManager: ringSessionManager)
                .tabItem { Label("Gym", systemImage: "flame.fill") }

            ActivityScreenView()
                .tabItem { Label(L10n.Tab.activity, systemImage: "figure.walk") }
            MetricsScreenView(ringSessionManager: ringSessionManager)
                .tabItem { Label(L10n.Tab.metrics, systemImage: "heart.text.square.fill") }
            ProfileScreenView(ringSessionManager: ringSessionManager)
                .tabItem { Label(L10n.Tab.profile, systemImage: "person.crop.circle.fill") }
        }
    }
}
