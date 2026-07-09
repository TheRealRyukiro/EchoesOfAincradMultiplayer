-- ============================================================================
-- AincradTogether v0.1.1
-- Co-op mod for Echoes of Aincrad (Unreal Engine 5), loaded via UE4SS.
--
-- How it works, in one paragraph: every packaged Unreal Engine game ships
-- with the engine's full client/server networking stack, even single-player
-- ones. This mod re-opens the current map as a listen server on the host
-- ("open <map>?listen") and points the second player's game at the host's
-- IP ("open <ip>:<port>"). Character movement replicates out of the box in
-- Unreal, so the two of you can see each other move. Two things always
-- break in games that were never meant to do this, and this mod patches
-- both at runtime: (1) the game usually refuses to spawn a body for the
-- second player, so we ask the GameMode to RestartPlayer() any player that
-- has no pawn; (2) NPCs/enemies are not marked as network-relevant, so we
-- flip bReplicates on them while hosting.
--
-- On top of that: an on-screen HUD with live ping (built from raw UMG
-- widgets, since shipping builds strip the usual debug-print paths, with a
-- console fallback), teleport helpers, a pause guard so the host's menus
-- don't freeze the partner's world, and a map-change watcher.
--
-- Everything here is defensive (pcall + validity checks) because the game
-- updates frequently and class layouts may shift; failures log loudly to
-- the UE4SS console instead of crashing.
-- ============================================================================

local Config = require("config")

local MOD_NAME = "AincradTogether"
local MOD_VERSION = "0.1.1"

-- ----------------------------------------------------------------------------
-- State
-- ----------------------------------------------------------------------------

local State = {
    Hosting = false,           -- we started a listen server
    Joining = false,           -- we connected (or tried to connect) to a host
    SpawnFixerRunning = false, -- the pawnless-player fixer loop is alive
    RepFixerRunning = false,   -- the replication fixer loop is alive
    PauseGuardRunning = false, -- the anti-pause loop is alive
    SessionStart = nil,        -- os.time() when hosting/joining began
    HudEnabled = true,         -- runtime toggle (F10), independent of config
    LastMapPath = nil,         -- for the map-change watcher
    UnpauseLogged = false,     -- log the first auto-unpause per session only
}

local Hud = {
    Widget = nil,     -- UUserWidget holding our text
    TextBlock = nil,  -- UTextBlock we write into
    Broken = false,   -- hard construction failure: stop trying, use console
    LastConsoleLine = nil, -- avoid spamming identical fallback lines
}

-- ----------------------------------------------------------------------------
-- Logging
-- ----------------------------------------------------------------------------

local function Log(Message)
    print(string.format("[%s] %s\n", MOD_NAME, Message))
end

local function Verbose(Message)
    if Config.VerboseLogging then
        Log(Message)
    end
end

-- ----------------------------------------------------------------------------
-- Engine object helpers
-- ----------------------------------------------------------------------------

local function GetKismetSystemLibrary()
    local Obj = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    if Obj and Obj:IsValid() then return Obj end
    return nil
end

local function GetGameplayStatics()
    local Obj = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    if Obj and Obj:IsValid() then return Obj end
    return nil
end

local function GetWidgetBlueprintLibrary()
    local Obj = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    if Obj and Obj:IsValid() then return Obj end
    return nil
end

-- Returns true if this PlayerController is driven by a keyboard/gamepad on
-- THIS machine (its .Player is a ULocalPlayer), false if it represents a
-- remote person connected over the network (its .Player is a UNetConnection).
local function IsLocalController(PlayerController)
    local Ok, Result = pcall(function()
        local Player = PlayerController.Player
        if Player and Player:IsValid() then
            return string.find(Player:GetClass():GetFullName(), "LocalPlayer", 1, true) ~= nil
        end
        return false
    end)
    return Ok and Result
end

local function GetLocalPlayerController()
    local Controllers = FindAllOf("PlayerController")
    if not Controllers then return nil end
    for _, PC in ipairs(Controllers) do
        if PC:IsValid() and IsLocalController(PC) then
            return PC
        end
    end
    -- Fall back to any valid controller so console commands still have a
    -- world context during odd transition states.
    for _, PC in ipairs(Controllers) do
        if PC:IsValid() then return PC end
    end
    return nil
end

local function GetRemoteControllers()
    local Remotes = {}
    local Controllers = FindAllOf("PlayerController") or {}
    for _, PC in ipairs(Controllers) do
        if PC:IsValid() and not IsLocalController(PC) then
            table.insert(Remotes, PC)
        end
    end
    return Remotes
end

local function ControllerHasPawn(PlayerController)
    local Ok, Result = pcall(function()
        local Pawn = PlayerController.Pawn
        return Pawn and Pawn:IsValid()
    end)
    return Ok and Result
end

local function GetControllerPawn(PlayerController)
    local Ok, Pawn = pcall(function() return PlayerController.Pawn end)
    if Ok and Pawn and Pawn:IsValid() then return Pawn end
    return nil
end

-- The GameMode object only exists on the machine with authority (the host,
-- or a plain single-player game). Nil on a joined client.
local function GetGameMode()
    local GS = GetGameplayStatics()
    local PC = GetLocalPlayerController()
    if not GS or not PC then return nil end
    local Ok, GM = pcall(function() return GS:GetGameMode(PC) end)
    if Ok and GM and GM:IsValid() then return GM end
    return nil
end

-- ----------------------------------------------------------------------------
-- Ping (Unreal measures this for us; PlayerState replicates to everyone)
-- ----------------------------------------------------------------------------

-- Returns ping in milliseconds, or nil if unknown. Tries the modern UE5
-- accessor first, then the replicated properties across engine versions:
-- CompressedPing/Ping are quantized to 4ms units, ExactPing is float ms.
local function GetPingMs(PlayerState)
    local Ok, Ms = pcall(function() return PlayerState:GetPingInMilliseconds() end)
    if Ok and type(Ms) == "number" and Ms > 0 then return math.floor(Ms + 0.5) end

    local OkE, Exact = pcall(function() return PlayerState.ExactPing end)
    if OkE and type(Exact) == "number" and Exact > 0 then return math.floor(Exact + 0.5) end

    local OkC, Compressed = pcall(function() return PlayerState.CompressedPing end)
    if OkC and type(Compressed) == "number" and Compressed > 0 then return Compressed * 4 end

    local OkP, Legacy = pcall(function() return PlayerState.Ping end)
    if OkP and type(Legacy) == "number" and Legacy > 0 then return Legacy * 4 end

    return nil
end

local function GetPlayerStateName(PlayerState)
    local Ok, Name = pcall(function() return PlayerState:GetPlayerName():ToString() end)
    if Ok and Name and Name ~= "" then return Name end
    return "Player"
end

-- Returns a list of { Name = string, PingMs = number|nil, IsLocal = bool }
-- for every player in the session, on host and client alike.
local function GetPlayerPingReport()
    local Report = {}
    local LocalPC = GetLocalPlayerController()
    local LocalPSName = nil
    if LocalPC then
        pcall(function()
            local PS = LocalPC.PlayerState
            if PS and PS:IsValid() then LocalPSName = PS:GetFullName() end
        end)
    end

    local PlayerStates = FindAllOf("PlayerState") or {}
    for _, PS in ipairs(PlayerStates) do
        if PS:IsValid() then
            local IsLocal = false
            pcall(function() IsLocal = (PS:GetFullName() == LocalPSName) end)
            table.insert(Report, {
                Name = GetPlayerStateName(PS),
                PingMs = GetPingMs(PS),
                IsLocal = IsLocal,
            })
        end
    end
    return Report
end

-- ----------------------------------------------------------------------------
-- Console command execution
-- ----------------------------------------------------------------------------

local function RunConsoleCommand(Command)
    local PC = GetLocalPlayerController()
    local KSL = GetKismetSystemLibrary()
    if not PC or not KSL then
        Log("Could not execute '" .. Command .. "' - no player controller yet. Load into the game first.")
        return false
    end
    Log("Executing: " .. Command)
    local Ok, Err = pcall(function()
        KSL:ExecuteConsoleCommand(PC, Command, PC)
    end)
    if not Ok then
        Log("ExecuteConsoleCommand failed: " .. tostring(Err))
        return false
    end
    return true
end

-- ----------------------------------------------------------------------------
-- Map name resolution
-- ----------------------------------------------------------------------------

-- Prefer the full package path ("/Game/Maps/L_Town01") because the console
-- "open" command resolves it unambiguously. Fall back to the short level
-- name if the world object is not readable for some reason.
local function GetCurrentMapPath()
    local PC = GetLocalPlayerController()
    if not PC then return nil end

    local OkWorld, World = pcall(function() return PC:GetWorld() end)
    if OkWorld and World and World:IsValid() then
        -- Full name looks like: "World /Game/Maps/Town/L_Town01.L_Town01"
        local FullName = World:GetFullName()
        local PackagePath = string.match(FullName, "(/%S+)%.")
        if PackagePath then return PackagePath end
    end

    local GS = GetGameplayStatics()
    if GS then
        local OkName, ShortName = pcall(function()
            return GS:GetCurrentLevelName(PC, true):ToString()
        end)
        if OkName and ShortName and ShortName ~= "" then return ShortName end
    end

    return nil
end

-- ----------------------------------------------------------------------------
-- On-screen HUD
--
-- Shipping builds compile out PrintString and the "stat" commands, so the
-- only reliable way to draw text is a real UMG widget. We build the world's
-- smallest one by hand through reflection: an empty UserWidget whose root is
-- a single TextBlock. If any step fails on this game's engine version, we
-- mark the HUD broken and mirror the same line to the UE4SS console instead.
-- ----------------------------------------------------------------------------

local SLATE_VISIBILITY_COLLAPSED = 1
local SLATE_VISIBILITY_SELF_HIT_TEST_INVISIBLE = 4

local function HudIsAlive()
    return Hud.Widget and Hud.Widget:IsValid() and Hud.TextBlock and Hud.TextBlock:IsValid()
end

local function TryCreateHud()
    if Hud.Broken or HudIsAlive() then return HudIsAlive() end
    if type(FText) ~= "function" then
        Hud.Broken = true
        Log("This UE4SS build has no FText constructor; HUD will use the console instead. (Update UE4SS to fix.)")
        return false
    end

    local PC = GetLocalPlayerController()
    if not PC then return false end -- not an error; try again later

    local Ok, Err = pcall(function()
        local WBL = GetWidgetBlueprintLibrary()
        assert(WBL, "WidgetBlueprintLibrary not found")
        local UserWidgetClass = StaticFindObject("/Script/UMG.UserWidget")
        assert(UserWidgetClass and UserWidgetClass:IsValid(), "UserWidget class not found")
        local TextBlockClass = StaticFindObject("/Script/UMG.TextBlock")
        assert(TextBlockClass and TextBlockClass:IsValid(), "TextBlock class not found")

        local Widget = WBL:Create(PC, UserWidgetClass, PC)
        assert(Widget and Widget:IsValid(), "widget creation returned nothing")

        local WidgetTree = Widget.WidgetTree
        assert(WidgetTree and WidgetTree:IsValid(), "widget has no WidgetTree")

        local TextBlock = StaticConstructObject(TextBlockClass, WidgetTree)
        assert(TextBlock and TextBlock:IsValid(), "TextBlock construction failed")

        WidgetTree.RootWidget = TextBlock
        Widget:AddToViewport(10000)
        pcall(function() Widget:SetVisibility(SLATE_VISIBILITY_SELF_HIT_TEST_INVISIBLE) end)
        TextBlock:SetText(FText(MOD_NAME))

        Hud.Widget = Widget
        Hud.TextBlock = TextBlock
    end)

    if not Ok then
        Hud.Broken = true
        Log("On-screen HUD unavailable on this game/engine version (" .. tostring(Err) .. ").")
        Log("Falling back to console output. Everything else works normally.")
        return false
    end
    Verbose("On-screen HUD created.")
    return true
end

local function FormatSessionClock()
    if not State.SessionStart or not os.time then return "" end
    local Elapsed = os.time() - State.SessionStart
    if Elapsed < 0 then return "" end
    return string.format(" | %02d:%02d:%02d", math.floor(Elapsed / 3600),
        math.floor(Elapsed / 60) % 60, Elapsed % 60)
end

local function BuildHudText()
    local Lines = {}
    if State.Hosting then
        local Remotes = GetRemoteControllers()
        if #Remotes == 0 then
            table.insert(Lines, "HOSTING - waiting for your partner to join" .. FormatSessionClock())
        else
            table.insert(Lines, string.format("HOSTING - %d player(s) connected%s", #Remotes + 1, FormatSessionClock()))
        end
    elseif State.Joining then
        table.insert(Lines, "CONNECTED" .. FormatSessionClock())
    else
        return nil -- solo: nothing to show
    end

    -- Ping is measured by whichever machine is the server, so each side
    -- shows the number that is real for it: the host shows the partner's
    -- ping, the client shows its own round-trip to the host.
    for _, Entry in ipairs(GetPlayerPingReport()) do
        local Ping = Entry.PingMs and (tostring(Entry.PingMs) .. " ms") or "..."
        if State.Joining and Entry.IsLocal then
            table.insert(Lines, "your ping: " .. Ping)
        elseif State.Hosting and not Entry.IsLocal then
            table.insert(Lines, string.format("%s: %s", Entry.Name, Ping))
        end
    end

    return table.concat(Lines, "\n")
end

local function UpdateHud()
    if not Config.ShowHud or not State.HudEnabled then
        if HudIsAlive() then
            pcall(function() Hud.Widget:SetVisibility(SLATE_VISIBILITY_COLLAPSED) end)
        end
        return
    end

    local Text = BuildHudText()
    if not Text then
        if HudIsAlive() then
            pcall(function() Hud.Widget:SetVisibility(SLATE_VISIBILITY_COLLAPSED) end)
        end
        return
    end

    if TryCreateHud() then
        pcall(function()
            Hud.Widget:SetVisibility(SLATE_VISIBILITY_SELF_HIT_TEST_INVISIBLE)
            Hud.TextBlock:SetText(FText(Text))
        end)
    else
        -- Console fallback: single-line version. Strip the session clock
        -- (it changes every second) and rate-limit, so we inform without
        -- flooding the console.
        local Flat = string.gsub(Text, "\n", "  |  ")
        Flat = string.gsub(Flat, " | %d+:%d%d:%d%d", "")
        local Now = os.time and os.time() or 0
        local ChangedEnough = Flat ~= Hud.LastConsoleLine
        local OldEnough = (Now - (Hud.LastConsoleTime or 0)) >= 30
        if ChangedEnough and OldEnough then
            Hud.LastConsoleLine = Flat
            Hud.LastConsoleTime = Now
            Log(Flat)
        end
    end
end

local function ToggleHud()
    State.HudEnabled = not State.HudEnabled
    Log("HUD " .. (State.HudEnabled and "shown" or "hidden"))
    UpdateHud()
end

-- ----------------------------------------------------------------------------
-- Teleport helpers
-- ----------------------------------------------------------------------------

-- Teleports TargetPawn next to AnchorPawn (small offset so they don't
-- overlap). Only meaningful on the machine with authority (the host).
local function TeleportPawnToPawn(TargetPawn, AnchorPawn)
    local Ok, Err = pcall(function()
        local Loc = AnchorPawn:K2_GetActorLocation()
        local Offset = Config.WarpOffset or 150
        local Dest = { X = Loc.X + Offset, Y = Loc.Y + Offset, Z = Loc.Z + 50 }
        TargetPawn:K2_TeleportTo(Dest, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    if not Ok then
        Log("Teleport failed: " .. tostring(Err))
        return false
    end
    return true
end

-- Finds (localPawn, remotePawn) or explains what's missing.
local function GetWarpPair()
    if not GetGameMode() then
        Log("Teleport commands only work on the machine that is HOSTING (it owns the world).")
        return nil, nil
    end
    local LocalPC = GetLocalPlayerController()
    local LocalPawn = LocalPC and GetControllerPawn(LocalPC) or nil
    local Remotes = GetRemoteControllers()
    local RemotePawn = nil
    for _, PC in ipairs(Remotes) do
        RemotePawn = GetControllerPawn(PC)
        if RemotePawn then break end
    end
    if not LocalPawn then Log("You have no body to teleport to/from right now.") end
    if not RemotePawn then Log("No partner with a body found. Are they connected? (coop_status)") end
    return LocalPawn, RemotePawn
end

local function WarpPartnerToMe()
    local LocalPawn, RemotePawn = GetWarpPair()
    if LocalPawn and RemotePawn and TeleportPawnToPawn(RemotePawn, LocalPawn) then
        Log("Brought your partner to you.")
    end
end

local function GoToPartner()
    local LocalPawn, RemotePawn = GetWarpPair()
    if LocalPawn and RemotePawn and TeleportPawnToPawn(LocalPawn, RemotePawn) then
        Log("Teleported you to your partner.")
    end
end

-- ----------------------------------------------------------------------------
-- Host-side fixup #1: spawn bodies for players that have none
-- ----------------------------------------------------------------------------

local function FixMissingPawns(ManualTrigger)
    local GameMode = GetGameMode()
    if not GameMode then
        if ManualTrigger then
            Log("No GameMode found - this command only works on the machine that is HOSTING.")
        end
        return
    end

    local LocalPC = GetLocalPlayerController()
    local HostPawn = LocalPC and GetControllerPawn(LocalPC) or nil

    local Controllers = FindAllOf("PlayerController") or {}
    for _, PC in ipairs(Controllers) do
        if PC:IsValid() and not ControllerHasPawn(PC) then
            local IsRemote = not IsLocalController(PC)
            -- Only auto-fix remote players; the host's own spawn is handled
            -- by the game's normal flow and interfering mid-load can fight
            -- it. A manual "coop_fixspawns" fixes everyone, host included.
            if IsRemote or ManualTrigger then
                Log("Player without a body detected (" .. PC:GetFullName() .. ") - asking the game to spawn one...")
                local OkRestart, Err = pcall(function()
                    GameMode:RestartPlayer(PC)
                end)
                if not OkRestart then
                    Log("RestartPlayer failed: " .. tostring(Err))
                    Log("If this keeps happening, run 'coop_status' and check docs/TROUBLESHOOTING.md.")
                elseif Config.SpawnAtHost and IsRemote and HostPawn then
                    -- The game spawned them at some PlayerStart, which could
                    -- be across the map. Pull them next to the host.
                    local NewPawn = GetControllerPawn(PC)
                    if NewPawn and TeleportPawnToPawn(NewPawn, HostPawn) then
                        Log("Moved the new player next to you.")
                    end
                end
            end
        end
    end
end

-- ----------------------------------------------------------------------------
-- Host-side fixup #2: make NPCs/enemies visible to the joining player
-- ----------------------------------------------------------------------------

local function ForceWorldReplication()
    if not State.Hosting then return end
    local Pawns = FindAllOf("Pawn")
    if not Pawns then return end

    local Flipped = 0
    for _, Pawn in ipairs(Pawns) do
        if Pawn:IsValid() then
            pcall(function()
                if not Pawn.bReplicates then
                    Pawn:SetReplicates(true)
                    Pawn:SetReplicateMovement(true)
                    Flipped = Flipped + 1
                end
            end)
        end
    end
    if Flipped > 0 then
        Verbose("Enabled replication on " .. Flipped .. " NPC(s)/pawn(s) so the other player can see them.")
    end
end

-- ----------------------------------------------------------------------------
-- Host-side fixup #3: keep the world running when the host opens a menu
--
-- Single-player games routinely pause the world for menus/inventory. On a
-- listen server that freezes the partner's game too, several times a minute.
-- While hosting with someone connected, veto the pause.
-- ----------------------------------------------------------------------------

local function KeepWorldRunning()
    if not State.Hosting or not Config.KeepWorldRunning then return end
    if #GetRemoteControllers() == 0 then return end -- nobody to protect

    local GS = GetGameplayStatics()
    local PC = GetLocalPlayerController()
    if not GS or not PC then return end

    pcall(function()
        if GS:IsGamePaused(PC) then
            GS:SetGamePaused(PC, false)
            if not State.UnpauseLogged then
                State.UnpauseLogged = true
                Log("The game tried to pause (menu?). Unpaused it so your partner's world keeps running.")
                Log("If this causes problems, set Config.KeepWorldRunning = false in config.lua.")
            end
        end
    end)
end

-- ----------------------------------------------------------------------------
-- Fixer loops (async timers; all UObject work is marshalled to the game thread)
-- ----------------------------------------------------------------------------

local function StartHostFixers()
    if Config.FixMissingPawns and not State.SpawnFixerRunning then
        State.SpawnFixerRunning = true
        LoopAsync(Config.SpawnFixIntervalMs or 2000, function()
            if not State.Hosting then
                State.SpawnFixerRunning = false
                return true -- stop the loop
            end
            ExecuteInGameThread(function() FixMissingPawns(false) end)
            return false
        end)
        Verbose("Spawn fixer started (every " .. tostring(Config.SpawnFixIntervalMs or 2000) .. "ms).")
    end

    if Config.ForceReplication and not State.RepFixerRunning then
        State.RepFixerRunning = true
        LoopAsync(Config.ReplicationFixIntervalMs or 5000, function()
            if not State.Hosting then
                State.RepFixerRunning = false
                return true -- stop the loop
            end
            ExecuteInGameThread(ForceWorldReplication)
            return false
        end)
        Verbose("Replication fixer started (every " .. tostring(Config.ReplicationFixIntervalMs or 5000) .. "ms).")
    end

    if Config.KeepWorldRunning and not State.PauseGuardRunning then
        State.PauseGuardRunning = true
        LoopAsync(300, function()
            if not State.Hosting then
                State.PauseGuardRunning = false
                return true -- stop the loop
            end
            ExecuteInGameThread(KeepWorldRunning)
            return false
        end)
        Verbose("Pause guard started.")
    end
end

-- ----------------------------------------------------------------------------
-- The main actions: Host / Join / Stop / Status
-- ----------------------------------------------------------------------------

local function HostSession()
    local Map = GetCurrentMapPath()
    if not Map then
        Log("Cannot host: no map loaded yet. Load into the game world first, then press Host.")
        return
    end
    Log("Hosting on map: " .. Map .. " (the map will reload - this is normal)")
    Log("Your partner should now press Join, with your IP in their config.lua.")
    State.Hosting = true
    State.Joining = false
    State.SessionStart = os.time and os.time() or nil
    State.UnpauseLogged = false
    if RunConsoleCommand("open " .. Map .. "?listen") then
        StartHostFixers()
    else
        State.Hosting = false
        State.SessionStart = nil
    end
end

local function JoinSession(Address)
    Address = Address or Config.HostAddress
    if not Address or Address == "" then
        Log("Cannot join: no address. Set Config.HostAddress in config.lua or use: coop_join <ip>")
        return
    end
    -- Append the default port if the user only gave an IP/hostname.
    if not string.find(Address, ":", 1, true) then
        Address = Address .. ":" .. tostring(Config.Port or 7777)
    end
    Log("Joining " .. Address .. " ...")
    State.Joining = true
    State.Hosting = false
    State.SessionStart = os.time and os.time() or nil
    RunConsoleCommand("open " .. Address)
end

local function StopSession()
    Log("Leaving co-op session (you will likely return to the main menu)...")
    State.Hosting = false
    State.Joining = false
    State.SessionStart = nil
    RunConsoleCommand("disconnect")
end

local function PrintPings()
    local Report = GetPlayerPingReport()
    if #Report == 0 then
        Log("No players found (not in a session, or still loading).")
        return
    end
    for _, Entry in ipairs(Report) do
        local Who = Entry.IsLocal and " (you)" or ""
        local Ping = Entry.PingMs and (tostring(Entry.PingMs) .. " ms") or "unknown"
        Log(string.format("  %s%s - ping: %s", Entry.Name, Who, Ping))
    end
    if State.Hosting then
        Log("(Host's own ping is ~0 by definition; the number that matters is your partner's.)")
    end
end

local function PrintStatus()
    Log("=== " .. MOD_NAME .. " v" .. MOD_VERSION .. " status ===")
    Log("Mode: " .. (State.Hosting and "HOSTING" or (State.Joining and "JOINED/JOINING" or "single-player")))
    Log("Current map: " .. tostring(GetCurrentMapPath()))
    Log("Fixers: spawn=" .. tostring(State.SpawnFixerRunning) ..
        " replication=" .. tostring(State.RepFixerRunning) ..
        " pause-guard=" .. tostring(State.PauseGuardRunning))
    Log("HUD: " .. (Hud.Broken and "console fallback" or (HudIsAlive() and "on-screen" or "not created yet")))

    local Controllers = FindAllOf("PlayerController") or {}
    Log("Player controllers in world: " .. tostring(#Controllers))
    for Index, PC in ipairs(Controllers) do
        if PC:IsValid() then
            local Where = IsLocalController(PC) and "local" or "REMOTE"
            local Body = ControllerHasPawn(PC) and "has body" or "NO BODY"
            local PawnClass = "?"
            pcall(function()
                if PC.Pawn and PC.Pawn:IsValid() then
                    PawnClass = PC.Pawn:GetClass():GetFullName()
                end
            end)
            Log(string.format("  #%d [%s, %s] %s | pawn class: %s", Index, Where, Body, PC:GetFullName(), PawnClass))
        end
    end

    Log("Players/pings:")
    PrintPings()

    if GetGameMode() then
        Log("GameMode (=> this machine has authority): " .. GetGameMode():GetFullName())
    else
        Log("GameMode: none visible (normal when you are the JOINING player)")
    end
    Log("=== end status ===")
end

-- ----------------------------------------------------------------------------
-- Background tick: HUD refresh + map-change watcher (always running, cheap)
-- ----------------------------------------------------------------------------

local function CheckMapChange()
    local Map = GetCurrentMapPath()
    if not Map or Map == State.LastMapPath then return end
    local Previous = State.LastMapPath
    State.LastMapPath = Map
    if not Previous then return end -- first observation, not a change

    Verbose("Map changed: " .. Previous .. " -> " .. Map)
    if State.Hosting then
        Log("Map changed while hosting. If the game itself triggered this (story/floor")
        Log("transition), the co-op session may have been dropped: have your partner run")
        Log("coop_status - and if they're gone, press " .. tostring(Config.Keybinds.Host) ..
            " to re-host, then they rejoin with " .. tostring(Config.Keybinds.Join) .. ".")
    elseif State.Joining then
        Log("Map changed. If you were kicked to the main menu, the host's session ended")
        Log("or the connection dropped - press " .. tostring(Config.Keybinds.Join) .. " to rejoin.")
    end
end

LoopAsync(Config.HudIntervalMs or 1000, function()
    ExecuteInGameThread(function()
        pcall(UpdateHud)
        pcall(CheckMapChange)
    end)
    return false -- never stops
end)

-- ----------------------------------------------------------------------------
-- Wiring: keybinds, console commands, join notifications
-- ----------------------------------------------------------------------------

local function BindKey(KeyName, Action, Description)
    if not KeyName then return end
    local KeyCode = Key[KeyName]
    if not KeyCode then
        Log("Unknown key name in config.lua: '" .. tostring(KeyName) .. "' (" .. Description .. " keybind disabled)")
        return
    end
    RegisterKeyBind(KeyCode, function()
        ExecuteInGameThread(Action)
    end)
    Verbose("Bound " .. KeyName .. " -> " .. Description)
end

BindKey(Config.Keybinds.Host, HostSession, "Host session")
BindKey(Config.Keybinds.Join, function() JoinSession(nil) end, "Join session")
BindKey(Config.Keybinds.Status, PrintStatus, "Print status")
BindKey(Config.Keybinds.ToggleHud, ToggleHud, "Toggle HUD")

local SimpleCommands = {
    coop_host      = HostSession,
    coop_stop      = StopSession,
    coop_status    = PrintStatus,
    coop_ping      = PrintPings,
    coop_hud       = ToggleHud,
    coop_warp      = WarpPartnerToMe,
    coop_goto      = GoToPartner,
    coop_fixspawns = function() FixMissingPawns(true) end,
}

for CommandName, Action in pairs(SimpleCommands) do
    RegisterConsoleCommandHandler(CommandName, function(_FullCommand, _Parameters, _Ar)
        ExecuteInGameThread(Action)
        return true
    end)
end

RegisterConsoleCommandHandler("coop_join", function(_FullCommand, Parameters, _Ar)
    local Address = Parameters[1]
    ExecuteInGameThread(function() JoinSession(Address) end)
    return true
end)

-- Cheerful feedback on the host when the partner's connection creates a
-- controller. Fires for the game's derived PlayerController class too.
NotifyOnNewObject("/Script/Engine.PlayerController", function(NewController)
    if State.Hosting then
        ExecuteInGameThread(function()
            local Ok, Name = pcall(function() return NewController:GetFullName() end)
            Log("A player joined! New controller: " .. (Ok and Name or "<unreadable>"))
            Log("If they are stuck invisible, wait ~" .. tostring((Config.SpawnFixIntervalMs or 2000) / 1000) ..
                "s for the spawn fixer, or run 'coop_fixspawns'.")
        end)
    end
end)

-- ----------------------------------------------------------------------------
-- Banner
-- ----------------------------------------------------------------------------

Log(MOD_NAME .. " v" .. MOD_VERSION .. " loaded.")
Log("Keys: " .. tostring(Config.Keybinds.Host) .. "=Host  " ..
    tostring(Config.Keybinds.Join) .. "=Join  " ..
    tostring(Config.Keybinds.Status) .. "=Status  " ..
    tostring(Config.Keybinds.ToggleHud) .. "=HUD on/off")
Log("Console commands: coop_host, coop_join <ip>, coop_stop, coop_status, coop_ping,")
Log("                  coop_hud, coop_warp (partner->you), coop_goto (you->partner), coop_fixspawns")
Log("Default join address (config.lua): " .. tostring(Config.HostAddress) .. ":" .. tostring(Config.Port))
