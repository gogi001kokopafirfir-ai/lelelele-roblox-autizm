-- visual-morph-fixed.lua (client-side injector)
-- Работает как локальный визуал: позиционирование, анимации, инструменты, чат-пузырь.
-- Настройки:
local MODEL_NAME = "Deer"                             -- имя шаблона в workspace
local VISUAL_NAME = "LOCAL_VISUAL_DEER"
local IDLE_ID = "rbxassetid://138304500572165"
local WALK_ID = "rbxassetid://78826693826761"
local SMOOTH = 0.45                                   -- сглаживание следования (0..1)
local FP_HIDE_DISTANCE = 0.6                          -- порог для определения первого лица
local TOOL_ALIGN_RESPONSIVENESS = 200
local TOOL_ALIGN_FORCE = 1e5

-- Не трогай дальше, если не понимаешь.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local lp = Players.LocalPlayer
if not lp then return end
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

-- helpers
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

-- create visual, position it so feet match player's feet
local template = findTemplate()
if not template then warn("Template '"..MODEL_NAME.."' not found in workspace") return end

-- remove previous
local prev = workspace:FindFirstChild(VISUAL_NAME)
if prev then pcall(function() prev:Destroy() end) end

local ok, visual = pcall(function() return template:Clone() end)
if not ok or not visual then warn("Clone failed:", visual) return end
visual.Name = VISUAL_NAME

-- sanitize visual: remove server scripts and humanoid to avoid conflicts
for _,d in ipairs(visual:GetDescendants()) do
    if d:IsA("Script") or d:IsA("ModuleScript") then pcall(function() d:Destroy() end) end
    if d:IsA("Humanoid") then pcall(function() d:Destroy() end) end
    if d:IsA("BasePart") then pcall(function() d.CanCollide = false; d.Anchored = false end) end
end

-- find primary part fallback
local prim = visual:FindFirstChild("HumanoidRootPart", true) or visual.PrimaryPart or visual:FindFirstChildWhichIsA("BasePart", true)
if prim then visual.PrimaryPart = prim end
visual.Parent = workspace

-- compute vertical offset so feet align
local playerChar = lp.Character or lp.CharacterAdded:Wait()
local playerMin = getMinY(playerChar) or (playerChar:FindFirstChild("HumanoidRootPart") and playerChar.HumanoidRootPart.Position.Y - 2) or 0
local visualMin = getMinY(visual) or (visual.PrimaryPart and visual.PrimaryPart.Position.Y - 2) or 0
local verticalDelta = (playerMin - visualMin)
-- log
print("[morph] playerMinY=", playerMin, "visualMinY=", visualMin, "deltaY=", verticalDelta)

-- give visual its own Humanoid+Animator to play animations
local visualHum = Instance.new("Humanoid")
visualHum.Name = "VisualHumanoid"
visualHum.Parent = visual
local animator = Instance.new("Animator")
animator.Parent = visualHum

local function loadTrackFromId(animatorObj, id)
    if not id then return nil end
    local a = Instance.new("Animation")
    a.AnimationId = id
    a.Parent = visual -- keep near visual
    local ok2, tr = pcall(function() return animatorObj:LoadAnimation(a) end)
    if not ok2 or not tr then
        warn("[morph] LoadAnimation failed for", id, tr)
        if a then pcall(function() a:Destroy() end) end
        return nil
    end
    tr.Priority = Enum.AnimationPriority.Movement
    return tr
end

local idleTrack = loadTrackFromId(animator, IDLE_ID)
local walkTrack = loadTrackFromId(animator, WALK_ID)
if idleTrack then pcall(function() idleTrack.Looped = true; idleTrack:Play() end) end

-- tools visual handling
local spawnedToolVisuals = {} -- tool -> {instance, aligns...}
local toolConns = {}

local function createToolVisual(tool)
    if not visual then return end
    local handle = tool:FindFirstChild("Handle") or tool:FindFirstChildWhichIsA("BasePart")
    if not handle then return end
    local hand = visual:FindFirstChild("RightHand", true) or visual:FindFirstChild("Right Arm", true) or visual.PrimaryPart
    if not hand then hand = visual.PrimaryPart end

    local visualHandle = handle:Clone()
    visualHandle.Name = "VISUAL_HANDLE_"..(tool.Name or "Tool")
    visualHandle.Parent = visual
    visualHandle.CanCollide = false

    local attV = Instance.new("Attachment"); attV.Parent = visualHandle
    local attH = Instance.new("Attachment"); attH.Parent = hand

    local ap = Instance.new("AlignPosition"); ap.Attachment0 = attV; ap.Attachment1 = attH
    ap.Responsiveness = TOOL_ALIGN_RESPONSIVENESS; ap.MaxForce = TOOL_ALIGN_FORCE; ap.RigidityEnabled = true; ap.Parent = visualHandle
    local ao = Instance.new("AlignOrientation"); ao.Attachment0 = attV; ao.Attachment1 = attH
    ao.Responsiveness = TOOL_ALIGN_RESPONSIVENESS; ao.MaxTorque = TOOL_ALIGN_FORCE; ao.RigidityEnabled = true; ao.Parent = visualHandle

    -- hide real handle locally to avoid duplicate visuals
    pcall(function() handle.LocalTransparencyModifier = 1 end)

    spawnedToolVisuals[tool] = {instance = visualHandle, attV = attV, attH = attH, ap = ap, ao = ao, realHandle = handle}
    return spawnedToolVisuals[tool]
end

local function removeToolVisual(tool)
    local data = spawnedToolVisuals[tool]
    if data then
        if data.instance and data.instance.Parent then pcall(function() data.instance:Destroy() end) end
        if data.realHandle then pcall(function() data.realHandle.LocalTransparencyModifier = 0 end) end
        spawnedToolVisuals[tool] = nil
    end
end

local function bindTool(tool)
    if toolConns[tool] then return end
    toolConns[tool] = {}
    toolConns[tool].eq = tool.Equipped:Connect(function()
        -- create visual copy attached to visual's hand
        createToolVisual(tool)
    end)
    toolConns[tool].uneq = tool.Unequipped:Connect(function()
        removeToolVisual(tool)
    end)
end

local function bindContainer(container)
    if not container then return end
    for _,child in ipairs(container:GetChildren()) do
        if child:IsA("Tool") then bindTool(child) end
    end
    container.ChildAdded:Connect(function(child)
        if child:IsA("Tool") then bindTool(child) end
    end)
end

bindContainer(lp:FindFirstChildOfClass("Backpack"))
if lp.Character then bindContainer(lp.Character) end
lp.CharacterAdded:Connect(function(ch)
    bindContainer(ch)
end)

-- follow loop with vertical offset
local char = lp.Character or lp.CharacterAdded:Wait()
local hrp = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
if not hrp then warn("No HRP on player char") return end

local followConn = RunService.RenderStepped:Connect(function()
    if not visual or not visual.PrimaryPart then return end
    -- compute target: align visual so its lowest point (minY+delta) matches player's ground
    local targetPos = hrp.Position + Vector3.new(0, verticalDelta, 0)
    local targetCFrame = CFrame.new(targetPos) * CFrame.new(0,0,0) -- keep orientation = hrp's orientation
    -- orientation: face same direction as player
    local target = CFrame.new(targetPos) * CFrame.Angles(0, hrp.CFrame:ToOrientation().Y, 0)
    local cur = visual.PrimaryPart.CFrame
    local new = cur:Lerp(target, SMOOTH)
    visual:SetPrimaryPartCFrame(new)

    -- FP/TP visibility handling
    if isFirstPerson() then
        -- hide visual (all parts) to avoid clipping, reveal player's body locally
        for _,p in ipairs(visual:GetDescendants()) do if p:IsA("BasePart") then p.LocalTransparencyModifier = 1 end end
        setLocalVisibility(char, true)
        -- also hide spawned tool visuals
        for t,d in pairs(spawnedToolVisuals) do if d.instance and d.instance.Parent then d.instance.LocalTransparencyModifier = 1 end end
        -- ensure real handles visible in FP
        for t,d in pairs(spawnedToolVisuals) do if d.realHandle then d.realHandle.LocalTransparencyModifier = 0 end end
    else
        -- show visual, hide player's real body locally
        for _,p in ipairs(visual:GetDescendants()) do if p:IsA("BasePart") then p.LocalTransparencyModifier = 0 end end
        setLocalVisibility(char, false)
        for t,d in pairs(spawnedToolVisuals) do if d.instance and d.instance.Parent then d.instance.LocalTransparencyModifier = 0 end end
        for t,d in pairs(spawnedToolVisuals) do if d.realHandle then d.realHandle.LocalTransparencyModifier = 1 end end
    end
end)

-- switch animation tracks based on real humanoid running
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

-- local chat bubble for player's own messages (so it appears above the Deer head)
local function showLocalChat(text, duration)
    duration = duration or 3
    if not visual then return end
    local head = visual:FindFirstChild("Head", true) or visual.PrimaryPart
    if not head then head = visual.PrimaryPart end
    local billboard = Instance.new("BillboardGui")
    billboard.Name = "LocalChatBubble"
    billboard.Adornee = head
    billboard.AlwaysOnTop = true
    billboard.Size = UDim2.new(0,200,0,50)
    billboard.StudsOffset = Vector3.new(0, 3, 0)
    billboard.Parent = visual
    local txt = Instance.new("TextLabel", billboard)
    txt.Size = UDim2.new(1,0,1,0)
    txt.BackgroundTransparency = 1
    txt.TextScaled = true
    txt.Text = text
    txt.TextColor3 = Color3.new(1,1,1)
    txt.Font = Enum.Font.SourceSansBold
    delay(duration, function()
        pcall(function() billboard:Destroy() end)
    end)
end

lp.Chatted:Connect(function(msg)
    showLocalChat(msg, 3)
end)

-- basic client-side health recovery (best-effort). NOT a guaranteed protection.
local healthConn
if realHum then
    healthConn = realHum.HealthChanged:Connect(function(h)
        -- If health decreased, try to heal locally to MaxHealth after tiny delay
        if realHum and realHum.Health < (realHum.MaxHealth or 100) then
            task.delay(0.03, function()
                pcall(function() realHum.Health = realHum.MaxHealth end)
            end)
        end
    end)
end

-- revert function
local function revert()
    if followConn then followConn:Disconnect(); followConn = nil end
    if healthConn then healthConn:Disconnect(); healthConn = nil end
    for t,_ in pairs(toolConns) do
        for k,c in pairs(toolConns[t]) do if c and c.Disconnect then c:Disconnect() end end
    end
    for tool,data in pairs(spawnedToolVisuals) do
        if data.realHandle then pcall(function() data.realHandle.LocalTransparencyModifier = 0 end) end
        if data.instance and data.instance.Parent then pcall(function() data.instance:Destroy() end) end
    end
    spawnedToolVisuals = {}
    if visual and visual.Parent then pcall(function() visual:Destroy() end) end
    setLocalVisibility(lp.Character, true)
    print("[morph] visual reverted.")
end

_G.revertMorph = revert
print("[morph] visual created. Vertical delta:", verticalDelta, "Call revertMorph() in console to undo.")
