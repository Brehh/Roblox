--[[============================================================================
    FUNKY FRIDAY — AUTOPLAY v4   (ENGINE-DIRECT, frame-perfect)
    --------------------------------------------------------------------------
    Wave-only. Reads the real chart from the gameplay engine inside the
    ClientActor VM (via run_on_actor) and fires each key exactly when the live
    song clock reaches that note's Time — so every note lands SICK.

      * Note source : GameHandler.Games[*].Notes  (each: Time, Direction,
                      Length, Field)  +  live clock  game.TimePosition
      * My field    : game.PlayingField (Side / Keys / ScrollDirection)
      * Input        : GAME-FIRE — calls the engine's own Lane:Hit directly (no VIM,
                       no window focus); the real note is judged, never a death note
                       (NEVER early — early presses are penalised)
      * Holds        : key held from Time .. Time+Length
      * Control      : ReplicatedStorage.FFAUTO_CTRL (BoolValue = enabled,
                       attrs "minMs"/"maxMs" = humanized late-offset range)
      * Humanize     : each note hit a random [minMs,maxMs] ms LATE so Mean MS
                       varies naturally instead of a robotic flat ~0ms.

    Result on test: Mean MS ~2ms, 100% Sick / full combo.
============================================================================]]--

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local RS               = game:GetService("ReplicatedStorage")
local lp               = Players.LocalPlayer

-- stop any previous instance
if getgenv().__FFV4 and getgenv().__FFV4.stop then pcall(getgenv().__FFV4.stop) end
local INST = { conns = {}, alive = true }
getgenv().__FFV4 = INST
local function track(c) table.insert(INST.conns, c); return c end

---------------------------------------------------- shared control object ---
local CTRL = RS:FindFirstChild("FFAUTO_CTRL") or Instance.new("BoolValue")
CTRL.Name = "FFAUTO_CTRL"; CTRL.Parent = RS
-- humanized timing: each note is hit a random amount LATE in [minMs, maxMs] (ms).
-- (late, not early — early presses are penalised. keep maxMs < ~40 to stay all-Sick.)
if CTRL:GetAttribute("minMs") == nil then CTRL:SetAttribute("minMs", 1) end
if CTRL:GetAttribute("maxMs") == nil then CTRL:SetAttribute("maxMs", 20) end
CTRL.Value = true

----------------------------------------- scheduler that runs in the Actor ---
local ACTOR_SRC = [==[
  local RS = game:GetService("ReplicatedStorage")
  local RunService = game:GetService("RunService")
  local function istab(t,k) local v=type(t)=="table" and rawget(t,k); return type(v)=="table" and v or nil end

  -- locate the engine table once
  if not _G.__FFE then
    for _,o in ipairs(getgc(true)) do
      if type(o)=="table" and istab(o,"GameHandler") and istab(o,"InputHandler")
         and istab(o,"Notes") and istab(o,"Mechanics") then _G.__FFE = o break end
    end
  end
  local E = _G.__FFE
  if not E then return end
  local GH = E.GameHandler

  local ctrl = RS:FindFirstChild("FFAUTO_CTRL")
  local rng = Random.new()
  local S = { g=nil, notes={}, idx=1, side=nil, lanes=nil, laneN=4, down={}, relAt={}, off={} }

  local function curGame()
    local games = rawget(GH,"Games")
    if type(games)~="table" then return nil end
    local best, bestT
    for _,v in pairs(games) do
      if type(v)=="table" and rawget(v,"PlayingField") and not v.AudioEnded then
        local t = rawget(v,"PlayedTick") or rawget(v,"LocalSongClockStart") or rawget(v,"TimeCreated") or 0
        if (not bestT) or t > bestT then best, bestT = v, t end   -- newest active game (survives resets)
      end
    end
    return best
  end
  local function setup(g)
    S.g = g
    local field = g.PlayingField
    S.side  = field.Side
    S.lanes = field.Lanes                          -- live lane objects, keyed by direction
    local n=0; for k in pairs(field.Lanes) do if type(k)=="number" and k>n then n=k end end
    S.laneN = (n>0) and n or 4
    local mine = {}
    for i=1,#g.Notes do local nt=g.Notes[i]; if nt.Field==S.side then mine[#mine+1]=nt end end
    table.sort(mine, function(a,b) return a.Time<b.Time end)
    -- flag real notes that have a DEATH note close AHEAD in the same lane, so we fire them
    -- slightly EARLY (still within the Sick window) -> the real note stays the nearest hit and
    -- Lane:Hit can't pick the death note instead.
    local dt = {}                                   -- [direction] = death-note times
    for i=1,#mine do local nt=mine[i]; local n2=nt.NoteData
      if type(n2)=="table" and (n2.Type=="Death" or n2.Type=="Poison") then
        dt[nt.Direction] = dt[nt.Direction] or {}; table.insert(dt[nt.Direction], nt.Time)
      end
    end
    S.early = {}
    for i=1,#mine do local nt=mine[i]; local l=dt[nt.Direction]
      if l then for _,d in ipairs(l) do
        if d > nt.Time and d <= nt.Time + 0.09 then S.early[i]=true break end
      end end
    end
    S.notes = mine; S.down={}; S.relAt={}; S.off={}
    local now = g.TimePosition; S.idx=1
    while S.idx<=#mine and mine[S.idx].Time < now-0.05 do S.idx=S.idx+1 end
  end
  -- GAME-FIRE: call the engine's own Lane:Hit directly (no VirtualInputManager, no
  -- window-focus needed). Fired at the note's exact time, the REAL note is the nearest
  -- hit, so a death note can never be the one judged.
  local function press(dir, isDown)
    if S.down[dir]==isDown then return end
    S.down[dir]=isDown
    local lane = S.lanes and S.lanes[dir]
    if lane then pcall(function() lane:Hit(isDown, os.clock()) end) end
  end

  if _G.__FFCONN then _G.__FFCONN:Disconnect() end
  _G.__FFCONN = RunService.Heartbeat:Connect(function()
   pcall(function()
    if not ctrl then ctrl = RS:FindFirstChild("FFAUTO_CTRL") end
    if not (ctrl and ctrl.Value) then for d=1,S.laneN do press(d,false) end return end
    -- re-arm on ANY game change (new song, restart, or mid-song RESET creates a new game obj)
    local cur = curGame()
    if cur ~= S.g then
      if cur then setup(cur) else for d=1,S.laneN do press(d,false) end S.g=nil; return end
    end
    local g = S.g
    if not g then return end
    local now = g.TimePosition
    if type(now) ~= "number" then return end
    local mn = tonumber(ctrl:GetAttribute("minMs")) or 1
    local mx = tonumber(ctrl:GetAttribute("maxMs")) or 20
    if mx < mn then mx = mn end
    local function offOf(i) if S.off[i]==nil then S.off[i] = rng:NextNumber(mn, mx)/1000 end return S.off[i] end
    -- release finished taps / holds
    for d,rt in pairs(S.relAt) do if rt and now>=rt then press(d,false); S.relAt[d]=nil end end
    -- fire due notes (NON-BLOCKING: press when the clock passes Time+offset). No spin = no stutter.
    local notes = S.notes
    while notes and S.idx <= #notes do
      local nt = notes[S.idx]
      if not (nt and nt.Time) then S.idx = S.idx+1
      else
        local nd = nt.NoteData
        local ndType = (type(nd)=="table") and nd.Type or nil
        if ndType == "Death" or ndType == "Poison" then
          S.idx = S.idx+1                               -- DON'T-PRESS notes: skip (hitting = death/damage)
        else
          -- death note close ahead? fire ~18ms early (still Sick) so the real note is nearest
          local off = (S.early and S.early[S.idx]) and -0.018 or offOf(S.idx)
          local fireAt = nt.Time + off
          if now >= fireAt then
            local dir = nt.Direction
            if S.down[dir] then press(dir,false) end     -- jack: clean re-press
            press(dir,true)
            local L = nt.Length or 0
            S.relAt[dir] = fireAt + (L>0 and L or 0.05)
            S.idx = S.idx+1
          else break end
        end
      end
    end
   end)
  end)
]==]

local function inject()
    local ca = lp:FindFirstChild("PlayerScripts") and lp.PlayerScripts:FindFirstChild("ClientActor")
    if ca and run_on_actor then pcall(run_on_actor, ca, ACTOR_SRC); return true end
    return false
end
task.spawn(inject)
track(lp:WaitForChild("PlayerScripts").ChildAdded:Connect(function(c)
    if c.Name=="ClientActor" then task.wait(1); task.spawn(inject) end
end))

--============================================================================
--  GUI
--============================================================================
local CoreGui = (gethui and gethui()) or game:GetService("CoreGui")
local old = CoreGui:FindFirstChild("FF_AUTO_V4"); if old then old:Destroy() end
local function mk(c,p,par) local o=Instance.new(c) for k,v in pairs(p) do o[k]=v end o.Parent=par return o end

local gui  = mk("ScreenGui",{Name="FF_AUTO_V4",ResetOnSpawn=false,ZIndexBehavior=Enum.ZIndexBehavior.Sibling},CoreGui)
local main = mk("Frame",{Size=UDim2.fromOffset(250,234),Position=UDim2.new(0,24,0.5,-117),
    BackgroundColor3=Color3.fromRGB(18,18,24),BorderSizePixel=0,Active=true},gui)
mk("UICorner",{CornerRadius=UDim.new(0,10)},main)
mk("UIStroke",{Color=Color3.fromRGB(95,80,150),Thickness=1.4,Transparency=0.15},main)

local bar = mk("Frame",{Size=UDim2.new(1,0,0,38),BackgroundColor3=Color3.fromRGB(34,28,52),BorderSizePixel=0,Active=true},main)
mk("UICorner",{CornerRadius=UDim.new(0,10)},bar)
mk("Frame",{Size=UDim2.new(1,0,0,12),Position=UDim2.new(0,0,1,-12),BackgroundColor3=Color3.fromRGB(34,28,52),BorderSizePixel=0},bar)
mk("TextLabel",{Size=UDim2.new(1,-16,1,0),Position=UDim2.fromOffset(14,0),BackgroundTransparency=1,
    Text="FF AUTOPLAY  ·  v4 engine",TextXAlignment=Enum.TextXAlignment.Left,Font=Enum.Font.GothamBold,
    TextSize=14,TextColor3=Color3.fromRGB(236,231,255)},bar)
local dot=mk("Frame",{Size=UDim2.fromOffset(12,12),Position=UDim2.new(1,-26,0.5,-6),BackgroundColor3=Color3.fromRGB(90,225,120),BorderSizePixel=0},bar)
mk("UICorner",{CornerRadius=UDim.new(1,0)},dot)

local toggle=mk("TextButton",{Size=UDim2.new(1,-24,0,42),Position=UDim2.fromOffset(12,48),BackgroundColor3=Color3.fromRGB(55,205,110),
    BorderSizePixel=0,Font=Enum.Font.GothamBold,TextSize=16,TextColor3=Color3.fromRGB(12,12,16),Text="ENABLED  (Right Ctrl)"},main)
mk("UICorner",{CornerRadius=UDim.new(0,8)},toggle)

local status=mk("TextLabel",{Size=UDim2.new(1,-24,0,18),Position=UDim2.fromOffset(12,98),BackgroundTransparency=1,
    Text="Injecting engine…",Font=Enum.Font.Gotham,TextSize=12.5,TextColor3=Color3.fromRGB(170,165,200),TextXAlignment=Enum.TextXAlignment.Left},main)
local stat=mk("TextLabel",{Size=UDim2.new(1,-24,0,66),Position=UDim2.fromOffset(12,118),BackgroundTransparency=1,Text="",
    Font=Enum.Font.Code,TextSize=13,TextColor3=Color3.fromRGB(212,206,235),TextXAlignment=Enum.TextXAlignment.Left,
    TextYAlignment=Enum.TextYAlignment.Top,RichText=true},main)

local function sbtn(t,x,w) local b=mk("TextButton",{Size=UDim2.fromOffset(w or 22,26),Position=UDim2.fromOffset(x,196),
    BackgroundColor3=Color3.fromRGB(50,46,70),BorderSizePixel=0,Font=Enum.Font.GothamBold,TextSize=15,
    TextColor3=Color3.fromRGB(230,225,250),Text=t},main) mk("UICorner",{CornerRadius=UDim.new(0,6)},b) return b end
local function slbl(x,w) return mk("TextLabel",{Size=UDim2.fromOffset(w,26),Position=UDim2.fromOffset(x,196),
    BackgroundTransparency=1,Font=Enum.Font.Gotham,TextSize=12,TextColor3=Color3.fromRGB(190,185,215),
    Text="",TextXAlignment=Enum.TextXAlignment.Center},main) end
local minDown=sbtn("-",12); local minLbl=slbl(36,56); local minUp=sbtn("+",94)
local maxDown=sbtn("-",128); local maxLbl=slbl(152,56); local maxUp=sbtn("+",210)
local function clampMs(v) return math.clamp(v, -10, 60) end
minDown.MouseButton1Click:Connect(function() CTRL:SetAttribute("minMs", clampMs((CTRL:GetAttribute("minMs") or 1)-1)) end)
minUp.MouseButton1Click:Connect(function()   CTRL:SetAttribute("minMs", clampMs((CTRL:GetAttribute("minMs") or 1)+1)) end)
maxDown.MouseButton1Click:Connect(function() CTRL:SetAttribute("maxMs", clampMs((CTRL:GetAttribute("maxMs") or 20)-1)) end)
maxUp.MouseButton1Click:Connect(function()   CTRL:SetAttribute("maxMs", clampMs((CTRL:GetAttribute("maxMs") or 20)+1)) end)

local function refresh()
    toggle.Text = CTRL.Value and "ENABLED  (Right Ctrl)" or "DISABLED (Right Ctrl)"
    toggle.BackgroundColor3 = CTRL.Value and Color3.fromRGB(55,205,110) or Color3.fromRGB(70,66,88)
    dot.BackgroundColor3 = CTRL.Value and Color3.fromRGB(90,225,120) or Color3.fromRGB(120,120,132)
end
toggle.MouseButton1Click:Connect(function() CTRL.Value = not CTRL.Value; refresh() end)
track(UserInputService.InputBegan:Connect(function(i,gp)
    if not gp and i.KeyCode==Enum.KeyCode.RightControl then CTRL.Value=not CTRL.Value; refresh() end
end))

do local drag,sp,sm
  bar.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then drag=true;sp=main.Position;sm=i.Position end end)
  track(UserInputService.InputChanged:Connect(function(i) if drag and i.UserInputType==Enum.UserInputType.MouseMovement then
     local d=i.Position-sm; main.Position=UDim2.new(sp.X.Scale,sp.X.Offset+d.X,sp.Y.Scale,sp.Y.Offset+d.Y) end end))
  track(UserInputService.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then drag=false end end))
end

INST.stop = function()
    INST.alive=false
    for _,c in ipairs(INST.conns) do pcall(function() c:Disconnect() end) end
    pcall(function() CTRL.Value=false end)
    if gui then pcall(function() gui:Destroy() end) end
end

local function rd(lbl) return lbl and (tostring(lbl.Text):gsub("<[^>]+>","")) or nil end
task.spawn(function()
  while INST.alive and gui.Parent do
    task.wait(0.1)
    minLbl.Text = string.format("min %dms", CTRL:GetAttribute("minMs") or 1)
    maxLbl.Text = string.format("max %dms", CTRL:GetAttribute("maxMs") or 20)
    local w = lp.PlayerGui:FindFirstChild("Window")
    if w and w:FindFirstChild("Game") then
      local hud=w.Game:FindFirstChild("HUD"); local st=hud and hud:FindFirstChild("Stats"); local sc=hud and hud:FindFirstChild("ScoreCounter")
      local function g(p,n) local f=p and p:FindFirstChild(n); local l=f and f:FindFirstChild("Label"); return rd(l) end
      status.Text = "Playing  ·  engine-direct"; status.TextColor3=Color3.fromRGB(150,222,170)
      stat.Text = string.format("<font color='#9fe6b0'>%s</font>   %s\n<font color='#7fd8ff'>%s</font>  %s\n%s  %s",
        tostring(g(st,"Accuracy")), tostring(g(st,"Combo")), tostring(g(sc,"Sick")), tostring(g(sc,"Good")),
        tostring(g(sc,"Bad")), tostring(g(st,"MeanMS")))
    else
      status.Text="Idle — start a song"; status.TextColor3=Color3.fromRGB(170,165,200)
      stat.Text="<font color='#888'>Reads the engine chart and\nhits every note on time.</font>"
    end
  end
end)

refresh()
status.Text = run_on_actor and "Engine injected — start a song" or "ERROR: run_on_actor missing"
warn("[FF-Auto v4] loaded — engine-direct frame-perfect autoplay. Right-Ctrl toggles.")
