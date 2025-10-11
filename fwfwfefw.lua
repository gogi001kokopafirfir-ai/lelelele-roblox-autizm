-- toolhandle-attach-fixed-debounce.lua  (локальный, инжектор)
-- Стабильный attach: debounce + проверка "готовности" содержимого ToolHandle

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local lp = Players.LocalPlayer
if not lp then warn("[tool-attach] No LocalPlayer") return end

-- попыточно остановим старые версии
if _G.stopToolAttach then pcall(_G.stopToolAttach) end
_G.stopToolAttach = nil

-- Настройки
local VISUAL_NAME = "LOCAL_DEER_VISUAL"
local HAND_OFFSET_CFRAME = CFrame.new(0, -0.15, -0.5)
local SEARCH_ATTACHMENT_NAMES = {"RightGripAttachment","RightHandAttachment"}
local TOOLHANDLE_NAME = "ToolHandle"
local MAX_OWNER_DISTANCE = 6
local DEBOUNCE_SEC = 0.14   -- задержка, даём игре подложить все части (подогнать при необходимости)
local MIN_PART_SIZE = 0.01  -- минимальный размер для части считать "реальной"

-- Состояние
local visual = workspace:FindFirstChild(VISUAL_NAME)
if not visual then warn("[tool-attach] visual '"..VISUAL_NAME.."' not found; запусти визуал сначала") end
local activeClone = nil
local activeSource = nil
local tracked = {}  -- folder -> {scheduled = bool, attached = bool, conns = {}}

-- HELPERS
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
    return visual:FindFirstChild("HumanoidRootPart") or visual.PrimaryPart, nil
end

local function isRenderablePart(part)
    if not part or not part:IsA("BasePart") then return false end
    -- size check
    local s = part.Size
    if (s.X*s.Y*s.Z) > MIN_PART_SIZE then return true end
    -- also consider if has mesh id (Common case)
    local mesh = part:FindFirstChildWhichIsA("SpecialMesh", true)
    if mesh and (mesh.MeshId and mesh.MeshId ~= "" or mesh.TextureId and mesh.TextureId ~= "") then
        return true
    end
    -- fallback check: transparency < 0.95 (visible)
    if part.Transparency and part.Transparency < 0.95 then return true end
    return false
end

local function cloneEntire(src)
    if not src then return nil end
    local ok, c = pcall(function() return src:Clone() end)
    if not ok or not c then warn("[tool-attach] clone failed:", tostring(c)); return nil end
    local modelClone
    if c:IsA("Model") then
        modelClone = c
    else
        modelClone = Instance.new("Model")
        c.Parent = modelClone
        modelClone.Name = "LOCAL_TOOL_MODEL"
    end
    -- sanitize & force visible
    local partsCount = 0
    for _, v in ipairs(modelClone:GetDescendants()) do
        if v:IsA("BasePart") then
            partsCount = partsCount + 1
            pcall(function()
                v.CanCollide = false
                v.LocalTransparencyModifier = 0
                v.Transparency = 0
                if v.Massless ~= nil then v.Massless = true end
            end)
        elseif v:IsA("Decal") then
            pcall(function() v.Transparency = 0 end)
        elseif v:IsA("Script") or v:IsA("LocalScript") or v:IsA("ModuleScript") then
            pcall(function() v:Destroy() end)
        end
    end
    modelClone.Parent = visual or Workspace
    return modelClone, partsCount
end

local function attachClone(modelClone)
    if not modelClone or not visual then return false end
    local prim = modelClone.PrimaryPart
    if not prim then
        for _, p in ipairs(modelClone:GetDescendants()) do
            if p:IsA("BasePart") then prim = p; break end
        end
        if prim then modelClone.PrimaryPart = prim end
    end
    if not prim then return false end

    local targetPart, targetAttachment = findTargetInVisual()
    if not targetPart then return false end

    local baseCFrame = targetPart.CFrame
    if targetAttachment and targetAttachment:IsA("Attachment") then baseCFrame = targetPart.CFrame * targetAttachment.CFrame end
    local desired = baseCFrame * HAND_OFFSET_CFRAME

    pcall(function() modelClone:SetPrimaryPartCFrame(desired) end)

    local weld = Instance.new("WeldConstraint")
    weld.Part0 = modelClone.PrimaryPart
    weld.Part1 = targetPart
    weld.Parent = modelClone.PrimaryPart

    return true
end

local function clearActive()
    if activeClone and activeClone.Parent then pcall(function() activeClone:Destroy() end) end
    activeClone = nil
    activeSource = nil
end

local function isHandleForLocal(folder)
    if not folder then return false end
    local par = folder.Parent
    if par == lp.Character or par == lp or (par and par.Name == lp.Name) then return true end
    local hrp = lp.Character and (lp.Character:FindFirstChild("HumanoidRootPart") or lp.Character.PrimaryPart)
    if not hrp then return false end
    for _, v in ipairs(folder:GetDescendants()) do
        if v:IsA("BasePart") and (v.Position - hrp.Position).Magnitude < MAX_OWNER_DISTANCE then return true end
    end
    return false
end

-- Try attach only if folder has at least one renderable descendant
local function tryAttachFromFolder(folder)
    if not folder or not folder.Parent then return end
    if tracked[folder] and tracked[folder].attached then return end
    if not isHandleForLocal(folder) then return end

    -- find any renderable descendant
    local found = nil
    for _, d in ipairs(folder:GetDescendants()) do
        if d:IsA("BasePart") and isRenderablePart(d) then
            found = d; break
        end
    end
    if not found then
        -- nothing renderable yet
        return false
    end

    -- ok, clone whole folder now
    clearActive()
    local cloned, parts = cloneEntire(folder)
    if cloned then
        local ok = attachClone(cloned)
        if ok then
            activeClone = cloned
            activeSource = folder
            tracked[folder] = tracked[folder] or {}
            tracked[folder].attached = true
            print(string.format("[tool-attach] attached clone from ToolHandle: %s  (parts=%d)", tostring(folder:GetFullName()), parts or 0))
            -- set removal listener
            tracked[folder].rem = folder.AncestryChanged:Connect(function(_, newParent)
                if not newParent then
                    tracked[folder] = nil
                    clearActive()
                end
            end)
            return true
        else
            pcall(function() if cloned and cloned.Parent then cloned:Destroy() end end)
        end
    end
    return false
end

-- schedule attach with debounce
local function scheduleAttach(folder)
    if not folder then return end
    tracked[folder] = tracked[folder] or {}
    if tracked[folder].scheduled then return end
    tracked[folder].scheduled = true
    task.delay(DEBOUNCE_SEC, function()
        if not folder or not folder.Parent then tracked[folder] = nil; return end
        tracked[folder].scheduled = false
        -- try attach; if failed, try once more after small delay (gives game time to populate more)
        local attached = tryAttachFromFolder(folder)
        if not attached then
            -- second try short delay
            task.delay(0.12, function()
                if folder and folder.Parent then tryAttachFromFolder(folder) end
            end)
        end
    end)
end

-- handler when ToolHandle appears
local function onToolHandleFound(folder)
    if not folder then return end
    if not isHandleForLocal(folder) then return end

    -- if already attached to this folder, ignore
    if activeSource == folder then return end

    -- if folder already has renderable parts, attach immediately
    if tryAttachFromFolder(folder) then return end

    -- otherwise subscribe to DescendantAdded and schedule attach on changes
    if not tracked[folder] then tracked[folder] = {} end
    if tracked[folder].descConn then return end
    tracked[folder].descConn = folder.DescendantAdded:Connect(function(desc)
        if desc and desc:IsA("BasePart") then scheduleAttach(folder) end
    end)
    tracked[folder].childConn = folder.ChildAdded:Connect(function(child) if child and child:IsA("BasePart") then scheduleAttach(folder) end end)
    -- also schedule an initial attempt (in case parts already present but were not counted)
    scheduleAttach(folder)
end

-- GLOBAL WATCHERS
local g1 = Workspace.DescendantAdded:Connect(function(inst)
    if inst and inst.Name == TOOLHANDLE_NAME and (inst:IsA("Folder") or inst:IsA("Model")) then
        task.defer(function() onToolHandleFound(inst) end)
    end
end)
local g2 = game.DescendantAdded:Connect(function(inst)
    if inst and inst.Name == TOOLHANDLE_NAME and (inst:IsA("Folder") or inst:IsA("Model")) then
        task.defer(function() onToolHandleFound(inst) end)
    end
end)

-- fallback: Tools in Backpack/Character (standard Tools)
local toolConns = {}
local function bindTool(tool)
    if not tool or toolConns[tool] then return end
    toolConns[tool] = {}
    toolConns[tool].equip = tool.Equipped:Connect(function()
        clearActive()
        local cl, parts = cloneEntire(tool)
        if cl and attachClone(cl) then
            activeClone = cl; activeSource = tool
            print("[tool-attach] attached clone from Tool: "..tostring(tool:GetFullName()).." parts="..tostring(parts))
            toolConns[tool].ancestry = tool.AncestryChanged:Connect(function(_, new) if not new then clearActive() end end)
        else
            pcall(function() if cl and cl.Parent then cl:Destroy() end end)
        end
    end)
    toolConns[tool].unequip = tool.Unequipped:Connect(function() clearActive() end)
end

local function watchContainer(container)
    if not container then return end
    for _, child in ipairs(container:GetChildren()) do if child:IsA("Tool") then bindTool(child) end end
    container.ChildAdded:Connect(function(child) if child and child:IsA("Tool") then bindTool(child) end end)
end

watchContainer(lp:FindFirstChildOfClass("Backpack"))
if lp.Character then watchContainer(lp.Character) end
lp.CharacterAdded:Connect(function(char) watchContainer(char) end)

-- cleanup
local function stopAll()
    if g1 then g1:Disconnect(); g1 = nil end
    if g2 then g2:Disconnect(); g2 = nil end
    clearActive()
    for f, t in pairs(tracked) do
        if t.descConn then pcall(function() t.descConn:Disconnect() end) end
        if t.childConn then pcall(function() t.childConn:Disconnect() end) end
        if t.rem then pcall(function() t.rem:Disconnect() end) end
    end
    tracked = {}
    for tool, tbl in pairs(toolConns) do
        for _, c in pairs(tbl) do pcall(function() c:Disconnect() end) end
    end
    toolConns = {}
    print("[tool-attach] stopped")
end

_G.stopToolAttach = stopAll
print("[tool-attach] running; visual:", tostring(visual and visual:GetFullName() or "nil"))
