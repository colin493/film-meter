# Film Meter

A light meter and film preview for iPhone, built for a Contax G2 and a Mamiya 6.

## What v0.1 does

- **Live film preview.** The view is cropped to the lens and format you pick, and rendered through the stock's latitude and your own look. That look was fitted to your Negative Lab Pro conversions, with greens pulled away from yellow.
- **Metering.** Modes are M, Av and Tv. Metering is either Subject (tap to meter, then place the subject on a zone) or Matrix. Matrix reads the whole scene: it detects faces, backlight from the sun's position, snow and night. It then shifts exposure to fit the stock's latitude. Everything runs on the phone with no network.
- **Stocks.** 24 are built in, with reciprocity from the manufacturers' data sheets (Settings lists each source). Push and pull are set per roll.
- **Filters.** Filters stack and their factors are compensated automatically. The polarizer is simulated on blue sky from the sun's position and the way you're pointing the phone. It assumes the dot sits at the top.
- **Locked frames.** Tap the lock button, press the Camera Control button, or long-press the viewfinder. The app grabs a three-shot bracket and merges it. The locked frame then shows:
  - red stripes where highlights pass the stock's limit and blue stripes where shadows fall off
  - an exposure slider and an aperture slider
  - depth of field simulated from the LiDAR depth map for the real lens and format, with near and far limits
- **Rolls.** Each camera holds its own roll with a frame count and log. The app shows the other camera's settings under the main reading. Saved compositions can be re-rendered later at any aperture or exposure.
- **Stock advisor.** Opened from the Stocks button. It ranks stocks for the scene in front of you.

## Put it on your iPhone without a Mac (TestFlight)

This path needs the Apple Developer Program ($99 a year). The app is built on GitHub's Macs.

1. **Enroll** at developer.apple.com/programs/enroll with your Apple ID. Approval can take up to 48 hours.
2. **Register the app ID.** Go to developer.apple.com/account and open Certificates, Identifiers & Profiles, then Identifiers. Press +, choose App IDs and then App. Enter the explicit bundle ID `com.colinmortimer.filmmeter`. No capabilities are needed.
3. **Create the app record.** At appstoreconnect.apple.com, open Apps, press +, choose New App, then iOS. App names must be unique across the App Store, so if "Film Meter" is taken, use something like "Film Meter CM". Pick the bundle ID from step 2 and use `filmmeter` as the SKU.
4. **Create an API key.** In App Store Connect, open Users and Access, then Integrations, then App Store Connect API, then Team Keys. Choose Generate API Key and give it **Admin** access. Download the .p8 file (Apple lets you download it only once) and note the Key ID and the Issuer ID. Your Team ID is under Membership details at developer.apple.com/account.
5. **Add four repository secrets** on GitHub, under Settings, then Secrets and variables, then Actions:
   - `ASC_KEY_ID`: the Key ID
   - `ASC_ISSUER_ID`: the Issuer ID
   - `ASC_KEY_P8`: paste the whole contents of the .p8 file
   - `APPLE_TEAM_ID`: the Team ID

   If you used a different bundle ID, also add a repository **variable** named `BUNDLE_ID`.
6. **Build.** Open Actions, choose Build Film Meter, then Run workflow. The build takes about 10 minutes, and Apple then processes it for another 5 to 30.
7. **Install.** Install Apple's TestFlight app on the iPhone. In App Store Connect, open your app, then TestFlight, then Internal Testing. Create a group, add yourself, and add the build. It then appears in TestFlight on the phone. Each build lasts 90 days, and every push to `main` makes a new one.

Every run also saves an unsigned `.ipa` as a build artifact, for sideloading tools if you ever want that route.

## With a Mac instead

Run `brew install xcodegen && xcodegen generate`, then open `FilmMeter.xcodeproj`. Set your team under Signing & Capabilities, plug in the iPhone and press Run. A free Apple ID works, but the app stops opening after 7 days until you run it again, and the phone needs Developer Mode turned on.

## First run

- Allow camera and location access. Location only gives the sun's position and stays on the phone.
- **Calibrate once.** Meter an evenly lit wall with the app and with the G2. If they differ, set the difference under Settings, then Meter offset.
- **Mark the polarizer.** Hold the filter with the threaded side toward your eye and look at glare on a table from a low angle. Turn it until the glare fades most, then dot the ring at 12 o'clock. Always mount it with the dot at the top.
- Load a roll in each camera from the film chip at the top. Tap **Log frame** each time you fire the film camera.

## Known limits in v0.1

- Matrix metering uses rules and on-device detection. It doesn't use a trained model yet.
- The polarizer is simulated on blue sky only, not on reflections from water or glass.
- The look was fitted to 9 color and 3 B&W frames from two rolls, and each stock's character is an adjustment on top of it. The shadow and highlight limits used for the stripes are approximations. Reciprocity figures come from the data sheets.
- The bracket for a locked frame comes from the video stream, so hold still for about half a second.
- The depth of field preview needs an iPhone with LiDAR (Pro models).
- Camera Control sets compensation and aperture while the app is open, and pressing it locks the frame. It can't launch the app yet, which would need a lock-screen capture extension.

## Project layout

- `FilmMeter/Model`: stocks (data sheet values), cameras, lenses, filters, rolls
- `FilmMeter/Core`: exposure maths, sun position, sky polarization, depth of field
- `FilmMeter/Film`: film curve, levelling and look tables (`Resources/ColinLook.bin`, `ColinBW.bin`)
- `FilmMeter/Camera`: capture session, depth, bracketing, frame analysis, Camera Control
- `FilmMeter/Render`: live preview, locked-frame rendering, grain
- `FilmMeter/UI`: SwiftUI screens
- `.github/workflows/ios.yml`: cloud build and TestFlight upload
