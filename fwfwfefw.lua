-- visual-deer-morph-fixed11.lua  (client / injector)
-- Added: Visual tool clone/attach to Deer hand on equip, manual offset tune.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local lp = Players.LocalPlayer
if not lp then warn("No LocalPlayer") return end

-- Подставь свои настройки / ID
local TEMPLATE_NAME = "Deer"
local IDLE_ID = "rbxassetid://138304500572165"
local WALK_ID = "rbxassetid://78826693826761"
local VISUAL_NAME = "LOCAL_DEER_VISUAL"
local FP_HIDE_DISTANCE = 0.6
local HIP_MANUAL_OFFSET = nil
local TOOL_OFFSET = CFrame.new(0, 0, 0) * CFrame.Angles(0, 0, 0)  -- manual tune pos/rot with F3X (e.g. Vector3(0.5, 0, -1), math.rad(90,0,0))

local template = workspace:FindFirstChild(TEMPLATE_NAME)
if not template then warn("Deer template not found") return end

local visual, animator, animController, idleTrack, walkTrack
local followConn, runConn
local connections = {}
local toolConns = {}
local childAddedConns = {}
local cam = workspace.CurrentCamera
local currentToolVisual = nil  -- current visual tool

local function addConn(c) if c then table.insert(connections, c) end end
local function disconnectAll() for _,c in ipairs(connections) do pcall(function() c:Disconnect() end) end connections = {} end

local function setLocalVisibility(model, visible, isVisual)
    if not model then return end
    for _, v in ipairs(model:GetDescendants()) do
        if v:IsA("BasePart") then
            pcall(function()
                v.LocalTransparencyModifier = visible and 0 or 1
                -- только для визуала меняем коллайд/массу
                if isVisual then
                    v.CanCollide = false
                    if v.Massless ~= nil then v.Massless = true end
                end
            end)
        end
    end
end

local function isFirstPerson()
    local char = lp.Character
    local head = char and char:FindFirstChild("Head")
    if not head or not cam then return false end
    return (cam.CFrame.Position - head.Position).Magnitude < FP_HIDE_DISTANCE
end

local function lowestY(model)
    if not model then return nil end
    local minY = math.huge; local found = false
    for _, p in ipairs(model:GetDescendants()) do
        if p:IsA("BasePart") then
            found = true
            local bottom = p.Position.Y - (p.Size.Y/2)
            if bottom < minY then minY = bottom end
        end
    end
    return found and minY or nil
end

local function loadTrack(animObj, id, looped)
    if not animObj or not id then return nil end
    local anim = Instance.new("Animation")
    anim.AnimationId = id
    anim.Parent = animObj
    local ok, track = pcall(function() return animObj:LoadAnimation(anim) end)
    if not ok or not track then pcall(function() anim:Destroy() end) warn("anim load failed", id, track) return nil end
    track.Looped = looped and true or false
    track.Priority = Enum.AnimationPriority.Movement
    return track
end

local function createVisualTool(tool)
    if not visual then return end
    -- clone ToolHandle if exist, else tool itself
    local handle = workspace:FindFirstChild("ToolHandle") or tool:FindFirstChild("Handle") or tool  -- game custom ToolHandle
    if not handle then return end
    local vHandle = handle:Clone()
    vHandle.Name = "VISUAL_TOOL_" .. (tool.Name or "Tool")
    vHandle.Parent = visual
    setLocalVisibility(vHandle, true, true)  -- apply visual props

    local deerHand = safeFindPart(visual, {"RightHand", "RightUpperArm", "RightArm"})
    if not deerHand then deerHand = visual.PrimaryPart end
    local gripAtt = vHandle:FindFirstChild("RightGripAttachment") or Instance.new("Attachment", vHandle)  -- use existing or new

    local handAtt = Instance.new("Attachment", deerHand)
    local ap = Instance.new("AlignPosition", vHandle); ap.Attachment0 = gripAtt; ap.Attachment1 = handAtt; ap.RigidityEnabled = true; ap.MaxForce = math.huge; ap.Responsiveness = 200
    local ao = Instance.new("AlignOrientation", vHandle); ao.Attachment0 = gripAtt; ao.Attachment1 = handAtt; ao.RigidityEnabled = true; ao.MaxTorque = math.huge; ao.Responsiveness = 200

    -- manual offset apply
    gripAtt.CFrame = TOOL_OFFSET

    return vHandle
end

local function bindTools(container)
    if not container then return end
    for _, t in ipairs(container:GetChildren()) do
        if t:IsA("Tool") and not toolConns[t] then
            toolConns[t] = {}
            toolConns[t].equip = t.Equipped:Connect(function()
                setLocalVisibility(t, false, false)
                if currentToolVisual then currentToolVisual:Destroy() end
                currentToolVisual = createVisualTool(t)
            end)
            toolConns[t].unequip = t.Unequipped:Connect(function()
                setLocalVisibility(t, true, false)
                if currentToolVisual then currentToolVisual:Destroy() currentToolVisual = nil end
            end)
            addConn(toolConns[t].equip); addConn(toolConns[t].unequip)
        end
    end
    if not childAddedConns[container] then
        childAddedConns[container] = container.ChildAdded:Connect(function(child)
            if child:IsA("Tool") and not toolConns[child] then
                toolConns[child] = {}
                toolConns[child].equip = child.Equipped:Connect(function()
                    setLocalVisibility(child, false, false)
                    if currentToolVisual then currentToolVisual:Destroy() end
                    currentToolVisual = createVisualTool(child)
                end)
                toolConns[child].unequip = child.Unequipped:Connect(function()
                    setLocalVisibility(child, true, false)
                    if currentToolVisual then currentToolVisual:Destroy() currentToolVisual = nil end
                end)
                addConn(toolConns[child].equip); addConn(toolConns[child].unequip)
            end
        end)
        addConn(childAddedConns[container])
    end
end

local function cleanupTools()
    for tool, tbl in pairs(toolConns) do
        if tbl.equip then pcall(function() tbl.equip:Disconnect() end) end
        if tbl.unequip then pcall(function() tbl.unequip:Disconnect() end) end
        toolConns[tool] = nil
    end
    for c, conn in pairs(childAddedConns) do pcall(function() conn:Disconnect() end) childAddedConns[c] = nil end
    if currentToolVisual then currentToolVisual:Destroy() currentToolVisual = nil end
end

local function createVisual()
    if visual then return end
    local ok, clone = pcall(function() return template:Clone() end)
    if not ok or not clone then warn("clone failed", clone) return end
    clone.Name = VISUAL_NAME

    -- sanitize clone
    for _, d in ipairs(clone:GetDescendants()) do
        if d:IsA("Script") or d:IsA("ModuleScript") or d:IsA("Humanoid") then pcall(function() d:Destroy() end) end
        if d:IsA("BasePart") then pcall(function() d.CanCollide = false; d.Anchored = false; if d.Massless ~= nil then d.Massless = true end end) end
    end

    local prim = clone:FindFirstChild("HumanoidRootPart") or clone:FindFirstChildWhichIsA("BasePart", true)
    if prim then clone.PrimaryPart = prim end
    clone.Parent = workspace
    visual = clone

    -- align feet
    local char = lp.Character or lp.CharacterAdded:Wait()
    local hrp = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
    local playerFeet = lowestY(char)
    local visualFeet = lowestY(visual)
    if playerFeet and visualFeet then
        local dy = playerFeet - visualFeet
        pcall(function() if visual.PrimaryPart then visual:SetPrimaryPartCFrame(visual.PrimaryPart.CFrame * CFrame.new(0, dy, 0)) end end)
        print("[visual] aligned feet dy=", dy)
    else
        print("[visual] feet align failed")
    end

    -- AnimationController (no Humanoid)
    animController = Instance.new("AnimationController"); animController.Parent = visual
    animator = Instance.new("Animator"); animator.Parent = animController
    idleTrack = loadTrack(animator, IDLE_ID, true)
    walkTrack = loadTrack(animator, WALK_ID, true)
    if idleTrack then pcall(function() idleTrack:Play() end) end

    -- hide real char visually (do NOT change its CanCollide)
    setLocalVisibility(char, false, false)

    -- compute HIP_OFFSET
    local HIP_OFFSET = HIP_MANUAL_OFFSET
    if not HIP_OFFSET then
        if visual.PrimaryPart and hrp then HIP_OFFSET = visual.PrimaryPart.Position.Y - hrp.Position.Y else HIP_OFFSET = 5.0 end
    end
    print("[visual] HIP_OFFSET =", HIP_OFFSET)

    -- bind tools
    pcall(function() bindTools(lp:FindFirstChildOfClass("Backpack")) end)
    pcall(function() bindTools(char) end)
    addConn(lp.CharacterAdded:Connect(function(nc) pcall(function() bindTools(nc) end); pcall(function() setLocalVisibility(nc, false, false) end) end))

    -- follow loop: snap PrimaryPart to target each frame, and zero velocities for all visual parts
    followConn = RunService.RenderStepped:Connect(function()
        if not visual or not visual.PrimaryPart or not hrp then return end
        local fp = isFirstPerson()
        if fp then
            setLocalVisibility(visual, false, true)
            setLocalVisibility(char, false, false)
        else
            setLocalVisibility(visual, true, true)
            setLocalVisibility(char, false, false)
        end

        local target = hrp.CFrame * CFrame.new(0, HIP_OFFSET, 0)
        -- snap root
        pcall(function() visual:SetPrimaryPartCFrame(target) end)
        -- zero velocities to avoid physics drift (do for parts only)
        for _, part in ipairs(visual:GetDescendants()) do
            if part:IsA("BasePart") then
                pcall(function()
                    part.AssemblyLinearVelocity = Vector3.new(0,0,0)
                    part.AssemblyAngularVelocity = Vector3.new(0,0,0)
                end)
            end
        end
    end)
    addConn(followConn)

    -- sync run -> anims
    local realHum = char:FindFirstChildOfClass("Humanoid")
    if realHum and walkTrack then
        runConn = realHum.Running:Connect(function(speed)
            if speed > 0.5 then
                if idleTrack then pcall(function() idleTrack:Stop(0.12) end) end
                if walkTrack and not walkTrack.IsPlaying then pcall(function() walkTrack:Play() end) end
            else
                if walkTrack and walkTrack.IsPlaying then pcall(function() walkTrack:Stop(0.12) end) end
                if idleTrack and not idleTrack.IsPlaying then pcall(function() idleTrack:Play() end) end
            end
        end)
        addConn(runConn)
    end

    print("[visual] created")
end

local function revertVisual()
    disconnectAll()
    cleanupTools()
    if visual and visual.Parent then pcall(function() visual:Destroy() end) end
    visual, animator, animController, idleTrack, walkTrack = nil, nil, nil, nil, nil
    local char = lp.Character
    if char then pcall(function() setLocalVisibility(char, true, false) end) end
    print("[visual] reverted")
end

-- run
