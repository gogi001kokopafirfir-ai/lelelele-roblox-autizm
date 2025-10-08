-- visual-morph-fixed.lua  (client / injector)
-- Вертикальная подгонка + локальный chat bubble + idle/walk анимации

local MODEL_NAME = "Deer" -- имя шаблона в workspace
local IDLE_ID    = "rbxassetid://138304500572165"
local WALK_ID    = "rbxassetid://78826693826761"
local VISUAL_NAME = "LOCAL_VISUAL_DEER"
local SMOOTH = 0.45 -- 0..1, скорость следования
local extraVerticalOffset = -0.03 -- мелкая корректировка вверх (если ноги всё ещё чуть врезаются)
local FP_HIDE_DISTANCE = 0.6 -- порог для первого лица

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local lp = Players.LocalPlayer
if not lp then warn("No LocalPlayer") return end
local cam = workspace.CurrentCamera

-- helpers
local function findTemplate()
    local t = workspace:FindFirstChild(MODEL_NAME)
    if t and t:IsA("Model") then return t end
    for _,m in ipairs(workspace:GetChildren()) do
        if m:IsA("Model") and string.find(string.lower(m.Name or ""), string.lower(MODEL_NAME)) then return m end
    end
    return nil
end

local function getLowestY(model)
    local minY = math.huge
    for _,part in ipairs(model:GetDescendants()) do
        if part:IsA("BasePart") then
            local bottom = part.Position.Y - (part.Size.Y / 2)
            if bottom < minY then minY = bottom end
        end
    end
    if minY == math.huge then return nil end
    return minY
end

local function getHighestPart(model)
    local best, bestTop = nil, -math.huge
    for _,part in ipairs(model:GetDescendants()) do
        if part:IsA("BasePart") then
            local top = part.Position.Y + (part.Size.Y / 2)
            if top > bestTop then bestTop = top; best = part end
        end
    end
    return best
end

local function setLocalVisibility(character, visible)
    for _,v in ipairs(character:GetDescendants()) do
        if v:IsA("BasePart") then
            pcall(function() v.LocalTransparencyModifier = visible and 0 or 1 end)
        end
    end
end

local function isFirstPerson()
    local character = lp.Character
    if not cam or not character then return false end
    local head = character:FindFirstChild("Head")
    if not head then return false end
    local dist = (cam.CFrame.Position - head.Position).Magnitude
    return dist < FP_HIDE_DISTANCE
end

-- load animation helper
local function loadTrackFromId(animator, id, parent)
    if not id or id == "" then return nil end
    local anim = Instance.new("Animation")
    anim.AnimationId = id
    anim.Parent = parent or animator
    local ok, tr = pcall(function() return animator:LoadAnimation(anim) end)
    if not ok or not tr then
        warn("LoadAnimation failed for", id, tr)
        pcall(function() anim:Destroy() end)
        return nil
    end
    tr.Priority = Enum.AnimationPriority.Movement
    return tr
end

-- create visual
local template = findTemplate()
if not template then warn("Template '"..MODEL_NAME.."' not found in workspace") return end

-- remove old visual if present
local oldVisual = workspace:FindFirstChild(VISUAL_NAME)
if oldVisual then pcall(function() oldVisual:Destroy() end) end

local ok, visual = pcall(function() return template:Clone() end)
if not ok or not visual then warn("Clone failed:", visual) return end
visual.Name = VISUAL_NAME

-- sanitize visual: remove server scripts and humanoid to ensure no conflicts
for _,d in ipairs(visual:GetDescendants()) do
    if d:IsA("Script") or d:IsA("ModuleScript") or d:IsA("Humanoid") then
        pcall(function() d:Destroy() end)
    end
    if d:IsA("BasePart") then
        pcall(function() d.Anchored = false; d.CanCollide = false end)
    end
end

-- set primary part
local prim = visual:FindFirstChild("HumanoidRootPart", true) or visual.PrimaryPart or visual:FindFirstChildWhichIsA("BasePart", true)
if prim then visual.PrimaryPart = prim end

-- put in workspace (temporary positioning: at player's HRP)
local char = lp.Character or lp.CharacterAdded:Wait()
local hrp = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
if not hrp then warn("Player HRP not found") end

-- initial naive positioning to compute measurements
if visual.PrimaryPart then
    visual:SetPrimaryPartCFrame(hrp and hrp.CFrame or CFrame.new(hrp.Position))
else
    visual.Parent = workspace
end
visual.Parent = workspace

-- compute vertical alignment:
local visualFeetY = getLowestY(visual)
local playerFeetY = getLowestY(char) or (hrp and (hrp.Position.Y - 2)) -- fallback guess
if visualFeetY and playerFeetY and visual.PrimaryPart then
    local deltaY = playerFeetY - visualFeetY + extraVerticalOffset
    -- apply the vertical shift to the whole visual (preserving orientation)
    visual:SetPrimaryPartCFrame(visual.PrimaryPart.CFrame * CFrame.new(0, deltaY, 0))
else
    warn("Could not compute feet Y (visual or player). visualFeetY:", visualFeetY, "playerFeetY:", playerFeetY)
end

-- ensure PrimaryPart still set
if not visual.PrimaryPart then
    local fallback = visual:FindFirstChildWhichIsA("BasePart", true)
    if fallback then visual.PrimaryPart = fallback end
end

-- create a humanoid+animator for visual so animations affect Motor6D
local visualHum = Instance.new("Humanoid")
visualHum.Name = "VisualHumanoid"
visualHum.Parent = visual
local animator = Instance.new("Animator")
animator.Parent = visualHum

-- load tracks
local idleTrack = loadTrackFromId(animator, IDLE_ID, visual)
local walkTrack = loadTrackFromId(animator, WALK_ID, visual)
if idleTrack then pcall(function() idleTrack.Looped = true; idleTrack:Play() end) end

-- decide head part for billboard chat (highest part)
local headPart = getHighestPart(visual) or visual.PrimaryPart

-- create local chat bubble in PlayerGui when local player chats
local function showLocalChat(msg, duration)
    duration = duration or 4
    if not headPart then return end
    local pg = lp:FindFirstChild("PlayerGui") or lp:WaitForChild("PlayerGui", 2)
    if not pg then return end
    -- create billboard
    local bb = Instance.new("BillboardGui")
    bb.Name = "LOCAL_CHAT_BB"
    bb.Adornee = headPart
    bb.Size = UDim2.new(0,200,0,50)
    bb.AlwaysOnTop = true
    bb.StudsOffset = Vector3.new(0, headPart.Size.Y/2 + 0.5, 0)
    bb.Parent = pg

    local tl = Instance.new("TextLabel")
    tl.Size = UDim2.new(1,0,1,0)
    tl.BackgroundTransparency = 0.3
    tl.BackgroundColor3 = Color3.new(0,0,0)
    tl.TextColor3 = Color3.new(1,1,1)
    tl.TextStrokeTransparency = 0.7
    tl.TextScaled = true
    tl.Font = Enum.Font.SourceSansSemibold
    tl.Text = msg
    tl.Parent = bb

    delay(duration, function() pcall(function() bb:Destroy() end) end)
end

-- hook local player's chat to show above deer
lp.Chatted:Connect(function(msg)
    showLocalChat(msg, 4)
end)

-- hide real player body locally initially
setLocalVisibility(char, false)

-- follow loop: smooth lerp to player's HRP
local followConn
followConn = RunService.RenderStepped:Connect(function()
    if not visual or not visual.PrimaryPart or not hrp then return end

    -- show/hide FP vs TP
    if isFirstPerson() then
        -- hide visual parts in FP
        for _,p in ipairs(visual:GetDescendants()) do if p:IsA("BasePart") then p.LocalTransparencyModifier = 1 end end
        setLocalVisibility(char, true) -- show player's real arms in FP
    else
        for _,p in ipairs(visual:GetDescendants()) do if p:IsA("BasePart") then p.LocalTransparencyModifier = 0 end end
        setLocalVisibility(char, false)
    end

    local target = hrp.CFrame
    local cur = visual.PrimaryPart.CFrame
    local new = cur:Lerp(target, SMOOTH)
    visual:SetPrimaryPartCFrame(new)
end)

-- switching idle/walk based on real humanoid
local realHum = char:FindFirstChildOfClass("Humanoid")
if realHum and walkTrack then
    realHum.Running:Connect(function(speed)
        if speed and speed > 0.5 then
            if idleTrack and idleTrack.IsPlaying then pcall(function() idleTrack:Stop(0.12) end) end
            if walkTrack and not walkTrack.IsPlaying then pcall(function() walkTrack:Play() end) end
        else
            if walkTrack and walkTrack.IsPlaying then pcall(function() walkTrack:Stop(0.12) end) end
            if idleTrack and not idleTrack.IsPlaying then pcall(function() idleTrack:Play() end) end
        end
    end)
end

-- revert function (call revertMorph() in client console to undo)
local function cleanup()
    if followConn then followConn:Disconnect(); followConn = nil end
    if visual and visual.Parent then pcall(function() visual:Destroy() end) end
    setLocalVisibility(char, true)
    print("Visual morph removed.")
end

_G.revertMorph = cleanup
print("Local visual morph applied. Call revertMorph() to remove.")
