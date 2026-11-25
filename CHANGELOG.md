# Changelog

Notable changes to StarDash. Versions follow [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added
- Alerts for a link that's up but struggling: high latency or packet loss over the last 5 minutes,
  and obstruction going up. Plus a once-a-day note when data used today passes a set amount.
  Each has its own level in Settings › Notifications, and each can be turned off.

### Changed
- The menu bar dish takes the link's color (green, amber, red or gray) in place of the status dot.
- With the dish colored by status, the menu bar no longer spells out why the link is degraded.
  The tooltip and the popover still say why.
- On the Sky page's 3D view, the link to the satellite shows data moving: blue packets coming down,
  purple ones going up, longer and brighter the more data is moving.

## [0.5.0] - 2026-11-26

### Added
- StarDash updates itself. It checks GitHub once a day, shows a new version in the popover and
  in Settings › Updates with its notes, and installs and reopens in a few seconds. Updates are signed,
  and the app refuses one that doesn't match the signature. Turn off the daily check in Settings.
- Pick the speed test server: Cloudflare as before, the nearest Ookla server, or any Ookla server
  by city or provider. Each result shows which server it used.

## [0.4.0] - 2026-11-26

### Added
- The popover shows the last hour as a strip: latency as a line, outages as red marks.
- A Today tile in the popover with data used since midnight, and the billing cycle total when signed in.
- Quick actions in the popover: stow or unstow, restart the dish, and snooze alerts for an hour.
- Data today as a menu bar item.
- Click the Latency, Today or Power tile in the popover to see its last 24 hours in place of the sky chart.
- The popover lists the last few outages over 2 seconds from the past day, with a link to the rest.
- Buttons in the popover footer open the Sky and Speed pages directly.

### Changed
- The popover's Pings tile is gone, and so is Ping success in the menu bar. It sat at 100% nearly all the time.
- The sky charts in the popover and on the dashboard are now a night sky, with stars, the Milky Way
  and a glowing horizon. Satellites show as small lights and obstructions glow red.

### Fixed
- Demo mode no longer shows the real dish location in Settings.

## [0.3.0] - 2026-11-21

### Added
- A Reset map button on the Sky page, under Obstructions. It's the same reset as on the Device page.

### Changed
- The 3D dome is now a night scene. The dish sits on the ground with hills on the horizon,
  under stars and the Milky Way, and the obstruction map shows as a dotted glass dome.
- Satellites are drawn as small craft high in the sky, in their real directions from the dish.
  The one the dish is most likely using is highlighted and linked to the dish by a thin beam.
- A Sky map switch hides the dome, for a clear view of the dish and the satellites.
- Satellites on the radar and horizon views are drawn as craft facing the way they fly,
  with a short fading trail.
- The menu bar icon is the app's dish and satellite. When the dish is offline, the signal arcs
  go and the satellite fades.
- The popover's sky chart shows satellites as dots, with only the likely connected one drawn as a craft.

### Removed
- The dish pointing beam and alignment markers on the sky views.

## [0.2.0] - 2026-11-19

### Added
- Optional sign-in with your Starlink account. It unlocks billing usage, router settings
  (Wi-Fi name, password and DNS) and network rules (data limits, online hours and pause timers).
  The session is kept in your keychain, and StarDash only contacts starlink.com for these features.
- Factory reset for the dish and router.
- How latency is spread, for the dish and the router.
- A log of public IP changes and of devices switching Wi-Fi band.
- Export of debug data as a JSON file from the Device page.
- App and Edit menus, so copy and paste shortcuts work.
- A new app icon.

### Changed
- Results of dish actions show inside the Device page tiles.
- The router, mesh nodes and this Mac are left out of network rules.
- With Wi-Fi off, the Sky page says so instead of waiting for a location.

## [0.1.2] - 2026-11-19

### Changed
- The Sky page explains how to get satellites showing when no location is set.

## [0.1.1] - 2026-11-19

### Fixed
- StarDash keeps waiting for a location fix instead of giving up after the first try.

## [0.1.0] - 2026-11-19

First release.

- Live throughput, latency, packet loss and power draw in the menu bar, with a popover.
- The obstruction map as a flat chart, a horizon view and a 3D dome, with a time-lapse.
- Starlink satellites overhead, computed from public orbit data.
- Outage and event history, kept between launches.
- Network devices with vendors, signal and traffic, plus mesh nodes.
- Speed tests from the Mac and the router, with the route a test takes.
- Dish controls: snow melt, sleep schedule, update time, map reset, stow and reboot.
- Demo mode for screenshots that hides identifying details.

[Unreleased]: https://github.com/sarequl/stardash/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/sarequl/stardash/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/sarequl/stardash/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/sarequl/stardash/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/sarequl/stardash/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/sarequl/stardash/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/sarequl/stardash/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/sarequl/stardash/releases/tag/v0.1.0
