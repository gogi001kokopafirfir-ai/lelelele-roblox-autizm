-- visual-morph-fixed-v3.lua (client injector)
-- Исправления: raycast-ground alignment, tool visual by offset, FP detection robust.

local MODEL_NAME = "Deer"
local VISUAL_NAME = "LOCAL_VISUAL_DEER"
local IDLE_ID = "rbxassetid://138304500572165"
local WALK_ID = "rbxassetid://78826693826761"

local SMOOTH = 0.45
local FP_HEAD_FACTOR = 0.7 -- множитель размера головы для определения FP
local TOOL_ALIGN_RESPONSIVENESS = 200
local TOOL_ALIGN_FORCE = 1e5

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = workspace

local lp = Players.LocalPlayer
if not lp then warn("No LocalPlayer"); return end
local cam = Workspace.CurrentCamera

-- helpers
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

-- raycast down to find ground Y under position
local function findGroundY(pos)
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Blacklist
    rayParams.FilterDescendantsInstances = {lp.Character}
    local res = Workspace:Raycast(pos, Vector3.new(0, -200, 0), rayParams)
    if res and res.Position then
        return res.Position.Y
    else
        -- fallback: return pos.Y - 3 (assume ground)
        return pos.Y - 3
    end
end

-- create visual
local template = findTemplate()
if not template then warn("Template not found: "..tostring(MODEL_NAME)); return end

-- remove old
local prev = Workspace:FindFirstChild(VISUAL_NAME)
if prev then pcall(function() prev:Destroy() end) end

local ok, visual = pcall(function() return template:Clone() end)
if not ok or not visual then warn("Clone failed:", visual); return end
visual.Name = VISUAL_NAME

-- sanitize
for _,d in ipairs(visual:GetDescendants()) do
    if d:IsA("Script") or d:IsA("ModuleScript") then pcall(function() d:Destroy() end) end
    if d:IsA("Humanoid") then pcall(function() d:Destroy() end) end
    if d:IsA("BasePart") then pcall(function() d.CanCollide = false; d.Anchored = false end) end
end

local prim = visual:FindFirstChild("HumanoidRootPart", true) or visual.PrimaryPart or visual:FindFirstChildWhichIsA("BasePart", true)
if prim then visual.PrimaryPart = prim end
visual.Parent = Workspace

-- compute visual min and base offset
local visualMin = getMinY(visual) or (visual.PrimaryPart and visual.PrimaryPart.Position.Y - 1) or 0
-- compute player's groundY using raycast under player's HRP
local playerChar = lp.Character or lp.CharacterAdded:Wait()
local hrp = playerChar:FindFirstChild("HumanoidRootPart") or playerChar.PrimaryPart
if not hrp then warn("No HRP"); return end
local groundY = findGroundY(hrp.Position)
-- baseOffset = how far visual's PrimaryPart Y is above visualMin; we'll preserve this when placing on ground
local baseOffset = (visual.PrimaryPart and (visual.PrimaryPart.Position.Y - visualMin)) or 1

-- compute target primaryPart Y to set feet on ground: targetY = groundY + baseOffset
local targetPrimaryY = groundY + baseOffset

print(string.format("[morph] groundY=%.3f visualMin=%.3f baseOffset=%.3f targetPrimaryY=%.3f", groundY, visualMin, baseOffset, targetPrimaryY))

-- give visual a Humanoid+Animator for animations
local visualHum = Instance.new("Humanoid")
visualHum.Name = "VisualHumanoid"
visualHum.Parent = visual
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

-- tools handling: map real tool -> visual handle with offset relative to their hands
local toolVisuals = {} -- tool -> {instance=part, realHandle, visualHandPath, offsetCFrame}
local function findHandInCharacter(model)
    -- try common names for R15 and R6
    local names = {"RightHand", "Right Arm", "RightHandAttachment", "RightGripAttachment", "RightLowerArm"}
    for _,n in ipairs(names) do
        local p = model:FindFirstChild(n, true)
        if p and p:IsA("BasePart") then return p end
        if p and p:IsA("Attachment") then
            -- get parent part
            if p.Parent and p.Parent:IsA("BasePart") then return p.Parent end
        end
    end
    -- fallback to PrimaryPart
    return model.PrimaryPart
end

local function onToolEquipped(tool)
    if toolVisuals[tool] then return end
    local handle = tool:FindFirstChild("Handle") or tool:FindFirstChildWhichIsA("BasePart")
    if not handle then return end
    local realHand = findHandInCharacter(lp.Character)
    local visualHand = findHandInCharacter(visual)
    if not realHand or not visualHand then
        -- fallback: attach to visual PrimaryPart
        realHand = lp.Character.PrimaryPart
        visualHand = visual.PrimaryPart
        if not realHand or not visualHand then return end
    end
    -- compute offset: offset = visualHand:Inverse() * handle.CFrame when equiped relative to realHand?
    -- we want: visualHandleCFrame = visualHand.CFrame * offsetVisual
    -- where offsetVisual = visualHand.CFrame:Inverse() * ( realHand.CFrame:Inverse() * handle.CFrame ) ? Simpler: compute relative of handle to realHand, then apply same to visualHand.
    local rel = realHand.CFrame:Inverse() * handle.CFrame
    local offsetVisual = rel -- we'll apply same rel but using visualHand
    -- create visual handle
    local vh = handle:Clone()
    vh.Name = "VISUAL_HANDLE_"..tool.Name
    vh.Parent = visual
    vh.CanCollide = false
    -- hide real handle locally
    pcall(function() handle.LocalTransparencyModifier = 1 end)
    toolVisuals[tool] = {instance = vh, realHandle = handle, visualHand = visualHand, rel = rel}
end

local function onToolUnequipped(tool)
    local data = toolVisuals[tool]
    if data then
        if data.instance and data.instance.Parent then pcall(function() data.instance:Destroy() end) end
        if data.realHandle then pcall(function() data.realHandle.LocalTransparencyModifier = 0 end) end
        toolVisuals[tool] = nil
    end
end

local function bindToolsInContainer(container)
    if not container then return end
    for _,child in ipairs(container:GetChildren()) do
        if child:IsA("Tool") then
            child.Equipped:Connect(function() onToolEquipped(child) end)
            child.Unequipped:Connect(function() onToolUnequipped(child) end)
        end
    end
    container.ChildAdded:Connect(function(child)
        if child:IsA("Tool") then
            child.Equipped:Connect(function() onToolEquipped(child) end)
            child.Unequipped:Connect(function() onToolUnequipped(child) end)
        end
    end)
end

bindToolsInContainer(lp:FindFirstChildOfClass("Backpack"))
if lp.Character then bindToolsInContainer(lp.Character) end
lp.CharacterAdded:Connect(function(ch) bindToolsInContainer(ch) end)

-- follow loop
local char = lp.Character or lp.CharacterAdded:Wait()
local hrp = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
if not hrp then warn("No HRP"); return end

local followConn
followConn = RunService.RenderStepped:Connect(function()
    local success, err = pcall(function()
        if not visual or not visual.PrimaryPart or not hrp then return end
        local rx, yaw, rz = hrp.CFrame:ToOrientation()
        if type(yaw) ~= "number" then yaw = 0 end

        -- recompute groundY each frame (in case of moving over slopes)
        local groundY = findGroundY(hrp.Position)
        local targetPrimaryPos = Vector3.new(hrp.Position.X, groundY + baseOffset, hrp.Position.Z)
        local targetCFrame = CFrame.new(targetPrimaryPos) * CFrame.Angles(0, yaw, 0)
        local cur = visual.PrimaryPart.CFrame
        local new = cur:Lerp(targetCFrame, SMOOTH)
        visual:SetPrimaryPartCFrame(new)

        -- update tool visuals: set visualHandle.CFrame = visualHand.CFrame * rel (where rel was based on realHand->handle)
        for tool,data in pairs(toolVisuals) do
            if data.instance and data.visualHand and data.rel then
                pcall(function()
                    local vhnd = data.visualHand
                    if vhnd:IsA("BasePart") then
                        data.instance.CFrame = vhnd.CFrame * data.rel
                    else
                        -- if attachment/other, fallback to primarypart
                        data.instance.CFrame = visual.PrimaryPart.CFrame * data.rel
                    end
                end)
            end
        end

        -- FP / TP visibility
        if isFirstPerson() then
            for _,p in ipairs(visual:GetDescendants()) do if p:IsA("BasePart") then p.LocalTransparencyModifier = 1 end end
            setLocalVisibility(char, true)
            -- ensure real handles are visible in FP
            for tool,data in pairs(toolVisuals) do if data.realHandle then data.realHandle.LocalTransparencyModifier = 0 end end
        else
            for _,p in ipairs(visual:GetDescendants()) do if p:IsA("BasePart") then p.LocalTransparencyModifier = 0 end end
            setLocalVisibility(char, false)
            for tool,data in pairs(toolVisuals) do if data.realHandle then data.realHandle.LocalTransparencyModifier = 1 end end
        end
    end)
    if not success then
        warn("[morph] follow error:", err)
    end
end)

-- animation switching by real humanoid
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

-- local chat bubble: attach to visual head if exists
lp.Chatted:Connect(function(msg)
    if not visual then return end
    local head = visual:FindFirstChild("Head", true) or visual.PrimaryPart
    if not head then return end
    local bill = Instance.new("BillboardGui")
    bill.Adornee = head
    bill.Size = UDim2.new(0,250,0,60)
    bill.AlwaysOnTop = true
    bill.StudsOffset = Vector3.new(0, (head.Size and head.Size.Y or 2) + 0.5, 0)
    bill.Parent = visual
    local lbl = Instance.new("TextLabel", bill)
    lbl.Size = UDim2.new(1,0,1,0)
    lbl.TextScaled = true
    lbl.BackgroundTransparency = 1
    lbl.Text = msg
    lbl.Font = Enum.Font.SourceSansBold
    lbl.TextColor3 = Color3.new(1,1,1)
    delay(3, function() pcall(function() bill:Destroy() end) end)
end)

-- revert function
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

print("[morph] started. If something wrong, run revertMorph() in the client console.")
