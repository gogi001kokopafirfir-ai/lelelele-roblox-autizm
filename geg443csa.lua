-- visual-morph-fixed-v2.lua  (client)
-- Исправления: убрано обращение .Y у ToOrientation(), защищён цикл слежения.

local MODEL_NAME = "Deer"                             -- имя шаблона в workspace
local VISUAL_NAME = "LOCAL_VISUAL_DEER"
local IDLE_ID = "rbxassetid://138304500572165"
local WALK_ID = "rbxassetid://78826693826761"
local SMOOTH = 0.45                                   -- сглаживание (0..1)
local FP_HIDE_DISTANCE = 0.6                          -- порог первого лица

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local lp = Players.LocalPlayer
if not lp then warn("No LocalPlayer"); return end
local cam = workspace.CurrentCamera

-- find template
local function findTemplate()
    local t = workspace:FindFirstChild(MODEL_NAME)
    if t and t:IsA("Model") then return t end
    for _,m in ipairs(workspace:GetChildren()) do
        if m:IsA("Model") and string.find(string.lower(m.Name or ""), string.lower(MODEL_NAME)) then return m end
    end
    return nil
end

local function getMinY(model)
    local minY = math.huge
    for _,p in ipairs(model:GetDescendants()) do
        if p:IsA("BasePart") then
            local y = p.Position.Y - (p.Size.Y/2)
            if y < minY then minY = y end
        end
    end
    if minY == math.huge then return nil end
    return minY
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

-- prepare visual
local template = findTemplate()
if not template then warn("Template '"..MODEL_NAME.."' not found in workspace") return end

local prev = workspace:FindFirstChild(VISUAL_NAME)
if prev then pcall(function() prev:Destroy() end) end

local ok, visual = pcall(function() return template:Clone() end)
if not ok or not visual then warn("Clone failed:", visual); return end
visual.Name = VISUAL_NAME

-- sanitize visual
for _,d in ipairs(visual:GetDescendants()) do
    if d:IsA("Script") or d:IsA("ModuleScript") then pcall(function() d:Destroy() end) end
    if d:IsA("Humanoid") then pcall(function() d:Destroy() end) end
    if d:IsA("BasePart") then pcall(function() d.CanCollide = false; d.Anchored = false end) end
end

local prim = visual:FindFirstChild("HumanoidRootPart", true) or visual.PrimaryPart or visual:FindFirstChildWhichIsA("BasePart", true)
if prim then visual.PrimaryPart = prim end
visual.Parent = workspace

-- compute vertical offset so feet match
local playerChar = lp.Character or lp.CharacterAdded:Wait()
local playerMin = getMinY(playerChar) or (playerChar:FindFirstChild("HumanoidRootPart") and (playerChar.HumanoidRootPart.Position.Y - 2)) or 0
local visualMin = getMinY(visual) or (visual.PrimaryPart and (visual.PrimaryPart.Position.Y - 2)) or 0
local verticalDelta = (playerMin - visualMin)
print(string.format("[morph] playerMin=%.3f visualMin=%.3f delta=%.3f", playerMin, visualMin, verticalDelta))

-- animator on visual
local visualHum = Instance.new("Humanoid")
visualHum.Name = "VisualHumanoid"
visualHum.Parent = visual
local animator = Instance.new("Animator")
animator.Parent = visualHum

local function loadTrackFromId(animatorObj, id)
    if not animatorObj or not id then return nil end
    local a = Instance.new("Animation")
    a.AnimationId = id
    a.Parent = visual
    local ok2, tr = pcall(function() return animatorObj:LoadAnimation(a) end)
    if not ok2 or not tr then
        warn("LoadAnimation failed for", id, tr)
        pcall(function() a:Destroy() end)
        return nil
    end
    tr.Priority = Enum.AnimationPriority.Movement
    return tr
end

local idleTrack = loadTrackFromId(animator, IDLE_ID)
local walkTrack = loadTrackFromId(animator, WALK_ID)
if idleTrack then pcall(function() idleTrack.Looped = true; idleTrack:Play() end) end

-- follow loop (защищён)
local char = lp.Character or lp.CharacterAdded:Wait()
local hrp = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
if not hrp then warn("No HRP on player char"); return end

local followConn
followConn = RunService.RenderStepped:Connect(function()
    local ok, err = pcall(function()
        if not visual or not visual.PrimaryPart or not hrp then return end

        -- compute yaw safely, using select to retrieve second return
        local rx, yaw, rz = hrp.CFrame:ToOrientation()
        if type(yaw) ~= "number" then yaw = 0 end

        -- target position: align visual's feet with player's feet
        local targetPos = hrp.Position + Vector3.new(0, verticalDelta, 0)
        local targetCFrame = CFrame.new(targetPos) * CFrame.Angles(0, yaw, 0)

        local cur = visual.PrimaryPart.CFrame
        local new = cur:Lerp(targetCFrame, SMOOTH)
        visual:SetPrimaryPartCFrame(new)

        -- FP/TP visibility
        if isFirstPerson() then
            for _,p in ipairs(visual:GetDescendants()) do if p:IsA("BasePart") then p.LocalTransparencyModifier = 1 end end
            setLocalVisibility(char, true)
        else
            for _,p in ipairs(visual:GetDescendants()) do if p:IsA("BasePart") then p.LocalTransparencyModifier = 0 end end
            setLocalVisibility(char, false)
        end
    end)
    if not ok then
        warn("[morph] follow error:", err)
    end
end)

-- switch animations by real humanoid Running
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

-- simple revert
_G.revertMorph = function()
    if followConn then followConn:Disconnect(); followConn = nil end
    if visual and visual.Parent then pcall(function() visual:Destroy() end) end
    setLocalVisibility(lp.Character, true)
    print("[morph] reverted")
end

print("[morph] visual created. Vertical delta:", verticalDelta)
