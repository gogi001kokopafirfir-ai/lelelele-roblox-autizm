-- morph-replace-simple-injector.lua
-- Клиентский/инжекторный скрипт: аккуратно заменяет LocalPlayer.Character на шаблон и локально проигрывает анимации.
-- Настрой: поменяй TEMPLATE_NAMES, IDLE_ID, WALK_ID при необходимости.

local TEMPLATE_NAMES = {"Deer", "Deer_LOCAL"} -- имена шаблона в workspace (в порядке приоритета)
local IDLE_ID = "rbxassetid://138304500572165"
local WALK_ID = "rbxassetid://78826693826761"

local Players = game:GetService("Players")
local StarterPlayer = game:GetService("StarterPlayer")
local RunService = game:GetService("RunService")

local lp = Players.LocalPlayer
if not lp then warn("[morph] LocalPlayer not found"); return end
local oldChar = lp.Character or lp.CharacterAdded:Wait()

local function log(...) print("[morph]", ...) end
local function warnlog(...) warn("[morph]", ...) end

-- helper: find template model in workspace
local function findTemplate()
    for _, name in ipairs(TEMPLATE_NAMES) do
        local m = workspace:FindFirstChild(name)
        if m and m:IsA("Model") then return m end
    end
    for _, m in ipairs(workspace:GetChildren()) do
        if m:IsA("Model") and string.find(string.lower(m.Name or ""), "deer", 1, true) then return m end
    end
    return nil
end

local function setPrimaryIfMissing(model)
    if not model.PrimaryPart then
        local p = model:FindFirstChild("HumanoidRootPart", true) or model:FindFirstChildWhichIsA("BasePart", true)
        if p then model.PrimaryPart = p; log("PrimaryPart set to", p:GetFullName()) end
    end
end

local function lowestYOfModel(m)
    local minY = math.huge
    for _, part in ipairs(m:GetDescendants()) do
        if part:IsA("BasePart") then
            local bottom = part.Position.Y - part.Size.Y / 2
            if bottom < minY then minY = bottom end
        end
    end
    if minY == math.huge then return nil end
    return minY
end

local function prepareClone(orig)
    local ok, clone = pcall(function() return orig:Clone() end)
    if not ok or not clone then warnlog("Clone failed:", clone); return nil end

    -- remove server scripts/modules/humanoids inside template to avoid conflicts
    for _, d in ipairs(clone:GetDescendants()) do
        if d:IsA("Script") or d:IsA("ModuleScript") or d:IsA("Humanoid") then
            pcall(function() d:Destroy() end)
        end
        if d:IsA("BasePart") then
            pcall(function() d.Anchored = false; d.CanCollide = false end)
        end
    end

    setPrimaryIfMissing(clone)
    return clone
end

local function copyStarterLocalScriptsToClone(clone)
    local folder = StarterPlayer:FindFirstChild("StarterCharacterScripts")
    if not folder then return end
    for _, child in ipairs(folder:GetChildren()) do
        if child:IsA("LocalScript") then
            local ok, c = pcall(function() return child:Clone() end)
            if ok and c then c.Parent = clone; log("Copied Starter LocalScript:", c.Name) end
        end
    end
end

local function transferTools(oldChar, newChar)
    if not lp then return end
    local bp = lp:FindFirstChildOfClass("Backpack")
    local function move(tool)
        if tool and tool:IsA("Tool") then
            pcall(function() tool.Parent = newChar end)
        end
    end
    if bp then
        for _, t in ipairs(bp:GetChildren()) do move(t) end
    end
    if oldChar then
        for _, t in ipairs(oldChar:GetChildren()) do
            if t:IsA("Tool") then move(t) end
        end
    end
end

-- FP local hiding helper (local only)
local function setLocalVisibility(character, visible)
    for _, v in ipairs(character:GetDescendants()) do
        if v:IsA("BasePart") then
            pcall(function() v.LocalTransparencyModifier = visible and 0 or 1 end)
        end
    end
end

-- safe animation loader (executed in injector, client-side)
local function loadAndPlayAnimationsOn(humanoid, idleId, walkId)
    if not humanoid then return nil end
    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then animator = Instance.new("Animator"); animator.Parent = humanoid end

    local function safeLoad(id)
        if not id or id == "" then return nil end
        local anim = Instance.new("Animation")
        anim.AnimationId = id
        anim.Parent = humanoid
        local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
        if not ok or not track then
            warn("[morph] LoadAnimation failed:", id, track)
            pcall(function() anim:Destroy() end)
            return nil
        end
        track.Priority = Enum.AnimationPriority.Movement
        return track
    end

    local idleTrack = safeLoad(idleId)
    local walkTrack = safeLoad(walkId)

    if idleTrack then pcall(function() idleTrack.Looped = true; idleTrack:Play() end) end

    if walkTrack then
        humanoid.Running:Connect(function(speed)
            if speed and speed > 0.5 then
                if idleTrack and idleTrack.IsPlaying then pcall(function() idleTrack:Stop(0.12) end) end
                if walkTrack and not walkTrack.IsPlaying then pcall(function() walkTrack:Play() end) end
            else
                if walkTrack and walkTrack.IsPlaying then pcall(function() walkTrack:Stop(0.12) end) end
                if idleTrack and not idleTrack.IsPlaying then pcall(function() idleTrack:Play() end) end
            end
        end)
    end

    return {idle = idleTrack, walk = walkTrack}
end

-- main morph procedure
local function doMorph()
    local template = findTemplate()
    if not template then warnlog("Template not found"); return end

    local newChar = prepareClone(template)
    if not newChar then warnlog("prepareClone failed"); return end

    -- try position clone at old character pivot
    setPrimaryIfMissing(newChar)
    local oldPivot = (oldChar.GetPivot and oldChar:GetPivot()) or (oldChar.PrimaryPart and oldChar.PrimaryPart.CFrame)
    if oldPivot and newChar.PrimaryPart then
        pcall(function() newChar:SetPrimaryPartCFrame(oldPivot) end)
    end

    -- vertical alignment by feet
    local playerFeetY = lowestYOfModel(oldChar)
    local cloneFeetY = lowestYOfModel(newChar)
    if playerFeetY and cloneFeetY and newChar.PrimaryPart then
        local delta = playerFeetY - cloneFeetY
        if math.abs(delta) > 1e-5 then
            pcall(function() newChar:SetPrimaryPartCFrame(newChar.PrimaryPart.CFrame * CFrame.new(0, delta, 0)) end)
            log("Vertical adjusted by", delta)
        end
    else
        log("Feet Y couldn't be computed; skipping vertical alignment")
    end

    -- parent into workspace BEFORE assignment
    newChar.Parent = workspace
    newChar.Name = lp.Name or "Player"

    -- optionally copy StarterCharacterScripts (so Animate and other local controllers exist)
    copyStarterLocalScriptsToClone(newChar)

    -- transfer tools
    transferTools(oldChar, newChar)

    -- assign as character (after parent and local scripts)
    local ok, err = pcall(function() lp.Character = newChar end)
    if not ok then
        warnlog("Failed to set lp.Character:", err)
        pcall(function() newChar:Destroy() end)
        return
    end

    -- ensure humanoid and camera subject
    local humanoid = newChar:FindFirstChildOfClass("Humanoid")
    if humanoid and workspace.CurrentCamera then
        pcall(function() workspace.CurrentCamera.CameraSubject = humanoid end)
    end

    -- local: load & play animations in this injector (client)
    local tracks = nil
    if humanoid then
        tracks = loadAndPlayAnimationsOn(humanoid, IDLE_ID, WALK_ID)
    end

    -- FP handling: hide body when camera is very close to head
    local headPart = newChar:FindFirstChild("Head", true) or newChar:FindFirstChildWhichIsA("BasePart", true)
    local FP_HIDE_DISTANCE = 0.6
    local conn
    conn = RunService.RenderStepped:Connect(function()
        if not headPart or not workspace.CurrentCamera then return end
        local d = (workspace.CurrentCamera.CFrame.Position - headPart.Position).Magnitude
        if d < FP_HIDE_DISTANCE then
            setLocalVisibility(newChar, false)
        else
            setLocalVisibility(newChar, true)
        end
    end)

    -- cleanup old char after short delay to avoid dropping tools abruptly
    task.delay(1.2, function()
        if oldChar and oldChar.Parent then
            pcall(function() oldChar:Destroy() end)
        end
    end)

    log("Morph applied successfully. New character:", newChar:GetFullName())
    -- expose revert in _G
    _G.__morph_revert = function()
        if conn then conn:Disconnect(); conn = nil end
        if tracks then
            if tracks.idle and tracks.idle.IsPlaying then pcall(function() tracks.idle:Stop() end) end
            if tracks.walk and tracks.walk.IsPlaying then pcall(function() tracks.walk:Stop() end) end
        end
        pcall(function()
            if lp.Character and lp.Character ~= newChar and lp.Character.Parent then lp.Character:Destroy() end
        end)
        -- try restore oldChar (best-effort)
        if oldChar and not oldChar.Parent then
            oldChar.Parent = workspace
            lp.Character = oldChar
        end
        log("Morph reverted (best-effort).")
    end
end

-- run
doMorph()
