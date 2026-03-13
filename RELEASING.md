# Releasing Biosense via TestFlight

Guide for archiving, uploading, and distributing the Biosense app to testers.

## Prerequisites

- **Apple Developer Program** membership ($99/year) — [enroll here](https://developer.apple.com/programs/)
- Xcode with your team signing identity (automatic signing)
- An app record in [App Store Connect](https://appstoreconnect.apple.com) for bundle ID `com.biosense.ring`

## One-Time Setup

1. **Create the App Store Connect record**
   - Go to App Store Connect > My Apps > "+" > New App
   - Platform: iOS
   - Name: Biosense
   - Primary language: English
   - Bundle ID: `com.biosense.ring`
   - SKU: `biosense-ring-1` (or any unique string)

2. **Verify HealthKit capability**
   - Apple Developer portal > Certificates, Identifiers & Profiles > Identifiers
   - Find `com.biosense.ring` and confirm **HealthKit** is enabled
   - (Xcode automatic signing usually handles this, but verify the first time)

## Releasing a Build

### 1. Bump the build number

Each upload needs a unique build number. In Xcode:

- Select the **Biosense** target > General > Identity
- Increment **Build** (e.g. 1 → 2 → 3 ...). Marketing version can stay at `1.0` until a real release.

Or from the command line:

```bash
# In the Biosense/ directory
agvtool next-version -all     # increments build number
agvtool what-version           # verify
```

### 2. Archive

1. In Xcode, set the destination to **Any iOS Device (arm64)** (not a simulator)
2. **Product > Archive**
3. Wait for the build to complete — the Organizer window opens automatically

### 3. Upload to App Store Connect

1. In the Organizer, select the new archive
2. Click **Distribute App**
3. Choose **App Store Connect** > **Upload**
4. Accept defaults for signing and entitlements
5. Click **Upload** — Xcode signs and submits the build

The build takes 5–30 minutes to process on Apple's side. You'll get an email when it's ready.

### 4. Release to Testers

1. Go to [App Store Connect](https://appstoreconnect.apple.com) > My Apps > Biosense > TestFlight
2. The new build appears under "iOS Builds" once processing completes
3. If this is the first build, Apple may ask for export compliance info (select "No" — the app uses no encryption beyond HTTPS)
4. Add testers:
   - **Internal testers**: Add team members (up to 100, no review needed)
   - **External testers**: Create a group, add emails — first build to external testers requires a brief Beta App Review (~24h)
5. Testers receive an email invite, install the [TestFlight app](https://apps.apple.com/app/testflight/id899247664), and tap to install

## Pushing Updates

1. Bump the build number
2. Archive and upload (steps 2–3 above)
3. Testers are notified automatically and can update from TestFlight

No new invite is needed — existing testers see the update immediately (internal) or after a brief review (external, usually fast after the first one).

## Notes

- **TestFlight builds expire after 90 days.** Upload a new build before then to keep access active.
- **Deployment target is iOS 18.2.** Testers must be on iOS 18.2 or later.
- **Background Bluetooth**: Testers may need to grant Bluetooth and Health permissions on first launch.
- **Build numbers must be unique** per version. Apple rejects duplicate build numbers.
