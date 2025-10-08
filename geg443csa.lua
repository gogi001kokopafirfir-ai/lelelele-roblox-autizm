-- local-visual-morph-clean.lua
-- Клиентский, инжекторный. Создаёт локальную визуальную копию (Deer) и проигрывает анимации.
-- Откат: revertLocalMorph()

local TEMPLATE_NAMES = {"Deer", "Deer_LOCAL"} -- возможные имена шаблона
local IDLE_ID = "rbxassetid://138304500572165"
local WALK_ID = "rbxassetid://78826693826761"

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local lp = Players.LocalPlayer
if not lp then warn("[morph] LocalPlayer not found"); return end
local char = lp.Character or lp.CharacterAdded:Wait()

local VISUAL_NAME = "LOCAL_VISUAL_DEER"
local FP_HIDE_DISTANCE = 0.6 -- порог для прятания визуала в FP
local SMOOTH = 0.5 -- сглаживание следования (0..1)
local EXTRA_VERTICAL_OFFSET = 0.02 -- если ноги всё ещё чуть врезаются, увеличь

local visual = nil
local visualHum = nil
local animator = nil
local idleTrack, walkTrack = nil, nil
local followConn = nil
local chatBubbles = {}

local function log(...) print("[morph]", ...) end
local function warnlog(...) warn("[morph]", ...) end

-- найти шаблон
local function findTemplate()
    for _, name in ipairs(TEMPLATE_NAMES) do
        local m = workspace:FindFirstChild(name)
        if m and m:IsA("Model") then return m end
    end
    -- fallback: ищем 'deer' в имени
    for _, m in ipairs(workspace:GetChildren()) do
        if m:IsA("Model") and tostring(m.Name):lower():find("deer") then return m end
    end
    return nil
end

-- низ модели (нижняя Y координата)
local function lowestYOfModel(m)
    if not m then return nil end
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

-- самая верхняя часть модели (для chat billboard)
local function highestPartOfModel(m)
    if not m then return nil end
    local bestPart = nil
    local bestY = -math.huge
    for _, part in ipairs(m:GetDescendants()) do
        if part:IsA("BasePart") then
            local top = part.Position.Y + part.Size.Y/2
            if top > bestY then bestY = top; bestPart = part end
        end
    end
    return bestPart
end

-- сброс старого визуала
local function cleanupVisual()
    if followConn then followConn:Disconnect(); followConn = nil end
    -- удалить все локальные пузырьки чата
    for _,v in pairs(chatBubbles) do
        pcall(function() v:Destroy() end)
    end
    chatBubbles = {}
    -- остановить треки
    pcall(function()
        if idleTrack and idleTrack.IsPlaying then idleTrack:Stop() end
        if walkTrack and walkTrack.IsPlaying then walkTrack:Stop() end
    end)
    idleTrack = nil; walkTrack = nil
    -- удалить animator/humanoid если были
    pcall(function()
        if animator and animator.Parent then animator:Destroy() end
        if visualHum and visualHum.Parent then visualHum:Destroy() end
    end)
    -- удалить сам визуал
    if visual and visual.Parent then
        pcall(function() visual:Destroy() end)
    end
    visual = nil
    animator = nil
    visualHum = nil
    log("Local visual cleaned up.")
end

-- показать локальный чат-пузырь над визуальной головой
local function showLocalChat(text, dur)
    dur = dur or 4
    if not visual then return end
    local head = highestPartOfModel(visual)
    if not head then return end
    local playerGui = lp:FindFirstChild("PlayerGui")
    if not playerGui then return end

    local bb = Instance.new("BillboardGui")
    bb.Name = "LOCAL_CHAT_BB"
    bb.Adornee = head
    bb.Parent = playerGui
    bb.Size = UDim2.new(0,200,0,50)
    bb.StudsOffset = Vector3.new(0, head.Size.Y/2 + 0.5, 0)
    bb.AlwaysOnTop = true

    local txt = Instance.new("TextLabel")
    txt.Size = UDim2.new(1,0,1,0)
    txt.BackgroundTransparency = 0.35
    txt.BackgroundColor3 = Color3.new(0,0,0)
    txt.TextColor3 = Color3.new(1,1,1)
    txt.TextStrokeTransparency = 0.7
    txt.TextScaled = true
    txt.Font = Enum.Font.SourceSansSemibold
    txt.Text = text
    txt.Parent = bb

    table.insert(chatBubbles, bb)
    task.delay(dur, function()
        pcall(function() bb:Destroy() end)
    end)
end

-- загружаем анимации в animator (локально)
local function loadAnimations(animatorObj)
    if not animatorObj then return end
    local function safeLoad(id)
        if not id or id == "" then return nil end
        local a = Instance.new("Animation")
        a.AnimationId = id
        a.Parent = animatorObj
        local ok, track = pcall(function() return animatorObj:LoadAnimation(a) end)
        if not ok or not track then
            warnlog("LoadAnimation failed for", id, track)
            pcall(function() a:Destroy() end)
            return nil
        end
        track.Priority = Enum.AnimationPriority.Movement
        return track
    end
    local idle = safeLoad(IDLE_ID)
    local walk = safeLoad(WALK_ID)
    if idle then pcall(function() idle.Looped = true; idle:Play() end) end
    return idle, walk
end

-- основной create visual
local function createVisual()
    cleanupVisual()

    local template = findTemplate()
    if not template then warnlog("Template not found in workspace"); return false end

    local ok, clone = pcall(function() return template:Clone() end)
    if not ok or not clone then warnlog("Failed to clone template:", clone); return false end
    clone.Name = VISUAL_NAME

    -- sanitize: удалить все Scripts/ModuleScripts/Humanoid чтобы не было конфликтов
    for _,d in ipairs(clone:GetDescendants()) do
        if d:IsA("Script") or d:IsA("ModuleScript") or d:IsA("Humanoid") then
            pcall(function() d:Destroy() end)
        end
        if d:IsA("BasePart") then
            pcall(function() d.Anchored = false; d.CanCollide = false end)
        end
    end

    -- set primary
    local prim = clone:FindFirstChild("HumanoidRootPart", true) or clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart", true)
    if prim then clone.PrimaryPart = prim end

    -- parent now so positions are meaningful
    clone.Parent = workspace
    visual = clone

    -- compute vertical alignment: align visual feet to player's feet
    local playerFeetY = lowestYOfModel(char)
    local visualFeetY = lowestYOfModel(visual)
    if playerFeetY and visualFeetY then
        local deltaY = playerFeetY - visualFeetY + EXTRA_VERTICAL_OFFSET
        if visual.PrimaryPart then
            pcall(function()
                visual:SetPrimaryPartCFrame(visual.PrimaryPart.CFrame * CFrame.new(0, deltaY, 0))
            end)
            log("Applied vertical shift:", deltaY)
        else
            warnlog("visual has no PrimaryPart; can't set CFrame exact")
        end
    else
        warnlog("Couldn't compute feet Y for alignment; playerFeetY:", playerFeetY, "visualFeetY:", visualFeetY)
    end

    -- create a Humanoid+Animator for visual so animations affect Motor6D
    visualHum = Instance.new("Humanoid")
    visualHum.Name = "LocalVisualHumanoid"
    visualHum.Parent = visual
    animator = Instance.new("Animator")
    animator.Parent = visualHum

    -- load animations locally
    idleTrack, walkTrack = loadAnimations(animator)

    -- chat hooking: show local bubble when local player chats
    local chatConn
    chatConn = lp.Chatted:Connect(function(msg)
        pcall(function() showLocalChat(msg, 4) end)
    end)

    -- follow loop: track player's HRP with smoothing
    local hrp = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
    if not hrp then warnlog("Player HRP not found"); end

    followConn = RunService.Heartbeat:Connect(function()
        if not visual or not visual.PrimaryPart or not hrp then return end
        -- FP hide: if camera close to player's head, hide visual
        local cam = workspace.CurrentCamera
        if cam then
            local head = char:FindFirstChild("Head") or char:FindFirstChildWhichIsA("BasePart", true)
            if head then
                local dist = (cam.CFrame.Position - head.Position).Magnitude
                if dist < FP_HIDE_DISTANCE then
                    -- hide visual parts locally
                    for _,p in ipairs(visual:GetDescendants()) do
                        if p:IsA("BasePart") then
                            p.LocalTransparencyModifier = 1
                        end
                    end
                else
                    for _,p in ipairs(visual:GetDescendants()) do
                        if p:IsA("BasePart") then
                            p.LocalTransparencyModifier = 0
                        end
                    end
                end
            end
        end

        -- follow HRP smoothly
        local target = hrp.CFrame
        local cur = visual.PrimaryPart.CFrame
        local new = cur:Lerp(target, SMOOTH)
        pcall(function() visual:SetPrimaryPartCFrame(new) end)
    end)

    log("Local visual created:", visual:GetFullName())
    return true
end

-- revert function
local function revertLocalMorph()
    cleanupVisual()
    log("revertLocalMorph called.")
end

-- expose revert globally
_G.revertLocalMorph = revertLocalMorph

-- run
local success = createVisual()
if not success then warnlog("createVisual failed") end
