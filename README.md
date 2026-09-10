# Realms Connect

Friend-code matchmaking and NAT traversal for [Realms](https://www.nexusmods.com/warhammer40kdarktide/mods/1223) servers in Warhammer 40,000: Darktide.

Two players find and join each other's Realm using a Darktide friend code instead of an IP address and port.

- Join a friend's Realm by typing their Darktide friend code.
- Browse friends who are currently hosting and join from a list.
- Accept or refuse join requests from the mission preparation screen, or from an on-screen prompt anywhere else.
- Opens a port on your router automatically while you host, where your router allows it.
- Connects players who are both behind a home router, without either of them forwarding a port.
- Lets friends join a mission already in progress, if the host allows it.
- Optionally hides your public IP address and friend code on screen, for streaming.

Download: [Nexus Mods](https://www.nexusmods.com/warhammer40kdarktide/mods/1297)

## Requirements

- Darktide Mod Framework (DMF)
- [Realms](https://www.nexusmods.com/warhammer40kdarktide/mods/1223) 0.7.0 or newer, by deluxghost. Realms itself requires SoloPlay.
- [Vox Manifold](https://www.nexusmods.com/warhammer40kdarktide/mods/1117)

Both the host and the joiner need all of the above installed, and must use the same Realms version.

## Installation

1. Install the requirements above.
2. Copy the `Realms Connect` folder into your Darktide `mods` folder.
3. Add these lines to the bottom of `mods\mod_load_order.txt`, in this order. `Realms` must appear above both.

   ```
   Vox Manifold
   Realms Connect
   ```

4. Start the game.

## Usage

**Friend codes.** Realms Connect uses your normal Darktide friend code. It is also shown at the top of the lobby's Requests tab while hosting; click it to copy it.

- The joiner needs the host's friend code.
- The host needs the joiner's friend code saved in Esc > Mods > Realms Connect > *Saved friend codes*. This is not needed if the joiner is already on the host's Darktide friends list, in the host's party, or in the same Mourningstar instance.

**Hosting.** Start a Realms server as normal. Join requests appear in the Requests tab on the mission preparation screen, or as a notification on the right of the screen anywhere else. F9 lets them in, F10 refuses them, and ignoring the request refuses it when the timer runs out.

**Joining.** Open Realms' Join screen. In the Realms Connect section, type the host's friend code, press *Look Up*, then *Connect*; or press *Check friends for open lobbies* and pick a friend who is hosting. A connection can take up to 48 seconds. An `ip:port` can also be typed into the friend code box to connect directly.

**Streaming.** *Hide my address and code on screen* shows your public IP address as `x.x.x.x` and your friend code as `xxxx-xxxx` in chat, the join screen and the hosting panel. Click either one to copy the real value. Log files are not affected.

## Network access

- STUN queries to public STUN servers (`stun.l.google.com`, `stun1.l.google.com`, `stun.cloudflare.com`, `global.stun.twilio.com`, `stun.voipgate.com`) to find your public address.
- UPnP or NAT-PMP to your own router only, to open a port while hosting. Turn off with *Router port mapping*.
- Join requests and replies travel over Darktide's own presence service, through Vox Manifold.

Realms Connect contacts no server run by the author, downloads nothing, and collects no statistics.

`bin/darktide-realms-connect.dll` performs the STUN queries and router port mapping.

## Reporting a problem

Turn on *Debug logging* in Esc > Mods > Realms Connect, then reproduce the failure. Before closing the game, type `/rc_report`, then `/rc_diag` and wait a few seconds. Quit, and attach the newest log from `%APPDATA%\Fatshark\Darktide\console_logs` from both the host and the joiner, with the rough time of the attempt.

A log contains the friend code, local network addresses and public IP address of the machine that wrote it. `/rc_diag` masks the public IP address by default.
