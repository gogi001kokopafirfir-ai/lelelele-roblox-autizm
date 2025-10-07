-- visual-morph-clean.lua  (client / injector)
-- Создаёт локальную визуальную копию (visual) и проигрывает анимации, без замены player.Character.

local MODEL_NAME = "Deer" -- имя шаблона в workspace (или добавь вариант в findTemplate)
local IDLE_ID    = "rbxassetid://138304500572165"
local WALK_ID    = "rbxassetid://78826693826761"
local VISUAL_NAME = "LOCAL_VISUAL_DEER" -- имя создаваемой визуальной модели
local SMOOTH = 0.45 -- интерполяция (0-1) при слежении за HRP
local FP_HIDE_DISTANCE = 0.6 -- порог дистанции камеры до головы для первого лица

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local lp = Players.LocalPlayer
if not lp then warn("No LocalPlayer") return end

-- Utility: найти шаблон Deer в workspace (по имени или по вхождению "deer")
local function findTemplate()
    local t = workspace:FindFirstChild(MODEL_NAME)
    if t and t:IsA("Model") then return t end
    for _,m in ipairs(workspace:GetChildren()) do
        if m:IsA("Model") and string.find(string.lower(m.Name or ""), string.lower(MODEL_NAME)) then return m end
    end
    return nil
end

local template = findTemplate()
if not template then warn("Template model '"..MODEL_NAME.."' not found in workspace") end

-- state
local visual = nil
local visualHum = nil
local animator = nil
local idleTrack, walkTrack = nil, nil
local followConn = nil
local toolConns = {}
local spawnedToolVisuals = {}
local cam = workspace.CurrentCamera

-- helpers
local function safeFindPart(model, names)
    for _,n in ipairs(names) do
        local p = model:FindFirstChild(n, true)
        if p and p:IsA("BasePart") then return p end
    end
    return nil
end

local function setLocalVisibility(character, visible)
    for _,v in ipairs(character:GetDescendants()) do
        if v:IsA("BasePart") then
            pcall(function() v.LocalTransparencyModifier = visible and 0 or 1 end)
        end
    end
end

local function isFirstPerson()
    if not cam then return false end
    local char = lp.Character
    if not char then return false end
    local head = char:FindFirstChild("Head")
    if not head then return false end
    local dist = (cam.CFrame.Position - head.Position).Magnitude
    return dist < FP_HIDE_DISTANCE
end

-- load animation id into animator, return track or nil
local function loadTrackFromId(animatorObj, id)
    if not animatorObj or not id then return nil end
    local a = Instance.new("Animation")
    a.AnimationId = id
    a.Parent = animatorObj -- keep near animator (script parent might be cleaned)
    local ok, tr = pcall(function() return animatorObj:LoadAnimation(a) end)
    if not ok or not tr then
        warn("LoadAnimation failed:", id, tr)
        a:Destroy()
        return nil
    end
    tr.Priority = Enum.AnimationPriority.Movement
    return tr
end

-- tool visual: clone handle and attach to visual hand using Align
local function createToolVisual(tool)
    if not visual then return end
    local handle = tool:FindFirstChild("Handle") or tool:FindFirstChildWhichIsA("BasePart")
    if not handle then return end
    local hand = safeFindPart(visual, {"RightHand","Right Arm","RightHand","RightUpperArm","RightArm"})
    if not hand then hand = visual.PrimaryPart end
    local visualHandle = handle:Clone()
    visualHandle.Name = "VISUAL_HANDLE_"..(tool.Name or "Tool")
    visualHandle.Parent = visual
    visualHandle.CanCollide = false

    -- create attachments
    local attV = Instance.new("Attachment"); attV.Parent = visualHandle
    local attH = Instance.new("Attachment"); attH.Parent = hand

    -- aligners
    local ap = Instance.new("AlignPosition"); ap.Attachment0 = attV; ap.Attachment1 = attH
    ap.Responsiveness = 200; ap.MaxForce = 1e5; ap.RigidityEnabled = true; ap.Parent = visualHandle
    local ao = Instance.new("AlignOrientation"); ao.Attachment0 = attV; ao.Attachment1 = attH
    ao.Responsiveness = 200; ao.MaxTorque = 1e5; ao.RigidityEnabled = true; ao.Parent = visualHandle

    return visualHandle, {ap=ap, ao=ao, attV=attV, attH=attH}
end

local function cleanupToolVisuals()
    for k,v in pairs(spawnedToolVisuals) do
        if v.instance and v.instance.Parent then pcall(function() v.instance:Destroy() end) end
    end
    spawnedToolVisuals = {}
    for k,c in pairs(toolConns) do
        if c then c:Disconnect() end
    end
    toolConns = {}
end

-- main create visual
local function createVisual()
    if visual and visual.Parent then return visual end
    if not template then template = findTemplate(); if not template then return nil end end

    local ok, clone = pcall(function() return template:Clone() end)
    if not ok or not clone then warn("Clone failed:", clone) return nil end

    clone.Name = VISUAL_NAME

    -- sanitize: remove server scripts, humanoid etc. Keep parts + Motor6D.
    for _,d in ipairs(clone:GetDescendants()) do
        if d:IsA("Script") or d:IsA("ModuleScript") then pcall(function() d:Destroy() end) end
        if d:IsA("Humanoid") then pcall(function() d:Destroy() end) end
        if d:IsA("BasePart") then
            pcall(function() d.CanCollide = false; d.Anchored = false end)
        end
    end

    -- ensure PrimaryPart
    local prim = clone:FindFirstChild("HumanoidRootPart", true) or clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart", true)
    if prim then clone.PrimaryPart = prim end

    clone.Parent = workspace
    visual = clone

    -- give it a Humanoid + Animator so Animator can affect Motor6D
    visualHum = Instance.new("Humanoid")
    visualHum.Name = "VisualHumanoid"
    visualHum.Parent = visual
    animator = Instance.new("Animator"); animator.Parent = visualHum

    -- load animations into visual animator
    idleTrack = loadTrackFromId(animator, IDLE_ID)
    walkTrack = loadTrackFromId(animator, WALK_ID)
    if idleTrack then pcall(function() idleTrack.Looped = true; idleTrack:Play() end) end

    -- hide real player parts locally
    local character = lp.Character
    if character then setLocalVisibility(character, false) end

    -- monitor tools to create visuals
    local function onToolEquipped(tool)
        local vh, info = createToolVisual(tool)
        if vh then spawnedToolVisuals[tool] = {instance = vh, info = info} end
    end
    local function onToolUnequipped(tool)
        local data = spawnedToolVisuals[tool]
        if data and data.instance and data.instance.Parent then pcall(function() data.instance:Destroy() end) end
        spawnedToolVisuals[tool] = nil
    end

    -- connect existing backpack/tools
    local function bindToolEventsToContainer(container)
        if not container then return end
        for _,item in ipairs(container:GetChildren()) do
            if item:IsA("Tool") then
                toolConns[item] = item.Equipped:Connect(function() onToolEquipped(item) end)
                toolConns[item .. "_uneq"] = item.Unequipped:Connect(function() onToolUnequipped(item) end)
            end
        end
        container.ChildAdded:Connect(function(child)
            if child:IsA("Tool") then
                toolConns[child] = child.Equipped:Connect(function() onToolEquipped(child) end)
                toolConns[child .. "_uneq"] = child.Unequipped:Connect(function() onToolUnequipped(child) end)
            end
        end)
    end

    bindToolEventsToContainer(lp:FindFirstChildOfClass("Backpack"))
    if lp.Character then bindToolEventsToContainer(lp.Character) end
    -- also bind future Character
    lp.CharacterAdded:Connect(function(char)
        bindToolEventsToContainer(char)
    end)

    -- follow loop
    local char = lp.Character or lp.CharacterAdded:Wait()
    local hrp = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
    if not hrp then warn("No HRP on player char") end

-- *** ВСТАВЬ ЭТОТ БЛОК в место старой логики слежения за HRP ***
-- Предполагается, что visual, visual.PrimaryPart, lp.Character и hrp уже определены.

-- 1) вычислим оффсеты модели (делаем один раз)
local visualHead = visual:FindFirstChild("Head", true) or visual:FindFirstChildWhichIsA("BasePart", true)
local primary = visual.PrimaryPart
if not primary then
    primary = visual:FindFirstChildWhichIsA("BasePart", true)
    visual.PrimaryPart = primary
end

-- head offset: вектор от PrimaryPart до головы (в мировых координатах)
local headOffsetLocal = Vector3.new(0,0,0)
if visualHead and primary then
    headOffsetLocal = primary.CFrame:PointToObjectSpace(visualHead.Position) -- head position in primary's local space
    -- Note: headOffsetLocal = visualHead.Position - primary.Position in local frame
else
    headOffsetLocal = Vector3.new(0, (primary.Size and primary.Size.Y/2) or 2, 0)
end

-- minimal Y offset: как далеко самая нижняя часть модели расположена относительно PrimaryPart
-- вычислим минимальную относительную Y среди всех частей
local minOffsetY = math.huge
for _, part in ipairs(visual:GetDescendants()) do
    if part:IsA("BasePart") then
        local rel = primary.CFrame:PointToObjectSpace(part.Position)
        if rel.Y < minOffsetY then minOffsetY = rel.Y end
    end
end
if minOffsetY == math.huge then minOffsetY = - (primary.Size and primary.Size.Y/2 or 1) end
-- minOffsetY — отрицательное число или ноль: когда primary находится на уровне, самый низ будет primary.Position + minOffsetY

-- опции настройки
local HEAD_PRIORITY = true             -- если true — стараемся совпадать по голове, но не проваливаться под землю
local VERTICAL_KEEP_CLEAR = 0.01       -- минимальный запас от земли (чтобы не зарываться)

-- функция вычисления целевого CFrame для visual.PrimaryPart
local function computeTargetPrimaryCFrame(hrpCFrame)
    -- hrpCFrame ориентируем по позиции и повороту HRP (используем hrp heading)
    -- хотим чтобы visual следовал за hrp по X,Z и повороту, а Y — определим отдельно
    local targetXZ = CFrame.new(hrpCFrame.Position.X, 0, hrpCFrame.Position.Z) * CFrame.Angles(0, hrpCFrame:ToEulerAnglesYXZ()) -- simpler: use hrpCFrame for orientation
    -- compute y for head alignment:
    local realHead = (lp.Character and lp.Character:FindFirstChild("Head")) or nil
    local y_for_head = nil
    if realHead and visualHead and primary then
        -- мы хотим: visualHeadWorldPos = realHead.Position
        -- visualHeadWorldPos = primaryPos + primary.CFrame:VectorToWorldSpace(headOffsetLocal)
        -- => primaryPos.Y = realHead.Position.Y - (primary.CFrame:VectorToWorldSpace(headOffsetLocal)).Y   (but primary orientation matters; simpler: use local Y offset)
        -- compute headOffset in primary local Y (already headOffsetLocal.y)
        local headLocalY = headOffsetLocal.Y
        -- world: primaryPos.Y = realHead.Position.Y - headLocalY (approximately, because of rotations we ignore pitch — acceptable)
        y_for_head = realHead.Position.Y - headLocalY
    end

    -- compute y so feet touch ground: find hrp ground Y (approx)
    local groundY = hrpCFrame.Position.Y -- approximation: player's HRP y is close to ground
    -- desired primary Y such that minimal part Y equals groundY:
    -- minimalPartWorldY = primaryPos.Y + minOffsetY
    -- so primaryPos.Y = groundY - minOffsetY
    local y_for_feet = groundY - minOffsetY + VERTICAL_KEEP_CLEAR

    -- choose final Y: try to match head but don't go below feet
    local finalY = y_for_head or y_for_feet
    if y_for_feet and finalY < y_for_feet then finalY = y_for_feet end

    -- build final cframe: use hrpCFrame for orientation and XZ, but override Y
    local base = hrpCFrame
    local finalCFrame = CFrame.new(base.Position.X, finalY, base.Position.Z) * CFrame.Angles(0, base:ToEulerAnglesYXZ()) -- keep orientation
    return finalCFrame
end

-- теперь follow loop: плавно интерполировать к computeTargetPrimaryCFrame(hrp.CFrame)
if followConn then followConn:Disconnect() end
followConn = game:GetService("RunService").RenderStepped:Connect(function()
    if not visual or not visual.PrimaryPart or not lp.Character then return end
    local hrpLocal = lp.Character:FindFirstChild("HumanoidRootPart") or lp.Character.PrimaryPart
    if not hrpLocal then return end

    -- compute target
    local targetCF = computeTargetPrimaryCFrame(hrpLocal.CFrame)
    -- smooth interpolation: lerp translation + slerp rotation using CFrame:Lerp
    local curCF = visual.PrimaryPart.CFrame
    local newCF = curCF:Lerp(targetCF, SMOOTH)
    visual:SetPrimaryPartCFrame(newCF)
end)
