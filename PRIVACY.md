# Duo Dash privacy policy

_Last updated: 17 November 2026_

Duo Dash is built so that your data stays on your iPhone. The developer runs no accounts, no
analytics and no advertising, and doesn't receive your location, contacts, messages, music,
calendar, car data, camera footage or voice.

## What stays on your device
Saved places, favourites, Duo Dash's own recents, settings, dashcam clips, car data, trip
history and the speech models are stored only on your iPhone. Your Claude API key (if you add one) and your
Spotify sign-in are stored in the iPhone's Keychain.

## Services the app talks to, and what they receive
- **Weather:** your approximate location (latitude and longitude) is sent to Open-Meteo, or to
  MET Norway if Open-Meteo is unreachable, to fetch the forecast.
- **Maps and directions:** Apple Maps (MapKit), under Apple's privacy policy.
- **Trip history** (Duo Dash Pro, only while "Record trips" is on): each drive's route,
  times, distance and speeds are saved on your iPhone (at most 200 trips; delete them in
  Settings → Duo Dash Pro → Trip history). The start and end points are sent to Apple Maps
  to look up place names. Nothing is sent to the developer.
- **Purchases** (Duo Dash Pro) are handled by Apple through the App Store; the developer
  doesn't receive your payment details.
- **Apple Intelligence** (the default assistant) runs on the device.
- **Claude** (only if you choose it and add your own API key): what you ask, your approximate
  location, your route and any contact you name are sent to Anthropic to answer.
- **Spotify** (only if you connect it): playback commands go to the Spotify app on your phone.
- **Speech models:** if they aren't included in your build, they're downloaded from public
  model hosts (Hugging Face, GitHub). Recognition and speech run on the device.
- **Announcements** (off unless you turn them on in Settings → Notifications): your device's
  push token, the app's bundle ID and version are sent to the developer's notification server
  so it can send update announcements. Turn it off and the token is deleted.

## Permissions
Location, Contacts, Calendar, Microphone and Speech, Camera, Bluetooth, HomeKit and Photos are
each asked for only when you use the feature that needs them, and are used only on the device
for that feature (except as listed above).

## Children
Duo Dash isn't directed at children and collects no personal information from anyone.

## Contact
Questions or requests: open an issue at https://github.com/yashpatilian/duo-dash/issues.
