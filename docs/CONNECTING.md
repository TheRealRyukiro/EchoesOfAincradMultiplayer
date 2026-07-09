# Connecting two PCs

The joiner's game connects directly to the host on **UDP port 7777**. All you
need is an IP address the joiner can reach.

## Option A — same house / same Wi-Fi (easiest)

1. On the **host** PC: press `Win+R`, run `cmd`, type `ipconfig`, and read the
   `IPv4 Address` (usually `192.168.x.x`).
2. On the **joiner** PC: put that address in
   `Mods\AincradTogether\Scripts\config.lua` → `Config.HostAddress`.
3. The first time you host, Windows may show a firewall popup for the game —
   click **Allow**. If there's no popup and joining times out, add an inbound
   rule manually: Windows Security → Firewall → Advanced settings → Inbound
   Rules → New Rule → Port → **UDP 7777** → Allow.

## Option B — different houses, no router fiddling (recommended)

Use [Tailscale](https://tailscale.com/download) (free for personal use). It
creates a private network between your two PCs, exactly like being on the same
Wi-Fi, with no port forwarding and no public exposure:

1. Both of you install Tailscale and log in — easiest is one of you creating
   the account and the other logging into the same one (or use its "Invite"
   flow).
2. The host reads their Tailscale IP from the Tailscale window (starts with
   `100.`).
3. The joiner puts that `100.x.y.z` address in `config.lua`.

Radmin VPN and ZeroTier work the same way if you prefer them.

## Option C — port forwarding (classic, more fuss)

1. Host forwards **UDP 7777** to their PC in the router admin page.
2. Host finds their public IP (search "what is my IP").
3. Joiner uses that public IP in `config.lua`.

Skip this if Option B is available to you — forwarding exposes the port to the
whole internet and breaks whenever your ISP changes your IP.

## Joining

With the game running and the host already hosting (they pressed F7 *after*
loading into the world):

- press **F8**, or
- open the UE4SS console and run `coop_join 100.64.12.34` (any address you
  type here overrides `config.lua`).

The joiner's screen should load into the host's map. Give it a few seconds;
the host's console will print `A player joined!` when the connection lands,
and the spawn fixer will give the joiner a body within a couple of seconds.

## A note on ports

`7777` is Unreal's default. If something else on the host PC already uses it,
change `Config.Port` on the joiner **and** launch the host's game with the
matching port (Steam → game Properties → Launch Options → `-Port=7778`).
