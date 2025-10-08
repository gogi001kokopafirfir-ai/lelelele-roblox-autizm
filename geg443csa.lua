-- visual-morph-clean-fixed.lua  (client / injector)
-- Фиксы: offset для позиционирования, HipHeight для реального char, улучшенные tools, FP cleanup.

local MODEL_NAME = "Deer" -- в workspace.Deer
local IDLE_ID    = "rbxassetid://138304500572165" -- проверь ID, они подозрительно длинные
local WALK_ID    = "rbxassetid://78826693826761"
local VISUAL_NAME = "LOCAL_VISUAL_DEER"
local SMOOTH = 0.45
local FP_HIDE_DISTANCE = 0.6
local HIP_OFFSET = 0  -- авто-расчёт ниже; если не ок, поставь вручную (высота разницы, напр. 2.5 для высокого Deer)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local lp = Players.LocalPlayer
if not lp then warn("No LocalPlayer") return end

local function findTemplate()
    local t = workspace:FindFirstChild(MODEL_NAME)
    if t and t:IsA("Model") then return t end
    return nil
end

local template = findTemplate()
if not template then warn("Template model '"..MODEL_NAME.."' not found in workspace") return end

-- state
local visual = nil
local visualHum = nil
local animator = nil
local idleTrack, walkTrack = nil, nil
local followConn = nil
local toolConns = {}
local spawnedToolVisuals = {}
local cam = workspace.CurrentCamera
local originalHipHeight = nil  -- для revert

-- helpers
local function safeFindPart(model, names)
    for _,n in ipairs(names) do
        local p = model:FindFirstChild(n, true)
        if p and p:IsA("BasePart") then return p end
    end
    return nil
end

local function setLocalVisibility(model, visible, excludeArms)
    for _,v in ipairs(model:GetDescendants()) do
        if v:IsA("BasePart") then
            if excludeArms and (string.find(v.Name:lower(), "arm") or string.find(v.Name:lower(), "hand")) then
                -- skip arms/hands for FP
            else
                pcall(function() v.LocalTransparencyModifier = visible and 0 or 1 end)
            end
        end
    end
end

local function isFirstPerson()
    if not cam then return false end
    local char = lp.Character
    if not char then return false end
    local head = char:FindFirstChild("Head")
    if not head then return false end
    local dist = (cam.CFrame.Position - head.Position).Magnitude
    return dist < FP_HIDE_DISTANCE
end

local function loadTrackFromId(animatorObj, id)
    if not animatorObj or not id then return nil end
    local a = Instance.new("Animation")
    a.AnimationId = id
    a.Parent = animatorObj
    local ok, tr = pcall(function() return animatorObj:LoadAnimation(a) end)
    if not ok or not tr then
        warn("LoadAnimation failed:", id, tr)
        a:Destroy()
        return nil
    end
    tr.Priority = Enum.AnimationPriority.Movement
    return tr
end

-- tool visual: clone WHOLE tool and attach
local function createToolVisual(tool)
    if not visual then return end
    local visualTool = tool:Clone()
    visualTool.Name = "VISUAL_"..(tool.Name or "Tool")
    visualTool.Parent = visual
    for _,p in ipairs(visualTool:GetDescendants()) do
        if p:IsA("BasePart") then p.CanCollide = false end
    end

    local hand = safeFindPart(visual, {"RightHand","Right Arm","RightHand","RightUpperArm","RightArm"})
    if not hand then hand = visual.PrimaryPart end

    local handle = visualTool:FindFirstChild("Handle") or visualTool:FindFirstChildWhichIsA("BasePart")
    if not handle then return end

    -- attachments
    local attV = Instance.new("Attachment"); attV.Parent = handle
    local attH = Instance.new("Attachment"); attH.Parent = hand

    local ap = Instance.new("AlignPosition"); ap.Attachment0 = attV; ap.Attachment1 = attH
    ap.Responsiveness = 200; ap.MaxForce = 1e5; ap.RigidityEnabled = true; ap.Parent = handle
    local ao = Instance.new("AlignOrientation"); ao.Attachment0 = attV; ao.Attachment1 = attH
    ao.Responsiveness = 200; ao.MaxTorque = 1e5; ao.RigidityEnabled = true; ao.Parent = handle

    return visualTool, {ap=ap, ao=ao, attV=attV, attH=attH}
end

local function cleanupToolVisuals()
    for k,v in pairs(spawnedToolVisuals) do
        if v.instance and v.instance.Parent then pcall(function() v.instance:Destroy() end) end
    end
    spawnedToolVisuals = {}
    for k,c in pairs(toolConns) do
        if c then c:Disconnect() end
    end
    toolConns = {}
end

-- main create visual
local function createVisual()
    if visual and visual.Parent then return visual end
    local ok, clone = pcall(function() return template:Clone() end)
    if not ok or not clone then warn("Clone failed:", clone) return nil end

    clone.Name = VISUAL_NAME

    -- sanitize
    for _,d in ipairs(clone:GetDescendants()) do
        if d:IsA("Script") or d:IsA("ModuleScript") then pcall(function() d:Destroy() end) end
        if d:IsA("Humanoid") then pcall(function() d:Destroy() end) end
        if d:IsA("BasePart") then
            pcall(function() d.CanCollide = false; d.Anchored = false end)
        end
    end

    local prim = clone:FindFirstChild("HumanoidRootPart", true) or clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart", true)
    if prim then clone.PrimaryPart = prim end

    clone.Parent = workspace
    visual = clone

    visualHum = Instance.new("Humanoid")
    visualHum.Name = "VisualHumanoid"
    visualHum.Parent = visual
    animator = Instance.new("Animator"); animator.Parent = visualHum

    idleTrack = loadTrackFromId(animator, IDLE_ID)
    walkTrack = loadTrackFromId(animator, WALK_ID)
    if idleTrack then pcall(function() idleTrack.Looped = true; idleTrack:Play() end) end
    if walkTrack then pcall(function() walkTrack.Looped = true end) end  -- добавил looped для walk

    local char = lp.Character or lp.CharacterAdded:Wait()
    local realHum = char:FindFirstChildOfClass("Humanoid")
    if realHum then
        originalHipHeight = realHum.HipHeight
        -- авто-offset: примерный, тесть и подкрути
        local visualHeight = visual:GetExtentsSize().Y
        local realHeight = char:GetExtentsSize().Y
        HIP_OFFSET = (visualHeight - realHeight) / 2  -- половина разницы, чтобы ноги на земле
        pcall(function() realHum.HipHeight = realHum.HipHeight + HIP_OFFSET end)  -- поднимаем реальный char
    end

    setLocalVisibility(char, false)  -- hide real

    -- tools
    local function onToolEquipped(tool)
        pcall(function() setLocalVisibility(tool, false) end)  -- hide real tool
        local vt, info = createToolVisual(tool)
        if vt then spawnedToolVisuals[tool] = {instance = vt, info = info} end
    end
    local function onToolUnequipped(tool)
        local data = spawnedToolVisuals[tool]
        if data and data.instance then pcall(function() data.instance:Destroy() end) end
        spawnedToolVisuals[tool] = nil
        pcall(function() setLocalVisibility(tool, true) end)  -- show real if needed
    end

    local function bindToolEventsToContainer(container)
        if not container then return end
        for _,item in ipairs(container:GetChildren()) do
            if item:IsA("Tool") then
                toolConns[item] = item.Equipped:Connect(function() onToolEquipped(item) end)
                toolConns[item .. "_uneq"] = item.Unequipped:Connect(function() onToolUnequipped(item) end)
            end
        end
        container.ChildAdded:Connect(function(child)
            if child:IsA("Tool") then
                toolConns[child] = child.Equipped:Connect(function() onToolEquipped(child) end)
                toolConns[child .. "_uneq"] = child.Unequipped:Connect(function() onToolUnequipped(child) end)
            end
        end)
    end

    bindToolEventsToContainer(lp:FindFirstChildOfClass("Backpack"))
    if char then bindToolEventsToContainer(char) end
    lp.CharacterAdded:Connect(function(newChar)
        bindToolEventsToContainer(newChar)
        local newHum = newChar:WaitForChild("Humanoid", 5)
        if newHum then pcall(function() newHum.HipHeight = newHum.HipHeight + HIP_OFFSET end) end
        setLocalVisibility(newChar, false)
    end)

    -- follow
    local hrp = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
    if not hrp then warn("No HRP") return end

    if followConn then followConn:Disconnect() end
    followConn = RunService.RenderStepped:Connect(function()
        if not visual or not visual.PrimaryPart or not hrp then return end
        local fp = isFirstPerson()
        if fp then
            -- FP: show real (only arms), hide visual fully + visual tools
            setLocalVisibility(visual, false)
            for _,data in pairs(spawnedToolVisuals) do
                if data.instance then setLocalVisibility(data.instance, false) end
            end
            setLocalVisibility(char, true, true)  -- show real, but hide non-arms for full FP
        else
            -- TP: show visual, hide real
            setLocalVisibility(visual, true)
            for _,data in pairs(spawnedToolVisuals) do
                if data.instance then setLocalVisibility(data.instance, true) end
            end
            setLocalVisibility(char, false)
        end
        -- lerp with offset: visual ниже на HIP_OFFSET, чтобы ноги на земле (реальный выше)
        local target = hrp.CFrame * CFrame.new(0, -HIP_OFFSET, 0)  -- сдвиг вниз
        local cur = visual.PrimaryPart.CFrame
        local new = cur:Lerp(target, SMOOTH)
        visual:SetPrimaryPartCFrame(new)
    end)

    -- anim switch
    if realHum and walkTrack then
        realHum.Running:Connect(function(speed)
            if speed > 0.5 then
                if idleTrack and idleTrack.IsPlaying then pcall(function() idleTrack:Stop(0.12) end) end
                if walkTrack and not walkTrack.IsPlaying then pcall(function() walkTrack:Play() end) end
            else
                if walkTrack and walkTrack.IsPlaying then pcall(function() walkTrack:Stop(0.12) end) end
                if idleTrack and not idleTrack.IsPlaying then pcall(function() idleTrack:Play() end) end
            end
        end)
    end

    return visual
end

-- revert
local function revertMorph()
    if followConn then followConn:Disconnect(); followConn = nil end
    cleanupToolVisuals()
    if visual then pcall(function() visual:Destroy() end) end
    visual = nil; animator = nil; idleTrack = nil; walkTrack = nil
    local char = lp.Character
    if char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum and originalHipHeight then pcall(function() hum.HipHeight = originalHipHeight end) end
        setLocalVisibility(char, true)
    end
    print("Morph reverted.")
end

local v = createVisual()
if v then
    print("Local visual created:", v:GetFullName())
    print("To revert: revertMorph() in console.")
else
    warn("Failed.")
end

_G.revertMorph = revertMorph
