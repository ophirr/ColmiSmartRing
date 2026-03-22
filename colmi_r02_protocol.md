# Colmi R02 BLE Protocol — Deep Dive Analysis

*Methods, Protocol Overview, and Real-Time Measurement Guide*

**Prepared for:** ophirr/ColmiSmartRing project
**Date:** March 22, 2026 (updated from March 19, 2026)
**Sources:** Community reverse engineering (GitHub, Codeberg, blogs)

> *This report consolidates community reverse-engineering findings for the Colmi R02 smart ring BLE protocol. All protocol details are based on open-source analysis of QRing app Bluetooth traffic — none of this is officially documented by Colmi.*

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Methodology](#2-methodology)
3. [Hardware Overview](#3-hardware-overview)
4. [BLE Architecture](#4-ble-architecture)
5. [Packet Format](#5-packet-format)
6. [Command Reference](#6-command-reference)
7. [Real-Time Measurement Protocol](#7-real-time-measurement-protocol)
8. [Historical Data Retrieval](#8-historical-data-retrieval)
9. [Activity & Step Tracking](#9-activity--step-tracking)
10. [Sport Real-Time Telemetry (0x73)](#10-sport-real-time-telemetry-0x73)
11. [Raw PPG/Accelerometer Streaming](#11-raw-ppgaccelerometer-streaming)
12. [Firmware & Security](#12-firmware--security)
13. [Open Questions and Mysteries](#13-open-questions-and-mysteries)
14. [Community Ecosystem](#14-community-ecosystem)
15. [iOS / Swift Implementation Notes](#15-ios--swift-implementation-notes)
16. [Quick Reference Card](#16-quick-reference-card)

---

## 1. Executive Summary

The Colmi R02 is a low-cost (~$20-$30) smart ring that has become a popular target in the hardware-hacking and open-source health monitoring communities. Its appeal stems from three properties that are rare in consumer wearables: a well-known commodity SoC with publicly available datasheets, a BLE protocol with no pairing security, and unsigned/unencrypted OTA firmware updates.

Since mid-2024 the community has produced a rich ecosystem of reverse-engineering artifacts: a full Python client, a Go CLI tool, GadgetBridge integration for Android, community protocol documentation, an iOS/Swift application (this project), and custom firmware. Together these resources have decoded virtually the entire BLE command surface of the ring, including real-time streaming of heart rate, SpO2, and raw PPG sensor data.

This report synthesizes all known findings with emphasis on the real-time measurement sub-protocol, which is the most complex and least-documented area relevant to the ophirr/ColmiSmartRing iOS project.

---

## 2. Methodology

The community protocol knowledge was built up through several complementary approaches:

### 2.1 BLE Traffic Capture (Wireshark)

The primary method used by the GadgetBridge team was to mirror the official QRing Android app's Bluetooth traffic through a custom Wireshark dissector. The QRing app is available for many Colmi device variants; only a subset of its commands are implemented on the R02/R03/R06. Packet captures were correlated with observed ring behavior to identify command semantics.

### 2.2 Firmware Analysis (atc1441)

Aaron Christophel (atc1441) downloaded official firmware images directly from Colmi's OTA update server (the firmware is neither signed nor encrypted), then analyzed the binary to understand the SoC, memory map, and BLE stack. He also identified the SWD debug pads on the PCB, providing a path to direct firmware dumping. A modified firmware (R02_3.00.06_FasterRawValuesMOD.bin) was produced to increase raw sensor sample rate.

### 2.3 Python Client Development (tahnok)

Wesley Ellis (tahnok) built a Python BLE client from scratch using bleak, iteratively sending raw commands and observing ring responses. His lab notebook (notes.tahnok.ca) documents the trial-and-error process. The resulting colmi_r02_client library (528 stars, 47 forks as of March 2026) includes validated request/response test pairs that serve as the ground truth for the protocol.

### 2.4 Community Documentation (Puxtril)

The colmi-docs project (Puxtril) compiled the reverse-engineered API into structured documentation at colmi.puxtril.com. The primary reference ring was an R03; commands are largely shared with the R02. The documentation defines C-style structs for all packet types and is the source for the DataType and DataAction enumerations.

### 2.5 Platform Ports

The Android GadgetBridge integration (PRs #3896 and #4223 on Codeberg) and the Go RingCLI tool (smittytone) each independently re-implemented the protocol, providing cross-validation. The Edge Impulse data collection project added raw PPG/SpO2 streaming using a modified firmware.

---

## 3. Hardware Overview

Understanding the hardware is essential context for the protocol, since sensor capabilities and MCU constraints shape what the ring can and cannot do.

| Component | Details |
|-----------|---------|
| SoC | BlueX RF03 — ARM Cortex-M0+, 200 KB RAM, 512 KB Flash |
| BLE | Built-in BLE stack in ROM; BLE 5.0 compatible |
| Heart Rate / SpO2 | VCare VC30F optical sensor (PPG-based) |
| Accelerometer | STK8321 3-axis MEMS (default refresh ~25 Hz; ~50 Hz with modified firmware) |
| Battery | 17 mAh LiPo |
| Debug Interface | SWD on P00 (SWCK) and P01 pads; accessible after scraping epoxy potting |
| Firmware Security | No signing, no encryption — OTA images downloadable from Colmi update server |
| OTA Flash Tool | atc1441.github.io/ATC_RF03_Writer.html (browser-based WebBluetooth) |

### 3.1 Hardware Revisions

Multiple hardware revisions exist. The BLE protocol is shared across revisions, but firmware binaries are **not interchangeable**.

| Model | Hardware Rev | Firmware Prefix | Notes |
|-------|-------------|-----------------|-------|
| R02 | V3.0 | `R02_3.00.xx` | Original community reverse-engineering target. ATC mod firmware available. |
| RT02R | V3.1 | `RT02R_3.11.xx` | Newer revision (observed June 2025+). Same BLE protocol. **Incompatible with V3.0 firmware.** |

Read the Device Information service (0x180A) characteristics to identify hardware revision before attempting any firmware modifications. The Biosense app reads Firmware Revision (0x2A26) and Hardware Revision (0x2A27) on connect.

> *Key implication: The ring runs a single MCU that manages both BLE and sensor acquisition. Heavy real-time streaming tasks compete with the BLE connection interval, which partly explains why the ring must be periodically "tickled" with CONTINUE packets during real-time measurements.*

---

## 4. BLE Architecture

### 4.1 GATT Service Layout

The ring exposes three BLE GATT services:

| Service | UUID | Purpose |
|---------|------|---------|
| Main Data Service | `6E40FFF0-B5A3-F393-E0A9-E50E24DCCA9E` | All health/command data |
| Device Information | `0000180A-0000-1000-8000-00805F9B34FB` | Standard BT SIG service |
| Big Data / Raw Sensor Service | `DE5BF728-D711-4E47-AF26-65E3012A5DC7` | Variable-length data (sleep, SpO2 history) AND raw sensor streaming (0xA1) |

### 4.2 Key Characteristics

| Name | Service | UUID | Properties | Usage |
|------|---------|------|------------|-------|
| RX (Write) | Main Data | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` | Write / Write No Response | Send commands to ring |
| TX (Notify) | Main Data | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` | Notify | Subscribe for ring responses |
| Big Data Write | Big Data | `DE5BF72A-D711-4E47-AF26-65E3012A5DC7` | Write | Send Big Data requests (sleep, SpO2 history) |
| Big Data Notify | Big Data | `DE5BF729-D711-4E47-AF26-65E3012A5DC7` | Notify | Receive Big Data responses AND raw sensor (0xA1) packets |
| Firmware Rev | Device Info | `00002A26-0000-1000-8000-00805F9B34FB` | Read | Firmware version string (e.g., `RT02R_3.11.00_250611`) |
| Hardware Rev | Device Info | `00002A27-0000-1000-8000-00805F9B34FB` | Read | Hardware revision string (e.g., `RT02R_V3.1`) |
| Serial Number | Device Info | `00002A25-0000-1000-8000-00805F9B34FB` | Read | Device serial number |
| System ID | Device Info | `00002A23-0000-1000-8000-00805F9B34FB` | Read | System identifier |
| CCCD | — | `00002902-0000-1000-8000-00805F9B34FB` | Write | Enable TX notifications |

The architecture closely mirrors Nordic Semiconductor's UART Service (NUS), making it straightforward to implement with standard CoreBluetooth or Android BluetoothGatt APIs. There is no pairing or bonding requirement — any central can read/write characteristics immediately after connection.

### 4.3 iOS CoreBluetooth Considerations

- iOS obscures peripheral MAC addresses; use `CBPeripheral.identifier` (randomly generated UUID) for persistence across sessions.
- Subscribe to TX characteristic notifications in `peripheral(_:didDiscoverCharacteristicsFor:)` after service discovery.
- The ring does NOT use the standard Heart Rate GATT profile (0x180D) — use the custom Nordic UART-like UUIDs above.
- Responses arrive asynchronously via `peripheral(_:didUpdateValueFor:)`. Buffer incoming packets and match to in-flight requests by command byte.
- **Critical:** `setNotifyValue` is async — must wait for `didUpdateNotificationStateFor` confirmation before sending any commands, or responses are silently dropped.
- **CoreBluetooth restore pitfall:** `didConnect` is NOT called when `peripheral.state == .connected` on state restoration — must handle the "already connected" path manually.

---

## 5. Packet Format

All communication uses a fixed 16-byte packet format for both requests (central -> ring) and responses (ring -> central):

| Byte(s) | Field | Description | Example |
|---------|-------|-------------|---------|
| 0 | Command | Identifies the command type. Same value in both request and response. | `0x1E` |
| 1-14 | Payload | 14 bytes of sub-data. Request payload encodes parameters; response payload encodes returned data. Unused bytes are 0x00. | `01 01 00 ... 00` |
| 15 | CRC | Checksum = sum(bytes[0..14]) mod 255. Note: mod 255, not mod 256. | `0x51` |

### 5.1 CRC Calculation

Python reference implementation:
```python
def make_packet(cmd: int, payload: bytearray) -> bytearray:
    assert len(payload) <= 14
    data = bytearray(16)
    data[0] = cmd
    data[1:1+len(payload)] = payload
    data[15] = sum(data[:15]) % 255
    return data
```

Swift equivalent (from Packet.swift pattern):
```swift
func makePacket(cmd: UInt8, payload: [UInt8]) -> Data {
    var data = [UInt8](repeating: 0, count: 16)
    data[0] = cmd
    payload.prefix(14).enumerated().forEach { data[$0.offset + 1] = $0.element }
    data[15] = UInt8(data.prefix(15).reduce(0, { ($0 + Int($1)) % 255 }))
    return Data(data)
}
```

### 5.2 Multi-Packet Responses

Some commands (historical heart rate, sleep, steps, SpO2) return multiple 16-byte packets in sequence. The packets contain a packet-count field and a total-packets field in the payload, allowing the receiver to know when the sequence is complete. The community deduced this pattern empirically; the exact byte positions for these fields vary by command.

> *For real-time measurements the response model is different — the ring sends a new packet approximately every 1-2 seconds containing the latest sensor reading, until the measurement session is explicitly stopped.*

---

## 6. Command Reference

The following table lists all known commands reverse-engineered from QRing Bluetooth captures. Note that QRing supports many Colmi models; only a subset are implemented on the R02/R03/R06.

| Hex | Decimal | Command Name | Notes | Biosense Status |
|-----|---------|-------------|-------|-----------------|
| 0x01 | 1 | CMD_SET_DEVICE_TIME | Sync device clock to host time | Implemented |
| 0x02 | 2 | CMD_TAKING_PICTURE | Trigger camera shutter (phone-side) | Not used |
| 0x03 | 3 | CMD_GET_DEVICE_ELECTRICITY_VALUE | Battery level & charging status | Implemented |
| 0x04 | 4 | CMD_SET_PHONE_OS | Inform ring of host OS (iOS/Android) | Not used |
| 0x07 | 7 | CMD_GET_STEP_TOTAL_SOMEDAY | Request step count for a given date | Not used |
| 0x08 | 8 | CMD_RE_BOOT | Reboot the ring | Not used |
| 0x0C | 12 | CMD_BP_TIMING_MONITOR_SWITCH | Enable/disable scheduled BP monitoring | Not used |
| 0x0D | 13 | CMD_HR_TIMING_MONITOR_DATA | Retrieve timed HR monitor data | Not used |
| 0x0E | 14 | CMD_HR_TIMING_MONITOR_CONFIRM | Acknowledge receipt of timed HR data | Not used |
| 0x10 | 16 | CMD_BIND_SUCCESS | Notify ring of successful pairing | Implemented (blink) |
| 0x11 | 17 | CMD_PHONE_NOTIFY | Send notification to ring display | Not used |
| 0x13 | 19 | CMD_GET_SPORT | Request sport/activity data | Not used |
| 0x15 | 21 | CMD_GET_HEART_RATE | Request historical heart rate log for date | Implemented |
| 0x16 | 22 | CMD_HR_TIMING_MONITOR_SWITCH | Enable/disable scheduled HR monitoring | Implemented |
| 0x17 | 23 | CMD_GET_PERSONALIZATION_SETTING | User profile (age, weight, height) | Not used |
| 0x1E | 30 | CMD_REAL_TIME_HEART_RATE | Real-time HR streaming (legacy single-type) | Implemented |
| 0x20 | 32 | CMD_CALIBRATION_RATE | Calibrate measurement rates | Not used |
| 0x21 | 33 | CMD_TARGET_SETTING | Set daily step/calorie targets | Not used |
| 0x22 | 34 | CMD_FIND_THE_PHONE | Ring-initiated "find my phone" alert | Not used |
| 0x23 | 35 | CMD_SET_ALARM_CLOCK | Configure ring alarm/vibration schedule | Not used |
| 0x27 | 39 | CMD_GET_BAND_INFO | Request firmware version & device ID | Not used |
| 0x2C | 44 | CMD_BLOOD_OXYGEN_SETTING | Settings protocol: SpO2 toggle | Implemented |
| 0x36 | 54 | CMD_PRESSURE_SETTING | Settings protocol: Stress toggle | Implemented |
| 0x37 | 55 | CMD_READ_PRESSURE_DATA | Historical stress data | Implemented |
| 0x38 | 56 | CMD_HRV_SETTING | Settings protocol: HRV toggle | Implemented |
| 0x39 | 57 | CMD_READ_HRV_DATA | Historical HRV data | Implemented |
| 0x43 | 67 | CMD_GET_STEP_SOMEDAY / Sports Data | 15-minute activity slots (steps/cal/dist) | Implemented |
| 0x44 | 68 | CMD_SLEEP_DATA | Request historical sleep data | Implemented |
| 0x48 | 72 | CMD_GET_STEP_TODAY | Today's aggregated totals (incl. running steps) | **Implemented (new)** |
| 0x69 | 105 | CMD_START_REAL_TIME / DataRequest | Start any real-time sensor measurement | Implemented |
| 0x6A | 106 | CMD_STOP_REAL_TIME | Stop active real-time measurement | Implemented |
| 0x6B | 107 | CMD_PATHWAY_A_STOP | SpO2 pathway A stop notification | Implemented |
| 0x73 | 115 | CMD_SPORT_REAL_TIME | Sport real-time telemetry (autonomous) | Implemented |
| 0x77 | 119 | CMD_PHONE_SPORT | Phone-initiated sport mode (walk/run/hike/cycle/other) | **Implemented (v1.6)** |
| 0x78 | 120 | CMD_PHONE_SPORT_NOTIFY | Real-time steps/HR/dist/cal during phone sport session | **Implemented (v1.6)** |
| 0xA1 | 161 | CMD_RAW_SENSOR | Raw PPG/accelerometer/SpO2 streaming (enable/disable) | **Implemented (new)** |
| 0xBC | 188 | Big Data Protocol | Sleep (dataId 39), SpO2 (dataId 42) | Implemented |

> *Commands 0x69 (DataRequest) and 0x6B (StopRealTime) are the primary pathway for all modern real-time measurements. Command 0x1E is an older/alternative real-time HR path that remains functional but is less general.*

---

## 7. Real-Time Measurement Protocol

This is the most protocol-rich area of the ring's BLE interface, and the area most relevant to the ColmiSmartRing iOS project. There are two parallel pathways.

### 7.1 DataType and DataAction Enumerations

From colmi.puxtril.com (Puxtril's reverse-engineered documentation):

| DataType | Value |
|----------|-------|
| HeartRate | 1 |
| BloodPressure | 2 |
| BloodOxygen / SpO2 | 3 |
| Fatigue | 4 |
| HealthCheck | 5 |
| RealtimeHeartRate (alt) | 6 |
| ECG | 7 |
| Pressure / Stress | 8 |
| BloodSugar | 9 |
| HRV | 10 |
| Temperature | 4 (on 0x69 pathway) |

| DataAction | Value |
|------------|-------|
| Start | 1 |
| Pause | 2 |
| Continue | 3 |
| Stop | 4 |

### 7.2 Pathway A: CMD_START_REAL_TIME (0x69 / 105)

This is the primary, general-purpose pathway for all measurement types. The command byte is 0x69 (decimal 105). **Note:** The Biosense app uses 0x69 for start and 0x6A for stop (the original report had a typo listing 0x6A as the start command).

#### Starting a Measurement

Packet structure (C-style, from colmi-docs):
```c
struct DataRequest {
    uint8_t commandId = 105;  // 0x69
    DataType dataType;        // e.g., 1 = HeartRate, 3 = SpO2
    DataAction action;        // 1 = Start
    uint8_t unk1;             // always 0x00
    uint8_t unk2;             // always 0x00
    char unused[10];          // zeros
    uint8_t crc;
};
```

#### Continuing a Measurement (Keep-Alive)

The ring does not stream indefinitely. The client must send a CONTINUE packet approximately every 1-2 seconds to signal that it still wants data. Failure to do so causes the ring to stop the measurement session.

> *The CONTINUE_HEART_RATE_PACKET constant uses command byte 0x1E (Pathway B), not 0x69. This cross-pathway continue is intentional in the Python client — it works on real hardware. This is one of several nuances that were discovered empirically rather than deduced from first principles.*

#### Stopping a Measurement

```python
CMD_STOP_REAL_TIME = 0x6B

def get_stop_packet(reading_type: RealTimeReading) -> bytearray:
    return make_packet(CMD_STOP_REAL_TIME,
                       bytearray([reading_type, 0, 0]))
```

#### Parsing the Response

The ring responds with a 16-byte packet on the TX characteristic:
```python
def parse_real_time_reading(packet: bytearray) -> Reading | ReadingError:
    assert packet[0] == CMD_START_REAL_TIME  # 0x69
    kind       = RealTimeReading(packet[1])  # DataType
    error_code = packet[2]                   # 0 = OK
    if error_code != 0:
        return ReadingError(kind, code=error_code)
    value = packet[3]                        # measurement value
    return Reading(kind=kind, value=value)
```

Key points: the measurement value occupies byte index 3. Heart rate is in BPM (single byte, 0-255). SpO2 is in percent (0-100). The ring delivers one such packet per measurement cycle — approximately every 1 second for heart rate.

**Temperature** is special: the value spans bytes 6-7 as a 16-bit little-endian raw value. Divide by 20.0 to get degrees Celsius (e.g., raw 730 = 36.5 C).

### 7.3 Pathway B: CMD_REAL_TIME_HEART_RATE (0x1E)

This is an older, heart-rate-specific pathway. The command byte is 0x1E (decimal 30). It is simpler but less general than Pathway A.

```c
struct RealtimeHeartrateRequest {
    uint8_t commandId = 30;  // 0x1E
    uint8_t type;            // documented as variable; only value 3 observed in QRing app
    char unused[13];
    uint8_t crc;
};

struct RealtimeHeartrateResponse {
    uint8_t commandId = 30;  // 0x1E
    uint8_t heartRate;       // BPM
    char unused[13];
    uint8_t crc;
};
```

The Python client uses 0x1E as the command byte for the heart-rate continue packet (CONTINUE_HEART_RATE_PACKET), reflecting the observed behavior from BLE traffic captures.

### 7.4 Full Sequence Walkthrough: Real-Time Heart Rate

The complete interaction for a 10-second real-time reading:

| Step | Direction | Packet (hex) | Description |
|------|-----------|-------------|-------------|
| 1 | Central -> Ring | `69 01 01 00 00 00 00 00 00 00 00 00 00 00 00 6D` | Start HR measurement (cmd=0x69, type=1, action=1) |
| 2 | Ring -> Central | `69 01 00 4F 00 00 00 00 00 00 00 00 00 00 00 <crc>` | First reading: HR = 0x4F = 79 BPM, error=0 |
| 3 | Central -> Ring | `1E 33 00 00 00 00 00 00 00 00 00 00 00 00 00 51` | CONTINUE_HEART_RATE_PACKET (keep-alive) |
| 4 | Ring -> Central | `69 01 00 50 00 00 00 00 00 00 00 00 00 00 00 <crc>` | Second reading: HR = 0x50 = 80 BPM |
| ... | ... (repeat 3-4) | | Continue packet every ~1-2s; reading returned each cycle |
| N | Central -> Ring | `6B 01 00 00 00 00 00 00 00 00 00 00 00 00 00 6D` | Stop measurement (cmd=0x6B, type=1) |

### 7.5 Real-Time SpO2

SpO2 follows exactly the same pattern as heart rate via Pathway A, substituting DataType = 3. Response: `packet[3]` = SpO2 percentage (e.g., 0x61 = 97%).

According to the community, heart rate and SpO2 real-time readings produce "reasonable" values on real hardware. Other DataTypes (ECG, blood pressure, blood sugar, HRV) return values but accuracy is considered unreliable — the VC30F sensor is a simple PPG sensor without the hardware required for true ECG, cuff-less BP, or blood glucose measurement.

### 7.6 Real-Time HRV

HRV (DataType = 10) can be started with the same framework. However, accurate HRV requires beat-to-beat R-R interval precision that the R02's PPG hardware cannot provide. The returned values should be treated as estimates only. The GadgetBridge PR notes that the community has not validated HRV output quality.

### 7.7 VC30F PPG Sensor Warmup Behavior

**All** sensor readings (HR, temp, SpO2) are unreliable during the first ~30 seconds after a cold start:

- HR starts elevated (70-90+ BPM) and ramps down toward true resting value over 30-60s
- Temperature ramps from ~27 C up toward body temp over 10-20s, with wild 5-10 C swings
- SpO2 takes the longest to converge (~60s)

**Spot-check strategy:** Collect readings for the full timeout, discard the warmup portion, and take the median of the settled (latter) readings. The Biosense app uses: HR timeout 60s, Temp timeout 20s, SpO2 timeout 60s.

---

## 8. Historical Data Retrieval

Historical data (heart rate log, SpO2 log, sleep, steps) uses different commands and a multi-packet response model. Understanding this is important for building the data sync functionality in the iOS app.

### 8.1 Heart Rate Log (0x15)

```python
# Request: cmd=0x15, payload = date encoded as [year-2000, month, day]
# Example for 2025-11-08: 0x15 19 0B 08 00 ... <crc>

# Response: multiple packets
#   Packet 0: metadata (total count, date, etc.)
#   Packets 1..N: heart rate readings (one per packet, ~minute resolution)
```

### 8.2 SpO2 Log (0x14 / 0x72)

SpO2 historical data follows the same multi-packet pattern as HR. One request packet yields multiple response packets — metadata first, then one data packet per reading across the 24-hour period.

### 8.3 Sleep Data (0x72 / Big Data)

Sleep data is the most complex historical record. The ring categorizes sleep stages (deep sleep, light sleep, REM/wake) and returns these as a sequence of time-stamped stage transitions. The GadgetBridge PR implemented sleep data sync in PR #3896 as part of full historical sync support (Steps, Heart Rate, Sleep, SpO2, Stress).

The Biosense app uses the Big Data protocol (magic byte 0xBC, dataId 39) for sleep retrieval via a separate BLE characteristic (colmiNotify).

### 8.4 Steps (0x43 / CMD_GET_STEP_SOMEDAY)

Step data for a given day is retrieved via CMD_GET_STEP_SOMEDAY (0x43) for intra-day 15-minute interval data. The SportDetailParser in colmi_r02_client handles multi-packet assembly for sport detail data.

**Packet layout (CMD 0x43 response):**

| Byte | Field | Encoding |
|------|-------|----------|
| 0 | Command | 0x43 (67) |
| 1 | Year | BCD (e.g., 0x25 = 2025) |
| 2 | Month | BCD |
| 3 | Day | BCD |
| 4 | Time Index | 0-95 (15-min slots; index/4 = hour, index%4*15 = minute) |
| 5 | Current Packet | 0-based index |
| 6 | Total Packets | Total count in sequence |
| 7-8 | Calories | Little-endian (x10 if new calorie protocol) |
| 9-10 | Steps | Little-endian |
| 11-12 | Distance | Little-endian (meters) |
| 13-14 | Unused | |
| 15 | CRC | |

Special packets:
- `packet[1] == 0xFF` — no data for this day
- `packet[1] == 0xF0` — version header; `packet[3] == 1` means new calorie protocol

**Important:** The ring stores activity data in **UTC**. When the local timezone is behind UTC, "today local" spans two UTC days. The app must fetch both dayOffset 0 and dayOffset 1 to cover the full local day.

---

## 9. Activity & Step Tracking

### 9.1 Today's Aggregated Totals (0x48 / CMD_GET_STEP_TODAY) — NEW

This command returns a single packet with today's cumulative totals, including a **separate running steps field** that the 15-minute slot data (0x43) does not expose.

**Request:** Empty payload — just `make_packet(0x48, [])`

**Response layout (confirmed via Gadgetbridge source + empirical verification):**

The layout matches Gadgetbridge's `goalsSettings` and `liveActivity` encoding pattern: 24-bit big-endian for value fields, 16-bit big-endian for duration.

| Byte(s) | Field | Encoding | Verified? |
|---------|-------|----------|-----------|
| 0 | Command | 0x48 (72) | ✅ |
| 1-3 | Total Steps | 24-bit big-endian | ✅ cross-checked with 0x43 slot sums |
| 4-6 | Running Steps | 24-bit big-endian | ✅ (0 when no running detected) |
| 7-9 | Calories | 24-bit big-endian | ⚠️ value much higher than 0x43 slot sum — likely includes BMR |
| 10-12 | Walking Distance (m) | 24-bit big-endian | ✅ cross-checked with 0x43 slot sums |
| 13-14 | Activity Duration (min) | 16-bit big-endian | ✅ |
| 15 | CRC | Sum of bytes 0-14 mod 256 | ✅ |

**Encoding reference (from Gadgetbridge `ColmiR0xPacketHandler.java`):**
- `goalsSettings`: same field order — steps(3B BE), calories(3B BE), distance(3B BE), sport(2B BE), sleep(2B BE)
- `liveActivity`: 24-bit BE for steps/calories/distance. Calories divided by 10.
- `historicalActivity` (0x43 slots): 16-bit for calories/steps/distance. Calories NOT divided by 10.
- CMD 0x48 calorie unit TBD — may match `liveActivity` (÷10) or have its own encoding.

**Verification notes (March 19, 2026):**
- Pre-workout raw: `48 00 03 dc 00 00 00 00 7f 6c 00 02 f1 00 0f 14`
  - steps[1-3] = `00 03 dc` = 988 ✅, dist[10-12] = `00 02 f1` = 753m ✅, cal[7-9] = `00 7f 6c` = 32620
- Post-workout raw: `48 00 04 14 00 00 00 00 87 4c 00 03 1f 00 0f 64`
  - steps[1-3] = `00 04 14` = 1044 (+56) ✅, dist[10-12] = `00 03 1f` = 799m (+46m) ✅, cal[7-9] = `00 87 4c` = 34636 (+2016)
- Calorie delta of 2016 for 56 steps is high — may include BMR or use deci-calories (÷10 = 201.6 cal still high).

**Key insight:** The ring's accelerometer pedometer uses different detection algorithms for walking and running strides. The 15-minute slot data (CMD 0x43) appears to primarily count walking-pattern steps — running strides are undercounted in that data. CMD 0x48 provides the `runningSteps` total separately, which is essential for accurate workout step tracking.

**Use case:** After a running workout, compare `totalSteps` from 0x48 with the sum of 15-minute slots from 0x43 to determine if running steps were missed.

### 9.2 Activity Data Deduplication Bug (Biosense-specific)

When `syncActivityData(dayOffset: 0)` is called, it automatically also fetches dayOffset 1 (yesterday UTC). If back-to-back syncs fire before the 1-second flush timer, the batch can contain duplicate (date, hour, minute) slots that get summed in hourly aggregation — producing exactly 2x the real value. The Biosense app now deduplicates by (date, hour, minute) key before aggregation.

### 9.3 Never-Reduce Guard

The persistence layer uses a "never reduce" guard: if the ring returns a lower step count for an hour that already has a higher stored value, the update is skipped. This prevents a partial sync of the still-active 15-minute slot from overwriting a higher value captured mid-activity. However, it also means once a doubled value is written, subsequent correct syncs cannot fix it — hence the one-time halving migration.

---

## 10. Sport Real-Time Telemetry (0x73)

The ring autonomously sends CMD 0x73 (115) packets when its firmware detects exercise-level activity. These packets arrive without being requested — the ring's accelerometer triggers them.

### 10.1 Packet Layout

| Byte | Field | Notes |
|------|-------|-------|
| 0 | Command | 115 (0x73) |
| 1 | Sub-type/flags | Constant 18 observed so far |
| 2-3 | Unknown | Always 0 |
| 4 | Cumulative counter A | Wraps at 256. **Not steps** — increments at heartbeat rate, similar to byte[10]. Hypothesis disproven by testing. |
| 5 | Unknown | Always 0 |
| 6 | Slow counter | Increments ~1 per 3 packets |
| 7 | Fast counter | Increments ~58 per packet, wraps at 256 |
| 8-9 | Unknown | Always 0 |
| 10 | Cumulative heartbeat counter | Used for sliding-window HR derivation (confirmed working) |
| 11-14 | Unknown | Always 0 |
| 15 | Checksum | |

### 10.2 HR Derivation from byte[10]

Byte[10] is a cumulative heartbeat counter that wraps at 256. By maintaining a sliding window of (timestamp, byte10) samples over the last ~10 seconds, the app derives an estimated HR:

```
totalBeats = sum of (delta byte10) across window (handling wraps)
derivedBPM = totalBeats * 60.0 / elapsed_seconds
```

This provides HR data when the 0x69 HR stream is displaced by sport RT telemetry (the two are mutually exclusive at the firmware level).

### 10.3 Firmware Mutual Exclusion

Sport RT (0x73) and the HR measurement stream (0x69) are mutually exclusive — the ring's firmware can only run one at a time. When the ring detects exercise and starts sending 0x73 packets, the 0x69 stream stops. The app must detect this and use the derived HR from byte[10] instead.

### 10.4 Phone Sport Mode (CMD 0x77 / 0x78)

Phone-initiated sport mode enables the app to tell the ring to enter enhanced tracking for a specific sport type. Unlike autonomous sport RT (0x73), this gives the app control over start/stop and the ring returns richer telemetry.

#### 10.4.1 Starting a Session (0x77)

```
Packet: [0x77, action, sportType, ...zeros..., crc]
Actions: 1=start, 2=pause, 3=resume, 4=end
Sport types: 4=walking, 7=running, 8=hiking, 9=cycling, 10=other
```

The ring echoes back a 0x77 ack packet confirming the action.

#### 10.4.2 Real-Time Notifications (0x78)

Once a phone sport session is active, the ring sends 0x78 packets approximately every second:

| Byte(s) | Field | Encoding |
|---------|-------|----------|
| 0 | Command | 0x78 |
| 1 | Sport type | Same as start command |
| 2 | Status/flags | |
| 3-4 | Duration | Seconds elapsed (uint8 byte[3] wraps at 256; extended to 16-bit with byte[4]) |
| 5 | Heart rate | BPM (0 = no reading yet) |
| 6-8 | Calories | 24-bit (encoding TBD) |
| 9-11 | Steps | 24-bit big-endian (cumulative for session) |
| 12-14 | Distance | 24-bit big-endian (meters, cumulative for session) |
| 15 | CRC | |

**Key advantage over 0x73:** Phone sport provides steps, distance, and calories — none of which 0x73 exposes. For running workouts, the step count enables cadence derivation (`delta_steps / delta_time × 60`), which is critical for cadence-coupling HR correction.

#### 10.4.3 Mutual Exclusion

Phone sport mode (0x77/0x78) and autonomous sport RT (0x73) appear to coexist — the ring sends both packet types during phone sport sessions. The 0x69 HR stream is displaced as with autonomous sport.

### 10.5 What 0x73 Does NOT Provide

- **No step count** — byte[4] was tested and disproven as a step counter. It tracks at heartbeat rate, not step rate.
- **No distance** — must be derived from GPS or estimated from other sources.
- **No calories** — the ring's own calorie estimate is only available via CMD 0x43 (15-min slots) or CMD 0x48 (today's totals).

---

## 11. Raw PPG/Accelerometer Streaming (CMD 0xA1)

The ring supports raw sensor streaming via command 0xA1, enabling access to raw PPG waveform, 3-axis accelerometer, and SpO2 values. This was originally documented by the Edge Impulse example project and has been **confirmed working on stock firmware** (tested on RT02R V3.1, firmware RT02R_3.11.00_250611).

### 11.1 Command Protocol

Raw sensor streaming uses the standard 16-byte UART packet format. Commands are sent on the Main Data service (RX characteristic); responses arrive on **both** the Main Data TX characteristic AND the Big Data notify characteristic (DE5BF729). The app must intercept 0xA1 packets on the Big Data service before they hit the Big Data reassembly buffer.

**Enable raw streaming:**
```
A1 04 00 00 00 00 00 00 00 00 00 00 00 00 00 A5
```
(cmd=0xA1, sub=0x04=enable, CRC=0xA5)

**Disable raw streaming:**
```
A1 02 00 00 00 00 00 00 00 00 00 00 00 00 00 A3
```
(cmd=0xA1, sub=0x02=disable, CRC=0xA3)

### 11.2 Response Packet Types

Once enabled, the ring streams three interleaved packet types, all with opcode 0xA1:

**PPG (byte[1] = 0x02):**

| Byte(s) | Field | Encoding |
|---------|-------|----------|
| 0 | Command | 0xA1 |
| 1 | Sensor type | 0x02 = PPG |
| 2-3 | Raw value | 16-bit big-endian |
| 4-5 | Max value | 16-bit big-endian |
| 6-7 | Min value | 16-bit big-endian |
| 8-9 | Diff value | 16-bit big-endian |
| 15 | CRC | |

**Accelerometer (byte[1] = 0x03):**

| Byte(s) | Field | Encoding |
|---------|-------|----------|
| 0 | Command | 0xA1 |
| 1 | Sensor type | 0x03 = Accelerometer |
| 2-3 | Y axis | 12-bit signed (sign-extend bit 11) |
| 4-5 | Z axis | 12-bit signed |
| 6-7 | X axis | 12-bit signed |
| 15 | CRC | |

Note: Axis order in the packet is Y, Z, X — not X, Y, Z. Values are in the STK8321's native units at ±2g range (12-bit resolution, ~1 mg/LSB).

**SpO2 (byte[1] = 0x01):**

| Byte(s) | Field | Encoding |
|---------|-------|----------|
| 0 | Command | 0xA1 |
| 1 | Sensor type | 0x01 = SpO2 |
| 2-3 | Raw value | 16-bit big-endian |
| 5 | Max | 8-bit |
| 7 | Min | 8-bit |
| 9 | Diff | 8-bit |
| 15 | CRC | |

### 11.3 Empirical Results (Stock Firmware)

**Tested on:** RT02R V3.1, firmware RT02R_3.11.00_250611 (stock, no modifications)

- **PPG sample rate:** ~1.1 Hz (1 packet/second)
- **Accelerometer sample rate:** ~1.1 Hz (1 packet/second)
- **SpO2 sample rate:** ~1.1 Hz (1 packet/second)
- **PPG raw values:** Observed ~6,700–7,000 range (plausible photoplethysmogram amplitude)
- **Accel values:** Observed X:-318 Y:-420 Z:485 at rest (gravity-dominated, magnitude ~720 consistent with ±2g at 12-bit)
- **All three sensor types stream simultaneously**

> **Critical limitation:** 1.1 Hz is too slow for adaptive noise cancellation (Scenario A). At Nyquist limit of 0.55 Hz, you cannot resolve the PPG pulse waveform (1.0–3.0 Hz cardiac frequency). This rate provides pre-averaged sensor summaries, not raw waveform data. Full ANC requires ~25+ Hz, which may require modified firmware.

### 11.4 Firmware Modification for Higher Throughput

The Edge Impulse / ATC community produced a modified firmware (R02_3.00.06_FasterRawValuesMOD.bin) that increases the raw data streaming rate from ~1 Hz to ~25-50 Hz.

**Compatibility warning:** The mod firmware is built for **R02 V3.0 hardware** with firmware base R02_3.00.06. It is **NOT compatible** with RT02R V3.1 hardware (different GPIO mappings, sensor configurations). Flashing V3.0 firmware onto V3.1 hardware may brick the ring.

| Hardware | Firmware | Mod Compatible? |
|----------|----------|-----------------|
| R02 V3.0 | R02_3.00.06 | Yes — flash via ATC_RF03_Writer |
| RT02R V3.1 | RT02R_3.11.00 | **No** — different hardware revision |

Stock firmware files for rollback are available in the ATC_RF03_Ring repo under `OTA_firmwares/`.

### 11.5 Practical Applications at 1 Hz

Even at 1.1 Hz, the raw sensor stream enables:
- **Cadence detection from accelerometer** — running cadence is highly periodic; 1 Hz accel data + step counts from 0x78 sport packets can estimate cadence (SPM)
- **PPG quality monitoring** — raw/max/min/diff values indicate signal quality and sensor contact
- **Cross-validation** — compare raw PPG trends against computed HR values to detect cadence coupling artifacts
- **SpO2 trending** — continuous raw SpO2 values for longitudinal tracking

For running HR correction without higher sample rates, the recommended approach is **Scenario B: post-hoc cadence-rejection filtering** using computed HR from 0x78 sport packets + cadence estimated from step deltas and/or 1 Hz accelerometer data. See Section 11.6.

### 11.6 Cadence Coupling (Motion Artifact) During Running

The R02's PPG-based HR is subject to **cadence coupling** during running — the most common failure mode of wrist/finger optical HR sensors. The sensor's algorithm partially or fully locks onto step cadence instead of cardiac pulse.

**Observed behavior:**
- Orange zone (actual HR ~155): reported HR ~+10 BPM (locks toward cadence ~170 SPM)
- Red zone (actual HR ~160): reported HR ~+20 BPM (locks toward cadence ~180 SPM)
- Offset scales with the gap between true HR and cadence frequency
- Worse at higher intensity (stronger ground impact = higher motion artifact amplitude)

**Root cause:** The VC30F PPG sensor measures blood volume changes via light absorption. During running, rhythmic impact forces create periodic blood pooling in the finger at step cadence frequency. When cadence (1.2–3.0 Hz) overlaps with cardiac frequency (1.0–3.0 Hz), the onboard algorithm cannot distinguish them.

**Correction approach (Scenario B — post-hoc):**
1. **Cadence extraction:** From 0x78 sport packets, compute `delta_steps / delta_time × 60` = SPM
2. **Coupling detection:** Flag HR samples where `|HR_reported - cadence| < threshold` (empirically ~5-8 BPM)
3. **Correction:** Kalman filter with physiological constraints (max HR rate of change ~2-3 BPM/sec), weighting flagged samples as low-confidence

---

## 12. Firmware & Security

The ring's openness at the firmware level is highly unusual for a consumer wearable:

- OTA firmware updates are delivered over BLE with no code signing and no encryption.
- Colmi's official firmware images are downloadable directly from the OTA server URL embedded in the QRing app.
- Custom firmware can be uploaded via the browser-based WebBluetooth OTA tool at atc1441.github.io/ATC_RF03_Writer.html.
- SWD debug pads (P00, P01) are accessible on the PCB after scraping through the epoxy potting, providing an alternative firmware dump path.

The RF03 SoC SDK is available in the atc1441 repository, enabling developers to write fully custom firmware with access to the BLE stack, VC30F optical sensor driver, and STK8321 accelerometer — well beyond what the stock firmware exposes.

---

## 13. Open Questions and Mysteries

The community has documented several areas that remain unclear:

### Resolved Questions

| Area | Resolution |
|------|------------|
| Serial Port Service | **RESOLVED.** The DE5BF728 service is the Big Data / Raw Sensor service. It handles variable-length structured data (sleep logs via dataId 39, SpO2 history via dataId 42) using the 0xBC magic byte protocol, AND raw sensor streaming (0xA1 command responses). Write characteristic: DE5BF72A, Notify characteristic: DE5BF729. |
| CMD_PHONE_SPORT (0x77) | **RESOLVED.** Fully implemented and documented. Phone-initiated sport mode with 5 sport types (walk=4, run=7, hike=8, cycle=9, other=10). Actions: start=1, pause=2, resume=3, end=4. Ring responds with 0x78 notification packets containing real-time steps, HR, distance, calories, duration. See Biosense v1.6 implementation. |
| 0xA1 Raw Sensor Streaming | **CONFIRMED** working on stock firmware (RT02R V3.1, 3.11.00) at ~1.1 Hz for all three sensor types (PPG, accelerometer, SpO2) simultaneously. Higher rates require modified firmware, which is only available for R02 V3.0 hardware. |

### Remaining Open Questions

| Area | Open Question |
|------|--------------|
| 0x69 unknown bytes | The DataRequest struct has two "unknown" bytes (unk1, unk2) always set to 0. Their purpose under non-zero conditions is unverified. |
| CONTINUE packet discrepancy | The CONTINUE_HEART_RATE_PACKET uses command byte 0x1E instead of 0x69. It works on real hardware, but the reason for the cross-pathway design is unknown. |
| ECG / Blood Pressure reliability | DataType values 2, 7, 9 return data but accuracy is uncertain — the VC30F is PPG-only. The ring may be applying firmware-side estimation algorithms. |
| Stress (0x08) | Stress/pressure measurement exists in the enum but no verified packet capture showing it in use on the R02 has been published. |
| Sleep stage granularity | The exact byte format for sleep stage transitions in the historical sleep packets is partially decoded; edge cases around multi-day data are not fully mapped. |
| Binding / CMD_BIND_SUCCESS (0x10) | Some ring variants require a bind command after connection. Whether the R02 enforces this is inconsistently reported. |
| Sport RT byte[4] | Confirmed NOT a step counter via empirical testing — increments at heartbeat rate. Actual purpose unknown (possibly redundant beat counter or PPG quality metric). |
| Running step undercounting in 0x43 | The 15-minute slot data appears to undercount running strides vs walking. CMD 0x48 `runningSteps` field may compensate, but the exact firmware logic is unknown. |
| HR log settings persistence | Ring firmware resets HR log interval (and possibly other settings) on its own midnight reboot cycle. App must re-apply settings periodically, not just on connect. |
| RT02R V3.1 mod firmware | No custom firmware exists for the V3.1 hardware revision. Higher raw sensor sample rates (needed for Scenario A adaptive noise cancellation) remain unavailable on this hardware. |
| Cadence coupling correction | Post-hoc Scenario B correction (cadence-rejection filter using 0x78 sport data) is designed but not yet validated against chest strap ground truth. Empirical threshold tuning needed. |
| 0xA1 on Big Data service | Raw sensor packets (0xA1) arrive on the Big Data notify characteristic in addition to (or instead of) the UART TX characteristic. The exact routing behavior may be firmware-version dependent. Apps must check both services. |

---

## 14. Community Ecosystem

The following projects collectively document the Colmi R02 protocol and provide reference implementations across multiple languages and platforms:

| Project | Language | Description & Link |
|---------|----------|-------------------|
| colmi_r02_client (tahnok) | Python | [github.com/tahnok/colmi_r02_client](https://github.com/tahnok/colmi_r02_client) — Primary Python client, 528 stars. CLI for all data types; validated test fixtures; 100% offline. |
| colmi-docs (Puxtril) | MkDocs | [colmi.puxtril.com](https://colmi.puxtril.com) ([github.com/Puxtril/colmi-docs](https://github.com/Puxtril/colmi-docs)) — Structured protocol documentation. Primary reference for C-style struct definitions. |
| ATC_RF03_Ring (atc1441) | C / Firmware | [github.com/atc1441/ATC_RF03_Ring](https://github.com/atc1441/ATC_RF03_Ring) — Hardware teardown, firmware dump, OTA tool, modified firmware (461 stars). |
| GadgetBridge PR #3896 & #4223 | Java/Kotlin | [codeberg.org — PR 3896](https://codeberg.org/Freeyourgadget/Gadgetbridge/pulls/3896) and [PR 4223](https://codeberg.org/Freeyourgadget/Gadgetbridge/pulls/4223) — Full Android support including real-time HR/step tracking and historical sync. |
| RingCLI (smittytone) | Go | [github.com/smittytone/RingCLI](https://github.com/smittytone/RingCLI) — macOS/Linux CLI. Accompanied by in-depth blog series documenting protocol exploration. |
| Edge Impulse example | Python | [github.com/edgeimpulse/example-data-collection-colmi-r02](https://github.com/edgeimpulse/example-data-collection-colmi-r02) — Raw PPG/SpO2/accelerometer streaming for ML data collection. Includes modified firmware. |
| ColmiSmartRing (this project — ophirr) | Swift (iOS) | [github.com/ophirr/ColmiSmartRing](https://github.com/ophirr/ColmiSmartRing) — iOS app with 5-zone HR tracking, HRV, gym workout mode, Apple Health integration, InfluxDB export. CoreBluetooth-based. |
| Smittytone Blog | Article | [blog.smittytone.net — Hoard of the Rings](https://blog.smittytone.net/2025/04/09/hoard-of-the-rings-colmi/) — Detailed reverse-engineering writeup (April 2025). Best narrative overview of the protocol. |
| Tedium Review | Article | [tedium.co — Colmi R02 Hacker Ring Review](https://tedium.co/2024/11/08/colmi-r02-hacker-ring-review/) — Consumer-facing review focused on hackability and community ecosystem (Nov 2024). |

---

## 15. iOS / Swift Implementation Notes

Specific considerations for the ophirr/ColmiSmartRing Swift project based on the protocol analysis:

### 15.1 Real-Time Measurement Loop

The key insight for real-time streaming in Swift is the need for a repeating timer to send CONTINUE packets. The pattern:

```swift
// 1. Subscribe to TX notifications before sending any command
peripheral.setNotifyValue(true, for: txCharacteristic)
// WAIT for didUpdateNotificationStateFor confirmation!

// 2. Send START packet
let startPacket = makePacket(cmd: 0x69, payload: [0x01, 0x01]) // HR, Start
peripheral.writeValue(startPacket, for: rxCharacteristic, type: .withResponse)

// 3. Set up ~1s repeating timer for CONTINUE packets
continueTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
    // Use the 0x1E continue packet as found in the Python reference client
    let continuePacket = Data([0x1E, 0x33, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                               0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x51])
    peripheral.writeValue(continuePacket, for: rxCharacteristic, type: .withResponse)
}

// 4. Parse responses in didUpdateValueFor
func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
    guard let data = c.value, data.count == 16 else { return }
    let bytes = [UInt8](data)
    if bytes[0] == 0x69 && bytes[2] == 0x00 {  // cmd=0x69, no error
        let bpm = Int(bytes[3])
        // update UI / write to HealthKit
    }
}

// 5. On completion, invalidate timer and send STOP
continueTimer?.invalidate()
let stopPacket = makePacket(cmd: 0x6B, payload: [0x01, 0x00, 0x00]) // HR, Stop
peripheral.writeValue(stopPacket, for: rxCharacteristic, type: .withResponse)
```

### 15.2 PPG Sensor State Machine

The Biosense app implements a centralized sensor state machine (`SensorState`) because multiple features compete for the single PPG sensor:

- **idle** — no active measurement
- **spotCheck(type)** — timed single measurement (HR, SpO2, temp)
- **continuousHR** — user-initiated HR streaming from home screen
- **spo2Stream** — continuous SpO2 monitoring
- **workout** — gym workout mode (HR stream + sport RT)

Transitions tear down the current state before setting up the new one, enforcing mutual exclusion.

### 15.3 InfluxDB Integration

The project's InfluxDBWriter.swift utility enables time-series storage of ring data. For real-time streaming this is particularly powerful — each ~1-second heart rate sample can be tagged with the BLE device identifier and written to InfluxDB for visualization in Grafana or similar tools.

### 15.4 Heart Rate Zones

The app implements a 5-zone heart rate model. The zone thresholds should be computed from the user's profile (age/max HR) rather than hardcoded, since the ring itself does not apply zone logic — it returns raw BPM values. The ring's CMD_GET_PERSONALIZATION_SETTING (0x17) can be used to read back stored user profile data.

### 15.5 Apple Health Integration

AppleHealthHeartRateWriter.swift should use HKQuantityTypeIdentifier.heartRate with the HKUnit.count().unitDivided(by: .minute()) type. For SpO2, use HKQuantityTypeIdentifier.oxygenSaturation. Both require NSHealthShareUsageDescription and NSHealthUpdateUsageDescription in Info.plist.

### 15.6 BLE Command Spacing

The ring's single-threaded UART handler can be overwhelmed by rapid sequential commands. The Biosense app enforces a minimum 0.6s spacing between commands (`RingConstants.bleCommandSpacing`), which is empirically reliable.

### 15.7 Ring Auto-Stop Behavior

The ring auto-stops the HR stream after ~60 seconds if no CONTINUE packets are received. The app implements a watchdog timer that restarts the stream when this happens during a workout.

---

## 16. Quick Reference Card

### Key UUIDs

```
Main Data Service : 6E40FFF0-B5A3-F393-E0A9-E50E24DCCA9E
  Write RX        : 6E400002-B5A3-F393-E0A9-E50E24DCCA9E
  Notify TX       : 6E400003-B5A3-F393-E0A9-E50E24DCCA9E

Big Data Service  : DE5BF728-D711-4E47-AF26-65E3012A5DC7
  Write           : DE5BF72A-D711-4E47-AF26-65E3012A5DC7
  Notify          : DE5BF729-D711-4E47-AF26-65E3012A5DC7

Device Info       : 0000180A-0000-1000-8000-00805F9B34FB
  Firmware Rev    : 00002A26-...
  Hardware Rev    : 00002A27-...
```

### Key Real-Time Commands

```
0x69 (105) = CMD_START_REAL_TIME   -> payload[0]=DataType, payload[1]=DataAction
0x6B (107) = CMD_STOP_REAL_TIME    -> payload[0]=DataType
0x1E  (30) = CMD_REAL_TIME_HR      -> legacy HR pathway; also used for CONTINUE keep-alive

DataType : HeartRate=1, SpO2=3, ECG=7, HRV=10
DataAction: Start=1, Pause=2, Continue=3, Stop=4
```

### Key Data Sync Commands

```
0x03  (3)  = Battery status
0x15 (21)  = HR log for date
0x16 (22)  = HR timing monitor settings (read/write)
0x43 (67)  = Activity 15-min slots (steps/cal/dist) for date
0x48 (72)  = Today's aggregated totals (totalSteps, runningSteps, cal, dist, duration)
0x44 (68)  = Sleep data
0x77 (119) = Phone sport start/pause/resume/end
0x78 (120) = Phone sport real-time notifications (steps/HR/dist/cal)
0xA1 (161) = Raw sensor streaming (enable=0x04, disable=0x02)
0xBC (188) = Big Data protocol (sleep dataId=39, SpO2 dataId=42)
```

### Pre-Built Packets

```
Start HR  : 69 01 01 00 00 00 00 00 00 00 00 00 00 00 00 6D
Stop HR   : 6B 01 00 00 00 00 00 00 00 00 00 00 00 00 00 6D
Continue  : 1E 33 00 00 00 00 00 00 00 00 00 00 00 00 00 51

Start SpO2: 69 03 01 00 00 00 00 00 00 00 00 00 00 00 00 6F
Stop SpO2 : 6B 03 00 00 00 00 00 00 00 00 00 00 00 00 00 6F

Battery   : 03 00 00 00 00 00 00 00 00 00 00 00 00 00 00 03
Today Tot : 48 00 00 00 00 00 00 00 00 00 00 00 00 00 00 48

Start Run : 77 01 07 00 00 00 00 00 00 00 00 00 00 00 00 7F  (phone sport, running)
End Run   : 77 04 07 00 00 00 00 00 00 00 00 00 00 00 00 82

Raw Enable: A1 04 00 00 00 00 00 00 00 00 00 00 00 00 00 A5
Raw Disabl: A1 02 00 00 00 00 00 00 00 00 00 00 00 00 00 A3
```

### Response Parsing

```
All packets: 16 bytes
  [0]   = Command byte (echoed from request)
  [1]   = DataType (for real-time) or sub-command
  [2]   = Error code (0 = OK)
  [3]   = Measurement value (BPM / SpO2 %)
 [4-14] = Reserved / additional data
  [15]  = CRC = sum(bytes[0..14]) mod 255
```

---

*All protocol details reverse-engineered by the open-source community. Not officially documented by Colmi.*
*Updated March 22, 2026 — added raw sensor streaming (0xA1) protocol with empirical results, phone sport mode (0x77/0x78), hardware revision variants (R02 V3.0 vs RT02R V3.1), Device Info service characteristics, cadence coupling analysis, resolved Serial Port Service mystery.*
*Previous: March 19, 2026 — CMD 0x48, Sport RT (0x73) analysis, activity deduplication findings, iOS implementation notes.*
