-- toolhandle-attach-robust.lua  (локальный, инжектор)
-- Отслеживает ToolHandle (и Tools) и клонирует их содержимое локально в VISUAL_NAME,
-- подписывается на ChildAdded/DescendantAdded чтобы поймать элементы сразу при появлении.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local lp = Players.LocalPlayer
if not lp then return end

-- Настройки
local VISUAL_NAME = "LOCAL_DEER_VISUAL"          -- имя визуальной модели (Deer)
local HAND_OFFSET_CFRAME = CFrame.new(0, -0.15, -0.6) -- подгони под свою модель
local SEARCH_ATTACHMENT_NAMES = {"RightGripAttachment","RightHandAttachment"} -- priority attachments
local TOOLHANDLE_NAME = "ToolHandle"             -- имя папки в игре (game-specific)
local MAX_OWNER_DISTANCE = 6                     -- радиус для эвристики принадлежности ToolHandle игроку

-- Внутренние состояния
local visual = workspace:FindFirstChild(VISUAL_NAME)
if not visual then warn("[tool-attach] visual '"..VISUAL_NAME.."' not found; скрипт запустится, когда появится.") end
local activeClone = nil      -- текущный клон, который прикрепили к visual
local activeSource = nil     -- ссылка на оригинал (Tool or ToolHandle folder)
local trackedHandles = {}    -- folder -> connections {descCon, removeCon}
local toolConns = {}         -- tool -> {equip, unequip, ancestry}

local function findTargetInVisual()
    if not visual then return nil, nil end
    for _, name in ipairs(SEARCH_ATTACHMENT_NAMES) do
        local inst = visual:FindFirstChild(name, true)
        if inst then
            if inst:IsA("Attachment") and inst.Parent and inst.Parent:IsA("BasePart") then
                return inst.Parent, inst
            elseif inst:IsA("BasePart") then
                return inst, nil
            end
        end
    end
    -- fallback
    local prim = visual:FindFirstChild("HumanoidRootPart") or visual.PrimaryPart
    return prim, nil
end

-- клонирует объект (folder/model/tool). Возвращает клонированный Model.
local function cloneEntire(src)
    if not src then return nil end
    local ok, c = pcall(function() return src:Clone() end)
    if not ok or not c then return nil end
    local modelClone
    if c:IsA("Model") then
        modelClone = c
    else
        modelClone = Instance.new("Model")
        c.Parent = modelClone
        modelClone.Name = "LOCAL_TOOL_MODEL"
    end
    -- sanitize and force visible
    for _, v in ipairs(modelClone:GetDescendants()) do
        if v:IsA("BasePart") then
            pcall(function()
                v.CanCollide = false
                v.LocalTransparencyModifier = 0     -- force visible locally
                v.Transparency = 0                 -- in case engine reads it (local)
                if v.Massless ~= nil then v.Massless = true end
            end)
        elseif v:IsA("Decal") then
            pcall(function() v.Transparency = 0 end)
        elseif v:IsA("Script") or v:IsA("LocalScript") or v:IsA("ModuleScript") then
            pcall(function() v:Destroy() end)
        end
    end
    modelClone.Parent = visual or workspace
    return modelClone
end

local function attachClone(modelClone)
    if not modelClone or not visual then return false end
    -- pick primary part for modelClone
    local prim = modelClone.PrimaryPart
    if not prim then
        for _, p in ipairs(modelClone:GetDescendants()) do
            if p:IsA("BasePart") then prim = p; break end
        end
        if prim then modelClone.PrimaryPart = prim end
    end
    if not prim then return false end

    -- pick target in visual
    local targetPart, targetAttachment = findTargetInVisual()
    if not targetPart then return false end

    local baseCFrame = targetPart.CFrame
    if targetAttachment and targetAttachment:IsA("Attachment") then
        baseCFrame = targetPart.CFrame * targetAttachment.CFrame
    end
    local desired = baseCFrame * HAND_OFFSET_CFRAME

    pcall(function() modelClone:SetPrimaryPartCFrame(desired) end)

    -- weld primary part to target
    local weld = Instance.new("WeldConstraint")
    weld.Part0 = modelClone.PrimaryPart
    weld.Part1 = targetPart
    weld.Parent = modelClone.PrimaryPart

    return true
end

local function clearActive()
    if activeClone and activeClone.Parent then
        pcall(function() activeClone:Destroy() end)
    end
    activeClone = nil
    activeSource = nil
end

-- получаем простую эвристику принадлежности папки ToolHandle локальному игроку
local function isHandleForLocal(folder)
    if not folder then return false end
    local par = folder.Parent
    if par == lp.Character or par == lp or (par and par.Name == lp.Name) then
        return true
    end
    -- distance fallback
    local hrp = lp.Character and (lp.Character:FindFirstChild("HumanoidRootPart") or lp.Character.PrimaryPart)
    if not hrp then return false end
    for _, v in ipairs(folder:GetDescendants()) do
        if v:IsA("BasePart") and (v.Position - hrp.Position).Magnitude < MAX_OWNER_DISTANCE then
            return true
        end
    end
    return false
end

-- when folder is populated (or parts appear) we clone & attach immediately
local function handleFolderPopulate(folder)
    if not folder or not isHandleForLocal(folder) then return end
    -- if there's already a clone created for some other source, clear it (we always show current)
    clearActive()

    -- if folder has children, clone whole folder
    if #folder:GetChildren() > 0 then
        local cloned = cloneEntire(folder)
        if cloned then
            if attachClone(cloned) then
                activeClone = cloned
                activeSource = folder
                -- remember to cleanup when folder removed
                if not trackedHandles[folder] then
                    trackedHandles[folder] = {}
                    trackedHandles[folder].rem = folder.AncestryChanged:Connect(function(_, newParent)
                        if not newParent then clearActive() end
                    end)
                end
                return
            else
                pcall(function() cloned:Destroy() end)
            end
        end
    end
    -- else folder empty currently: subscribe to ChildAdded / DescendantAdded to catch first BasePart
    if not trackedHandles[folder] then
        trackedHandles[folder] = {}
        trackedHandles[folder].childAdded = folder.ChildAdded:Connect(function(child)
            if child:IsA("BasePart") or child:FindFirstChildWhichIsA then
                -- brief yield: sometimes children spawn with inner parts; wait tiny bit then clone whole folder
                task.defer(function()
                    if folder and folder.Parent then
                        -- when first BasePart appears -> clone entire folder and attach
                        local cloned = cloneEntire(folder)
                        if cloned and attachClone(cloned) then
                            activeClone = cloned
                            activeSource = folder
                            -- wire removal
                            trackedHandles[folder].rem = folder.AncestryChanged:Connect(function(_, newParent)
                                if not newParent then clearActive() end
                            end)
                        else
                            pcall(function() if cloned and cloned.Parent then cloned:Destroy() end end)
                        end
                    end
                end)
            end
        end)
        trackedHandles[folder].desc = folder.DescendantAdded:Connect(function(desc)
            if desc and desc:IsA("BasePart") then
                -- same logic as above; childAdded covers most cases but descendant may be useful
                task.defer(function()
                    if folder and folder.Parent then
                        local cloned = cloneEntire(folder)
                        if cloned and attachClone(cloned) then
                            activeClone = cloned
                            activeSource = folder
                            trackedHandles[folder].rem = folder.AncestryChanged:Connect(function(_, newParent)
                                if not newParent then clearActive() end
                            end)
                        else
                            pcall(function() if cloned and cloned.Parent then cloned:Destroy() end end)
                        end
                    end
                end)
            end
        end)
    end
end

-- global listener for ToolHandle appearing anywhere
local globalHandleConn = Workspace.DescendantAdded:Connect(function(inst)
    if not inst then return end
    if inst.Name == TOOLHANDLE_NAME and (inst:IsA("Folder") or inst:IsA("Model")) then
        task.defer(function() handleFolderPopulate(inst) end)
    end
end)

-- auxiliary global (covers odd placements)
local globalGConn = game.DescendantAdded:Connect(function(inst)
    if not inst then return end
    if inst.Name == TOOLHANDLE_NAME and (inst:IsA("Folder") or inst:IsA("Model")) then
        task.defer(function() handleFolderPopulate(inst) end)
    end
end)

-- fallback: monitor Tools in Backpack/Character (standard behavior)
local function bindTool(tool)
    if not tool or toolConns[tool] then return end
    toolConns[tool] = {}
    toolConns[tool].equip = tool.Equipped:Connect(function()
        -- clone entire tool (preferable), attach
        clearActive()
        local cl = cloneEntire(tool)
        if cl and attachClone(cl) then
            activeClone = cl
            activeSource = tool
            -- cleanup when tool removed
            toolConns[tool].ancestry = tool.AncestryChanged:Connect(function(_, newPar) if not newPar then clearActive() end end)
        else
            pcall(function() if cl and cl.Parent then cl:Destroy() end end)
        end
    end)
    toolConns[tool].unequip = tool.Unequipped:Connect(function() clearActive() end)
    -- if tool destroyed
    toolConns[tool].ancestry = tool.AncestryChanged:Connect(function(_, newPar) if not newPar then clearActive() end end)
end

local function watchContainer(container)
    if not container then return end
    for _, child in ipairs(container:GetChildren()) do
        if child:IsA("Tool") then bindTool(child) end
    end
    container.ChildAdded:Connect(function(child) if child:IsA("Tool") then bindTool(child) end end)
end

-- init watchers
watchContainer(lp:FindFirstChildOfClass("Backpack"))
if lp.Character then watchContainer(lp.Character) end
lp.CharacterAdded:Connect(function(char) watchContainer(char) end)

-- cleanup util
local function stopAll()
    if globalHandleConn then globalHandleConn:Disconnect(); globalHandleConn = nil end
    if globalGConn then globalGConn:Disconnect(); globalGConn = nil end
    clearActive()
    for f, conns in pairs(trackedHandles) do
        for _, c in pairs(conns) do pcall(function() c:Disconnect() end) end
    end
    trackedHandles = {}
    for t, tbl in pairs(toolConns) do
        for _, c in pairs(tbl) do pcall(function() c:Disconnect() end) end
    end
    toolConns = {}
end

_G.stopToolAttach = stopAll
print("[toolhandle-attach] running — watching ToolHandle and Tools. VISUAL:", VISUAL_NAME)
