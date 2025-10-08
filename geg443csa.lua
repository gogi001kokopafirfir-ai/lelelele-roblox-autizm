-- morph-replace-clean-fixed.lua
-- Клиент: аккуратная замена LocalPlayer.Character на шаблон (Deer)
-- Настройки:
local TEMPLATE_NAMES = {"Deer", "Deer_LOCAL"} -- возможные имена шаблона
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

local function findTemplate()
    for _, name in ipairs(TEMPLATE_NAMES) do
        local m = workspace:FindFirstChild(name)
        if m and m:IsA("Model") then return m end
    end
    for _, m in ipairs(workspace:GetChildren()) do
        if m:IsA("Model") and string.find(string.lower(m.Name or ""), "deer") then return m end
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
            local bottom = part.Position.Y - part.Size.Y/2
            if bottom < minY then minY = bottom end
        end
    end
    if minY == math.huge then return nil end
    return minY
end

local function prepareClone(orig)
    local ok, clone = pcall(function() return orig:Clone() end)
    if not ok or not clone then warnlog("Clone failed:", clone); return nil end

    -- удаляем серверные скрипты/модули и humanoid внутри шаблона (чтобы не было конфликтов)
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
            if ok and c then c.Parent = clone; log("Copied LocalScript:", c.Name) end
        end
    end
end

local function transferTools(oldChar, newChar)
    local bp = lp:FindFirstChildOfClass("Backpack")
    local function move(tool)
        if tool and tool:IsA("Tool") then
            pcall(function() tool.Parent = newChar end)
        end
    end
    if bp then for _,t in ipairs(bp:GetChildren()) do move(t) end end
    if oldChar then for _,t in ipairs(oldChar:GetChildren()) do if t:IsA("Tool") then move(t) end end end
end

-- Вставляем компактный LocalScript внутрь клона; он будет выполняться уже в контексте character.
-- LocalScript читает атрибуты clone: "MorphIdle" и "MorphWalk".
local LOCAL_SCRIPT_SOURCE =
-- __MORPH_ANIM_LOCAL (внутри клона)
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local lp = Players.LocalPlayer
local char = script.Parent

local idleId = char:GetAttribute("MorphIdle") or ""
local walkId = char:GetAttribute("MorphWalk") or ""

local humanoid = char:WaitForChild("Humanoid", 5)
if not humanoid then warn("[morph-local] Humanoid not found"); return end

local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoid)

local function safeLoad(animId)
    if not animId or animId == "" then return nil end
    local a = Instance.new("Animation")
    a.AnimationId = animId
    a.Parent = script
    local ok, track = pcall(function() return animator:LoadAnimation(a) end)
    if not ok or not track then warn("[morph-local] LoadAnimation failed:", animId, track); pcall(function() a:Destroy() end); return nil end
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

-- простой FP handling: прятать части клона при близкой камере (чтобы не клипало)
local cam = workspace.CurrentCamera
local FP_HIDE_DISTANCE = 0.6
local function setLocalVis(character, visible)
    for _,p in ipairs(character:GetDescendants()) do
        if p:IsA("BasePart") then p.LocalTransparencyModifier = visible and 0 or 1 end
    end
end

local head = char:FindFirstChild("Head", true) or char:FindFirstChildWhichIsA("BasePart", true)
if head then
    RunService.RenderStepped:Connect(function()
        if not cam or not head then return end
        local d = (cam.CFrame.Position - head.Position).Magnitude
        if d < FP_HIDE_DISTANCE then
            setLocalVis(char, false)
        else
            setLocalVis(char, true)
        end
    end)
end

print("[morph-local] init done")

local function insertLocalScriptToClone(clone)
    local ls = Instance.new("LocalScript")
    ls.Name = "__MORPH_ANIM_LOCAL"
    ls.Source = LOCAL_SCRIPT_SOURCE
    ls.Parent = clone
    return ls
end

-- main morph routine
local function doMorph()
    local template = findTemplate()
    if not template then warnlog("Template not found"); return end

    local newChar = prepareClone(template)
    if not newChar then warnlog("prepareClone failed"); return end

    -- position newChar at oldChar pivot
    setPrimaryIfMissing(newChar)
    local oldPivot = (oldChar.GetPivot and oldChar:GetPivot()) or (oldChar.PrimaryPart and oldChar.PrimaryPart.CFrame)
    if oldPivot and newChar.PrimaryPart then
        pcall(function() newChar:SetPrimaryPartCFrame(oldPivot) end)
    end

    -- vertical align by lowest Y
    local playerFeet = lowestYOfModel(oldChar)
    local cloneFeet = lowestYOfModel(newChar)
    if playerFeet and cloneFeet and newChar.PrimaryPart then
        local delta = playerFeet - cloneFeet
        if math.abs(delta) > 1e-5 then
            pcall(function() newChar:SetPrimaryPartCFrame(newChar.PrimaryPart.CFrame * CFrame.new(0, delta, 0)) end)
            log("Vertical adjust by", delta)
        end
    else
        log("Could not compute feet Y; skipping vertical adjust")
    end

    -- parent into workspace BEFORE assigning character
    newChar.Parent = workspace
    newChar.Name = lp.Name

    -- put animation IDs as attributes (LocalScript inside clone will read them)
    newChar:SetAttribute("MorphIdle", IDLE_ID)
    newChar:SetAttribute("MorphWalk", WALK_ID)

    -- copy StarterCharacterScripts (local scripts) into clone
    copyStarterLocalScriptsToClone(newChar)

    -- insert our LocalScript controller
    insertLocalScriptToClone(newChar)

    -- transfer tools
    transferTools(oldChar, newChar)

    -- assign as character (must be after parenting and local scripts placed)
    local ok, err = pcall(function() lp.Character = newChar end)
    if not ok then
        warnlog("Failed to set lp.Character:", err)
        pcall(function() newChar:Destroy() end)
        return
    end

    -- set camera subject to humanoid for proper camera behavior
    local hum = newChar:FindFirstChildOfClass("Humanoid")
    if hum and workspace.CurrentCamera then
        pcall(function() workspace.CurrentCamera.CameraSubject = hum end)
    end

    -- remove old char after short delay
    task.delay(1.2, function()
        if oldChar and oldChar.Parent then pcall(function() oldChar:Destroy() end) end
    end)

    log("Morph complete ->", newChar:GetFullName())
end

-- run
doMorph()
