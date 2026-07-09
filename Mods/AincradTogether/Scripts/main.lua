-- ============================================================================
-- AincradTogether v0.1.0
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
-- Everything here is defensive (pcall + validity checks) because the game
-- updates frequently and class layouts may shift; failures log loudly to
-- the UE4SS console instead of crashing.
-- ============================================================================

local Config = require("config")

local MOD_NAME = "AincradTogether"
local MOD_VERSION = "0.1.0"

-- ----------------------------------------------------------------------------
-- State
-- ----------------------------------------------------------------------------

local State = {
    Hosting = false,           -- we started a listen server
    Joining = false,           -- we connected (or tried to connect) to a host
    SpawnFixerRunning = false, -- the pawnless-player fixer loop is alive
    RepFixerRunning = false,   -- the replication fixer loop is alive
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

local function ControllerHasPawn(PlayerController)
    local Ok, Result = pcall(function()
        local Pawn = PlayerController.Pawn
        return Pawn and Pawn:IsValid()
    end)
    return Ok and Result
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
-- Host-side fixup #1: spawn bodies for players that have none
-- ----------------------------------------------------------------------------

local function FixMissingPawns(ManualTrigger)
    local GS = GetGameplayStatics()
    local AnyPC = GetLocalPlayerController()
    if not GS or not AnyPC then return end

    -- GetGameMode only returns an object on the machine with authority
    -- (the host). On a client this is nil, which conveniently makes this
    -- whole fixer a no-op there.
    local GameMode = nil
    local OkGM, GM = pcall(function() return GS:GetGameMode(AnyPC) end)
    if OkGM and GM and GM:IsValid() then GameMode = GM end
    if not GameMode then
        if ManualTrigger then
            Log("No GameMode found - this command only works on the machine that is HOSTING.")
        end
        return
    end

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
end

-- ----------------------------------------------------------------------------
-- The three main actions: Host / Join / Status
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
    if RunConsoleCommand("open " .. Map .. "?listen") then
        StartHostFixers()
    else
        State.Hosting = false
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
    RunConsoleCommand("open " .. Address)
end

local function StopSession()
    Log("Leaving co-op session (you will likely return to the main menu)...")
    State.Hosting = false
    State.Joining = false
    RunConsoleCommand("disconnect")
end

local function PrintStatus()
    Log("=== " .. MOD_NAME .. " v" .. MOD_VERSION .. " status ===")
    Log("Mode: " .. (State.Hosting and "HOSTING" or (State.Joining and "JOINED/JOINING" or "single-player")))
    Log("Current map: " .. tostring(GetCurrentMapPath()))
    Log("Fixers: spawn=" .. tostring(State.SpawnFixerRunning) .. " replication=" .. tostring(State.RepFixerRunning))

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

    local GS = GetGameplayStatics()
    local AnyPC = GetLocalPlayerController()
    if GS and AnyPC then
        local OkGM, GM = pcall(function() return GS:GetGameMode(AnyPC) end)
        if OkGM and GM and GM:IsValid() then
            Log("GameMode (=> this machine has authority): " .. GM:GetFullName())
        else
            Log("GameMode: none visible (normal when you are the JOINING player)")
        end
    end
    Log("=== end status ===")
end

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

RegisterConsoleCommandHandler("coop_host", function(_FullCommand, _Parameters, _Ar)
    ExecuteInGameThread(HostSession)
    return true
end)

RegisterConsoleCommandHandler("coop_join", function(_FullCommand, Parameters, _Ar)
    local Address = Parameters[1]
    ExecuteInGameThread(function() JoinSession(Address) end)
    return true
end)

RegisterConsoleCommandHandler("coop_stop", function(_FullCommand, _Parameters, _Ar)
    ExecuteInGameThread(StopSession)
    return true
end)

RegisterConsoleCommandHandler("coop_status", function(_FullCommand, _Parameters, _Ar)
    ExecuteInGameThread(PrintStatus)
    return true
end)

RegisterConsoleCommandHandler("coop_fixspawns", function(_FullCommand, _Parameters, _Ar)
    ExecuteInGameThread(function() FixMissingPawns(true) end)
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
    tostring(Config.Keybinds.Status) .. "=Status")
Log("Console commands: coop_host, coop_join <ip>, coop_stop, coop_status, coop_fixspawns")
Log("Default join address (config.lua): " .. tostring(Config.HostAddress) .. ":" .. tostring(Config.Port))
