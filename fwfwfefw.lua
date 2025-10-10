-- attach-visual-tools.lua  (client / injector)
-- Клонирует визуальный предмет и вешает его в руке визуала (Deer).
-- Настраиваемые параметры вверху.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local workspace = game:GetService("Workspace")
local lp = Players.LocalPlayer
if not lp then warn("No LocalPlayer") return end

-- ============ Настройки ============
local VISUAL_NAMES = {"LOCAL_DEER_VISUAL", "Deer_LOCAL", "LOCAL_DEER"} -- модели, где искать визуал
local ATTACH_CANDIDATES = {
    "RightGripAttachment", "RightGrip", "RightGripAttachment0", "RightHand", "RightArm",
    "FrontRightLeg", "Front_Right_Leg", "RightFrontLeg", "Right_Front_Leg"
}
local TOOL_HANDLE_FOLDER_NAME = "ToolHandle" -- если тулхендлы складывает туда игра
local MANUAL_ATTACH_CFRAME = CFrame.new(0,0,0) -- если нужно подвинуть позицию/ориентацию вручную (в local space of attach)
local TOOL_CLONE_PREFIX = "VIS_TOOL_"
local DEBUG = false
-- ====================================

local attachedClone = nil   -- текущный clone model
local attachedTool = nil    -- реальный Tool (если есть)
local attachPart = nil      -- Part on visual where tool attaches
local attachOffset = nil    -- CFrame offset: attachCFrame * offset = toolPrimary.CFrame
local visualModel = nil

local function dbg(...)
    if DEBUG then print("[attach-tools]", ...) end
end

-- ищем визуальную модель (по имени или по наличию LocalVisualAnimController)
local function findVisual()
    -- 1) быстрый поиск по именам
    for _, n in ipairs(VISUAL_NAMES) do
        local m = workspace:FindFirstChild(n)
        if m and m:IsA("Model") then
            dbg("found visual by name", n)
            return m
        end
    end
    -- 2) поиск по наличию AnimationController с именем LocalVisualAnimController
    for _, obj in ipairs(workspace:GetChildren()) do
        if obj:IsA("Model") then
            if obj:FindFirstChild("LocalVisualAnimController") or obj:FindFirstChildWhichIsA("AnimationController") then
                dbg("found visual by animcontroller:", obj.Name)
                return obj
            end
            -- fallback: find Animator / Animator descendant
            if obj:FindFirstChildWhichIsA("Animator", true) then
                dbg("found visual by Animator descendant:", obj.Name)
                return obj
            end
        end
    end
    return nil
end

-- найти подходящую part/attachment в visual
local function findAttachPart(model)
    if not model then return nil end
    -- first: attachments by name
    for _, name in ipairs(ATTACH_CANDIDATES) do
        local it = model:FindFirstChild(name, true)
        if it and it:IsA("Attachment") then
            return it.Parent -- attachment attachment.Parent should be a BasePart
        elseif it and it:IsA("BasePart") then
            return it
        end
    end
    -- second: try to find RightHand / FrontRightLeg parts explicitly
    for _, p in ipairs(model:GetDescendants()) do
        if p:IsA("BasePart") then
            local ln = string.lower(p.Name)
            if ln:find("right") and (ln:find("hand") or ln:find("arm") or ln:find("front") or ln:find("leg")) then
                return p
            end
        end
    end
    -- fallback: PrimaryPart or Head
    if model.PrimaryPart then return model.PrimaryPart end
    local head = model:FindFirstChild("Head", true)
    if head then return head end
    -- last resort: any BasePart
    for _, p in ipairs(model:GetDescendants()) do
        if p:IsA("BasePart") then return p end
    end
    return nil
end

-- выбрать источник (где взять визуальную модель предмета)
local function findToolSource(tool)
    -- if workspace has ToolHandle folder with children, prefer that (game-specific)
    local fh = workspace:FindFirstChild(TOOL_HANDLE_FOLDER_NAME)
    if fh and #fh:GetChildren() > 0 then
        dbg("Using workspace.ToolHandle as tool source")
        return fh
    end
    -- otherwise use the Tool instance itself (it may contain parts)
    if tool and tool.Parent then
        return tool
    end
    return nil
end

-- sanitize cloned tool model (remove scripts)
local function sanitizeToolClone(mdl)
    for _, d in ipairs(mdl:GetDescendants()) do
        if d:IsA("Script") or d:IsA("ModuleScript") or d:IsA("LocalScript") then
            pcall(function() d:Destroy() end)
        end
        if d:IsA("BasePart") then
            pcall(function()
                d.CanCollide = false
                d.LocalTransparencyModifier = 0
                if d.Massless ~= nil then d.Massless = true end
            end)
        end
    end
end

-- helper: find primary part in a model (first BasePart or named Handle/OriginalItem)
local function choosePrimary(mdl)
    if not mdl then return nil end
    local candidates = {"Handle", "OriginalItem", "Part", "Main", "Mesh", "Head"}
    for _, name in ipairs(candidates) do
        local p = mdl:FindFirstChild(name, true)
        if p and p:IsA("BasePart") then return p end
    end
    -- otherwise first BasePart
    for _, c in ipairs(mdl:GetDescendants()) do
        if c:IsA("BasePart") then return c end
    end
    return nil
end

-- attach visual clone to visualModel at attachPart with computed offset
local function attachCloneToVisual(cloneModel, attachP, manualCFrame)
    if not cloneModel or not attachP then return end
    sanitizeToolClone(cloneModel)
    -- choose primary for the clone
    local primary = choosePrimary(cloneModel)
    if not primary then
        warn("No BasePart in tool clone to use as Primary")
        cloneModel:Destroy()
        return
    end
    cloneModel.Parent = visualModel
    cloneModel.Name = TOOL_CLONE_PREFIX .. (cloneModel.Name or "tool")
    cloneModel.PrimaryPart = primary

    -- compute offset: offset such that attach.CFrame * offset = toolPrimary.CFrame
    local offset = attachP.CFrame:Inverse() * primary.CFrame
    if manualCFrame then
        offset = offset * manualCFrame
    end

    attachedClone = cloneModel
    attachPart = attachP
    attachOffset = offset
    dbg("attached tool clone:", cloneModel.Name, "offset:", tostring(offset))
end

-- clean current attached clone
local function clearAttached()
    if attachedClone and attachedClone.Parent then
        pcall(function() attachedClone:Destroy() end)
    end
    attachedClone = nil
    attachedTool = nil
    attachPart = nil
    attachOffset = nil
end

-- create clone from source and attach
local function createAndAttachFromSource(source, toolObj)
    if not source then return end
    -- If source is a folder like ToolHandle with multiple children, wrap them into a Model
    local newModel
    if source:IsA("Folder") or source:IsA("Model") and source ~= toolObj then
        -- clone entire folder/model
        local ok, cl = pcall(function() return source:Clone() end)
        if not ok or not cl then warn("failed clone source", cl); return end
        -- if cloned is a Folder, wrap children into a Model
        if cl:IsA("Folder") then
            local mdl = Instance.new("Model")
            mdl.Name = "temp_tool_clone"
            for _, c in ipairs(cl:GetChildren()) do
                c.Parent = mdl
            end
            cl:Destroy()
            newModel = mdl
        else
            newModel = cl
        end
    else
        -- clone tool object (Tool or part)
        local ok, cl = pcall(function() return source:Clone() end)
        if not ok or not cl then warn("failed clone tool", cl); return end
        newModel = cl
    end

    -- attach to visual at best attach part
    local ap = findAttachPart(visualModel)
    if not ap then
        warn("No attach part found in visualModel")
        newModel:Destroy()
        return
    end
    attachCloneToVisual(newModel, ap, MANUAL_ATTACH_CFRAME)
end

-- monitor tool equip/unequip from player's character and backpack
local function monitorTools()
    -- when a Tool is equipped in character, or when ToolHandle appears/changes, we update visual
    local function onEquip(tool)
        pcall(clearAttached)
        attachedTool = tool
        -- try to find source: workspace.ToolHandle first, else the tool itself
        local source = findToolSource(tool) or tool
        createAndAttachFromSource(source, tool)
    end
    local function onUnequip(tool)
        pcall(clearAttached)
    end

    -- bind existing tools
    local function bindContainer(container)
        if not container then return end
        -- ChildAdded may be used for new tools
        container.ChildAdded:Connect(function(child)
            if child:IsA("Tool") then
                child.Equipped:Connect(function() onEquip(child) end)
                child.Unequipped:Connect(function() onUnequip(child) end)
            end
        end)
        -- existing tools
        for _, t in ipairs(container:GetChildren()) do
            if t:IsA("Tool") then
                t.Equipped:Connect(function() onEquip(t) end)
                t.Unequipped:Connect(function() onUnequip(t) end)
            end
        end
    end

    bindContainer(lp:FindFirstChildOfClass("Backpack"))
    if lp.Character then bindContainer(lp.Character) end
    lp.CharacterAdded:Connect(function(char)
        bindContainer(char)
    end)

    -- also monitor workspace.ToolHandle changes (some games put tool visuals there)
    local th = workspace:FindFirstChild(TOOL_HANDLE_FOLDER_NAME)
    if th then
        th.ChildAdded:Connect(function()
            -- if there's currently an attachedTool, attempt to reattach from ToolHandle
            if attachedTool then
                -- small delay to allow game to populate the folder
                task.delay(0.05, function()
                    if attachedTool then
                        createAndAttachFromSource(th, attachedTool)
                    end
                end)
            end
        end)
    else
        -- if folder appears later
        workspace.ChildAdded:Connect(function(c)
            if c and c.Name == TOOL_HANDLE_FOLDER_NAME then
                -- bind new
                c.ChildAdded:Connect(function()
                    if attachedTool then
                        task.delay(0.05, function() createAndAttachFromSource(c, attachedTool) end)
                    end
                end)
            end
        end)
    end
end

-- per-frame updater: move attachedClone PrimaryPart to attachPart using stored offset
local function startFollowLoop()
    RunService:BindToRenderStep("VisualToolFollow_"..lp.UserId, Enum.RenderPriority.Camera.Value + 1, function()
        if attachedClone and attachedClone.PrimaryPart and attachPart and attachOffset then
            local ok, err = pcall(function()
                attachedClone.PrimaryPart.CFrame = attachPart.CFrame * attachOffset
            end)
            if not ok then dbg("follow error", err) end
        end
    end)
end

-- find visual model and start
visualModel = findVisual()
if not visualModel then
    warn("Visual model not found in workspace. Attach-visual-tools will try to auto-find later.")
    -- try to watch workspace for visual appearing
    workspace.ChildAdded:Connect(function(child)
        if not visualModel and child:IsA("Model") then
            if child:FindFirstChild("LocalVisualAnimController") or child.Name == VISUAL_NAMES[1] then
                visualModel = child
                dbg("visual found on ChildAdded:", child.Name)
            end
        end
    end)
else
    dbg("visualModel:", visualModel:GetFullName())
end

monitorTools()
startFollowLoop()

-- Expose some functions for manual control/tuning
_G.AttachTools_Clear = clearAttached
_G.AttachTools_FindAttachPart = function()
    if visualModel then return findAttachPart(visualModel) end
    return nil
end
_G.AttachTools_SetManualCFrame = function(cf)
    if type(cf) == "userdata" and cf.ClassName == "CFrame" then
        MANUAL_ATTACH_CFRAME = cf
        if attachedClone and attachPart then
            -- recompute offset quickly
            local prim = attachedClone.PrimaryPart
            if prim then attachOffset = attachPart.CFrame:Inverse() * prim.CFrame * MANUAL_ATTACH_CFRAME end
        end
    end
end

print("[attach-visual-tools] running. Take a tool to see it in Deer hand. Use AttachTools_Clear() to clear.")
