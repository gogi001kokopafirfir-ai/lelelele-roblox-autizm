-- attach-tool-to-deer.lua  (локальный, инжектор)
-- Делает локальную копию взятого тулза и закрепляет её у визуала (Deer).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local lp = Players.LocalPlayer
if not lp then return end

-- Настройки:
local VISUAL_NAME = "LOCAL_DEER_VISUAL"  -- имя визуальной модели Deer (та, что мы создавали)
local HAND_OFFSET_CFRAME = CFrame.new(0, -0.2, -0.6) -- финальная позиция предмета относительно targetPart (подгоняй)
local SEARCH_ATTACHMENT_NAMES = {"RightGripAttachment","RightHandAttachment","RightHand","Right Arm","UpperTorso","HumanoidRootPart"}
local CLONE_NAME_PREFIX = "LOCAL_TOOL_VIS_"

-- Внутренние таблицы
local visualModel = workspace:FindFirstChild(VISUAL_NAME)
if not visualModel then warn("[tool-attach] visual model not found: "..VISUAL_NAME) return end

local equippedMap = {} -- tool -> {clone = part, weld = WeldConstraint}
local toolConns = {}   -- tool -> { equipConn, unequipConn }
local function findTargetPartInVisual()
    if not visualModel then return nil end
    -- ищем attachment/part для правой руки в визуале
    for _, name in ipairs(SEARCH_ATTACHMENT_NAMES) do
        local inst = visualModel:FindFirstChild(name, true)
        if inst and inst:IsA("BasePart") then
            return inst
        end
        if inst and inst:IsA("Attachment") then
            -- если нашли attachment — используем его.Parent как targetPart, и применим attachment.CFrame
            if inst.Parent and inst.Parent:IsA("BasePart") then
                return inst.Parent, inst
            end
        end
    end
    -- fallback: PrimaryPart
    return visualModel.PrimaryPart, nil
end

-- находит подходящую BasePart внутри тулза (Handle или первая BasePart)
local function findToolHandlePart(tool)
    if not tool then return nil end
    -- сначала стандартный Handle
    local handle = tool:FindFirstChild("Handle", true)
    if handle and handle:IsA("BasePart") then return handle end
    -- иначе первая BasePart внутри тулза
    for _, v in ipairs(tool:GetDescendants()) do
        if v:IsA("BasePart") then return v end
    end
    -- if ToolHandle folder exists in workspace (game-specific), try to find related ToolHandle by Player name
    local th = workspace:FindFirstChild("ToolHandle", true) -- best-effort; may not exist
    if th then
        for _, v in ipairs(th:GetDescendants()) do
            if v:IsA("BasePart") then return v end
        end
    end
    return nil
end

local function makeLocalCloneOfPart(part)
    if not part then return nil end
    local ok, clone = pcall(function() return part:Clone() end)
    if not ok or not clone then return nil end
    clone.Name = CLONE_NAME_PREFIX .. (part.Name or "part")
    -- safety: make it non-collidable and massless so it doesn't interfere
    pcall(function()
        clone.CanCollide = false
        if clone:IsA("BasePart") and clone.Massless ~= nil then clone.Massless = true end
    end)
    return clone
end

local function attachCloneToVisual(clonePart, targetPart, targetAttachment)
    if not clonePart or not targetPart then return nil end
    -- parent clone under visual model to keep things organized
    clonePart.Parent = visualModel

    -- Position clone to desired CFrame relative to target
    -- if we have an attachment, use its world CFrame as base
    local baseCFrame = targetPart.CFrame
    if targetAttachment and targetAttachment:IsA("Attachment") then
        baseCFrame = targetPart.CFrame * targetAttachment.CFrame
    end
    -- compute target world CFrame for clone
    local targetWorld = baseCFrame * HAND_OFFSET_CFRAME
    pcall(function() clonePart.CFrame = targetWorld end)

    -- create WeldConstraint between clonePart and targetPart
    local weld = Instance.new("WeldConstraint")
    weld.Part0 = clonePart
    weld.Part1 = targetPart
    weld.Parent = clonePart

    -- Ensure clone is visible locally (if you hide real tools)
    -- optionally tweak Transparency/Material here

    return weld
end

local function onToolEquipped(tool)
    if not tool or equippedMap[tool] then return end
    -- find the "handle" part inside the tool
    local handlePart = findToolHandlePart(tool)
    if not handlePart then
        warn("[tool-attach] no handle found in tool:", tool.Name)
        return
    end

    -- find visual target (part in deer and optional attachment)
    local targetPart, targetAttachment = findTargetPartInVisual()
    if not targetPart then
        warn("[tool-attach] no target part in visual found")
        return
    end

    -- create clone of the handle part
    local clone = makeLocalCloneOfPart(handlePart)
    if not clone then
        warn("[tool-attach] failed to clone handle")
        return
    end

    -- attach
    local ok, weld = pcall(function() return attachCloneToVisual(clone, targetPart, targetAttachment) end)
    if not ok or not weld then
        pcall(function() clone:Destroy() end)
        warn("[tool-attach] failed to weld clone")
        return
    end

    equippedMap[tool] = { clone = clone, weld = weld }
end

local function onToolUnequipped(tool)
    local data = equippedMap[tool]
    if not data then return end
    if data.weld then pcall(function() data.weld:Destroy() end) end
    if data.clone and data.clone.Parent then pcall(function() data.clone:Destroy() end) end
    equippedMap[tool] = nil
end

-- bind Tool instances (in Backpack or Character)
local function bindToolInstance(tool)
    if not tool or toolConns[tool] then return end
    if not tool:IsA("Tool") then return end
    -- Equipped/Unequipped events
    local eConn = tool.Equipped:Connect(function() onToolEquipped(tool) end)
    local uConn = tool.Unequipped:Connect(function() onToolUnequipped(tool) end)
    toolConns[tool] = {equip = eConn, unequip = uConn}
end

local function unbindToolInstance(tool)
    local t = toolConns[tool]
    if not t then return end
    pcall(function() if t.equip then t.equip:Disconnect() end end)
    pcall(function() if t.unequip then t.unequip:Disconnect() end end)
    toolConns[tool] = nil
end

-- watch Backpack and Character
local function watchContainer(container)
    if not container then return end
    for _, child in ipairs(container:GetChildren()) do
        if child:IsA("Tool") then bindToolInstance(child) end
    end
    container.ChildAdded:Connect(function(child)
        if child:IsA("Tool") then bindToolInstance(child) end
    end)
end

-- initial bind
watchContainer(lp:FindFirstChildOfClass("Backpack"))
if lp.Character then watchContainer(lp.Character) end
lp.CharacterAdded:Connect(function(char)
    watchContainer(char)
    -- cleanup possible leftover clones for old tools
    for tool, data in pairs(equippedMap) do
        if tool and (tool.Parent ~= char) then
            onToolUnequipped(tool)
        end
    end
end)

-- also watch if new tools appear in Backpack at runtime
local backpack = lp:FindFirstChildOfClass("Backpack")
if backpack then
    backpack.ChildAdded:Connect(function(child) if child:IsA("Tool") then bindToolInstance(child) end end)
end

-- ensure cleanup on unequip / destroy (if tool removed)
-- also listen for Tools being destroyed -> clean map
RunService.Heartbeat:Connect(function()
    for tool, data in pairs(equippedMap) do
        if not tool or not tool.Parent then
            onToolUnequipped(tool)
        end
    end
end)

print("[tool-attach] running. VISUAL:", VISUAL_NAME)
