-- visual-deer-morph-fixed5.lua  (client / injector)
-- Fixes: Full hide real char in FP (no arm dup), no visual tools (game handles FP tools in Particles), chat offset, Decal hide.

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
local HIP_OFFSET = 5.0  -- manual default; tune 4-6 if auto high

local template = workspace:FindFirstChild(TEMPLATE_NAME)
if not template then warn("Deer not found") return end

local visual = nil
local visualHum = nil
local animator = nil
local idleTrack, walkTrack = nil, nil
local followConn = nil
local toolConns = {}
local cam = workspace.CurrentCamera
local originalHip = nil
local originalChatOffset = 0

local function safeFindPart(model, names)
    for _, n in ipairs(names) do
        local p = model:FindFirstChild(n, true)
        if p and p:IsA("BasePart") then return p end
    end
    return nil
end

local function setLocalVisibility(model, visible)
    for _, v in ipairs(model:GetDescendants()) do
        if v:IsA("BasePart") then
            pcall(function() v.LocalTransparencyModifier = visible and 0 or 1 end)
        elseif v:IsA("Decal") then
            pcall(function() v.Transparency = visible and 0 or 1 end)
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

local function cleanupTools()
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
    HIP_OFFSET = (visualHeight - realHeight) / 2 - 3  -- subtract 3 for horns/extra
    print("Calculated OFFSET =", HIP_OFFSET)

    -- hack doors: no collide real head/torso
    local head = char:FindFirstChild("Head")
    local torso = char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso")
    if head then pcall(function() head.CanCollide = false end) end
    if torso then pcall(function() torso.CanCollide = false end) end

    -- chat bubble offset
    local chatConfig = game.TextChatService:FindFirstChildOfClass("BubbleChatConfiguration")
    if chatConfig then
        originalChatOffset = chatConfig.VerticalStudsOffset
        chatConfig.VerticalStudsOffset = HIP_OFFSET + 1
        print("Chat offset set to", chatConfig.VerticalStudsOffset)
    end

    -- tools (no visual tools, game handles FP tools in Particles)
    local function bindTools(container)
        if not container then return end
        for _, t in ipairs(container:GetChildren()) do
            if t:IsA("Tool") then
                toolConns[t] = t.Equipped:Connect(function()
                    setLocalVisibility(t, false)  -- hide real tool in FP/TP
                end)
                toolConns[t.."_un"] = t.Unequipped:Connect(function()
                    setLocalVisibility(t, true)
                end)
            end
        end
        container.ChildAdded:Connect(function(child)
            if child:IsA("Tool") then
                toolConns[child] = child.Equipped:Connect(function()
                    setLocalVisibility(child, false)
                end)
                toolConns[child.."_un"] = child.Unequipped:Connect(function()
                    setLocalVisibility(child, true)
                end)
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
            setLocalVisibility(char, false)  -- full hide real in FP for Particles
            -- debug check Particles
            local particles = workspace:FindFirstChild("Particles")
            local fpArms = particles and particles:FindFirstChild("FirstPersonArms")
            print("FP Arms exist:", fpArms and "yes" or "no")
        else
            setLocalVisibility(visual, true)
            setLocalVisibility(char, false)
        end
        local target = hrp.CFrame * CFrame.new(0, HIP_OFFSET, 0)
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
    local chatConfig = game.TextChatService:FindFirstChildOfClass("BubbleChatConfiguration")
    if chatConfig then chatConfig.VerticalStudsOffset = originalChatOffset end
    print("Reverted")
end

createVisual()
print("Deer visual on. revert() to off.")
_G.revert = revert-- visual-deer-morph-fixed5.lua  (client / injector)
-- Fixes: Full hide real char in FP (no arm dup), no visual tools (game handles FP tools in Particles), chat offset, Decal hide.

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
local HIP_OFFSET = 5.0  -- manual default; tune 4-6 if auto high

local template = workspace:FindFirstChild(TEMPLATE_NAME)
if not template then warn("Deer not found") return end

local visual = nil
local visualHum = nil
local animator = nil
local idleTrack, walkTrack = nil, nil
local followConn = nil
local toolConns = {}
local cam = workspace.CurrentCamera
local originalHip = nil
local originalChatOffset = 0

local function safeFindPart(model, names)
    for _, n in ipairs(names) do
        local p = model:FindFirstChild(n, true)
        if p and p:IsA("BasePart") then return p end
    end
    return nil
end

local function setLocalVisibility(model, visible)
    for _, v in ipairs(model:GetDescendants()) do
        if v:IsA("BasePart") then
            pcall(function() v.LocalTransparencyModifier = visible and 0 or 1 end)
        elseif v:IsA("Decal") then
            pcall(function() v.Transparency = visible and 0 or 1 end)
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

local function cleanupTools()
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
    HIP_OFFSET = (visualHeight - realHeight) / 2 - 3  -- subtract 3 for horns/extra
    print("Calculated OFFSET =", HIP_OFFSET)

    -- hack doors: no collide real head/torso
    local head = char:FindFirstChild("Head")
    local torso = char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso")
    if head then pcall(function() head.CanCollide = false end) end
    if torso then pcall(function() torso.CanCollide = false end) end

    -- chat bubble offset
    local chatConfig = game.TextChatService:FindFirstChildOfClass("BubbleChatConfiguration")
    if chatConfig then
        originalChatOffset = chatConfig.VerticalStudsOffset
        chatConfig.VerticalStudsOffset = HIP_OFFSET + 1
        print("Chat offset set to", chatConfig.VerticalStudsOffset)
    end

    -- tools (no visual tools, game handles FP tools in Particles)
    local function bindTools(container)
        if not container then return end
        for _, t in ipairs(container:GetChildren()) do
            if t:IsA("Tool") then
                toolConns[t] = t.Equipped:Connect(function()
                    setLocalVisibility(t, false)  -- hide real tool in FP/TP
                end)
                toolConns[t.."_un"] = t.Unequipped:Connect(function()
                    setLocalVisibility(t, true)
                end)
            end
        end
        container.ChildAdded:Connect(function(child)
            if child:IsA("Tool") then
                toolConns[child] = child.Equipped:Connect(function()
                    setLocalVisibility(child, false)
                end)
                toolConns[child.."_un"] = child.Unequipped:Connect(function()
                    setLocalVisibility(child, true)
                end)
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
            setLocalVisibility(char, false)  -- full hide real in FP for Particles
            -- debug check Particles
            local particles = workspace:FindFirstChild("Particles")
            local fpArms = particles and particles:FindFirstChild("FirstPersonArms")
            print("FP Arms exist:", fpArms and "yes" or "no")
        else
            setLocalVisibility(visual, true)
            setLocalVisibility(char, false)
        end
        local target = hrp.CFrame * CFrame.new(0, HIP_OFFSET, 0)
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
    local chatConfig = game.TextChatService:FindFirstChildOfClass("BubbleChatConfiguration")
    if chatConfig then chatConfig.VerticalStudsOffset = originalChatOffset end
    print("Reverted")
end

createVisual()
print("Deer visual on. revert() to off.")
_G.revert = revert
