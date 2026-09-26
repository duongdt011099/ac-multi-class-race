# Multiple Class Race For Assetto Corsa

A CSP Lua app for Assetto Corsa that provides class-based position tracking and gap timing for multi-class races.

<!-- [screenshot: config panel] -->
<!-- [screenshot: leaderboard HUD] -->

## Features

- **Class-based positions** — Track your position within your class separately from overall position
- **Time gap display** — See the time gap to the nearest class car ahead (+) and behind (-)
- **Manual class assignment** — You define class names; cars matching that tag/class are assigned
- **Persistent settings** — Class assignments are saved and persist across sessions
- **Qualifying/Practice auto-save** — Automatically export every car's best lap time to a JSON file each second during qualifying and practice sessions

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

<img width="494" height="307" alt="image" src="https://github.com/user-attachments/assets/758715dc-2458-4b38-ace4-972b48bdcd74" />

### Leaderboard HUD

The leaderboard overlay shows during your session:

| Panel | Description |
|-------|-------------|
| **LAP** | Current lap / total laps |
| **OVERALL** | Overall position among all cars |
| **CLASS** | Position within your class |
| **Gap** | Time gap to class car ahead (+) and behind (-) |

<img width="317" height="183" alt="image" src="https://github.com/user-attachments/assets/95ea3d53-74e8-49f1-98a4-f809e8fd29a1" />

### Qualifying / Practice Auto-Save

While driving in **Qualifying** or **Practice** sessions, the app can automatically export the best lap times of every car on track to a JSON file.

**Enable it:** in the Config window, tick **"Auto-save Qualifying/Practice best-lap results (every second)"**. This option is only shown outside race sessions (qualifying, practice, and the main menu).

**Choose where to save:** click **"Choose save folder..."** to pick a destination folder. By default, results are written into the app's own folder (`apps\lua\Multi_Class\`). Use **"Reset to Default (app folder)"** to go back to the default. The status line below the controls shows where the results were last saved.

**What happens:** while enabled, the app writes a fresh snapshot once every second during the session. A new file is created for each session, named with a timestamp:

```
qualifying-result_YYYYMMDD_HHMMSS.json
```

The file is a JSON array with one entry per car that has set a lap time:

```json
[
    {
        "driver": "Driver Name",
        "car": "car_id",
        "skin": "skin_id",
        "bestLapTimeMs": "01:30.123"
    }
]
```

| Field | Description |
|-------|-------------|
| `driver` | Driver name |
| `car` | Car ID |
| `skin` | Car skin ID |
| `bestLapTimeMs` | Best lap time, formatted `MM:SS.mmm` |

Auto-save only runs in Qualifying/Practice sessions — it never writes results during a race.

## How Classes Work

Classes are **not auto-detected**. To set up classes:

1. Open the **Config** window
2. Type a class name that matches the car's tag (e.g. `GT3`) into the input box
3. Click **Add Class** — the app matches cars whose tags, class field, or name match your entry (case-insensitive) and assigns them
4. Use **Verify** to confirm every car belongs to a class
5. **Remove** a class to unassign its cars

<img width="848" height="563" alt="image" src="https://github.com/user-attachments/assets/5135a3fa-cf4f-4dd1-a032-205184bdca79" />

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

- **Author:** Duong Do
- **Version:** 1.0
- Built with the Assetto Corsa CSP Lua API
