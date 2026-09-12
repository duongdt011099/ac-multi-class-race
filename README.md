# Multiple Class Race

A CSP Lua app for Assetto Corsa that provides class-based position tracking and gap timing for multi-class races.

<!-- [screenshot: config panel] -->
<!-- [screenshot: leaderboard HUD] -->

## Features

- **Class-based positions** — Track your position within your class separately from overall position
- **Time gap display** — See the time gap to the nearest class car ahead (+) and behind (-)
- **Manual class assignment** — You define class names; cars matching that tag/class are assigned
- **Persistent settings** — Class assignments are saved and persist across sessions

## Requirements

- Assetto Corsa with **Custom Shaders Patch (CSP) v0.2.7** or higher
- **Offline / single-player only** — Does not work in online races
- Supported sessions: Race, Practice, Qualifying, Hotlap

## Installation

1. Copy the `apps\lua\Multi_Class\` folder into your Assetto Corsa installation:
   ```
   <Assetto Corsa>\apps\lua\Multi_Class\
   ```
2. Open Content Manager, go to **Settings > CSP > Apps** and enable "Multiple Class Race"
3. The app will auto-open when you enter a session

## Usage

### Config Window

The config window opens automatically in the main menu. From here you can:

- **Enable Multiple Class Race** — Toggle the feature on/off
- **Add Class** — Type a class name (e.g. `GT3`, `GT4`, `LMP2`) and click "Add Class" to assign matching cars
- **Verify** — Check that all cars on the grid are assigned to a class
- **Remove** — Remove a class and unassign its cars

<!-- [screenshot: adding a class in config panel] -->

### Leaderboard HUD

The leaderboard overlay shows during your session:

| Panel | Description |
|-------|-------------|
| **LAP** | Current lap / total laps |
| **OVERALL** | Overall position among all cars |
| **CLASS** | Position within your class |
| **Gap** | Time gap to class car ahead (+) and behind (-) |

<!-- [screenshot: leaderboard HUD during race] -->

## How Classes Work

Classes are **not auto-detected**. To set up classes:

1. Open the **Config** window
2. Type a class name that matches the car's tag (e.g. `GT3`) into the input box
3. Click **Add Class** — the app matches cars whose tags, class field, or name match your entry (case-insensitive) and assigns them
4. Use **Verify** to confirm every car belongs to a class
5. **Remove** a class to unassign its cars

If no cars match your input, the app will show available tags and suggest the closest match.

## Gap Display

- The gap panel only appears **during an active race session** (after lights go out)
- Gap is calculated using CSP's `ac.getGapBetweenCars()` for accurate time-based gaps
- Gap shows only cars in **your class**, not all cars on track
- `+X.Xs` = class car ahead of you, `-X.Xs` = class car behind you

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "Please update your Custom Shaders Patch" | Update CSP to v0.2.7 or higher |
| "This app only works for Offline/Single-player" | Disconnect from online play |
| "This app works in Race, Practice, or Qualifying sessions" | Switch to a supported session type |
| "Waiting for car data to load..." | Wait for the session to fully initialize |
| No class assignments found | Add classes in the Config window first |

## Credits

- **Author:** Anonymous
- **Version:** 1.0
- Built with the Assetto Corsa CSP Lua API