# SSIDekick

A Mac menu bar app that keeps an eye on your Wi-Fi. It warns you about look-alike networks, shows
how good your connection is, and checks whether anything is tampering with your traffic.

**[Download the latest release](https://github.com/networkitout/SSIDekick/releases/latest)**

## What it does

- **Spots look-alike networks.** Flags other networks using your network's name. One of these
  could be an "evil twin" set up to intercept your traffic.
- **Shows connection quality.** Signal, noise and channel crowding for the network you're on.
- **Checks connectivity.** Whether your router, DNS and the internet respond, and how quickly.
- **Checks for interception.** Warns when DNS answers look tampered with or HTTPS certificates
  aren't trusted.
- **Lists nearby networks** in a window, grouped by network name.
- **Notifies you** when something changes, and **copies a report** you can paste into a message or
  ticket.

## Install

1. Download `SSIDekick-<version>.zip` from the
   [latest release](https://github.com/networkitout/SSIDekick/releases/latest) and unzip it.
2. Move `SSIDekick.app` to your Applications folder and open it.
3. When asked, allow Location access. macOS only shows Wi-Fi network names to apps that have it.

Requires macOS 15 or later, on Apple silicon or Intel. The app is signed with Developer ID and
notarized by Apple.

## Using it

- **Left-click** the menu bar icon for the panel: your connection, connectivity checks, and buttons
  for Nearby networks, Scan now, Copy report, Settings and Quit.
- **Right-click** (or Control-click) the icon for a short menu with Settings and Quit.
- The icon changes colour when something needs a look, and turns red for a likely problem.

In **Settings** you can choose how often to scan, turn off the public IP lookup or the interception
checks, and have SSIDekick open at login.

## Permissions and privacy

- **Location:** used only so macOS reveals Wi-Fi network names and access point addresses.
  SSIDekick doesn't record or send your location.
- **Local network:** used to ping your router, query your DNS server, and list devices your Mac
  already knows on the network.
- **Notifications:** optional, for alerts when something changes.

To check your connection, SSIDekick contacts:

- `captive.apple.com`, to see whether the internet is reachable or a login page is in the way.
- Your DNS server, with a lookup of `apple.com`.
- `api.ipify.org`, to show your public IP address. You can turn this off in Settings.
- For the interception checks, every 5 minutes: DNS lookups of `one.one.one.one`, `dns.google` and a
  random made-up name, and an HTTPS connection to `www.apple.com`. You can turn these off in Settings.

There are no accounts and no analytics, and nothing is sent to the developer. A copied report goes
only to your clipboard.

## Building from source

See [DEVELOPMENT.md](DEVELOPMENT.md).

## License

MIT. See [LICENSE](LICENSE).
