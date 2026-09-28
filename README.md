# Film Meter

A light meter and film preview for iPhone, built for a Contax G2 and a Mamiya 6.

## What v0.1 does

- **Live film preview.** The view is cropped to the lens and format you pick, and rendered through the stock's latitude and your own look. That look was fitted to your Negative Lab Pro conversions, with greens pulled away from yellow.
- **Metering.** Modes are M, Av and Tv. Metering is either Subject (tap to meter, then place the subject on a zone) or Matrix. Matrix reads the whole scene: it detects faces, backlight from the sun's position, snow and night. It then shifts exposure to fit the stock's latitude. Everything runs on the phone with no network.
- **Stocks.** 24 are built in, with reciprocity from the manufacturers' data sheets (each source is in `FilmMeter/Model/Film.swift`). Push and pull are set per roll. With no roll loaded, the Rolls screen picks a preview stock or no film simulation.
- **Filters.** Filters stack and their factors are compensated automatically. The polarizer is simulated on blue sky from the sun's position and the way you're pointing the phone. It assumes the dot sits at the top.
- **Locked frames.** Tap the lock button, press the Camera Control button, or long-press the viewfinder. The app grabs a three-shot bracket and merges it. The locked frame then shows:
  - red stripes where highlights pass the stock's limit and blue stripes where shadows fall off
  - an exposure slider and an aperture slider
  - depth of field simulated from the LiDAR depth map for the real lens and format, with near and far limits
- **Rolls.** Each camera holds its own roll with a frame count and log. The app shows the other camera's settings under the main reading. Saved compositions can be re-rendered later at any aperture or exposure.
- **Stock advisor.** Opened from the Stocks button. It ranks stocks for the scene in front of you.

## Free install with SideStore

SideStore installs apps with a free Apple ID and re-signs them on the phone. Every push to `main` builds Film Meter on GitHub's Macs and publishes it to a feed that SideStore reads.

Once:

1. Install SideStore on the phone with iloader (iloader.app). That needs a Mac, or an Intel or AMD Windows PC with iTunes. Windows on ARM can't see an iPhone over USB, so there it needs the experimental WSL route with usbipd-win. On that route, run `tools/usbmuxd-wsl.sh` inside Ubuntu first. Stock usbmuxd hangs on large copies there, because usbipd-win drops the zero-length USB packets it relies on.
2. On the phone, turn on Developer Mode under Settings, Privacy & Security. Then trust your Apple ID under Settings, General, VPN & Device Management.
3. Install LocalDevVPN from the App Store and connect it.
4. Open SideStore and sign in with the same Apple ID.
5. In SideStore, open Sources, tap +, and add `https://raw.githubusercontent.com/colin493/film-meter/sidestore/source.json`. Install Film Meter from that source.

After that:

- New builds show up as updates inside SideStore.
- Tap Refresh in SideStore at least once every 7 days, with LocalDevVPN connected, or the app stops opening.
- A free Apple ID can hold 3 sideloaded apps at once, and SideStore counts as one.

Each build is also attached to a GitHub release. The ten newest are kept.

## TestFlight instead ($99 a year)

This path needs the Apple Developer Program. It needs no computer at all, and builds last 90 days instead of 7.

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
- `.github/workflows/ios.yml`: cloud build, SideStore feed and TestFlight upload
- `scripts/sidestore_source.py`: writes the SideStore feed from the built app
