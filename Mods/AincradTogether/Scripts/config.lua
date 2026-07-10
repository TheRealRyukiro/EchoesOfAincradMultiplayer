-- ============================================================================
-- AincradTogether configuration
-- Edit this file, then restart the game (or hot-reload UE4SS mods with
-- Ctrl+R in the UE4SS console) for changes to take effect.
-- ============================================================================

local Config = {}

-- ---------------------------------------------------------------------------
-- Connection
-- ---------------------------------------------------------------------------

-- Default address the JOIN key connects to. The person who is NOT hosting
-- sets this to the host's IP (LAN IP, or Tailscale/Radmin/ZeroTier IP).
-- You can also join a specific address from the in-game console instead:
--   coop_join 100.64.12.34
Config.HostAddress = "127.0.0.1"

-- UDP port the session runs on. 7777 is Unreal's default. Only change this
-- if you also launch the game with a matching -Port= argument on the host.
Config.Port = 7777

-- ---------------------------------------------------------------------------
-- Keybinds (see the "Key" enum names in the UE4SS docs; F1-F12, etc.)
-- Set a key to nil to disable that keybind and use console commands only.
-- ---------------------------------------------------------------------------

Config.Keybinds = {
    Host      = "F7",  -- start hosting the map you are currently standing in
    Join      = "F8",  -- join Config.HostAddress
    Status    = "F9",  -- print a session/diagnostic report to the UE4SS console
    ToggleHud = "F6",  -- show/hide the on-screen session HUD
                       -- (not F10: that opens the in-game console, where the
                       --  coop_* commands are typed)
}

-- ---------------------------------------------------------------------------
-- On-screen HUD (session state + live ping)
-- ---------------------------------------------------------------------------

-- Draw a small text HUD (top-left) while in a session: who is connected,
-- their ping in ms, and how long you've been playing. Built from engine UMG
-- widgets; if that fails on some game version, the same line goes to the
-- UE4SS console instead. Toggle at runtime with the ToggleHud key.
Config.ShowHud = true

-- How often the HUD (and the map-change watcher) refreshes.
Config.HudIntervalMs = 1000

-- ---------------------------------------------------------------------------
-- Host-side fixups
-- ---------------------------------------------------------------------------

-- While hosting, periodically look for connected players that have no body
-- (pawn) and ask the game to spawn one for them. This is the fix for the
-- most common failure mode of single-player games: the second player joins
-- and is stuck as an invisible spectator.
Config.FixMissingPawns = true
Config.SpawnFixIntervalMs = 2000

-- After spawning a body for a joining player, teleport them next to the
-- host instead of leaving them wherever the game's PlayerStart happens to
-- be (which can be across the map). "coop_warp" does the same on demand.
Config.SpawnAtHost = true

-- Distance (in Unreal units, ~cm) the teleport commands place players apart
-- so they don't spawn inside each other.
Config.WarpOffset = 150

-- While hosting, periodically force NPCs/enemies to replicate so the
-- joining player can see them move. Single-player games usually never mark
-- their AI as network-relevant; this flips that switch at runtime.
-- If the game becomes unstable while hosting, try turning this off first.
Config.ForceReplication = true
Config.ReplicationFixIntervalMs = 5000

-- Single-player games often pause the world when the host opens a menu or
-- inventory - which would freeze the partner's game too. While hosting with
-- someone connected, the mod vetoes those pauses. Turn off if menus behave
-- strangely while hosting.
Config.KeepWorldRunning = true

-- ---------------------------------------------------------------------------
-- Debugging
-- ---------------------------------------------------------------------------

-- Extra log output in the UE4SS console. Leave on while the mod is young.
Config.VerboseLogging = true

return Config
