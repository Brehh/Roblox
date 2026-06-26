--==================================================================
--  Nocturnal Protocol : Friday Night Partying  -  AUTOPLAY  (SAFE/v3)
--  NO VirtualInputManager (it hard-freezes this PC). Pure engine calls.
--
--  Key idea for full holds: sustain tails are separate IsSustain notes that
--  live in the song's active-notes table (S.notes), NOT in the per-lane input
--  tables. We iterate S.notes (+ the stable per-lane tables for taps) and call
--  Goodhit() on every player note in range — directly crediting tap heads AND
--  sustain bits, bypassing the engine's hold-credit cap.
--  Loop is frame-locked to Heartbeat (60Hz) — cannot busy-spin/freeze.
--  Toggle: switch in GUI or Right-Ctrl
--==================================================================

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local CoreGui          = game:GetService("CoreGui")
local LP               = Players.LocalPlayer

local G = getgenv()
G.__NP_AUTO = G.__NP_AUTO or { on = false, hits = 0 }
local STATE = G.__NP_AUTO
if G.__NP_CLEANUP then pcall(G.__NP_CLEANUP) end

local EARLY = 48    -- hit when note is within this many ms before the receptor
local LATE  = 170   -- still hit notes up to this late (catches dense tail bits)

----------------------------------------------------------------------
-- 1) Engine discovery
----------------------------------------------------------------------
local FN = G.__NP_FN or {}; G.__NP_FN = FN
local WANT = { CheckInput=true, GetNextHittable=true, Goodhit=true, MissNote=true }

local function discover()
    if G.__AP then for k in pairs(WANT) do if G.__AP[k] and not FN[k] then FN[k]=G.__AP[k] end end end
    local need = false
    for k in pairs(WANT) do if not FN[k] then need = true end end
    if not need then return true end
    for _, v in ipairs(getgc()) do
        if type(v) == "function" then
            local ok, name = pcall(debug.info, v, "n")
            if ok and WANT[name] and not FN[name] then FN[name] = v end
        end
    end
    return FN.Goodhit ~= nil and FN.CheckInput ~= nil
end

local function getLaneTables()
    if not FN.CheckInput then return nil end
    local ok, u = pcall(debug.getupvalue, FN.CheckInput, 4)
    if ok and type(u) == "table" then return u end
    return nil
end

local function getConductor()
    if not FN.GetNextHittable then return nil end
    local ok, c = pcall(debug.getupvalue, FN.GetNextHittable, 2)
    if ok and type(c) == "table" and c.SongPos ~= nil then return c end
    return nil
end

local function isNote(v)
    return type(v)=="table" and rawget(v,"StrumTime")~=nil and rawget(v,"NoteData")~=nil
end

-- The active-notes table S (has .notes + .unspawnedNotes) is recreated per song,
-- so we re-locate it periodically and pick the one with the largest remaining
-- chart (= the current song). Taps still work via the stable lane tables while
-- S is being (re)found, so a brief lag at song start never breaks tap play.
local cachedS, sFrames = nil, 999
local function findS()
    local best, bestScore = nil, -1
    for _, f in ipairs(getgc()) do
        if type(f) == "function" then
            local ok, s = pcall(debug.info, f, "s")
            if ok and s and s:find("GameHandler") then
                for i = 1, 8 do
                    local o, u = pcall(debug.getupvalue, f, i)
                    if not o then break end
                    if type(u) == "table" and rawget(u,"notes") ~= nil and rawget(u,"unspawnedNotes") ~= nil then
                        local score = 0
                        for _ in pairs(u.unspawnedNotes) do score += 1 end
                        if score > bestScore then bestScore = score; best = u end
                    end
                end
            end
        end
    end
    return best
end
local function getS()
    sFrames += 1
    if not cachedS or sFrames > 60 then
        local s = findS()
        if s then cachedS = s end
        sFrames = 0
    end
    return cachedS
end

----------------------------------------------------------------------
-- 2) Autoplay step — Goodhit every player note in range (taps + tails)
----------------------------------------------------------------------
local recByLane = {}   -- [NoteData] = receptor object

local function doStep()
    local Goodhit = FN.Goodhit
    if not Goodhit then return end
    local C = getConductor()
    if not C then return end
    local sp = C.SongPos
    local laneBusy = {}   -- lanes with a note at/near the receptor right now

    local function tryHit(n)
        if not isNote(n) then return end
        if n.MustPress ~= true then return end
        if n.shouldPress == false then return end   -- skip "do NOT press" notes (mines / EbolaNote)
        local ld = n.NoteData or 0
        local rt = rawget(n, "ReceptorTarget")
        if rt then recByLane[ld] = rt end
        if n.TooLate or n.__AP or not n.StrumTime then return end
        local diff = n.StrumTime - sp
        -- hit as soon as it reaches the receptor; no lower bound — the engine's
        -- own TooLate flag (checked above) decides when it's truly unhittable,
        -- so trailing/end-of-song notes still get caught instead of slipping by.
        if diff <= EARLY then
            n.__AP = true
            pcall(Goodhit, n)
            STATE.hits += 1
            laneBusy[ld] = true
        end
    end

    -- sustain tails (and everything else) live here
    local S = getS()
    if S and type(S.notes) == "table" then
        for _, n in pairs(S.notes) do tryHit(n) end
    end
    -- stable per-lane tables (taps/heads) — always works even if S is stale
    local lanes = getLaneTables()
    if lanes then
        for _, arr in pairs(lanes) do
            if type(arr) == "table" then for _, n in pairs(arr) do tryHit(n) end end
        end
    end

    -- reset receptors of lanes with nothing at the receptor (clears stuck glow)
    for ld, r in pairs(recByLane) do
        if not laneBusy[ld] and type(r) == "table" then
            local ca = r.CurrAnimation
            if r.Holding or (ca ~= "static" and ca ~= "default") then
                pcall(function() r.Holding = false end)
                pcall(function() r:PlayAnimation("static") end)
            end
        end
    end
end

----------------------------------------------------------------------
-- 3) Main loop  (frame-synced)
----------------------------------------------------------------------
local function startLoop()
    G.__NP_GEN = (G.__NP_GEN or 0) + 1
    local myGen = G.__NP_GEN
    discover()
    local rescan = 0
    task.spawn(function()
        while G.__NP_GEN == myGen do
            RunService.Heartbeat:Wait()
            if STATE.on then
                rescan += 1
                if rescan > 180 then rescan = 0; if not FN.Goodhit then discover() end end
                pcall(doStep)
            end
        end
    end)
end

----------------------------------------------------------------------
-- 4) Modern GUI
----------------------------------------------------------------------
local ACCENT  = Color3.fromRGB(149, 76, 233)
local ACCENT2 = Color3.fromRGB(232, 73, 158)
local BG      = Color3.fromRGB(20, 20, 28)
local BG2     = Color3.fromRGB(30, 30, 42)
local TXT     = Color3.fromRGB(235, 235, 245)
local SUB     = Color3.fromRGB(150, 150, 170)

local function corner(p,r) local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,r or 8); c.Parent=p; return c end
local function pad(p,n) local u=Instance.new("UIPadding"); for _,s in ipairs({"Left","Right","Top","Bottom"}) do u["Padding"..s]=UDim.new(0,n) end u.Parent=p end

local gui = Instance.new("ScreenGui")
gui.Name="NP_AutoplayGUI"; gui.ResetOnSpawn=false; gui.IgnoreGuiInset=true
gui.ZIndexBehavior=Enum.ZIndexBehavior.Sibling
pcall(function() gui.Parent=(gethui and gethui()) or CoreGui end)
if not gui.Parent then gui.Parent=LP:WaitForChild("PlayerGui") end

local main=Instance.new("Frame")
main.Name="Main"; main.Size=UDim2.fromOffset(290,176); main.Position=UDim2.new(0,24,0.5,-88)
main.BackgroundColor3=BG; main.BorderSizePixel=0; main.Parent=gui
corner(main,14)
local stroke=Instance.new("UIStroke"); stroke.Color=ACCENT; stroke.Thickness=1.4; stroke.Transparency=0.2; stroke.Parent=main

local bar=Instance.new("Frame"); bar.Size=UDim2.new(1,0,0,40); bar.BackgroundColor3=BG2; bar.BorderSizePixel=0; bar.Parent=main
corner(bar,14)
local barFix=Instance.new("Frame"); barFix.Size=UDim2.new(1,0,0,14); barFix.Position=UDim2.new(0,0,1,-14); barFix.BackgroundColor3=BG2; barFix.BorderSizePixel=0; barFix.Parent=bar
local grad=Instance.new("UIGradient"); grad.Color=ColorSequence.new(ACCENT,ACCENT2); grad.Rotation=25; grad.Parent=bar
local title=Instance.new("TextLabel"); title.BackgroundTransparency=1; title.Size=UDim2.new(1,-20,1,0); title.Position=UDim2.fromOffset(14,0)
title.Font=Enum.Font.GothamBold; title.TextSize=15; title.TextColor3=Color3.new(1,1,1); title.TextXAlignment=Enum.TextXAlignment.Left
title.Text="NOCTURNAL  •  AUTOPLAY"; title.Parent=bar

local body=Instance.new("Frame"); body.BackgroundTransparency=1; body.Size=UDim2.new(1,0,1,-40); body.Position=UDim2.fromOffset(0,40); body.Parent=main
pad(body,14)

local toggleRow=Instance.new("Frame"); toggleRow.BackgroundColor3=BG2; toggleRow.BorderSizePixel=0; toggleRow.Size=UDim2.new(1,0,0,46); toggleRow.Parent=body
corner(toggleRow,10)
local tLabel=Instance.new("TextLabel"); tLabel.BackgroundTransparency=1; tLabel.Position=UDim2.fromOffset(14,0); tLabel.Size=UDim2.new(1,-80,1,0)
tLabel.Font=Enum.Font.GothamMedium; tLabel.TextSize=14; tLabel.TextColor3=TXT; tLabel.TextXAlignment=Enum.TextXAlignment.Left; tLabel.Text="Autoplay"; tLabel.Parent=toggleRow
local sw=Instance.new("TextButton"); sw.AnchorPoint=Vector2.new(1,0.5); sw.Position=UDim2.new(1,-12,0.5,0); sw.Size=UDim2.fromOffset(48,26)
sw.BackgroundColor3=Color3.fromRGB(60,60,75); sw.AutoButtonColor=false; sw.Text=""; sw.Parent=toggleRow
corner(sw,13)
local knob=Instance.new("Frame"); knob.AnchorPoint=Vector2.new(0,0.5); knob.Position=UDim2.new(0,3,0.5,0); knob.Size=UDim2.fromOffset(20,20)
knob.BackgroundColor3=Color3.new(1,1,1); knob.BorderSizePixel=0; knob.Parent=sw
corner(knob,10)

local status=Instance.new("TextLabel"); status.BackgroundColor3=BG2; status.BorderSizePixel=0; status.Position=UDim2.fromOffset(0,54); status.Size=UDim2.new(1,0,0,42)
status.Font=Enum.Font.GothamMedium; status.TextSize=13; status.TextColor3=SUB; status.Text="Idle"; status.Parent=body
corner(status,10)

local hint=Instance.new("TextLabel"); hint.BackgroundTransparency=1; hint.Position=UDim2.fromOffset(0,102); hint.Size=UDim2.new(1,0,0,16)
hint.Font=Enum.Font.Gotham; hint.TextSize=11; hint.TextColor3=SUB; hint.Text="Hotkey: Right-Ctrl   •   drag the title bar"; hint.Parent=body

----------------------------------------------------------------------
-- 5) Toggle + status
----------------------------------------------------------------------
local function setToggle(on)
    STATE.on = on
    TweenService:Create(knob,TweenInfo.new(0.18,Enum.EasingStyle.Quad),{Position = on and UDim2.new(0,25,0.5,0) or UDim2.new(0,3,0.5,0)}):Play()
    TweenService:Create(sw,TweenInfo.new(0.18),{BackgroundColor3 = on and ACCENT or Color3.fromRGB(60,60,75)}):Play()
    TweenService:Create(stroke,TweenInfo.new(0.18),{Color = on and ACCENT2 or ACCENT}):Play()
    if on then STATE.hits = 0 end
end
sw.MouseButton1Click:Connect(function() setToggle(not STATE.on) end)
local inputConn = UserInputService.InputBegan:Connect(function(i,gp)
    if not gp and i.KeyCode==Enum.KeyCode.RightControl then setToggle(not STATE.on) end
end)

local statusConn = RunService.Heartbeat:Connect(function()
    if not STATE.on then status.TextColor3=SUB; status.Text="Idle  —  toggle to start"; return end
    local lanes=getLaneTables(); local active=0
    if lanes then for _,arr in pairs(lanes) do if type(arr)=="table" then
        for _,n in pairs(arr) do if isNote(n) and n.MustPress and not n.TooLate then active+=1 end end end end end
    status.TextColor3=TXT
    if not (FN.Goodhit and FN.CheckInput) then status.Text="⚠ engine not found — start a song"
    elseif active>0 then status.Text=("▶ PLAYING   •   hits: %d"):format(STATE.hits)
    else status.Text=("✓ ready   •   hits: %d"):format(STATE.hits) end
end)

----------------------------------------------------------------------
-- 6) Drag
----------------------------------------------------------------------
do
    local dragging,ds,sp0
    bar.InputBegan:Connect(function(i)
        if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then
            dragging=true; ds=i.Position; sp0=main.Position
            i.Changed:Connect(function() if i.UserInputState==Enum.UserInputState.End then dragging=false end end)
        end
    end)
    UserInputService.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch) then
            local d=i.Position-ds
            main.Position=UDim2.new(sp0.X.Scale,sp0.X.Offset+d.X,sp0.Y.Scale,sp0.Y.Offset+d.Y)
        end
    end)
end

----------------------------------------------------------------------
-- 7) Boot
----------------------------------------------------------------------
discover()
startLoop()
setToggle(STATE.on)

G.__NP_CLEANUP = function()
    G.__NP_GEN = (G.__NP_GEN or 0) + 1
    if inputConn then inputConn:Disconnect() end
    if statusConn then statusConn:Disconnect() end
    if gui then gui:Destroy() end
end

main.Size=UDim2.fromOffset(290,0)
TweenService:Create(main,TweenInfo.new(0.35,Enum.EasingStyle.Back,Enum.EasingDirection.Out),{Size=UDim2.fromOffset(290,176)}):Play()
print("[NP Autoplay] v3 (S.notes direct, no VIM) loaded. Toggle with the switch or Right-Ctrl.")
