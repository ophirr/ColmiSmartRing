# Biosense Codebase Refactor Plan

**Date:** 2026-03-17
**Scope:** Anti-patterns, maintainability, readability, performance
**Codebase:** ~12,000 lines across 59 Swift files

---

## Executive Summary

The codebase is functional and well-structured at the feature-module level, but has accumulated significant technical debt in three areas: a **2,500-line god object** (RingSessionManager), **business logic embedded in SwiftUI views** (ReadingsGraphsView), and **no protocol abstractions** in the persistence layer. The plan below is ordered by impact — the first 3 phases address ~80% of the debt.

---

## Phase 1: Decompose RingSessionManager (CRITICAL)

**Current state:** 2,510 lines, 22+ responsibilities, 35+ @Published properties, 15+ callbacks, nested DispatchQueue chains ("pyramid of doom").

### 1A. Extract `BLEConnectionManager`
- **Move:** BLE scanning, discovery, connect/disconnect, peripheral delegation, characteristic discovery, CoreBluetooth state restoration
- **Keep in RingSessionManager:** Only the high-level `connect()` / `disconnect()` API that delegates to this new class
- **Estimated scope:** ~400 lines extracted

### 1B. Extract `RingCommandScheduler`
- **Move:** All `DispatchQueue.main.asyncAfter` delay chains into a proper async command queue
- **Pattern:** Replace the 8-deep nested asyncAfter in `syncOnConnect()` and the 7-deep chain in `handleBatteryResponse()` with:
  ```swift
  struct ScheduledCommand {
      let delay: TimeInterval
      let action: () async -> Void
  }
  func executeSequence(_ commands: [ScheduledCommand]) async { ... }
  ```
- **Also:** Extract all magic delay numbers (5.0, 0.6, 1.2, 5.4, 6.0, 6.6, 7.2, 7.8, 20, 22, 24...) into named constants with documenting comments
- **Estimated scope:** ~300 lines extracted, ~50 magic numbers named

### 1C. Extract `SpotCheckManager`
- **Move:** Spot-check state machine (timeout tasks, warmup filtering, median calculations, sensor transitions), the 3-mode cascade (SpO2 → HR → Temp)
- **State:** Owns `spotCheckTempReadings`, `spotCheckHRReadings`, `spotCheckTimeoutTask`, `sensorState` for spot-check modes
- **Estimated scope:** ~250 lines extracted

### 1D. Extract `RingProtocolParser`
- **Move:** The `switch packet[0]` dispatch table, all byte-level parsing (HR stream 0x69, Sport RT 0x73, battery, sleep, HRV, blood oxygen, activity, settings responses)
- **Pattern:** Pure functions that take `[UInt8]` and return typed enums:
  ```swift
  enum RingResponse {
      case heartRate(bpm: Int, spo2: Int?, timestamp: Date)
      case battery(BatteryInfo)
      case sleepData([SleepPeriod])
      case hrLog(HeartRateLog)
      // ...
  }
  static func parse(_ packet: [UInt8]) -> RingResponse?
  ```
- **Benefit:** Testable in isolation, no BLE dependency
- **Estimated scope:** ~500 lines extracted

### 1E. Extract `KeepAliveManager`
- **Move:** 60-second keepalive chain, ping count tracking, full sync cycle triggering, modulo-based spot-check rotation
- **Estimated scope:** ~150 lines extracted

### Post-extraction RingSessionManager
- **Target:** ~800-900 lines — a thin orchestrator that wires the 5 sub-managers together
- **Role:** Owns the `@Observable` state that views bind to, delegates all work

---

## Phase 2: Extract Business Logic from Views

### 2A. Create `ReadingsGraphsViewModel` (from ReadingsGraphsView)
**Current state:** ReadingsGraphsView is 1,175 lines. Lines 882-1114 contain protocol parsing, data decoding, and SwiftData persistence — none of which belongs in a View.

- **Move to ViewModel:**
  - `consumeActivityPacket()`, `consumeSplitSeriesPacket()`, `consumeBloodOxygenPayload()`
  - `decodeBigDataBloodOxygen()`, `decodeBloodOxygenFixedBlocks()`, `decodeBloodOxygenDaySamples()`
  - All SwiftData persistence operations
  - Date range calculations (56 lines of calendar math)
  - Data filtering/aggregation computed properties (`hrvData`, `bloodOxygenData`, `stressData`, `selectedDayActivitySamples`, etc.)
- **Pattern:** `@Observable class ReadingsGraphsViewModel` with `@MainActor`
- **View responsibility:** Only layout, styling, and binding to ViewModel properties
- **Target view size:** ~400 lines (layout only)

### 2B. Fix @Query Performance
**Current state:** Views fetch ALL records then filter in computed properties.

- **Replace:**
  ```swift
  // BAD: Fetches all, filters in view
  @Query(sort: \StoredActivitySample.timestamp) var all: [StoredActivitySample]
  var filtered: [StoredActivitySample] { all.filter { isWithinSelectedDay($0.timestamp) } }
  ```
- **With:** Dynamic `FetchDescriptor` with date-range predicates pushed to the DB layer, triggered when `selectedDate` changes

### 2C. Remove Dead Code from ReadingsGraphsView
- Legacy persistence/decode methods that duplicate `RingDataPersistenceCoordinator` functionality
- Unused `HeartRateGraphContainerView` in `HeartRateGraphView.swift`
- Redundant property aliases in `ActivityScreenView`

---

## Phase 3: Protocol-Based Persistence Layer

### 3A. Define Persistence Protocols
```swift
protocol HealthDataPersistor {
    func persistHeartRate(_ readings: [(bpm: Int, time: Date)]) async
    func persistSpO2(_ readings: [(percent: Double, time: Date)]) async
    func persistHRV(_ readings: [(sdnn: Double, time: Date)]) async
    func persistTemperature(celsius: Double, time: Date) async
    func persistSleep(_ day: SleepDay) async
    func persistActivity(_ samples: [ParsedActivitySlot]) async
}
```

### 3B. Implement Concrete Persistors
- `SwiftDataPersistor: HealthDataPersistor` — owns ModelContext, dedup logic
- `HealthKitPersistor: HealthDataPersistor` — wraps the 4 existing HealthKit writers
- `InfluxDBPersistor: HealthDataPersistor` — wraps InfluxDBWriter

### 3C. Simplify RingDataPersistenceCoordinator
- Reduce from 695 lines to ~200 lines
- Becomes a thin fan-out: receives data, calls `persistors.forEach { $0.persist(data) }`
- Filtering/validation logic moves to a shared `DataValidator` utility

### 3D. Consolidate HealthKit Writers
- Extract shared base: `requestAuthorizationIfNeeded()`, `save()`, sync-identifier generation
- The 4 writers (`AppleHealthHeartRateWriter`, `SleepWriter`, `ActivityWriter`, `GymWriter`) inherit or compose from a shared `HealthKitWriter` base
- Eliminate duplicated authorization boilerplate

---

## Phase 4: Concurrency Modernization

### 4A. Replace DispatchQueue Chains with async/await
- **Target:** All `DispatchQueue.main.asyncAfter` patterns → `Task.sleep(for:)` in structured async sequences
- **Specifically:** `syncOnConnect()`, `handleBatteryResponse()`, `runPeriodicSync()` — convert to:
  ```swift
  func syncOnConnect() async {
      await syncDeviceTime()
      try? await Task.sleep(for: .milliseconds(600))
      await syncSleepData()
      for day in 0..<7 {
          try? await Task.sleep(for: .milliseconds(600))
          await getHeartRateLog(dayOffset: day)
      }
      // ...
  }
  ```

### 4B. Replace Timer + DispatchWorkItem with AsyncStream
- Keepalive chain → `AsyncTimerSequence` or actor-based timer
- Periodic sync → `Task` with `while !Task.isCancelled` loop
- Add proper `deinit` cleanup (currently missing for timers and tasks)

### 4C. Enforce @MainActor Boundaries
- Audit all callbacks from `RingSessionManager` to ensure they dispatch to MainActor
- Add `@Sendable` annotations where closures cross isolation boundaries
- Address the `writeTrackingSetting` continuation leak (pre-existing bug)

---

## Phase 5: Reusable UI Components

### 5A. Generic Activity Chart
- Unify `ActivityStepsChartView`, `ActivityDistanceChartView`, `ActivityCaloriesChartView` into:
  ```swift
  struct ActivityMetricChartView: View {
      let title: String
      let color: Color
      let data: [DailyMetric]
      let unit: String
  }
  ```

### 5B. MetricCardView
- Extract the repeated card pattern from `HomeSummaryCardsView` (4 cards with identical structure):
  ```swift
  struct MetricCardView: View {
      let icon: String
      let title: String
      let value: String
      let subtitle: String?
      let tintColor: Color
  }
  ```

### 5C. Extract GymSettingsSheet
- Move the 140-line `GymSettingsSheet` from `GymScreenView.swift` into its own file

### 5D. Shared ViewModifiers
- Extract repeated `.chartYAxis { AxisMarks(position: .leading) }` into a modifier
- Create `.biosenseCardStyle()` for the consistent card appearance

---

## Phase 6: Error Handling & Resilience

### 6A. Surface Errors to UI
- Replace silent `guard ... return` patterns with Result types or error callbacks
- Add user-visible error states for: BLE failures, HealthKit authorization denied, InfluxDB write failures

### 6B. InfluxDB Retry Queue
- Add exponential backoff for failed writes (currently lost permanently)
- Buffer failed writes to disk for retry on next app launch

### 6C. Secure Credential Storage
- Move InfluxDB token from `UserDefaults` (plaintext) to Keychain
- Remove hardcoded fallback in `Secrets.swift` if possible

---

## Phase 7: Housekeeping

### 7A. Fix Logging Inconsistencies
- Replace 2 `print()` calls in `AppleHealthSleepWriter.swift` with `tLog()`
- Replace 1 `debugPrint()` call in `BiosenseApp.swift` with `tLog()`

### 7B. Add Accessibility
- Add `.accessibilityLabel()` and `.accessibilityValue()` to all real-time metric displays
- Add chart accessibility for VoiceOver

### 7C. Document Magic Numbers
- All BLE timeouts (60s HR, 20s temp, 60s SpO2) → named constants with comments explaining firmware constraints
- All sync delay sequences → named constants documenting why each delay exists
- Sport RT window (10s), keepalive modulo (3, 10), full sync interval (5 pings) → named constants

### 7D. Remove Dead Code
- `HeartRateGraphContainerView` (unused)
- Redundant aliases in `ActivityScreenView`
- Legacy persistence methods in `ReadingsGraphsView` (duplicated by coordinator)

---

## Priority & Effort Matrix

| Phase | Impact | Effort | Risk | Recommendation |
|-------|--------|--------|------|----------------|
| 1: Decompose RingSessionManager | Very High | High (3-4 days) | Medium | Do first — unlocks testability |
| 2: Extract View Business Logic | High | Medium (1-2 days) | Low | Do second — fixes performance |
| 3: Protocol Persistence Layer | High | Medium (1-2 days) | Low | Do third — enables testing |
| 4: Concurrency Modernization | Medium | Medium (1-2 days) | Medium | Do after Phase 1 |
| 5: Reusable UI Components | Medium | Low (0.5 day) | Very Low | Quick wins anytime |
| 6: Error Handling | Medium | Medium (1 day) | Low | Do after Phase 3 |
| 7: Housekeeping | Low | Low (0.5 day) | Very Low | Do anytime |

**Total estimated effort:** ~10-12 days of focused work

---

## What NOT to Change

- **Feature module organization** — already clean and well-separated
- **SwiftData model definitions** — properly structured with cascading relationships
- **tLog() pattern** — good convention, just needs 3 stragglers fixed
- **@Observable usage** — correct modern pattern (not legacy @StateObject)
- **GymSessionManager** — well-scoped at 487 lines with clear responsibilities
- **DemoDataGenerator** — isolated utility, fine at 338 lines
