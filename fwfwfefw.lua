-- toolhandle-attach-robust-fixed.lua  (локальный инжектор)
-- Надёжная версия: авто-очистка старых инстансов, детальный debug.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local lp = Players.LocalPlayer
if not lp then warn("[tool-attach] No LocalPlayer, abort") return end

-- stop previous instances if any
if _G.stopToolAttach then
    pcall(function() _G.stopToolAttach() end)
    _G.stopToolAttach = nil
end
if _G.stopToolAttachToDeer then
    pcall(function() _G.stopToolAttachToDeer() end)
    _G.stopToolAttachToDeer = nil
end

-- SETTINGS (подгони при необходимости)
local VISUAL_NAME = "LOCAL_DEER_VISUAL"
local HAND_OFFSET_CFRAME = CFrame.new(0, -0.15, -0.5)
local SEARCH_ATTACHMENT_NAMES = {"RightGripAttachment","RightHandAttachment"}
local TOOLHANDLE_NAME = "ToolHandle"
local MAX_OWNER_DISTANCE = 6

-- state
local visual = workspace:FindFirstChild(VISUAL_NAME)
if not visual then
    warn("[tool-attach] visual not found: " .. VISUAL_NAME .. " — запусти визуал перед этим скриптом")
else
    print("[tool-attach] visual found:", visual:GetFullName())
end
local activeClone = nil
local activeSource = nil
local trackedHandles = {}   -- folder -> {childConn, descConn, remConn}
local toolConns = {}       -- tool -> {equipConn, unequipConn, ancestryConn}

-- helpers
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

local function cloneEntire(src)
    if not src then return nil end
    local ok, c = pcall(function() return src:Clone() end)
    if not ok or not c then
        warn("[tool-attach] clone failed for", src:GetFullName(), c)
        return nil
    end
    local modelClone
    if c:IsA("Model") then
        modelClone = c
    else
        modelClone = Instance.new("Model")
        c.Parent = modelClone
        modelClone.Name = "LOCAL_TOOL_MODEL"
    end
    for _, v in ipairs(modelClone:GetDescendants()) do
        if v:IsA("BasePart") then
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
    modelClone.Parent = visual or workspace
    return modelClone
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
    if targetAttachment and targetAttachment:IsA("Attachment") then
        baseCFrame = targetPart.CFrame * targetAttachment.CFrame
    end
    local desired = baseCFrame * HAND_OFFSET_CFRAME

    pcall(function() modelClone:SetPrimaryPartCFrame(desired) end)

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

local function isHandleForLocal(folder)
    if not folder then return false end
    local par = folder.Parent
    if par == lp.Character or par == lp or (par and par.Name == lp.Name) then
        return true
    end
    local hrp = lp.Character and (lp.Character:FindFirstChild("HumanoidRootPart") or lp.Character.PrimaryPart)
    if not hrp then return false end
    for _, v in ipairs(folder:GetDescendants()) do
        if v:IsA("BasePart") and (v.Position - hrp.Position).Magnitude < MAX_OWNER_DISTANCE then
            return true
        end
    end
    return false
end

local function handleFolderPopulate(folder)
    if not folder then return end
    if not isHandleForLocal(folder) then return end
    clearActive()
    if #folder:GetChildren() > 0 then
        local cloned = cloneEntire(folder)
        if cloned and attachClone(cloned) then
            activeClone = cloned
            activeSource = folder
            print("[tool-attach] attached clone from ToolHandle:", folder:GetFullName())
            if not trackedHandles[folder] then
                trackedHandles[folder] = {}
                trackedHandles[folder].rem = folder.AncestryChanged:Connect(function(_, newParent)
                    if not newParent then clearActive() end
                end)
            end
            return
        else
            pcall(function() if cloned and cloned.Parent then cloned:Destroy() end end)
        end
    end
    if not trackedHandles[folder] then
        trackedHandles[folder] = {}
        trackedHandles[folder].childConn = folder.ChildAdded:Connect(function(child)
            if child and child:IsA("BasePart") then
                task.defer(function()
                    if folder and folder.Parent then
                        local cloned = cloneEntire(folder)
                        if cloned and attachClone(cloned) then
                            activeClone = cloned
                            activeSource = folder
                            print("[tool-attach] attached clone (after child) from ToolHandle:", folder:GetFullName())
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
        trackedHandles[folder].descConn = folder.DescendantAdded:Connect(function(desc)
            if desc and desc:IsA("BasePart") then
                task.defer(function()
                    if folder and folder.Parent then
                        local cloned = cloneEntire(folder)
                        if cloned and attachClone(cloned) then
                            activeClone = cloned
                            activeSource = folder
                            print("[tool-attach] attached clone (after desc) from ToolHandle:", folder:GetFullName())
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

local globalHandleConn = Workspace.DescendantAdded:Connect(function(inst)
    if inst and inst.Name == TOOLHANDLE_NAME and (inst:IsA("Folder") or inst:IsA("Model")) then
        task.defer(function() handleFolderPopulate(inst) end)
    end
end)
local globalGConn = game.DescendantAdded:Connect(function(inst)
    if inst and inst.Name == TOOLHANDLE_NAME and (inst:IsA("Folder") or inst:IsA("Model")) then
        task.defer(function() handleFolderPopulate(inst) end)
    end
end)

local function bindTool(tool)
    if not tool or toolConns[tool] then return end
    toolConns[tool] = {}
    toolConns[tool].equip = tool.Equipped:Connect(function()
        clearActive()
        local cl = cloneEntire(tool)
        if cl and attachClone(cl) then
            activeClone = cl
            activeSource = tool
            print("[tool-attach] attached clone from Tool:", tool:GetFullName())
            toolConns[tool].ancestry = tool.AncestryChanged:Connect(function(_, newP) if not newP then clearActive() end end)
        else
            pcall(function() if cl and cl.Parent then cl:Destroy() end end)
        end
    end)
    toolConns[tool].unequip = tool.Unequipped:Connect(function() clearActive() end)
    toolConns[tool].ancestry = tool.AncestryChanged:Connect(function(_, newP) if not newP then clearActive() end end)
end

local function watchContainer(container)
    if not container then return end
    for _, child in ipairs(container:GetChildren()) do
        if child:IsA("Tool") then bindTool(child) end
    end
    container.ChildAdded:Connect(function(child) if child and child:IsA("Tool") then bindTool(child) end end)
end

watchContainer(lp:FindFirstChildOfClass("Backpack"))
if lp.Character then watchContainer(lp.Character) end
lp.CharacterAdded:Connect(function(char) watchContainer(char) end)

-- cleanup
local function stopAll()
    if globalHandleConn then globalHandleConn:Disconnect(); globalHandleConn = nil end
    if globalGConn then globalGConn:Disconnect(); globalGConn = nil end
    clearActive()
    for folder, conns in pairs(trackedHandles) do
        for k, c in pairs(conns) do pcall(function() c:Disconnect() end) end
    end
    trackedHandles = {}
    for t, tbl in pairs(toolConns) do
        for _, c in pairs(tbl) do pcall(function() c:Disconnect() end) end
    end
    toolConns = {}
    print("[tool-attach] stopped")
end

_G.stopToolAttach = stopAll
print("[tool-attach] running — watching ToolHandle and Tools. VISUAL:", VISUAL_NAME)
