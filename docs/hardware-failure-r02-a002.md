# R02 Hardware Failure: Unit R02_A002 (March 2026)

## Summary

After ~3 weeks of development use, unit R02_A002 exhibited progressive BLE
radio degradation leading to unusable connection stability. Replaced with
R02_D305 (RT02CR variant) which connected immediately and held stable.

## Timeline

- **Early March 2026:** Unit paired and working. Connection stable for
  minutes at a time during development/testing.
- **~March 20-22:** Connection duration began shortening. Disconnects
  started appearing during spot-check cycles.
- **March 23-24:** Connection limited to ~8-9 seconds before CBError 6
  (supervision timeout). Full sync could not complete without disconnect.
  CBError 15 (encryption failure) on most reconnect attempts.

## Symptoms

### BLE Supervision Timeout (CBError 6)
- Every connection died after 7-9 seconds of data transfer
- Ring's radio stopped responding to link-layer keepalives
- Pattern was consistent regardless of command load or timing

### Encryption Failures (CBError 15)
- `"Failed to encrypt the connection, the connection has timed out unexpectedly."`
- 3-8 failed reconnect attempts between each successful connection
- Indicates degraded secure element or corrupted BLE pairing state

### MTU Stuck at 23
- Never negotiated above the BLE default MTU of 23 bytes
- Healthy unit (R02_D305) immediately negotiated MTU 247

### Connection Pattern
```
Connect → 7-9s of data → CBError 6 disconnect
  → CBError 15 (retry fail)
  → CBError 15 (retry fail)
  → CBError 15 (retry fail)
  → Connect → 7-9s → CBError 6
  (repeat)
```

## Distinguishing from Software Bugs

The key diagnostic: **identical app code on replacement hardware (R02_D305)
held connections for minutes+, negotiated MTU 247, zero CBError 15 failures.**

If you see similar symptoms, check:
1. Does the ring negotiate MTU > 23? If stuck at 23, suspect hardware.
2. Are CBError 15 (encryption) failures appearing on reconnect? Hardware.
3. Is connection duration consistently <10s regardless of command pacing? Hardware.
4. Does a different ring unit work fine with the same app build? Confirmed hardware.

## Hardware Comparison

| Property | R02_A002 (failed) | R02_D305 (replacement) |
|----------|-------------------|----------------------|
| Hardware | RT02R_V3.1 | RT02CR_V3.1 |
| Firmware | RT02R_3.11.00_250611 | RT02CR_3.12.00_251205 |
| MTU | 23 (default, never negotiated) | 247 |
| Connection stability | 7-9 seconds max | Minutes+ |
| CBError 15 on reconnect | Frequent (3-8 per cycle) | None observed |

Note: The "C" in RT02CR may indicate a hardware revision with improved radio.

## Probable Cause

The $20 R02 uses a low-cost BLE radio. Aggressive development usage
(rapid spot-check cycling, watchdog restarts, continuous PPG streaming,
raw sensor experiments, undocumented command probing) over ~3 weeks
likely stressed a marginal radio to failure. The encryption failures
suggest the secure pairing state or radio frontend degraded.

## Lessons

- Treat R02 units as consumable during development
- Keep a spare ring for swap-testing connection issues
- MTU = 23 is the first red flag for radio health
- CBError 15 clusters = radio degradation, not a software bug to chase
