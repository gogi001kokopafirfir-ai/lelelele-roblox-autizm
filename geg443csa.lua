-- morph-deer-inject.lua  (client / injector for private place)
-- M = morph to Deer with anims, R = revert. Auto-morph on load.
-- Features: Anims (idle/walk), FP shows original-ish hands (auto if rig match), tools interact (visible in TP fixed near char), chat over Deer head.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local lp = Players.LocalPlayer
if not lp then warn("No LocalPlayer") return end

local TEMPLATE = workspace:FindFirstChild("Deer")
if not TEMPLATE then warn("Deer model not found in workspace") return end

local IDLE_ID = "rbxassetid://138304500572165"  -- check in Studio if loads
local WALK_ID = "rbxassetid://78826693826761"

local AUTO_MORPH_ON_LOAD = true  -- set false if manual only
local morphedData = {}  -- {UserId = {oldChar, newChar, idleTrack, walkTrack, animConn}}

local function getRoot(model)
    return model:FindFirstChild("HumanoidRootPart") or model:FindFirstChildWhichIsA("BasePart")
end

local function safeSetCamera(char)
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum and workspace.CurrentCamera then
        workspace.CurrentCamera.CameraSubject = hum
    end
end

local function loadAnim(animator, id, looped, priority)
    local anim = Instance.new("Animation")
    anim.AnimationId = id
    local track = pcall(function() return animator:LoadAnimation(anim) end)
    if not track then warn("Failed load anim:", id) return nil end
    track.Looped = looped
    track.Priority = priority or Enum.AnimationPriority.Movement
    return track
end

local function setupAnims(char)
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then warn("No Humanoid in clone") return nil, nil end
    local animator = Instance.new("Animator", hum)
    local idle = loadAnim(animator, IDLE_ID, true)
    local walk = loadAnim(animator, WALK_ID, true)
    if idle then idle:Play() end  -- start idle

    -- switch on speed
    local conn = hum.Running:Connect(function(speed)
        if speed > 0.5 then
            if idle and idle.IsPlaying then idle:Stop(0.1) end
            if walk and not walk.IsPlaying then walk:Play() end
        else
            if walk and walk.IsPlaying then walk:Stop(0.1) end
            if idle and not idle.IsPlaying then idle:Play() end
        end
    end)

    return idle, walk, conn
end

local function morphPlayer(plr)
    if morphedData[plr.UserId] then return end  -- already morphed

    local oldChar = plr.Character or plr.CharacterAdded:Wait()
    if not oldChar then warn("No old char") return end

    local clone = TEMPLATE:Clone()
    clone.Name = plr.Name

    -- position
    local oldRoot = getRoot(oldChar)
    local newRoot = getRoot(clone)
    if oldRoot and newRoot then
        newRoot.CFrame = oldRoot.CFrame
    end

    clone.Parent = workspace

    -- setup anims before assign (engine auto-hipheight after)
    local idle, walk, animConn = setupAnims(clone)

    -- assign char
    pcall(function() plr.Character = clone end)
    safeSetCamera(clone)

    -- transfer tools from old to new (backpack or equipped)
    local backpack = plr:FindFirstChildOfClass("Backpack")
    if backpack then
        for _, tool in ipairs(backpack:GetChildren()) do
            if tool:IsA("Tool") then tool.Parent = clone end
        end
    end
    for _, tool in ipairs(oldChar:GetChildren()) do
        if tool:IsA("Tool") then tool.Parent = clone end
    end

    -- store
    morphedData[plr.UserId] = {oldChar = oldChar, newChar = clone, idleTrack = idle, walkTrack = walk, animConn = animConn}

    -- optional: if tools not in hands, fix position (e.g. attach to root + offset)
    -- RunService.Heartbeat:Connect(function() -- if need fixed pos
    --     for _, tool in ipairs(clone:GetChildren()) do
    --         if tool:IsA("Tool") and tool.Handle then
    --             tool.Handle.CFrame = newRoot.CFrame * CFrame.new(2, 0, 0)  -- example offset right
    --         end
    --     end
    -- end)

    -- FP hack: if want original hands, clone old arms and attach (uncomment if rig mismatch)
    -- local oldRightArm = oldChar:FindFirstChild("RightUpperArm")  -- assume R15
    -- if oldRightArm then
    --     local fpArm = oldRightArm:Clone()
    --     fpArm.Parent = workspace.CurrentCamera  -- attach to cam
    --     -- position via RenderStepped to follow
    -- end  -- but this bags, better match rig

    -- destroy old char after delay (avoid nil refs)
    task.delay(1, function() if oldChar then oldChar:Destroy() end end)
end

local function revertPlayer(plr)
    local data = morphedData[plr.UserId]
    if not data then return end

    if data.animConn then data.animConn:Disconnect() end
    if data.idleTrack then data.idleTrack:Stop() end
    if data.walkTrack then data.walkTrack:Stop() end

    if data.oldChar and data.oldChar.Parent then
        pcall(function() plr.Character = data.oldChar end)
        safeSetCamera(data.oldChar)
    else
        plr:LoadCharacter()
    end

    if data.newChar then data.newChar:Destroy() end
    morphedData[plr.UserId] = nil
end

-- keys
UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.M then morphPlayer(lp) end
    if input.KeyCode == Enum.KeyCode.R then revertPlayer(lp) end
end)

-- reset on respawn
lp.CharacterAdded:Connect(function() morphedData[lp.UserId] = nil end)

-- auto
if AUTO_MORPH_ON_LOAD then
    task.wait(0.5)  -- wait load
    morphPlayer(lp)
end

print("[Deer Morph] Ready. M = morph, R = revert.")
