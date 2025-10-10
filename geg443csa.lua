-- visual-deer-morph-fixed3.lua  (client / injector)
-- Fixes: Manual OFFSET default 5.0 (tune for no air/ground clip), print extents, no negative Hip.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local lp = Players.LocalPlayer
if not lp then warn("No LocalPlayer") return end

local TEMPLATE_NAME = "Deer"
local IDLE_ID = "rbxassetid://138304500572165"
local WALK_ID = "rbxassetid://78826693826761"
local VISUAL_NAME = "LOCAL_DEER_VISUAL"
local SMOOTH = 1  -- max smooth, no jitter
local FP_HIDE_DISTANCE = 0.6
local HIP_OFFSET = 5.0  -- manual tune here; 5-7 for typical oversized Deer; print below helps

local template = workspace:FindFirstChild(TEMPLATE_NAME)
if not template then warn("Deer not found") return end

local visual = nil
local visualHum = nil
local animator = nil
local idleTrack, walkTrack = nil, nil
local followConn = nil
local toolVisuals = {}
local toolConns = {}
local cam = workspace.CurrentCamera
local originalHip = nil

local function safeFindPart(model, names)
    for _, n in ipairs(names) do
        local p = model:FindFirstChild(n, true)
        if p and p:IsA("BasePart") then return p end
    end
    return nil
end

local function setLocalVisibility(model, visible, excludeArms)
    for _, v in ipairs(model:GetDescendants()) do
        if v:IsA("BasePart") then
            local name = v.Name:lower()
            if excludeArms and (name:find("arm") or name:find("hair") or name:find("hand")) then
                -- skip
            elseif excludeArms and (name:find("head") or name:find("torso") or name:find("leg") or name:find("hair")) then
                pcall(function() v.LocalTransparencyModifier = 1 end)
            else
                pcall(function() v.LocalTransparencyModifier = visible and 0 or 1 end)
            end
        end
    end
end

local function isFirstPerson()
    local char = lp.Character
    local head = char and char:FindFirstChild("Head")
    return head and (cam.CFrame.Position - head.Position).Magnitude < FP_HIDE_DISTANCE
end

local function loadTrack(animator, id, looped)
    local anim = Instance.new("Animation")
    anim.AnimationId = id
    local success, track = pcall(animator.LoadAnimation, animator, anim)
    if not success then warn("Load fail " .. id .. ": " .. track) anim:Destroy() return nil end
    track.Looped = looped
    track.Priority = Enum.AnimationPriority.Movement
    return track
end

local function createToolVisual(tool)
    if not visual then return end
    local vTool = tool:Clone()
    vTool.Name = "VISUAL_" .. tool.Name
    vTool.Parent = visual
    for _, p in ipairs(vTool:GetDescendants()) do if p:IsA("BasePart") then p.CanCollide = false end end

    local hand = safeFindPart(visual, {"RightHand", "RightUpperArm", "RightArm"})
    if not hand then hand = visual.PrimaryPart end
    local handle = vTool:FindFirstChild("Handle") or vTool:FindFirstChildWhichIsA("BasePart")
    if not handle then return end

    local attV = Instance.new("Attachment", handle)
    local attH = Instance.new("Attachment", hand)
    local ap = Instance.new("AlignPosition", handle); ap.Attachment0 = attV; ap.Attachment1 = attH; ap.RigidityEnabled = true; ap.MaxForce = 1e5; ap.Responsiveness = 200
    local ao = Instance.new("AlignOrientation", handle); ao.Attachment0 = attV; ao.Attachment1 = attH; ao.RigidityEnabled = true; ao.MaxTorque = 1e5; ao.Responsiveness = 200

    return vTool
end

local function cleanupTools()
    for _, v in pairs(toolVisuals) do if v then v:Destroy() end end
    toolVisuals = {}
    for _, c in pairs(toolConns) do if c then c:Disconnect() end end
    toolConns = {}
end

local function createVisual()
    if visual then return end
    local clone = template:Clone()
    clone.Name = VISUAL_NAME
    for _, d in ipairs(clone:GetDescendants()) do
        if d:IsA("Script") or d:IsA("ModuleScript") or d:IsA("Humanoid") then d:Destroy() end
        if d:IsA("BasePart") then d.CanCollide = false; d.Anchored = false end
    end
    local prim = clone:FindFirstChild("HumanoidRootPart") or clone:FindFirstChildWhichIsA("BasePart")
    if prim then clone.PrimaryPart = prim end
    clone.Parent = workspace
    visual = clone

    visualHum = Instance.new("Humanoid", visual)
    animator = Instance.new("Animator", visualHum)
    idleTrack = loadTrack(animator, IDLE_ID, true)
    walkTrack = loadTrack(animator, WALK_ID, true)
    if idleTrack then idleTrack:Play() end

    local char = lp.Character or lp.CharacterAdded:Wait()
    local realHum = char:FindFirstChildOfClass("Humanoid")
    if realHum then
        originalHip = realHum.HipHeight
    end
    setLocalVisibility(char, false)

    -- auto offset (comment if manual only)
    local realHeight = char:GetExtentsSize().Y
    local visualHeight = visual:GetExtentsSize().Y
    HIP_OFFSET = (visualHeight - realHeight) / 2 - 3  -- subtract 3 for horns/extra; tune -1 to -5 if still high
    print("Calculated OFFSET =", HIP_OFFSET)

    -- hack doors: no collide real head/torso
    local head = char:FindFirstChild("Head")
    local torso = char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso")
    if head then pcall(function() head.CanCollide = false end) end
    if torso then pcall(function() torso.CanCollide = false end) end

    -- tools
    local function onEquip(tool)
        setLocalVisibility(tool, false)
        toolVisuals[tool] = createToolVisual(tool)
    end
    local function onUnequip(tool)
        if toolVisuals[tool] then toolVisuals[tool]:Destroy() toolVisuals[tool] = nil end
        setLocalVisibility(tool, true)
    end
    local function bindTools(container)
        if not container then return end
        for _, t in ipairs(container:GetChildren()) do
            if t:IsA("Tool") then
                toolConns[t] = t.Equipped:Connect(onEquip)
                toolConns[t.."_un"] = t.Unequipped:Connect(onUnequip)
            end
        end
        container.ChildAdded:Connect(function(child)
            if child:IsA("Tool") then
                toolConns[child] = child.Equipped:Connect(onEquip)
                toolConns[child.."_un"] = child.Unequipped:Connect(onUnequip)
            end
        end)
    end
    bindTools(lp.Backpack)
    bindTools(char)
    lp.CharacterAdded:Connect(function(newChar)
        bindTools(newChar)
        local head = newChar:FindFirstChild("Head")
        local torso = newChar:FindFirstChild("UpperTorso") or newChar:FindFirstChild("Torso")
        if head then pcall(function() head.CanCollide = false end) end
        if torso then pcall(function() torso.CanCollide = false end) end
        setLocalVisibility(newChar, false)
    end)

    -- follow
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then warn("No HRP") return end
    followConn = RunService.RenderStepped:Connect(function()
        if not visual or not visual.PrimaryPart or not hrp then return end
        local fp = isFirstPerson()
        if fp then
            setLocalVisibility(visual, false)
            for _, vt in pairs(toolVisuals) do setLocalVisibility(vt, false) end
            setLocalVisibility(char, true, true)
        else
            setLocalVisibility(visual, true)
            for _, vt in pairs(toolVisuals) do setLocalVisibility(vt, true) end
            setLocalVisibility(char, false)
        end
        local target = hrp.CFrame * CFrame.new(0, HIP_OFFSET, 0)  -- up visual
        local cur = visual.PrimaryPart.CFrame
        visual:SetPrimaryPartCFrame(cur:Lerp(target, SMOOTH))
    end)

    -- anim
    if realHum and walkTrack then
        realHum.Running:Connect(function(speed)
            if speed > 0.5 then
                if idleTrack then idleTrack:Stop(0.1) end
                if walkTrack then walkTrack:Play() end
            else
                if walkTrack then walkTrack:Stop(0.1) end
                if idleTrack then idleTrack:Play() end
            end
        end)
    end
end

local function revert()
    if followConn then followConn:Disconnect() end
    cleanupTools()
    if visual then visual:Destroy() end
    visual = nil; animator = nil; idleTrack = nil; walkTrack = nil
    local char = lp.Character
    if char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum and originalHip then hum.HipHeight = originalHip end
        setLocalVisibility(char, true)
    end
    print("Reverted")
end

createVisual()
print("Deer visual on. revert() to off.")
_G.revert = revert
