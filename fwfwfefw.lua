-- simple-tool-attach.lua  (локальный инжектор, компактный)
-- Клонирует Handle/part предмета при Equipped и weld'ит к визуалу Deer.

local Players = game:GetService("Players")
local lp = Players.LocalPlayer
if not lp then return end

-- Настройки
local VISUAL_NAME = "LOCAL_DEER_VISUAL"      -- имя визуальной модели (должна уже быть в workspace)
local HAND_OFFSET = CFrame.new(0, -0.15, -0.5) * CFrame.Angles(0, 0, 0) -- подгоняй (Y вверх/вниз, Z вперед/назад)
local ATTACH_ORDER = {"RightGripAttachment","RightHandAttachment","RightHand","Right Arm","UpperTorso","HumanoidRootPart"}

-- internal
local visual = workspace:FindFirstChild(VISUAL_NAME)
if not visual then warn("[attach] visual not found:", VISUAL_NAME) end

local currentClone = nil
local currentTool = nil
local currentConn = nil

local function findTargetPart()
    if not visual then return nil, nil end
    for _, name in ipairs(ATTACH_ORDER) do
        local found = visual:FindFirstChild(name, true)
        if found then
            if found:IsA("Attachment") and found.Parent and found.Parent:IsA("BasePart") then
                return found.Parent, found
            elseif found:IsA("BasePart") then
                return found, nil
            end
        end
    end
    -- fallback
    local prim = visual:FindFirstChild("HumanoidRootPart") or visual.PrimaryPart
    return prim, nil
end

local function findPartFromTool(tool)
    if not tool then return nil end
    -- prefer Handle
    local h = tool:FindFirstChild("Handle", true)
    if h and h:IsA("BasePart") then return h end
    -- try workspace.<player>.ToolHandle (game-specific case)
    local plFolder = workspace:FindFirstChild(lp.Name)
    if plFolder then
        local th = plFolder:FindFirstChild("ToolHandle", true) or plFolder:FindFirstChild("ToolHandle")
        if th then
            for _, d in ipairs(th:GetDescendants()) do
                if d:IsA("BasePart") then return d end
            end
        end
    end
    -- fallback: first BasePart inside tool
    for _, d in ipairs(tool:GetDescendants()) do
        if d:IsA("BasePart") then return d end
    end
    return nil
end

local function clearCurrent()
    if currentConn then
        pcall(function() currentConn:Disconnect() end)
        currentConn = nil
    end
    if currentClone and currentClone.Parent then
        pcall(function() currentClone:Destroy() end)
    end
    currentClone = nil
    currentTool = nil
end

local function attachToolToVisual(tool)
    clearCurrent()
    if not tool then return end
    local srcPart = findPartFromTool(tool)
    if not srcPart then
        warn("[attach] no source part found in tool:", tool.Name)
        return
    end

    local targetPart, targetAttachment = findTargetPart()
    if not targetPart then
        warn("[attach] no visual target found (visual missing or has no hand part)")
        return
    end

    -- клонируем только исходную геометрическую часть (чтобы было просто)
    local ok, clone = pcall(function() return srcPart:Clone() end)
    if not ok or not clone then
        warn("[attach] clone failed")
        return
    end
    clone.Name = "LOCAL_TOOL_CLONE"
    -- безопасные настройки
    pcall(function()
        clone.Parent = visual or workspace
        clone.CanCollide = false
        clone.LocalTransparencyModifier = 0
        clone.Transparency = 0
        if clone.Massless ~= nil then clone.Massless = true end
    end)

    -- позиционируем и привязываем weld
    local baseCFrame = targetPart.CFrame
    if targetAttachment and targetAttachment:IsA("Attachment") then
        baseCFrame = targetPart.CFrame * targetAttachment.CFrame
    end
    pcall(function() clone.CFrame = baseCFrame * HAND_OFFSET end)

    local weld = Instance.new("WeldConstraint")
    weld.Part0 = clone
    weld.Part1 = targetPart
    weld.Parent = clone

    currentClone = clone
    currentTool = tool

    -- cleanup on tool removal / unequip
    currentConn = tool.AncestryChanged:Connect(function(_, parent)
        if not parent then clearCurrent() end
    end)
    -- also remove clone when tool unequipped (if tool has event)
    if tool:FindFirstChildWhichIsA("Tool") == nil then
        -- do nothing
    end

    print("[attach] attached clone for tool:", tool.Name, "-> target:", targetPart.Name)
end

-- bind existing backpack & character tools (Equipped)
local function bindToolInstance(tool)
    if not tool or not tool:IsA("Tool") then return end
    -- connect equipped/unequipped
    tool.Equipped:Connect(function()
        attachToolToVisual(tool)
    end)
    tool.Unequipped:Connect(function()
        clearCurrent()
    end)
    -- if tool removed entirely
    tool.AncestryChanged:Connect(function(_, parent)
        if not parent then clearCurrent() end
    end)
end

local backpack = lp:FindFirstChildOfClass("Backpack")
if backpack then
    for _, t in ipairs(backpack:GetChildren()) do
        if t:IsA("Tool") then bindToolInstance(t) end
    end
    backpack.ChildAdded:Connect(function(c) if c:IsA("Tool") then bindToolInstance(c) end end)
end
if lp.Character then
    for _, t in ipairs(lp.Character:GetChildren()) do if t:IsA("Tool") then bindToolInstance(t) end end
    lp.Character.ChildAdded:Connect(function(c) if c:IsA("Tool") then bindToolInstance(c) end end)
end

-- quick helper: if tool is already equipped (some games auto-equip), try to attach immediately
task.defer(function()
    local char = lp.Character
    if char then
        for _, t in ipairs(char:GetChildren()) do
            if t:IsA("Tool") then
                -- if tool has Handle moved to ToolHandle, findPartFromTool will try workspace[lp.Name].ToolHandle
                -- attach once
                attachToolToVisual(t)
                break
            end
        end
    end
end)

print("[attach] simple tool attach running. VISUAL:", tostring(visual and visual.Name or "nil"))
