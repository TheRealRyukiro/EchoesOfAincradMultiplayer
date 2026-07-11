-- ============================================================================
-- AincradTogether (version: see MOD_VERSION below)
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
local MOD_VERSION = "0.2.0-dev"

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
    HudEnabled = true,         -- runtime toggle (ToggleHud key), independent of config
    LastMapPath = nil,         -- for the map-change watcher
    UnpauseLogged = false,     -- log the first auto-unpause per session only
    RefreshDueAt = nil,        -- os.time() when a one-time post-travel refresh runs
    -- Session resilience (v0.2):
    LastJoinAddress = nil,     -- last address we joined, for auto-reconnect
    WasConnected = false,      -- guest: we saw the host's PlayerState at least once
    LastRemoteCount = 0,       -- host: remote players seen last tick
    ReconnectDueAt = nil,      -- os.time() of the next auto-reconnect attempt
    ReconnectAttemptsLeft = nil,
    RehostDueAt = nil,         -- os.time() when the host auto-re-hosts after travel
    SelfTravelUntil = nil,     -- map changes before this time are our own doing
}

-- Object scans (FindAllOf) walk the entire engine object array - expensive
-- enough in a big open world to hitch the game when done on a timer (v0.1.2
-- scanned once per second: the cause of the periodic stutter while hosting).
-- v0.1.3 is event-driven instead: UE4SS notifies us when controllers, player
-- states and pawns are constructed; the master tick only classifies, prunes
-- and renders. Full scans happen exactly three ways: shortly after a session
-- starts, after a map change, and on manual console commands.
local Cache = {
    LocalPC = nil,           -- last known local PlayerController
    Remotes = {},            -- remote (network) PlayerControllers
    PlayerStates = {},       -- event-fed, validity-pruned
    PendingControllers = {}, -- constructed, awaiting local/remote verdict
    PendingPawns = {},       -- constructed while hosting, awaiting bReplicates
    LastScanAt = 0,          -- rate limit for fallback full scans
}

local Hud = {
    Widget = nil,     -- UUserWidget holding our text
    TextBlock = nil,  -- UTextBlock we write into
    Broken = false,   -- construction keeps failing: use console until next map
    Attempts = 0,     -- construction attempts on the current map
    LastConsoleLine = nil, -- avoid spamming identical fallback lines
    LastConsoleTime = 0,   -- rate limit for the console fallback
}
local HUD_MAX_ATTEMPTS_PER_MAP = 3

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

-- One full controller scan; refreshes the shared cache. Expensive - called
-- only at session start / map change / manual commands (Force), or as a
-- rate-limited fallback when the cache is empty.
local function RefreshControllerCache(Force)
    local Now = os.time and os.time() or 0
    if not Force and (Now - Cache.LastScanAt) < 5 then return end
    Cache.LastScanAt = Now
    Cache.LocalPC = nil
    Cache.Remotes = {}
    local Controllers = FindAllOf("PlayerController")
    if not Controllers then return end
    local AnyValid = nil
    for _, PC in ipairs(Controllers) do
        if PC:IsValid() then
            AnyValid = AnyValid or PC
            if IsLocalController(PC) then
                Cache.LocalPC = Cache.LocalPC or PC
            else
                table.insert(Cache.Remotes, PC)
            end
        end
    end
    -- Fall back to any valid controller so console commands still have a
    -- world context during odd transition states.
    Cache.LocalPC = Cache.LocalPC or AnyValid
end

local function GetLocalPlayerController()
    if Cache.LocalPC and Cache.LocalPC:IsValid() then
        return Cache.LocalPC
    end
    RefreshControllerCache()
    return Cache.LocalPC
end

local function GetRemoteControllers()
    -- Served from the cache (refreshed every master tick); prune anything
    -- that died since. Cheap enough for the 300ms pause guard.
    local Alive = {}
    for _, PC in ipairs(Cache.Remotes) do
        if PC:IsValid() then table.insert(Alive, PC) end
    end
    return Alive
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

local function RefreshPlayerStateCache()
    Cache.PlayerStates = FindAllOf("PlayerState") or {}
end

-- Returns a list of { Name = string, PingMs = number|nil, IsLocal = bool }
-- for every player in the session, on host and client alike. Reads the
-- cached PlayerState list unless FreshScan is set (manual commands).
local function GetPlayerPingReport(FreshScan)
    local Report = {}
    local LocalPC = GetLocalPlayerController()
    local LocalPSName = nil
    if LocalPC then
        pcall(function()
            local PS = LocalPC.PlayerState
            if PS and PS:IsValid() then LocalPSName = PS:GetFullName() end
        end)
    end

    if FreshScan or #Cache.PlayerStates == 0 then
        RefreshPlayerStateCache()
    end
    local PlayerStates = Cache.PlayerStates
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

-- Some UE4SS builds (including the community one for this game) ship without
-- the Lua FText constructor. The engine can still make an FText for us
-- through reflection, so try both paths.
local function MakeText(Str)
    if type(FText) == "function" then
        local Ok, Result = pcall(FText, Str)
        if Ok and Result then return Result end
    end
    local KTL = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    if KTL and KTL:IsValid() then
        local Ok, Result = pcall(function() return KTL:Conv_StringToText(Str) end)
        if Ok and Result then return Result end
    end
    return nil
end

local function TryCreateHud()
    if Hud.Broken or HudIsAlive() then return HudIsAlive() end
    if not MakeText(MOD_NAME) then
        Hud.Broken = true
        if not Hud.NoTextWarned then
            Hud.NoTextWarned = true
            Log("No way to build FText on this UE4SS build; HUD will use the console instead.")
        end
        return false
    end

    local PC = GetLocalPlayerController()
    if not PC then return false end -- not an error; try again later

    Hud.Attempts = Hud.Attempts + 1

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
        -- Slightly translucent so the corner watermark reads as an overlay,
        -- not game UI. Best-effort: not all builds expose it.
        pcall(function() Widget:SetRenderOpacity(0.85) end)
        TextBlock:SetText(MakeText(MOD_NAME))

        Hud.Widget = Widget
        Hud.TextBlock = TextBlock
    end)

    if not Ok then
        Log("On-screen HUD attempt " .. Hud.Attempts .. " failed (" .. tostring(Err) .. ").")
        if Hud.Attempts >= HUD_MAX_ATTEMPTS_PER_MAP then
            -- Give up on this map; a map change resets the counter and we
            -- try again (some maps/loading states can't host widgets).
            Hud.Broken = true
            Log("Falling back to console output until the next map change. Everything else works normally.")
        end
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

    -- Permanent corner watermark: always the first line, visible in and out
    -- of sessions (F6 hides the whole HUD; Config.ShowWatermark disables
    -- just this line).
    if Config.ShowWatermark ~= false then
        table.insert(Lines, MOD_NAME .. " v" .. MOD_VERSION)
    end

    if State.Hosting then
        local Remotes = GetRemoteControllers()
        if #Remotes == 0 then
            table.insert(Lines, "HOSTING - waiting for your partner to join" .. FormatSessionClock())
        else
            table.insert(Lines, string.format("HOSTING - %d player(s) connected%s", #Remotes + 1, FormatSessionClock()))
        end
    elseif State.Joining then
        table.insert(Lines, "CONNECTED" .. FormatSessionClock())
    end

    -- Ping is measured by whichever machine is the server, so each side
    -- shows the number that is real for it: the host shows the partner's
    -- ping, the client shows its own round-trip to the host. (Session only:
    -- solo must not touch the PlayerState cache, which could trigger scans.)
    if State.Hosting or State.Joining then
        for _, Entry in ipairs(GetPlayerPingReport()) do
            local Ping = Entry.PingMs and (tostring(Entry.PingMs) .. " ms") or "..."
            if State.Joining and Entry.IsLocal then
                table.insert(Lines, "your ping: " .. Ping)
            elseif State.Hosting and not Entry.IsLocal then
                table.insert(Lines, string.format("%s: %s", Entry.Name, Ping))
            end
        end
    end

    if #Lines == 0 then return nil end
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
            local AsText = MakeText(Text)
            if AsText then Hud.TextBlock:SetText(AsText) end
        end)
    else
        -- Console fallback: single-line version. Only while in a session (a
        -- watermark line alone is pointless in a log), stripped of the
        -- session clock (it changes every second) and rate-limited, so we
        -- inform without flooding the console.
        if not (State.Hosting or State.Joining) then return end
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
-- Nameplates: floating names above other players (v0.2)
--
-- Targeting is symmetric on host and guest: every PlayerState except the
-- local one belongs to another human, and its reflected PawnPrivate property
-- points at their body. Each such pawn gets an engine TextRenderActor
-- attached above its head (KeepWorld attachment preserves the offset while
-- the pawn moves), refreshed once per master tick.
-- ----------------------------------------------------------------------------

local Nameplates = {
    ByPawn = {},        -- pawn full name -> { Plate = TextRenderActor, Pawn = pawn }
    Broken = false,     -- hard spawn failure: feature disables itself
}

local EATTACH_RULE_KEEP_WORLD = 1        -- EAttachmentRule::KeepWorld
local ESPAWN_ALWAYS_SPAWN = 1            -- ESpawnActorCollisionHandlingMethod::AlwaysSpawn

local function DestroyNameplate(Entry)
    pcall(function()
        if Entry.Plate and Entry.Plate:IsValid() then
            Entry.Plate:K2_DestroyActor()
        end
    end)
end

local function DestroyAllNameplates()
    for _, Entry in pairs(Nameplates.ByPawn) do
        DestroyNameplate(Entry)
    end
    Nameplates.ByPawn = {}
end

local function SpawnNameplate(Pawn, Name)
    local GS = GetGameplayStatics()
    local PC = GetLocalPlayerController()
    local PlateClass = StaticFindObject("/Script/Engine.TextRenderActor")
    if not (GS and PC and PlateClass and PlateClass:IsValid()) then return nil end

    local Ok, PlateOrErr = pcall(function()
        local Loc = Pawn:K2_GetActorLocation()
        local Transform = {
            Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
            Translation = { X = Loc.X, Y = Loc.Y, Z = Loc.Z + (Config.NameplateHeight or 120) },
            Scale3D = { X = 1, Y = 1, Z = 1 },
        }
        local Plate = GS:BeginDeferredActorSpawnFromClass(PC, PlateClass, Transform, ESPAWN_ALWAYS_SPAWN, PC)
        if not (Plate and Plate:IsValid()) then error("spawn returned nothing") end
        GS:FinishSpawningActor(Plate, Transform)
        Plate:K2_AttachToActor(Pawn, "None",
            EATTACH_RULE_KEEP_WORLD, EATTACH_RULE_KEEP_WORLD, EATTACH_RULE_KEEP_WORLD, false)
        local TextComp = Plate.TextRender
        if TextComp and TextComp:IsValid() then
            local AsText = MakeText(Name)
            if AsText then TextComp:SetText(AsText) end
            pcall(function() TextComp:SetHorizontalAlignment(1) end) -- EHTA_Center
            pcall(function() TextComp:SetWorldSize(Config.NameplateSize or 24) end)
            pcall(function() TextComp:SetTextRenderColor({ R = 255, G = 235, B = 130, A = 255 }) end)
        end
        return Plate
    end)

    if not Ok or not PlateOrErr then
        if not Nameplates.Broken then
            Nameplates.Broken = true
            Log("Nameplates unavailable on this build (" .. tostring(PlateOrErr) .. ") - feature disabled.")
            Log("(Everything else keeps working. Set Config.Nameplates = false to silence.)")
        end
        return nil
    end
    return PlateOrErr
end

local function UpdateNameplates()
    if Nameplates.Broken or Config.Nameplates == false then return end
    if not (State.Hosting or State.Joining) then
        if next(Nameplates.ByPawn) then DestroyAllNameplates() end
        return
    end

    local LocalPC = GetLocalPlayerController()
    if not LocalPC then return end
    local LocalPSName = nil
    pcall(function()
        local PS = LocalPC.PlayerState
        if PS and PS:IsValid() then LocalPSName = PS:GetFullName() end
    end)

    -- Which pawns should carry a plate right now?
    local Wanted = {} -- pawn full name -> { Pawn = pawn, Name = player name }
    for _, PS in ipairs(Cache.PlayerStates) do
        pcall(function()
            if not PS:IsValid() then return end
            if LocalPSName and PS:GetFullName() == LocalPSName then return end
            local Pawn = PS.PawnPrivate
            if Pawn and Pawn:IsValid() then
                Wanted[Pawn:GetFullName()] = { Pawn = Pawn, Name = GetPlayerStateName(PS) }
            end
        end)
    end

    -- Drop plates whose pawn vanished or is no longer another player's.
    for PawnName, Entry in pairs(Nameplates.ByPawn) do
        local PawnAlive, PlateAlive = false, false
        pcall(function() PawnAlive = Entry.Pawn:IsValid() end)
        pcall(function() PlateAlive = Entry.Plate:IsValid() end)
        if not Wanted[PawnName] or not PawnAlive or not PlateAlive then
            DestroyNameplate(Entry)
            Nameplates.ByPawn[PawnName] = nil
        end
    end

    -- Create missing plates.
    for PawnName, Want in pairs(Wanted) do
        if not Nameplates.ByPawn[PawnName] then
            local Plate = SpawnNameplate(Want.Pawn, Want.Name)
            if Plate then
                Nameplates.ByPawn[PawnName] = { Plate = Plate, Pawn = Want.Pawn }
                Verbose("Nameplate created for " .. Want.Name)
            end
            if Nameplates.Broken then return end
        end
    end

    -- Turn the text toward the local camera (yaw only), best-effort.
    pcall(function()
        local Cam = LocalPC.PlayerCameraManager
        if not (Cam and Cam:IsValid()) then return end
        local CamLoc = Cam:GetCameraLocation()
        for _, Entry in pairs(Nameplates.ByPawn) do
            pcall(function()
                if Entry.Plate:IsValid() then
                    local Loc = Entry.Plate:K2_GetActorLocation()
                    local Yaw = math.deg(math.atan(CamLoc.Y - Loc.Y, CamLoc.X - Loc.X))
                    Entry.Plate:K2_SetActorRotation({ Pitch = 0, Yaw = Yaw, Roll = 0 }, false)
                end
            end)
        end
    end)
end

-- ----------------------------------------------------------------------------
-- Host-side fixup #1: spawn bodies for players that have none
-- ----------------------------------------------------------------------------

local function FixMissingPawns(ManualTrigger)
    -- A manual coop_fixspawns deserves fresh data, not the event-fed cache.
    if ManualTrigger then RefreshControllerCache(true) end
    local GameMode = GetGameMode()
    if not GameMode then
        if ManualTrigger then
            Log("No GameMode found - this command only works on the machine that is HOSTING.")
        end
        return
    end

    local LocalPC = GetLocalPlayerController()
    local HostPawn = LocalPC and GetControllerPawn(LocalPC) or nil

    -- Reads the cached controller list (refreshed every second) rather than
    -- rescanning the whole object array on each fixer pass.
    local Controllers = {}
    if Cache.LocalPC and Cache.LocalPC:IsValid() then table.insert(Controllers, Cache.LocalPC) end
    for _, PC in ipairs(Cache.Remotes) do table.insert(Controllers, PC) end
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

    -- Replication is handled event-driven (new pawns are flipped as they
    -- spawn); this slow sweep is just a safety net for stragglers, and can
    -- be disabled by setting the interval to 0.
    local SweepMs = Config.ReplicationSweepIntervalMs or 30000
    if Config.ForceReplication and SweepMs > 0 and not State.RepFixerRunning then
        State.RepFixerRunning = true
        LoopAsync(SweepMs, function()
            if not State.Hosting then
                State.RepFixerRunning = false
                return true -- stop the loop
            end
            ExecuteInGameThread(ForceWorldReplication)
            return false
        end)
        Verbose("Replication safety sweep started (every " .. tostring(SweepMs) .. "ms).")
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
    -- The ?listen reload keeps the same map path, so the map-change watcher
    -- won't fire: schedule the one-time post-travel cache refresh explicitly.
    -- Also mark the upcoming travel as self-inflicted so the auto-rehost
    -- logic never reacts to its own reload.
    State.RefreshDueAt = (os.time and os.time() or 0) + 3
    State.SelfTravelUntil = (os.time and os.time() or 0) + 30
    if RunConsoleCommand("open " .. Map .. "?listen") then
        StartHostFixers()
    else
        State.Hosting = false
        State.SessionStart = nil
        State.RefreshDueAt = nil
    end
end

local function JoinSession(Address)
    -- The #1 solo-testing accident: pressing Join on the machine that is
    -- already hosting connects the game to itself and tears the session
    -- down. One game instance cannot be host and client at once.
    if State.Hosting then
        Log("You are currently HOSTING - joining from this same game would end your session.")
        Log("Your partner presses Join on THEIR machine. (To switch roles here, run coop_stop first.)")
        return
    end
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
    State.RefreshDueAt = (os.time and os.time() or 0) + 5
    -- Resilience bookkeeping: remember where we're going for auto-reconnect,
    -- mark the connect travel as self-inflicted, reset connected-ness.
    State.LastJoinAddress = Address
    State.WasConnected = false
    State.SelfTravelUntil = (os.time and os.time() or 0) + 30
    RunConsoleCommand("open " .. Address)
end

local function StopSession()
    Log("Leaving co-op session (you will likely return to the main menu)...")
    State.Hosting = false
    State.Joining = false
    State.SessionStart = nil
    -- Cancel any pending resilience work: leaving is intentional.
    State.ReconnectDueAt = nil
    State.ReconnectAttemptsLeft = nil
    State.RehostDueAt = nil
    State.WasConnected = false
    State.LastRemoteCount = 0
    State.SelfTravelUntil = (os.time and os.time() or 0) + 30
    RunConsoleCommand("disconnect")
end

local function PrintPings()
    local Report = GetPlayerPingReport(true)
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

    -- New world: cached objects are stale, and a HUD that could not be
    -- built on the previous map deserves another shot here. Schedule the
    -- one-time full refresh for once the new world has settled.
    Cache.LocalPC = nil
    Cache.Remotes = {}
    Cache.PlayerStates = {}
    Cache.PendingControllers = {}
    Cache.PendingPawns = {}
    Hud.Broken = false
    Hud.Attempts = 0
    State.RefreshDueAt = (os.time and os.time() or 0) + 2

    if not Previous then return end -- first observation, not a change

    Verbose("Map changed: " .. Previous .. " -> " .. Map)
    local Now = os.time and os.time() or 0
    local SelfTravel = State.SelfTravelUntil and Now < State.SelfTravelUntil

    if State.Hosting then
        Log("Map changed while hosting. If the game itself triggered this (story/floor")
        Log("transition), the co-op session may have been dropped: have your partner run")
        Log("coop_status - and if they're gone, press " .. tostring(Config.Keybinds.Host) ..
            " to re-host, then they rejoin with " .. tostring(Config.Keybinds.Join) .. ".")
        -- Auto-rehost (v0.2): a game-initiated travel with a partner attached
        -- almost certainly dropped the session; re-open it automatically.
        if Config.AutoRehost and not SelfTravel and (State.LastRemoteCount or 0) > 0 then
            State.RehostDueAt = Now + 5
            Log("Auto-rehost armed: re-opening the session in ~5s (Config.AutoRehost).")
        end
    elseif State.Joining then
        Log("Map changed. If you were kicked to the main menu, the host's session ended")
        Log("or the connection dropped - press " .. tostring(Config.Keybinds.Join) .. " to rejoin.")
        -- Auto-reconnect (v0.2): only after we were genuinely connected, and
        -- never for our own connect travel.
        if Config.AutoReconnect and State.WasConnected and not SelfTravel and State.LastJoinAddress then
            State.ReconnectAttemptsLeft = Config.AutoReconnectAttempts or 3
            State.ReconnectDueAt = Now + (Config.AutoReconnectDelayS or 8)
            State.WasConnected = false
            Log("Auto-reconnect armed: retrying " .. State.LastJoinAddress .. " shortly (Config.AutoReconnect).")
        end
    end
end

-- Keeps only valid, unique objects (a construction event and a full scan
-- can both insert the same object).
local function PruneObjectList(List)
    local Alive, Seen = {}, {}
    for _, Obj in ipairs(List) do
        pcall(function()
            if Obj:IsValid() then
                local Name = Obj:GetFullName()
                if not Seen[Name] then
                    Seen[Name] = true
                    table.insert(Alive, Obj)
                end
            end
        end)
    end
    return Alive
end

-- New controllers get classified once their .Player resolves: local ones
-- refresh the cached local controller (recreated on every map load), remote
-- ones enter the cache and - while hosting - get announced as a real join.
local function ProcessPendingControllers()
    if #Cache.PendingControllers == 0 then return end
    local Remaining = {}
    for _, Entry in ipairs(Cache.PendingControllers) do
        Entry.Ticks = Entry.Ticks + 1
        local PC = Entry.PC
        local Ok, Classified = pcall(function()
            if not PC:IsValid() then return true end -- died before classification
            local Player = PC.Player
            if not (Player and Player:IsValid()) then return false end -- not classified yet
            if IsLocalController(PC) then
                Cache.LocalPC = PC
            else
                table.insert(Cache.Remotes, PC)
                if State.Hosting then
                    Log("A player joined! Controller: " .. PC:GetFullName())
                    Log("If they seem invisible, give the spawn fixer a couple of seconds, or run 'coop_fixspawns'.")
                end
            end
            return true
        end)
        local Done = (Ok and Classified) or Entry.Ticks > 10
        if not Done then table.insert(Remaining, Entry) end
    end
    Cache.PendingControllers = Remaining
end

-- Pawns spawned while hosting get their replication flag flipped one tick
-- after construction (flipping during construction is too early).
local function ProcessPendingPawns()
    if #Cache.PendingPawns == 0 then return end
    if not State.Hosting then
        Cache.PendingPawns = {}
        return
    end
    local Flipped = 0
    for _, Pawn in ipairs(Cache.PendingPawns) do
        pcall(function()
            if Pawn:IsValid() and not Pawn.bReplicates then
                Pawn:SetReplicates(true)
                Pawn:SetReplicateMovement(true)
                Flipped = Flipped + 1
            end
        end)
    end
    Cache.PendingPawns = {}
    if Flipped > 0 then
        Verbose("Enabled replication on " .. Flipped .. " newly spawned pawn(s).")
    end
end

LoopAsync(Config.HudIntervalMs or 1000, function()
    ExecuteInGameThread(function()
        -- No object scans here - just classify, prune, render, watch.
        local Now = os.time and os.time() or 0
        pcall(function()
            Cache.Remotes = PruneObjectList(Cache.Remotes)
            Cache.PlayerStates = PruneObjectList(Cache.PlayerStates)
            if Cache.LocalPC and not Cache.LocalPC:IsValid() then Cache.LocalPC = nil end
        end)
        if State.RefreshDueAt and Now >= State.RefreshDueAt then
            -- The one-time post-travel full refresh (session start/map load).
            State.RefreshDueAt = nil
            pcall(function() RefreshControllerCache(true) end)
            if State.Hosting or State.Joining then pcall(RefreshPlayerStateCache) end
            if State.Hosting and Config.ForceReplication then pcall(ForceWorldReplication) end
        end
        pcall(ProcessPendingControllers)
        pcall(ProcessPendingPawns)

        -- Session resilience (v0.2): connected-ness tracking + deferred
        -- rehost/reconnect execution.
        pcall(function()
            if State.Hosting then
                State.LastRemoteCount = #GetRemoteControllers()
            elseif State.Joining and #Cache.PlayerStates > 1 then
                State.WasConnected = true
            end

            if State.RehostDueAt and Now >= State.RehostDueAt then
                State.RehostDueAt = nil
                if State.Hosting then
                    Log("Auto-rehost: re-opening the co-op session after the map change...")
                    HostSession()
                end
            end

            if State.ReconnectDueAt and Now >= State.ReconnectDueAt then
                State.ReconnectDueAt = nil
                if not State.Joining then
                    State.ReconnectAttemptsLeft = nil
                elseif State.WasConnected then
                    Log("Auto-reconnect: connection re-established.")
                    State.ReconnectAttemptsLeft = nil
                elseif (State.ReconnectAttemptsLeft or 0) > 0 then
                    State.ReconnectAttemptsLeft = State.ReconnectAttemptsLeft - 1
                    Log("Auto-reconnect: rejoining " .. tostring(State.LastJoinAddress) ..
                        " (" .. tostring(State.ReconnectAttemptsLeft) .. " attempts left after this)...")
                    JoinSession(State.LastJoinAddress)
                    State.ReconnectDueAt = Now + (Config.AutoReconnectDelayS or 8)
                else
                    Log("Auto-reconnect gave up. Press " .. tostring(Config.Keybinds.Join) .. " to retry manually.")
                end
            end
        end)

        pcall(UpdateHud)
        pcall(UpdateNameplates)
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

-- F10 opens the in-game console (UE4SS ConsoleEnabler), so binding the HUD
-- there - as old config.lua versions did - collides with it. Auto-remap.
local HudKeyName = Config.Keybinds.ToggleHud
if HudKeyName == "F10" then
    Log("config.lua binds the HUD toggle to F10, which opens the in-game console - using F6 instead.")
    Log("(Edit Config.Keybinds.ToggleHud in config.lua to silence this.)")
    HudKeyName = "F6"
end
BindKey(HudKeyName, ToggleHud, "Toggle HUD")

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

-- Console commands already execute on the game thread, so run the action
-- directly - and acknowledge into the in-game console so there's visible
-- feedback right where the command was typed.
local function AckToConsole(Ar, CommandName)
    pcall(function()
        Ar:Log("[" .. MOD_NAME .. "] " .. CommandName .. " executed - details in the UE4SS console/log.")
    end)
end

for CommandName, Action in pairs(SimpleCommands) do
    RegisterConsoleCommandHandler(CommandName, function(_FullCommand, _Parameters, Ar)
        pcall(Action)
        AckToConsole(Ar, CommandName)
        return true
    end)
end

RegisterConsoleCommandHandler("coop_join", function(_FullCommand, Parameters, Ar)
    local Address = Parameters[1]
    pcall(function() JoinSession(Address) end)
    AckToConsole(Ar, "coop_join")
    return true
end)

-- Event-driven cache feeds: UE4SS tells us when relevant objects are
-- constructed, so nothing needs to scan the object array on a timer.
NotifyOnNewObject("/Script/Engine.PlayerController", function(NewController)
    table.insert(Cache.PendingControllers, { PC = NewController, Ticks = 0 })
end)

NotifyOnNewObject("/Script/Engine.PlayerState", function(NewPlayerState)
    table.insert(Cache.PlayerStates, NewPlayerState)
end)

NotifyOnNewObject("/Script/Engine.Pawn", function(NewPawn)
    if State.Hosting and Config.ForceReplication then
        table.insert(Cache.PendingPawns, NewPawn)
    end
end)

-- ----------------------------------------------------------------------------
-- Banner
-- ----------------------------------------------------------------------------

Log(MOD_NAME .. " v" .. MOD_VERSION .. " loaded.")
Log("Keys: " .. tostring(Config.Keybinds.Host) .. "=Host  " ..
    tostring(Config.Keybinds.Join) .. "=Join  " ..
    tostring(Config.Keybinds.Status) .. "=Status  " ..
    tostring(HudKeyName) .. "=HUD on/off")
Log("Console commands: coop_host, coop_join <ip>, coop_stop, coop_status, coop_ping,")
Log("                  coop_hud, coop_warp (partner->you), coop_goto (you->partner), coop_fixspawns")
Log("Default join address (config.lua): " .. tostring(Config.HostAddress) .. ":" .. tostring(Config.Port))
