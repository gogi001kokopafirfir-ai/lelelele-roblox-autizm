-- attach-toolhandle-to-deer.lua  (client / injector)
-- Автомат: наблюдает за workspace.ToolHandle, клонирует визуалы и привязывает их к Deer визуалу.
-- Консольные команды:
--   _G.ReloadDeerTools()          -- пересоздаёт привязки по текущему ToolHandle (если есть)
--   _G.ClearDeerTools()           -- удаляет все визуальные прикрепления
--   _G.SetToolOffset(name, pos, rotDeg)  -- сохраняет/меняет offset для инструмента (pos Vector3, rotDeg Vector3 (deg))
--   _G.ListAttachedTools()        -- печатает список текущих привязанных
-- Настрой: если имя deer'а другое — поменяй VISUAL_NAME.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local VISUAL_NAME = "LOCAL_DEER_VISUAL" -- имя визуальной модели deer в workspace
local TOOL_HANDLE_FOLDER_NAME = "ToolHandle" -- имя папки, которая появляется в workspace при экипировке
local ATTACHED_FOLDER_NAME = "Deer_AttachedTools" -- где будут храниться визуальные копии внутри deer

-- default offsets (можешь заполнять через SetToolOffset)
-- формат: offsets["OriginalItem"] = {pos = Vector3.new(x,y,z), rot = Vector3.new(rx,ry,rz)} (rot в градусах)
local offsets = {}

-- internal state
local visual = workspace:FindFirstChild(VISUAL_NAME)
local attached = {} -- name -> {model = Model, welds = {...}, offset = {...}}
local watching = false
local toolHandleFolder = nil

-- utilities
local function v3(...) return Vector3.new(...) end
local function deg2rad(v) return Vector3.new(math.rad(v.X), math.rad(v.Y), math.rad(v.Z)) end

local function findVisual()
    visual = workspace:FindFirstChild(VISUAL_NAME) or workspace:WaitForChild(VISUAL_NAME, 3)
    return visual
end

local function findBestHandPart(model)
    if not model then return nil end
    local names = {"RightHand","RightForeleg","RightArm","FrontRightHoof","RightFrontHoof","RightHoof","HoofR","Hand","RightGripAttachment"}
    -- try case-insensitive search for parts
    for _, n in ipairs(names) do
        local found = model:FindFirstChild(n, true)
        if found and found:IsA("BasePart") then return found end
    end
    -- fallback: try to find an Attachment named RightGripAttachment and return its parent
    for _, a in ipairs(model:GetDescendants()) do
        if a:IsA("Attachment") and string.lower(a.Name):match("right") then
            if a.Parent and a.Parent:IsA("BasePart") then return a.Parent end
        end
    end
    -- last fallback: PrimaryPart
    if model.PrimaryPart and model.PrimaryPart:IsA("BasePart") then return model.PrimaryPart end
    -- try any BasePart
    for _, p in ipairs(model:GetDescendants()) do
        if p:IsA("BasePart") then return p end
    end
    return nil
end

-- clean clone: remove scripts and internal welds/motor6d/etc.
local function sanitizeClone(m)
    for _,d in ipairs(m:GetDescendants()) do
        if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ModuleScript")
        or d:IsA("Weld") or d:IsA("WeldConstraint") or d:IsA("Motor6D")
        or d:IsA("AlignOrientation") or d:IsA("AlignPosition") then
            pcall(function() d:Destroy() end)
        end
        if d:IsA("BasePart") then
            pcall(function()
                d.CanCollide = false
                if d.Massless ~= nil then d.Massless = true end
                d.LocalTransparencyModifier = 0
            end)
        end
    end
end

local function clearAttached()
    for name,info in pairs(attached) do
        pcall(function()
            if info.model and info.model.Parent then info.model:Destroy() end
        end)
        attached[name] = nil
    end
end

local function listAttached()
    for name,info in pairs(attached) do
        print("Attached:", name, "model:", info.model and info.model:GetFullName() or "nil", "offset:", info.offset and info.offset.pos, info.offset and info.offset.rot)
    end
end

-- set offset via console
_G.SetToolOffset = function(name, pos, rotDeg)
    if type(name) ~= "string" then error("name string") end
    pos = pos or Vector3.new(0,0,0)
    rotDeg = rotDeg or Vector3.new(0,0,0)
    offsets[name] = {pos = pos, rot = rotDeg}
    print("Offset set for", name, offsets[name])
end

_G.ListAttachedTools = listAttached
_G.ClearDeerTools = function() clearAttached(); print("Cleared attached visuals") end

-- attach single tool (folder) -> clone & weld to visual
local function attachToolFolderToVisual(folder)
    if not folder or not folder.Parent then return end
    local v = findVisual()
    if not v then warn("visual not found") return end
    local hand = findBestHandPart(v)
    if not hand then warn("hand part not found in visual") return end

    -- clear old ones
    clearAttached()

    -- If folder contains multiple parts/models, we treat each top-level child as a thing to attach
    for _,child in ipairs(folder:GetChildren()) do
        -- We only clone reasonable things (BasePart or Model)
        if child:IsA("Model") or child:IsA("BasePart") or child:IsA("Folder") then
            local clone = child:Clone()
            clone.Name = ("deervis_%s"):format(child.Name)
            sanitizeClone(clone)

            -- If clone is a single part, wrap into Model for consistent handling
            local rootPart = clone:IsA("BasePart") and clone or clone:FindFirstChildWhichIsA("BasePart", true)
            if not rootPart then
                -- create dummy part if none found
                rootPart = Instance.new("Part")
                rootPart.Size = Vector3.new(0.2,0.2,0.2)
                rootPart.Transparency = 1
                rootPart.Parent = clone
            end

            local modelParent = v:FindFirstChild(ATTACHED_FOLDER_NAME) or Instance.new("Folder")
            modelParent.Name = ATTACHED_FOLDER_NAME
            modelParent.Parent = v

            clone.Parent = modelParent

            -- default offset for this tool (if present)
            local ofs = offsets[child.Name] or {pos = Vector3.new(0,0,0), rot = Vector3.new(0,0,0)}
            -- compute tool CFrame as hand.CFrame * offset (rot in deg)
            local rotRad = deg2rad(ofs.rot)
            local toolCFrame = hand.CFrame * (CFrame.Angles(rotRad.X, rotRad.Y, rotRad.Z) * CFrame.new(ofs.pos))
            -- place clone so its primary/base part matches
            pcall(function() 
                if clone.PrimaryPart == nil then
                    clone.PrimaryPart = rootPart
                end
                clone:SetPrimaryPartCFrame(toolCFrame)
            end)

            -- create weld constraint between hand and tool root
            pcall(function()
                local weld = Instance.new("WeldConstraint")
                weld.Name = "deer_weld_"..child.Name
                weld.Part0 = hand
                weld.Part1 = clone.PrimaryPart
                weld.Parent = clone.PrimaryPart
            end)

            -- store info for later adjustments
            attached[child.Name] = {model = clone, weldPart = clone.PrimaryPart, offset = ofs}
            print("Attached visual for", child.Name, "->", clone:GetFullName())
        end
    end
end

-- watcher: look for workspace.ToolHandle
local function tryAttachFromWorkspace()
    local fh = Workspace:FindFirstChild(TOOL_HANDLE_FOLDER_NAME)
    if fh and fh.Parent then
        toolHandleFolder = fh
        attachToolFolderToVisual(fh)
        return true
    end
    return false
end

-- watcher: reconnect on ChildAdded/ChildRemoved in workspace
local workspaceConn = nil
local function startWatching()
    if watching then return end
    watching = true
    -- if folder already present
    tryAttachFromWorkspace()
    workspaceConn = Workspace.ChildAdded:Connect(function(c)
        if c.Name == TOOL_HANDLE_FOLDER_NAME then
            toolHandleFolder = c
            attachToolFolderToVisual(c)
        end
    end)
end

-- public helpers
_G.ReloadDeerTools = function()
    if toolHandleFolder and toolHandleFolder.Parent then
        attachToolFolderToVisual(toolHandleFolder)
    else
        -- try to find in workspace
        if not tryAttachFromWorkspace() then warn("No ToolHandle in workspace; equip a tool to populate it") end
    end
end

_G.DetachAllTools = function() clearAttached(); print("Detached all") end

-- allow runtime offset tweak (and reapply)
_G.SetToolOffsetAndReapply = function(name, pos, rotDeg)
    _G.SetToolOffset(name, pos, rotDeg)
    _G.ReloadDeerTools()
end

-- start
startWatching()
print("[deer-tool-attach] running. Use ReloadDeerTools() to force attach, SetToolOffset(name,pos,rotDeg) to tweak offsets.")
