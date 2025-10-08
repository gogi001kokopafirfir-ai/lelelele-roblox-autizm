-- visual-morph-pass.lua  (client / injector)
-- Не заменяет server character. Создаёт локальную визуальную копию Deer,
-- синхронизирует её с реальным персонажем и проигрывает animations.

local TEMPLATE_NAME = "Deer" -- имя шаблона в workspace
local IDLE_ID = "rbxassetid://138304500572165"
local WALK_ID = "rbxassetid://78826693826761"

local SMOOTH = 0.5              -- сглаживание следования (0..1)
local EXTRA_VERTICAL_OFFSET = 0 -- положить положительное, если Deer чуть врезается
local FP_HIDE_DISTANCE = 0.6    -- дистанция камеры для сокрытия визуала в FP

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local lp = Players.LocalPlayer
if not lp then warn("No LocalPlayer") return end
local char = lp.Character or lp.CharacterAdded:Wait()

-- ---- утилиты ----
local function findTemplate()
    local t = workspace:FindFirstChild(TEMPLATE_NAME)
    if t and t:IsA("Model") then return t end
    for _,m in ipairs(workspace:GetChildren()) do
        if m:IsA("Model") and tostring(m.Name):lower():find(TEMPLATE_NAME:lower()) then return m end
    end
    return nil
end

local function lowestY(model)
    local minY = math.huge
    for _,v in ipairs(model:GetDescendants()) do
        if v:IsA("BasePart") then
            local bottom = v.Position.Y - v.Size.Y/2
            if bottom < minY then minY = bottom end
        end
    end
    return (minY == math.huge) and nil or minY
end

local function highestPart(model)
    local best, bestY = nil, -math.huge
    for _,v in ipairs(model:GetDescendants()) do
        if v:IsA("BasePart") then
            local top = v.Position.Y + v.Size.Y/2
            if top > bestY then bestY = top; best = v end
        end
    end
    return best
end

local function sanitizeVisual(model)
    -- удаляем скрипты/модули/humanoid чтобы визуал был чисто косметическим
    for _,v in ipairs(model:GetDescendants()) do
        if v:IsA("Script") or v:IsA("ModuleScript") or v:IsA("Humanoid") then
            pcall(function() v:Destroy() end)
        end
        if v:IsA("BasePart") then
            pcall(function() v.Anchored = false; v.CanCollide = false end)
        end
    end
end

-- ---- создание визуала ----
local visual -- ссылка на текущий визуал
local visualHum, animator, idleTrack, walkTrack
local followConn, chatConn

local function createVisual()
    if visual and visual.Parent then visual:Destroy() end

    local template = findTemplate()
    if not template then warn("Template not found: "..TEMPLATE_NAME); return false end

    local ok, clone = pcall(function() return template:Clone() end)
    if not ok or not clone then warn("Clone failed", clone); return false end

    clone.Name = "LOCAL_VISUAL_" .. (lp.Name or "Player")
    sanitizeVisual(clone)

    -- попытка найти PrimaryPart
    local prim = clone:FindFirstChild("HumanoidRootPart", true) or clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart", true)
    if prim then clone.PrimaryPart = prim end

    clone.Parent = workspace
    visual = clone

    -- вертикальная подгонка ног: выравниваем нижние точки
    local playerFeet = lowestY(char)
    local visualFeet = lowestY(visual)
    if playerFeet and visualFeet and visual.PrimaryPart then
        local delta = playerFeet - visualFeet + EXTRA_VERTICAL_OFFSET
        if math.abs(delta) > 1e-5 then
            pcall(function() visual:SetPrimaryPartCFrame(visual.PrimaryPart.CFrame * CFrame.new(0, delta, 0)) end)
        end
    else
        warn("Could not compute feet alignment (playerFeet, visualFeet):", playerFeet, visualFeet)
    end

    -- даём визуалу Humanoid + Animator для анимаций (локально)
    visualHum = Instance.new("Humanoid")
    visualHum.Name = "LOCAL_VISUAL_HUMANOID"
    visualHum.Parent = visual
    animator = Instance.new("Animator")
    animator.Parent = visualHum

    -- загрузка анимаций (pcall wrap inside)
    local function safeLoad(id, looped)
        if not id then return nil end
        local a = Instance.new("Animation")
        a.AnimationId = id
        a.Parent = visual
        local ok, track = pcall(function() return animator:LoadAnimation(a) end)
        if not ok or not track then
            warn("LoadAnimation failed:", id, track)
            pcall(function() a:Destroy() end)
            return nil
        end
        track.Priority = Enum.AnimationPriority.Movement
        track.Looped = looped and true or false
        return track
    end

    idleTrack = safeLoad(IDLE_ID, true)
    walkTrack = safeLoad(WALK_ID, true)
    if idleTrack then pcall(function() idleTrack:Play() end) end

    -- создаём локальный чат-пузырь при отправке сообщения
    chatConn = lp.Chatted:Connect(function(msg)
        local head = highestPart(visual)
        if not head then return end
        local pg = lp:FindFirstChild("PlayerGui")
        if not pg then return end
        local bb = Instance.new("BillboardGui", pg)
        bb.Adornee = head
        bb.Size = UDim2.new(0,200,0,40)
        bb.StudsOffset = Vector3.new(0, head.Size.Y/2 + 0.5, 0)
        bb.AlwaysOnTop = true
        local lbl = Instance.new("TextLabel", bb)
        lbl.Size = UDim2.new(1,0,1,0)
        lbl.BackgroundTransparency = 0.4
        lbl.Text = msg
        lbl.TextScaled = true
        task.delay(3, function() pcall(function() bb:Destroy() end) end)
    end)

    -- follow loop: синхронизирует визуал с настоящим char.HumanoidRootPart
    local hrp = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
    followConn = RunService.RenderStepped:Connect(function()
        if not visual or not visual.PrimaryPart or not hrp then return end
        -- FP hide: если камера близко к голове игрока, прячем визуал
        local cam = workspace.CurrentCamera
        if cam then
            local head = char:FindFirstChild("Head") or char:FindFirstChildWhichIsA("BasePart", true)
            if head then
                local d = (cam.CFrame.Position - head.Position).Magnitude
                local hide = d < FP_HIDE_DISTANCE
                for _,p in ipairs(visual:GetDescendants()) do
                    if p:IsA("BasePart") then
                        p.LocalTransparencyModifier = hide and 1 or 0
                    end
                end
            end
        end

        -- позиционируем визуал на HRP с плавностью (Lerp)
        local target = hrp.CFrame
        local cur = visual.PrimaryPart.CFrame
        local new = cur:Lerp(target, SMOOTH)
        pcall(function() visual:SetPrimaryPartCFrame(new) end)
    end)

    -- переключение анимаций по реальному humanoid.Running (сервера/локального char)
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

    return true
end

local function revertVisual()
    if followConn then followConn:Disconnect(); followConn = nil end
    if chatConn then chatConn:Disconnect(); chatConn = nil end
    if idleTrack then pcall(function() idleTrack:Stop() end) end
    if walkTrack then pcall(function() walkTrack:Stop() end) end
    if animator and animator.Parent then animator:Destroy() end
    if visualHum and visualHum.Parent then visualHum:Destroy() end
    if visual and visual.Parent then visual:Destroy() end
    visual, visualHum, animator, idleTrack, walkTrack = nil, nil, nil, nil, nil
    print("Visual morph reverted.")
end

-- expose revert to console
_G.revertLocalMorph = revertVisual

-- create and run
local ok = createVisual()
if not ok then warn("Visual morph failed") end
print("Local visual morph created. Call revertLocalMorph() to remove.")
