-- morph-deer-inject-fixed-hip.lua  (client / injector)
-- Fixes: HipHeight to original for doors/height, proper pcall, checks.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local lp = Players.LocalPlayer
if not lp then warn("No LocalPlayer") return end

local TEMPLATE = workspace:FindFirstChild("Deer")
if not TEMPLATE then warn("Deer not found") return end

local IDLE_ID = "rbxassetid://138304500572165"  -- тесть ID в Studio
local WALK_ID = "rbxassetid://78826693826761"

local AUTO_MORPH_ON_LOAD = true
local FIXED_HIP = 1.0  -- manual tune: original R15 ~2.0; уменьши, если всё равно высоко/не проходит
local morphedData = {}

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
    local success, track = pcall(animator.LoadAnimation, animator, anim)
    if not success then
        warn("Failed load " .. id .. ": " .. tostring(track))
        anim:Destroy()
        return nil
    end
    track.Looped = looped or false
    track.Priority = priority or Enum.AnimationPriority.Movement
    return track
end

local function setupAnims(char)
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then warn("No Humanoid") return nil, nil, nil end
    local animator = hum:FindFirstChildOfClass("Animator") or Instance.new("Animator", hum)
    local idle = loadAnim(animator, IDLE_ID, true)
    local walk = loadAnim(animator, WALK_ID, true)
    if not idle or not walk then warn("Anims fail") return nil, nil, nil end
    idle:Play()

    local conn = hum.Running:Connect(function(speed)
        if speed > 0.5 then
            if idle.IsPlaying then idle:Stop(0.1) end
            if not walk.IsPlaying then walk:Play() end
        else
            if walk.IsPlaying then walk:Stop(0.1) end
            if not idle.IsPlaying then idle:Play() end
        end
    end)

    return idle, walk, conn
end

local function morphPlayer(plr)
    if morphedData[plr.UserId] then return end

    local oldChar = plr.Character or plr.CharacterAdded:Wait()
    if not oldChar then warn("No old char") return end
    local oldHum = oldChar:FindFirstChildOfClass("Humanoid")
    local originalHip = oldHum and oldHum.HipHeight or FIXED_HIP  -- save original

    local clone = TEMPLATE:Clone()
    clone.Name = plr.Name

    local oldRoot = getRoot(oldChar)
    local newRoot = getRoot(clone)
    if oldRoot and newRoot then
        newRoot.CFrame = oldRoot.CFrame
    end

    clone.Parent = workspace

    local idle, walk, animConn = setupAnims(clone)
    if not idle then warn("Anims failed, abort") clone:Destroy() return end

    -- fix height for doors: set to original HipHeight
    local newHum = clone:FindFirstChildOfClass("Humanoid")
    if newHum then
        newHum.HipHeight = originalHip  -- or FIXED_HIP if nil
        print("Set Deer HipHeight to", newHum.HipHeight)  -- debug F9
    end

    local success = pcall(function() plr.Character = clone end)
    if not success then warn("Set char failed") clone:Destroy() return end
    safeSetCamera(clone)

    -- tools transfer
    local backpack = plr:FindFirstChildOfClass("Backpack")
    if backpack then
        for _, tool in ipairs(backpack:GetChildren()) do
            if tool:IsA("Tool") then tool.Parent = clone end
        end
    end
    for _, tool in ipairs(oldChar:GetChildren()) do
        if tool:IsA("Tool") then tool.Parent = clone end
    end

    morphedData[plr.UserId] = {oldChar = oldChar, newChar = clone, idleTrack = idle, walkTrack = walk, animConn = animConn}

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

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.M then morphPlayer(lp) end
    if input.KeyCode == Enum.KeyCode.R then revertPlayer(lp) end
end)

lp.CharacterAdded:Connect(function() morphedData[lp.UserId] = nil end)

if AUTO_MORPH_ON_LOAD then
    task.wait(0.5)
    morphPlayer(lp)
end

print("[Deer Morph Hip Fix] Ready. M = morph, R = revert.")
