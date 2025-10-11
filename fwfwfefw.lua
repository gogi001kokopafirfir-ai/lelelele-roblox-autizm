-- toolhandle-attach-to-deer.lua  (локальный, инжектор)
-- Клонирует предмет из ToolHandle (или Tool.Handle) и привязывает локально к VISUAL_NAME.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local lp = Players.LocalPlayer
if not lp then return end

-- Настройки
local VISUAL_NAME = "LOCAL_DEER_VISUAL" -- имя визуальной модели (Deer)
local HAND_OFFSET_CFRAME = CFrame.new(0, -0.2, -0.5) -- подгоняй по нужде
local SEARCH_ATTACHMENT_NAMES = {"RightGripAttachment","RightHandAttachment"} -- attachments в visual
local CLONE_PARENT = workspace -- куда временно помещаем (потом пересадим в visual)
local TOOLHANDLE_NAME = "ToolHandle" -- имя папки в игре, которую надо отслеживать

-- Внутренние структуры
local visual = workspace:FindFirstChild(VISUAL_NAME)
if not visual then warn("[tool-attach] visual model '"..VISUAL_NAME.."' not found") end

local activeClone = nil      -- текущный локальный клон предмета (Model or BasePart)
local activeSource = nil     -- оригинал (Tool or ToolHandle folder) that we cloned from
local toolConns = {}         -- для Tool.Equipped/Unequipped
local handleFolderConns = {} -- для слежения за ToolHandle удаления

-- helper: находим targetPart (часть визуала для прикрепления) и optional Attachment
local function findTargetInVisual()
    if not visual then return nil, nil end
    for _, name in ipairs(SEARCH_ATTACHMENT_NAMES) do
        local att = visual:FindFirstChild(name, true)
        if att then
            if att:IsA("Attachment") and att.Parent and att.Parent:IsA("BasePart") then
                return att.Parent, att
            elseif att:IsA("BasePart") then
                return att, nil
            end
        end
    end
    -- fallback: берём PrimaryPart или HumanoidRootPart
    local prim = visual:FindFirstChild("HumanoidRootPart") or visual.PrimaryPart
    return prim, nil
end

-- helper: клонирует всю папку/Tool (включая subparts), делает non-collidable, возвращает модель/part
local function cloneEntireObject(src)
    if not src then return nil end
    local ok, cloned = pcall(function() return src:Clone() end)
    if not ok or not cloned then return nil end

    -- если клон — не Model, положим его в Model
    local modelClone
    if cloned:IsA("Model") then
        modelClone = cloned
    else
        modelClone = Instance.new("Model")
        cloned.Parent = modelClone
        modelClone.Name = "LOCAL_TOOL_MODEL"
    end

    -- sanitize: отключаем столкновения и делаем massless
    for _, v in ipairs(modelClone:GetDescendants()) do
        if v:IsA("BasePart") then
            pcall(function() v.CanCollide = false; if v.Massless ~= nil then v.Massless = true end end)
        elseif v:IsA("Script") or v:IsA("LocalScript") or v:IsA("ModuleScript") then
            pcall(function() v:Destroy() end)
        end
    end

    -- parent under visual for cleanup convenience
    modelClone.Parent = visual or CLONE_PARENT
    return modelClone
end

-- attach cloned model/part to targetPart using WeldConstraint (keeps relative pose)
local function attachCloneToTarget(modelClone, targetPart, targetAttachment)
    if not modelClone or not targetPart then return end

    -- set PrimaryPart for modelClone if missing
    local prim = modelClone.PrimaryPart
    if not prim then
        -- pick first BasePart
        for _, v in ipairs(modelClone:GetDescendants()) do
            if v:IsA("BasePart") then prim = v; break end
        end
        if prim then modelClone.PrimaryPart = prim end
    end
    if not prim then return end

    -- position clone so it visually sits near target: if have attachment use that, else base on targetPart
    local baseCFrame = targetPart.CFrame
    if targetAttachment and targetAttachment:IsA("Attachment") then
        baseCFrame = targetPart.CFrame * targetAttachment.CFrame
    end
    -- world target for the clone root
    local desired = baseCFrame * HAND_OFFSET_CFRAME

    -- put clone world position to desired (move its PrimaryPart)
    pcall(function() modelClone:SetPrimaryPartCFrame(desired) end)

    -- weld PrimaryPart to targetPart
    local weld = Instance.new("WeldConstraint")
    weld.Name = "LOCAL_TOOL_WELD"
    weld.Part0 = modelClone.PrimaryPart
    weld.Part1 = targetPart
    weld.Parent = modelClone.PrimaryPart

    return weld
end

-- cleanup previous clone
local function clearActiveClone()
    if activeClone and activeClone.Parent then
        pcall(function() activeClone:Destroy() end)
    end
    activeClone = nil
    activeSource = nil
end

-- process ToolHandle folder (game-specific) when appears
local function onToolHandleFound(folder)
    if not folder or not visual then return end
    -- quick heuristic: check if folder belongs to our player/character
    local parent = folder.Parent
    local belongsToLocal = false
    if parent == lp.Character or parent == lp or (parent and parent.Name == lp.Name) then
        belongsToLocal = true
    else
        -- fallback: if any descendant of folder is within small distance to our HRP, consider it ours
        local hrp = lp.Character and (lp.Character:FindFirstChild("HumanoidRootPart") or lp.Character.PrimaryPart)
        if hrp then
            for _, v in ipairs(folder:GetDescendants()) do
                if v:IsA("BasePart") and (v.Position - hrp.Position).Magnitude < 6 then
                    belongsToLocal = true; break
                end
            end
        end
    end

    if not belongsToLocal then return end

    -- safe: wait a tick for ToolHandle to be populated
    task.wait(0.03)

    -- decide source part(s) to clone: prefer a child BasePart collection, otherwise clone folder
    local srcModel = nil
    -- if folder has children, clone folder
    if #folder:GetChildren() > 0 then
        srcModel = folder
    end

    if srcModel then
        clearActiveClone()
        local cloned = cloneEntireObject(srcModel)
        if cloned then
            local targetPart, targetAttachment = findTargetInVisual()
            attachCloneToTarget(cloned, targetPart, targetAttachment)
            activeClone = cloned
            activeSource = folder
            -- if the folder is removed later — cleanup
            handleFolderConns[folder] = folder.AncestryChanged:Connect(function(_, newParent)
                if not newParent then
                    -- original folder removed -> clear our clone
                    clearActiveClone()
                    if handleFolderConns[folder] then handleFolderConns[folder]:Disconnect() end
                    handleFolderConns[folder] = nil
                end
            end)
        end
    end
end

-- fallback: Tool.Equipped handler (in case game uses standard Tool)
local function onToolEquipped(tool)
    if not tool or not visual then return end
    -- clone entire tool model (safer than single Handle)
    clearActiveClone()
    local cloned = cloneEntireObject(tool)
    if not cloned then return end
    local targetPart, targetAttachment = findTargetInVisual()
    attachCloneToTarget(cloned, targetPart, targetAttachment)
    activeClone = cloned
    activeSource = tool
    -- bind tool destroy/unequip to cleanup
    local function onRemoved()
        clearActiveClone()
        if toolConns[tool] then
            if toolConns[tool].equip then pcall(function() toolConns[tool].equip:Disconnect() end) end
            if toolConns[tool].unequip then pcall(function() toolConns[tool].unequip:Disconnect() end) end
            toolConns[tool] = nil
        end
    end
    toolConns[tool] = {}
    toolConns[tool].equip = tool.Equipped:Connect(function() end) -- keep reference
    toolConns[tool].unequip = tool.Unequipped:Connect(onRemoved)
    -- if tool destroyed, cleanup
    tool.AncestryChanged:Connect(function(_, newParent) if not newParent then onRemoved() end end)
end

-- watch player's backpack/character for Tool.Equipped
local function watchToolsInContainer(container)
    if not container then return end
    for _, child in ipairs(container:GetChildren()) do
        if child:IsA("Tool") then
            -- ensure we bind events
            if not toolConns[child] then
                toolConns[child] = {}
                toolConns[child].equip = child.Equipped:Connect(function() onToolEquipped(child) end)
                toolConns[child].unequip = child.Unequipped:Connect(function() clearActiveClone() end)
            end
        end
    end
    container.ChildAdded:Connect(function(child)
        if child:IsA("Tool") then
            if not toolConns[child] then
                toolConns[child] = {}
                toolConns[child].equip = child.Equipped:Connect(function() onToolEquipped(child) end)
                toolConns[child].unequip = child.Unequipped:Connect(function() clearActiveClone() end)
            end
        end
    end)
end

-- initial bind
watchToolsInContainer(lp:FindFirstChildOfClass("Backpack"))
if lp.Character then watchToolsInContainer(lp.Character) end
lp.CharacterAdded:Connect(function(char) watchToolsInContainer(char) end)

-- listen for any ToolHandle appearing anywhere (fast path)
local conn = Workspace.DescendantAdded:Connect(function(inst)
    if not inst then return end
    if inst.Name == TOOLHANDLE_NAME and inst:IsA("Folder") or inst:IsA("Model") then
        -- small delay to wait population
        task.defer(function() onToolHandleFound(inst) end)
    end
end)

-- also listen globally in case ToolHandle placed under player object (rare)
local gconn = game.DescendantAdded:Connect(function(obj)
    if obj and obj.Name == TOOLHANDLE_NAME and (obj:IsA("Folder") or obj:IsA("Model")) then
        task.defer(function() onToolHandleFound(obj) end)
    end
end)

-- cleanup on exit
local function stopAll()
    conn:Disconnect(); gconn:Disconnect()
    clearActiveClone()
    for t, tbl in pairs(toolConns) do
        pcall(function()
            if tbl.equip then tbl.equip:Disconnect() end
            if tbl.unequip then tbl.unequip:Disconnect() end
        end)
        toolConns[t] = nil
    end
    for f, c in pairs(handleFolderConns) do pcall(function() c:Disconnect() end) handleFolderConns[f] = nil end
end

_G.stopToolAttachToDeer = stopAll
print("[tool-attach] running — watching ToolHandle and Tools. VISUAL:", VISUAL_NAME)
