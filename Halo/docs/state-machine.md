# Ring App State Machine

The app has **two layered state machines**: a BLE connection state machine and a PPG sensor state machine that runs on top of it.

## 1. BLE Connection State Machine

```
                    ┌──────────────┐
                    │  App Launch   │
                    └──────┬───────┘
                           │
                    savedRingIdentifier?
                     ╱            ╲
                   yes             no
                   ╱                ╲
          ┌───────▼────────┐   ┌────▼─────────┐
          │ Retrieve Known │   │  No Ring      │
          │  Peripheral    │   │  (waiting for │
          │  from system   │   │   discovery)  │
          └───────┬────────┘   └────┬─────────┘
                  │                 │ startDiscovery()
             found?                 │
           ╱       ╲         ┌──────▼──────────┐
         yes        no       │  Discovering     │
         ╱           ╲       │  (scan for R02_) │
  ┌─────▼──┐   ┌─────▼────┐ └────────┬─────────┘
  │connect()│  │ Scanning  │    selectPeripheral()
  └────┬────┘  │ For Ring  │          │
       │       └─────┬─────┘   ┌──────▼──────┐
       │        found │        │   connect()  │
       │       savedID│        └──────┬───────┘
       │             │                │
       ▼             ▼                ▼
  ┌──────────────────────────────────────────┐
  │              CONNECTED                    │
  │                                           │
  │  didConnect → discoverServices            │
  │  → discoverCharacteristics                │
  │  → syncOnConnect()                        │
  │     ├─ clear stale streams                │
  │     ├─ battery, sleep, HR log, HRV,       │
  │     │  SpO2, pressure, activity sync      │
  │     ├─ ensure HR log settings             │
  │     ├─ initial spot-checks (SpO2→HR→Temp) │
  │     └─ startKeepalive()                   │
  └──────────────────┬───────────────────────-┘
                     │
               didDisconnect
                     │
                     ▼
  ┌──────────────────────────────────────────┐
  │           DISCONNECTED                    │
  │  reset all state, sensorState → idle      │
  │  stop keepalive, stop periodic sync       │
  │                                           │
  │  if savedRing → auto-reconnect (2s delay) │
  │  didFailToConnect → retry (5s delay)      │
  │  foreground event → findRingAgain()       │
  └──────────────────────────────────────────┘
```

## 2. PPG Sensor State Machine (`SensorState`)

The ring has a single VC30F PPG sensor — only one measurement at a time. All transitions go through `transitionSensor(to:)` which tears down the old state and sets up the new one.

```
                         ┌─────────────────────┐
                         │                     │
       ┌─────────────────┤       IDLE          ◄──────────────────────┐
       │                 │                     │                      │
       │                 └──┬──────┬───────┬───┘                      │
       │                    │      │       │                          │
       │   startSpotCheck() │      │       │  toggleContinuousHR()   │
       │                    │      │       │                          │
       │   ┌────────────────▼──┐   │   ┌───▼──────────────┐          │
       │   │   SPOT CHECK      │   │   │  CONTINUOUS HR    │          │
       │   │                   │   │   │                   │          │
       │   │ types:            │   │   │ sendRealTimeStart │          │
       │   │  • HR  (30s tmo)  │   │   │  (heartRate)      │         │
       │   │  • SpO2 (60s tmo) │   │   │                   │          │
       │   │  • Temp (20s tmo) │   │   │ toggle off → idle │          │
       │   │                   │   │   └───────────────────┘          │
       │   │ on valid reading: │   │                                  │
       │   │  finishSpotCheck()│   │                                  │
       │   │  → idle           │   │   enterWorkoutMode()             │
       │   │                   │   │                                  │
       │   │ on timeout:       │   │   ┌───────────────────┐          │
       │   │  → idle           │   └──►│    WORKOUT         │          │
       │   │                   │       │                   │          │
       │   │ then:             │       │ sendRealTimeStart │          │
       │   │  scheduleNext-    │       │  (heartRate)      │          │
       │   │  Keepalive()      │       │                   │          │
       │   └───────────────────┘       │ exitWorkoutMode() ├──────────┘
       │                               │  → idle           │
       │  startSpO2Streaming()         └───────────────────┘
       │                                         ▲
       │   ┌───────────────────┐                 │
       └──►│   SPO2 STREAM      │                 │
           │                   │    workout takes │
           │ sendSpO2Start()   │    priority,     │
           │ 2s continue       │    blocks all    │
           │  keepalives       │    others        │
           │                   │                  │
           │ stopSpO2 → idle   │                  │
           └───────────────────┘                  │
                                                  │
                                    (any state preempted
                                     by transitionSensor —
                                     old state torn down
                                     before new state setup)
```

## 3. Keepalive & Spot-Check Cycle

This is the background heartbeat that keeps InfluxDB fed:

```
  ┌──────────────────────────────────────────────────────┐
  │                  KEEPALIVE CHAIN                      │
  │                                                      │
  │   scheduleNextKeepalive() ──(60s delay)──►           │
  │                                                      │
  │   sendKeepalive()                                    │
  │     │                                                │
  │     ├─ if workout/continuousHR → skip, reschedule    │
  │     │                                                │
  │     └─ send CMD_BATTERY ──► ring responds ──►        │
  │                                                      │
  │   handleBatteryResponse()                            │
  │     │                                                │
  │     ├─ Spot-check rotation (if idle):                │
  │     │    ping % 10 == 0  →  SpO2                     │
  │     │    ping % 3  == 0  →  Temperature              │
  │     │    otherwise       →  Heart Rate               │
  │     │                                                │
  │     ├─ startSpotCheck() ──► reading/timeout ──►      │
  │     │    finishSpotCheck() → scheduleNextKeepalive() │
  │     │                                 ▲              │
  │     │                                 │              │
  │     │                     ◄───────────┘              │
  │     │                                                │
  │     └─ Every 5 pings: full data sync                 │
  │         (HR log, HRV, SpO2 log, pressure, activity)  │
  │         staggered 2s apart, starting 20s after ping  │
  │                                                      │
  │   Safety: 30s fallback if ring doesn't respond       │
  │   Stall detect: if >120s since last ping, any        │
  │     battery response restarts the chain              │
  └──────────────────────────────────────────────────────┘
```

## Key Mutual-Exclusion Rules

- **Workout blocks everything** — keepalive battery reads skip, spot-checks skip, periodic sync skips
- **HR stream (0x69) and Sport RT (0x73) are mutually exclusive** at firmware level
- **`transitionSensor()` always tears down old state before setting up new** — prevents orphaned BLE streams
- **Disconnect hard-resets to idle** — no BLE commands sent (connection already gone)

## Source Files

- `RingSessionManager.swift` — BLE protocol, connection management, sensor state machine, keepalive chain
- `GymSessionManager.swift` — gym workout session, calls `enterWorkoutMode()` / `exitWorkoutMode()`
- `Log.swift` — `tLog()` timestamped logging helper
