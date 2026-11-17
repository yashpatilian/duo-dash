# Car setup: what to buy and how to test it

This guide covers the hardware for Duo Dash's car features and how to test each feature in
the car. The steps work in most cars built from about 2001 onwards (1996 onwards in the US).

| Feature | Hardware needed |
|---|---|
| Calendar and weather | Nothing |
| Dashcam | A mount that leaves the rear cameras uncovered, and power |
| Car data (engine data, battery voltage, fault codes) | An OBD‑II adapter |
| Home (garage, lights, locks) | HomeKit accessories, plus a one‑off setup step (see below) |

## Shopping list (cheapest first)

### 1. OBD‑II adapter (car data)
It must be **ELM327‑compatible** and support **Bluetooth LE** (often listed as "BLE",
"Bluetooth 4.0" or "dual mode"). iPhones can't use classic‑Bluetooth‑only adapters.
Avoid adapters that only work with their maker's app (FIXD, Carly, BlueDriver): Duo Dash
connects to the adapter directly.

| Option | Price (approx.) | Notes |
|---|---|---|
| Generic "ELM327 Dual‑Mode" mini adapter | US$8–15 | Worth trying first. Some ultra‑cheap clones handle older cars' **K‑line** protocol badly; test it the day it arrives (below) and return it if the car doesn't answer. |
| **Vgate iCar Pro Bluetooth 4.0 (BLE)** | US$30–40 | Well‑known and reliable, including on older K‑line cars. The safe choice. |
| **OBDLink CX** | US$80 | Premium BLE adapter, fast and well supported. |

**Older cars (roughly 2001–2008 outside the US):** many use the older K‑line protocol
(ISO 9141‑2 / KWP2000). A generic ELM327 usually reaches the **engine computer**
(RPM, speed, temperatures, fault codes) but not the body or ABS modules. Battery voltage
always works because the adapter measures it itself.

### 2. Mount (dashcam and everyday use)
- Get a car mount that clamps a **small tablet or foldable**: the unfolded iPhone Duo is
  about 16 × 11.5 cm (6.3 × 4.5 in), so look for a clamp range of at least 16.5 cm. Phone‑only mounts are
  too small.
- For the dashcam, the clamp **must not cover the camera bump** on the back of the left
  half. When unfolded on the dash, those rear cameras face the road.
- Mount it high and central (top of the dash or a windscreen mount). It must not block
  your view of the road.

### 3. Power
- A USB‑C car charger with Power Delivery, 20 W or more, plus a USB‑C cable long enough
  to reach the mount.
- The dashcam and the screen being on all the time use a lot of power, so keep the phone
  plugged in on long drives.

## Fitting the OBD‑II adapter
1. Find the port: almost always under the dashboard on the driver's side, near your knee
   (a 16‑pin trapezoid socket). Your car's manual or a quick search for your model shows
   exactly where.
2. Plug the adapter in. Its light comes on.
3. Turn the ignition **on**. Starting the engine is better.

**Check the adapter first (2 minutes, recommended):**
1. Install the free **Car Scanner** app.
2. Open Settings → Connection, choose the adapter, then tap Connect.
3. If it shows a protocol (e.g. "ISO 9141‑2" or "KWP2000") and live RPM or coolant
   temperature, the adapter works with your car and Duo Dash will read the same data.
4. If it connects to the adapter but says "No response from ECU" or "Unable to connect",
   the adapter can't talk to your car (common with the cheapest clones on K‑line cars).
   Return it and get the Vgate iCar Pro BLE or an OBDLink CX.

**Then in Duo Dash:**
1. Open the **Car** app in the dock and allow Bluetooth.
2. Tap **Search**, then choose your adapter. Duo Dash remembers it and reconnects by itself
   from then on.
3. You should see **Connected** with the protocol, then live tiles. Only the values your car
   supports are shown.
4. If you see "Adapter connected, but the car's computer didn't answer", the adapter is
   fine but the car isn't answering. Check the ignition is on, then see the check above.
5. With the adapter connected, the Dashboard's third card shows speed, coolant temperature,
   battery voltage and a warning dot when there's a fault code.
6. **Clear codes** only works when parked (speed 0), and asks you to confirm first.

## Dashcam
1. Mount the unfolded Duo so the rear cameras see the road ahead.
2. Open **Dashcam** in the dock, allow the camera, then tap the red record button.
3. It records in 1‑minute pieces and keeps the last 10 minutes; you can choose 2, 5, 10, 20
   or 30 in Settings → Dashcam. Older footage is overwritten automatically.
   Looping doesn't wear out the phone's storage in any meaningful way: an hour of driving
   writes about 3.6 GB, and the flash can take hundreds of terabytes over its life.
4. Tap **Save clip** to keep the last minute or two. Saved clips are never overwritten.
   Open one to play it, delete it or **Save to Photos**.
5. Settings → Dashcam also has **Start automatically** (off by default) and microphone
   recording (off by default).

Limits to know about:
- iOS only lets an app use the camera while it's on screen. The dashcam pauses when the
  phone locks or another app is in front, so keep Duo Dash open while driving (the screen
  stays on automatically).
- Phones get hot behind a windscreen in summer. Duo Dash drops to 720p when the phone is
  hot and pauses if it gets too hot. Shade the phone, and keep it away from heater vents.

## Calendar and weather
- The first time, allow Calendar access. The Dashboard shows your next event with a **Go**
  button, and the Calendar app lists today and tomorrow.
- Events need a location for Go to work. A place picked from Maps when you create the
  event is the most accurate.
- Weather appears on the map and at the top of Calendar. When you preview a route, it shows
  the weather at your destination for your arrival time. Weather data is from Open‑Meteo.

## Home (HomeKit)
HomeKit needs Apple's HomeKit capability, which requires your own app ID. It's off by default
so everyone's first build works. To turn it on:
1. Sign in to Xcode: Xcode → Settings → Accounts → **+** → Apple ID.
2. Run:
   ```bash
   scripts/setup.sh --homekit --install
   ```
3. Open **Home** in the dock and allow access. Your accessories and scenes from Apple's Home
   app appear as tiles. Hold a tile to add it to the Dashboard.
4. **Arriving home:** set your Home place in Saved Places. Within 300 m of home, Duo Dash
   offers "Open garage?". You can turn on opening it automatically in Settings → Home.
   Locks are never opened automatically.

**No HomeKit accessories yet?** You can try it with a demo home (a garage door, lock, lights
and scenes) by launching with the demo flag from your Mac:
```bash
xcrun devicectl device process launch --device <your-device-id> --terminate-existing <your.bundle.id> -- -DemoHome
```

## Safety and the law
- Use a commercially made mount that holds the phone firmly.
- Set things up before you drive. Road rules on touching a mounted phone differ by country
  and state, and are often stricter for learner and provisional drivers: check yours.
- A dashcam must not block your view of the road.
