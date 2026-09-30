# Multiple Class Race For Assetto Corsa

A CSP Lua app for Assetto Corsa that provides class-based position tracking and gap timing for multi-class races.

<!-- [screenshot: config panel] -->
<!-- [screenshot: leaderboard HUD] -->

## Features

- **Class-based positions** — Track your position within your class separately from overall position
- **Time gap display** — See the time gap to the nearest class car ahead (+) and behind (-)
- **Manual class assignment** — You define class names; cars matching that tag/class are assigned
- **Persistent settings** — Class assignments are saved and persist across sessions
- **Automatic session result export** — Writes a JSON result once when a Race, Qualifying or Practice session finishes, ready to import into the dashboard

## Requirements

- Assetto Corsa with **Custom Shaders Patch (CSP) v0.2.7** or higher
- **Offline / single-player only** — Does not work in online races
- Supported sessions: Race, Practice, Qualifying, Hotlap

## Installation

You can drag & drop the rar file into Content Manager or do it manually by extracting it:
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

### Automatic Session Result Export

The app can automatically export a session's result to a JSON file **once, when the session finishes**. This works for **Race**, **Qualifying** and **Practice**.

**Default:** auto-save is checked on a fresh install. Existing saved preferences are respected. In the Config window, use **"Auto-save session result when the session finishes"** to change it; the checkbox is available in every session type, including Race.

**Choose where to save:** click **"Choose result folder..."** to pick a destination. The default is:

```
<My Documents>\Assetto Corsa\mcr-results\
```

Each session type gets its own subfolder. Use **"Reset to Default"** to go back. The status line below the controls shows where the last result was written.

**What happens:** when a session ends, the app writes a single file per session, named with the time the result was written:

```
mcr-results\practice\yyMMdd-HHmmss.json
mcr-results\qualifying\yyMMdd-HHmmss.json
mcr-results\race\yyMMdd-HHmmss.json
```

The file is written to a temporary `.tmp` name first and then renamed, so a reader can never pick up a half-written file. Each session is exported at most once; restarting the same session type produces a new file.

#### Practice and Qualifying

A JSON array with one entry per car that has set a lap time:

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

#### Race

A Content Manager compatible results file, so it can be loaded by Content Manager as well as the dashboard:

```json
{
  "track": "monza",
  "numberOfSessions": 1,
  "players": [
    { "name": "Driver Name", "car": "car_id", "skin": "skin_id" }
  ],
  "sessions": [
    {
      "type": 3,
      "lapsCount": 12,
      "lapsTotal": [12, 11, 10],
      "bestLaps": [ { "car": 0, "lap": 12, "time": 91234 } ],
      "raceResult": [0, 1, 2]
    }
  ]
}
```

`raceResult` lists car indices in finishing order, and `bestLaps` only includes cars that actually set a time.

If the result folder cannot be resolved or is not writable, the app reports the reason in the config window and shows a warning instead of failing silently.

### Importing results into the dashboard

When Assetto Corsa closes, the **Multi-Class Race Dashboard** scans the result folder and offers to import anything new it finds:

- A **Yes/No prompt** appears with a **Race** picker, pre-selected to the session you launched from the dashboard. If that race cannot be determined, pick it manually.
- Choosing **No** records the file as declined so it is not offered again.
- Importing a Race result **replaces** the existing race session in that race, including its points.
- Files you import yourself from the dashboard's **Race** tab are also recorded, so they are not offered twice.

Previously imported or declined files are remembered, so restarting the dashboard will not re-prompt for them.

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

## License

This project is licensed under the **MIT License** with additional terms. See the [`LICENSE`](LICENSE) file for the full text.

- You may **read, study, and contribute** to the source code.
- The **author credit** ("Duong Do") must not be removed or changed in any copy or derivative work.
- Redistributing or publishing the **complete source code** as a standalone repository or release is **not permitted**.

## Credits

- **Author:** Duong Do
- **Version:** 1.0
- Built with the Assetto Corsa CSP Lua API
