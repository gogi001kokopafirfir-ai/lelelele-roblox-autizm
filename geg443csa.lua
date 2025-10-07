-- visual-morph-fixed-v5.lua (client)
-- Исправления: правильное сравнение ориентации (yaw), стабильный follow + защита.

local MODEL_NAME = "Deer"
local VISUAL_NAME = "LOCAL_VISUAL_DEER"
local IDLE_ID = "rbxassetid://138304500572165"
local WALK_ID = "rbxassetid://78826693826761"

local FOLLOW_SMOOTH_SPEED = 18
local VERTICAL_SMOOTH_SPEED = 8
local GROUND_RAY_INTERVAL = 0.12
local POSITION_DEADZONE = 0.02
local FP_HEAD_FACTOR = 0.7

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = workspace

local lp = Players.LocalPlayer
if not lp then warn("No LocalPlayer"); return end
local cam = Workspace.CurrentCamera

local function findTemplate()
    local t = Workspace:FindFirstChild(MODEL_NAME)
    if t and t:IsA("Model") then return t end
    for _,m in ipairs(Workspace:GetChildren()) do
        if m:IsA("Model") and string.find(string.lower(m.Name or ""), string.lower(MODEL_NAME)) then return m end
    end
    return nil
end

local function getMinY(model)
    local minY = math.huge
    for _,v in ipairs(model:GetDescendants()) do
        if v:IsA("BasePart") then
            local y = v.Position.Y - v.Size.Y/2
            if y < minY then minY = y end
        end
    end
    if minY == math.huge then return nil end
    return minY
end

local function setLocalVisibility(character, visible)
    for _,p in ipairs(character:GetDescendants()) do
        if p:IsA("BasePart") then
            pcall(function() p.LocalTransparencyModifier = visible and 0 or 1 end)
        end
    end
end

local function isFirstPerson()
    local char = lp.Character
    if not cam or not char then return false end
    local head = char:FindFirstChild("Head")
    if not head then return false end
    local dist = (cam.CFrame.Position - head.Position).Magnitude
    local threshold = (head.Size.Magnitude * FP_HEAD_FACTOR) + 0.5
    return dist < threshold
end

local function findGroundY(pos)
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Blacklist
    rayParams.FilterDescendantsInstances = {lp.Character}
    local res = Workspace:Raycast(pos + Vector3.new(0,0.5,0), Vector3.new(0,-400,0), rayParams)
    if res and res.Position then
        return res.Position.Y
    else
        return pos.Y - 2.5
    end
end

local function expAlpha(speed, dt)
    if dt <= 0 then return 1 end
    local a = 1 - math.exp(-speed * dt)
    if a < 0 then a = 0 end
    if a > 1 then a = 1 end
    return a
end

-- create visual
local template = findTemplate()
if not template then warn("Template not found: "..tostring(MODEL_NAME)); return end
local prev = Workspace:FindFirstChild(VISUAL_NAME)
if prev then pcall(function() prev:Destroy() end) end

local ok, visual = pcall(function() return template:Clone() end)
if not ok or not visual then warn("Clone failed:", visual); return end
visual.Name = VISUAL_NAME

-- sanitize and anchor visual parts so physics won't fight us
for _,d in ipairs(visual:GetDescendants()) do
    if d:IsA("Script") or d:IsA("ModuleScript") then pcall(function() d:Destroy() end) end
    if d:IsA("Humanoid") then pcall(function() d:Destroy() end) end
    if d:IsA("BasePart") then
        pcall(function()
            d.Anchored = true
            d.CanCollide = false
        end)
    end
end

local prim = visual:FindFirstChild("HumanoidRootPart", true) or visual.PrimaryPart or visual:FindFirstChildWhichIsA("BasePart", true)
if prim then visual.PrimaryPart = prim end
visual.Parent = Workspace

-- compute placement
local visualMin = getMinY(visual) or (visual.PrimaryPart and visual.PrimaryPart.Position.Y - 1) or 0
local playerChar = lp.Character or lp.CharacterAdded:Wait()
local hrp = playerChar:FindFirstChild("HumanoidRootPart") or playerChar.PrimaryPart
if not hrp then warn("No HRP on player"); return end
local groundY = findGroundY(hrp.Position)
local baseOffset = (visual.PrimaryPart and (visual.PrimaryPart.Position.Y - visualMin)) or 1
local targetPrimaryY = groundY + baseOffset

local smoothPrimaryCFrame = visual.PrimaryPart.CFrame
local smoothGroundY = targetPrimaryY
local timeSinceLastGround = 0

print(string.format("[morph] initial groundY=%.3f visualMin=%.3f baseOffset=%.3f targetPrimaryY=%.3f",
    groundY, visualMin, baseOffset, targetPrimaryY))

-- animator
local visualHum = Instance.new("Humanoid"); visualHum.Name = "VisualHumanoid"; visualHum.Parent = visual
local animator = Instance.new("Animator"); animator.Parent = visualHum

local function loadTrack(animatorObj, animId)
    if not animatorObj or not animId then return nil end
    local a = Instance.new("Animation"); a.AnimationId = animId; a.Parent = visual
    local ok2, tr = pcall(function() return animatorObj:LoadAnimation(a) end)
    if not ok2 or not tr then warn("LoadAnimation failed:", animId, tr); pcall(function() a:Destroy() end); return nil end
    tr.Priority = Enum.AnimationPriority.Movement
    return tr
end

local idleTrack = loadTrack(animator, IDLE_ID)
local walkTrack = loadTrack(animator, WALK_ID)
if idleTrack then pcall(function() idleTrack.Looped = true; idleTrack:Play() end) end

-- tools visuals (per-equip relative transform)
local toolVisuals = {}
local function findHand(model)
    local names = {"RightHand","Right Arm","RightUpperArm","RightLowerArm","RightGripAttachment"}
    for _,n in ipairs(names) do
        local p = model:FindFirstChild(n, true)
        if p and p:IsA("BasePart") then return p end
        if p and p:IsA("Attachment") and p.Parent and p.Parent:IsA("BasePart") then return p.Parent end
    end
    return model.PrimaryPart
end

local function onToolEquipped(tool)
    if toolVisuals[tool] then return end
    local handle = tool:FindFirstChild("Handle") or tool:FindFirstChildWhichIsA("BasePart")
    if not handle then return end
    local realHand = findHand(lp.Character)
    local visualHand = findHand(visual)
    if not realHand or not visualHand then return end
    local rel = realHand.CFrame:Inverse() * handle.CFrame
    local vh = handle:Clone()
    vh.Name = "VISUAL_HANDLE_"..tool.Name
    vh.Parent = visual
    vh.Anchored = true
    vh.CanCollide = false
    pcall(function() handle.LocalTransparencyModifier = 1 end)
    toolVisuals[tool] = {instance = vh, visualHand = visualHand, rel = rel, realHandle = handle}
end

local function onToolUnequipped(tool)
    local data = toolVisuals[tool]
    if data then
        if data.instance and data.instance.Parent then pcall(function() data.instance:Destroy() end) end
        if data.realHandle then pcall(function() data.realHandle.LocalTransparencyModifier = 0 end) end
        toolVisuals[tool] = nil
    end
end

local function bindTools(container)
    if not container then return end
    for _,ch in ipairs(container:GetChildren()) do
        if ch:IsA("Tool") then
            ch.Equipped:Connect(function() onToolEquipped(ch) end)
            ch.Unequipped:Connect(function() onToolUnequipped(ch) end)
        end
    end
    container.ChildAdded:Connect(function(child)
        if child:IsA("Tool") then
            child.Equipped:Connect(function() onToolEquipped(child) end)
            child.Unequipped:Connect(function() onToolUnequipped(child) end)
        end
    end)
end

bindTools(lp:FindFirstChildOfClass("Backpack"))
if lp.Character then bindTools(lp.Character) end
lp.CharacterAdded:Connect(function(ch) bindTools(ch) end)

-- follow loop
local char = lp.Character or lp.CharacterAdded:Wait()
local hrp = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
if not hrp then warn("No HRP"); return end

local followConn
followConn = RunService.Heartbeat:Connect(function(dt)
    local ok, err = pcall(function()
        if not visual or not visual.PrimaryPart or not hrp then return end

        timeSinceLastGround = timeSinceLastGround + dt
        if timeSinceLastGround >= GROUND_RAY_INTERVAL then
            local newGround = findGroundY(hrp.Position)
            local newTargetY = newGround + baseOffset
            local a_vert = expAlpha(VERTICAL_SMOOTH_SPEED, dt)
            smoothGroundY = smoothGroundY + (newTargetY - smoothGroundY) * a_vert
            timeSinceLastGround = 0
        end

        local rx1, yawCur, rz1 = visual.PrimaryPart.CFrame:ToOrientation()
        local rx2, yawT, rz2 = hrp.CFrame:ToOrientation()
        if type(yawCur) ~= "number" then yawCur = 0 end
        if type(yawT) ~= "number" then yawT = 0 end

        local targetPos = Vector3.new(hrp.Position.X, smoothGroundY, hrp.Position.Z)
        local targetCFrame = CFrame.new(targetPos) * CFrame.Angles(0, yawT, 0)

        -- position check + yaw difference check (both scalar numbers)
        local posDiff = (visual.PrimaryPart.Position - targetCFrame.Position).Magnitude
        local yawDiff = math.abs(yawCur - yawT)
        if posDiff < POSITION_DEADZONE and yawDiff < 0.01 then
            -- very close -> skip
        else
            local a = expAlpha(FOLLOW_SMOOTH_SPEED, dt)
            local new = visual.PrimaryPart.CFrame:Lerp(targetCFrame, a)
            visual:SetPrimaryPartCFrame(new)
        end

        -- update tool visuals
        for tool,data in pairs(toolVisuals) do
            if data.instance and data.visualHand and data.rel then
                pcall(function()
                    if data.visualHand:IsA("BasePart") then
                        data.instance.CFrame = data.visualHand.CFrame * data.rel
                    else
                        data.instance.CFrame = visual.PrimaryPart.CFrame * data.rel
                    end
                end)
            end
        end

        -- FP / TP visibility
        if isFirstPerson() then
            for _,p in ipairs(visual:GetDescendants()) do if p:IsA("BasePart") then p.LocalTransparencyModifier = 1 end end
            setLocalVisibility(char, true)
            for tool,data in pairs(toolVisuals) do if data.realHandle then data.realHandle.LocalTransparencyModifier = 0 end end
        else
            for _,p in ipairs(visual:GetDescendants()) do if p:IsA("BasePart") then p.LocalTransparencyModifier = 0 end end
            setLocalVisibility(char, false)
            for tool,data in pairs(toolVisuals) do if data.realHandle then data.realHandle.LocalTransparencyModifier = 1 end end
        end
    end)
    if not ok then
        warn("[morph] follow error:", err)
    end
end)

-- animation switching
local realHum = hrp.Parent and hrp.Parent:FindFirstChildOfClass("Humanoid")
if realHum then
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

-- local chat bubble
lp.Chatted:Connect(function(msg)
    if not visual then return end
    local head = visual:FindFirstChild("Head", true) or visual.PrimaryPart
    if not head then return end
    local bill = Instance.new("BillboardGui"); bill.Adornee = head; bill.Size = UDim2.new(0,250,0,60); bill.AlwaysOnTop = true
    bill.StudsOffset = Vector3.new(0, (head.Size and head.Size.Y or 2) + 0.5, 0); bill.Parent = visual
    local lbl = Instance.new("TextLabel", bill); lbl.Size = UDim2.new(1,0,1,0); lbl.TextScaled = true; lbl.BackgroundTransparency = 1
    lbl.Text = msg; lbl.Font = Enum.Font.SourceSansBold; lbl.TextColor3 = Color3.new(1,1,1)
    delay(3, function() pcall(function() bill:Destroy() end) end)
end)

_G.revertMorph = function()
    if followConn then followConn:Disconnect(); followConn = nil end
    for tool,data in pairs(toolVisuals) do
        if data.instance and data.instance.Parent then pcall(function() data.instance:Destroy() end) end
        if data.realHandle then pcall(function() data.realHandle.LocalTransparencyModifier = 0 end) end
    end
    toolVisuals = {}
    if visual and visual.Parent then pcall(function() visual:Destroy() end) end
    setLocalVisibility(lp.Character, true)
    print("[morph] reverted")
end

print("[morph] started. Check Output for any 'LoadAnimation failed' lines.")
