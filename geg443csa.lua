-- visual-morph-safe.lua
-- Надёжный клиентский морф: локальный визуал, Align только движет визуаль (не реального игрока),
-- chat через BillboardGui на визуале. Откат: revertMorph().

local MODEL_NAME = "Deer"
local IDLE_ID = "rbxassetid://138304500572165"
local WALK_ID = "rbxassetid://78826693826761"

-- Настройки: в случае «внутри земли» увеличь MANUAL_Y_OFFSET на +0.2 / +0.5
local MANUAL_Y_OFFSET = 0.3
local RESPONSIVENESS = 80    -- НИЗКИЙ, чтобы не дергать физику
local MAX_FORCE = 1e5
local MAX_TORQUE = 1e5
local FP_HIDE_DISTANCE = 0.6

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local lp = Players.LocalPlayer
if not lp then error("No LocalPlayer") end

-- state
local template, visual, visualHum, animator
local idleTrack, walkTrack
local hrpAttach -- attachment PARENTED to real HRP but used as target (Attachment1)
local primAttach -- attachment on visual.PrimaryPart (Attachment0)
local alignPos, alignOri
local spawnedToolVisuals = {}
local toolConns = {}
local followConn

-- Helpers
local function isFirstPerson()
    local cam = workspace.CurrentCamera
    if not cam then return false end
    local char = lp.Character
    if not char then return false end
    local head = char:FindFirstChild("Head")
    if not head then return false end
    return (cam.CFrame.Position - head.Position).Magnitude < FP_HIDE_DISTANCE
end

local function setLocalVisibility(char, visible)
    if not char then return end
    for _,p in ipairs(char:GetDescendants()) do
        if p:IsA("BasePart") then
            pcall(function() p.LocalTransparencyModifier = visible and 0 or 1 end)
        end
    end
end

-- ВНИМАНИЕ: в отличие от прошлых версий — НИКОГДА не делаем Align, у которого Attachment0 принадлежит реальному персонажу.
-- Align всегда будет иметь Attachment0 на визуальной модели (чтобы силы применялись только к визуалу).

local function makeAttachment(parent, name, pos)
    if not parent or not parent.Parent then return nil end
    local a = Instance.new("Attachment")
    a.Name = name or "vis_att"
    if typeof(pos) == "Vector3" then a.Position = pos end
    a.Parent = parent
    return a
end

local function makeAlignPosition(parent, att0, att1)
    if not parent or not att0 or not att1 then return nil end
    local ap = Instance.new("AlignPosition")
    ap.Attachment0 = att0  -- attachment на визуальной части (будет подталкиваться)
    ap.Attachment1 = att1  -- target attachment (на реальном HRP) — как цель, силы применяются к Attachment0.part
    ap.Responsiveness = RESPONSIVENESS
    ap.MaxForce = MAX_FORCE
    ap.RigidityEnabled = true
    ap.Parent = parent
    return ap
end

local function makeAlignOrientation(parent, att0, att1)
    if not parent or not att0 or not att1 then nil end
    local ao = Instance.new("AlignOrientation")
    ao.Attachment0 = att0
    ao.Attachment1 = att1
    ao.Responsiveness = RESPONSIVENESS
    ao.MaxTorque = MAX_TORQUE
    ao.RigidityEnabled = true
    ao.Parent = parent
    return ao
end

local function safeLoadAnimation(animatorObj, animId)
    if not animatorObj or not animId then return nil end
    local ok, res = pcall(function()
        local a = Instance.new("Animation")
        a.AnimationId = animId
        a.Parent = animatorObj
        return animatorObj:LoadAnimation(a)
    end)
    if not ok then
        warn("LoadAnimation error:", res)
        return nil
    end
    if not res then
        warn("LoadAnimation returned nil for", animId)
        return nil
    end
    res.Priority = Enum.AnimationPriority.Movement
    return res
end

local function computeBoundingBox(model)
    local ok, cf, sz = pcall(function() return model:GetBoundingBox() end)
    if ok and cf and sz then return cf, sz end
    -- fallback: compute min/max over parts
    local minX, minY, minZ, maxX, maxY, maxZ
    for _,p in ipairs(model:GetDescendants()) do
        if p:IsA("BasePart") then
            local pos = p.Position
            local hx,hy,hz = p.Size.X/2, p.Size.Y/2, p.Size.Z/2
            local aMinX, aMaxX = pos.X-hx, pos.X+hx
            local aMinY, aMaxY = pos.Y-hy, pos.Y+hy
            local aMinZ, aMaxZ = pos.Z-hz, pos.Z+hz
            if not minX or aMinX < minX then minX = aMinX end
            if not minY or aMinY < minY then minY = aMinY end
            if not minZ or aMinZ < minZ then minZ = aMinZ end
            if not maxX or aMaxX > maxX then maxX = aMaxX end
            if not maxY or aMaxY > maxY then maxY = aMaxY end
            if not maxZ or aMaxZ > maxZ then maxZ = aMaxZ end
        end
    end
    if not minX then return nil end
    local center = Vector3.new((minX+maxX)/2, (minY+maxY)/2, (minZ+maxZ)/2)
    local size = Vector3.new(maxX-minX, maxY-minY, maxZ-minZ)
    return CFrame.new(center), size
end

local function createToolVisual(tool)
    if not tool or not visual then return end
    if spawnedToolVisuals[tool] then return spawnedToolVisuals[tool] end
    local ok, cloneTool = pcall(function() return tool:Clone() end)
    if not ok or not cloneTool then return end
    for _,d in ipairs(cloneTool:GetDescendants()) do
        if d:IsA("Script") or d:IsA("ModuleScript") then pcall(function() d:Destroy() end) end
    end
    cloneTool.Name = "VIS_"..(tool.Name or "Tool")
    cloneTool.Parent = visual
    local handle = cloneTool:FindFirstChild("Handle") or cloneTool:FindFirstChildWhichIsA("BasePart")
    local handPart = visual:FindFirstChild("RightHand", true) or visual:FindFirstChildWhichIsA("BasePart", true) or visual.PrimaryPart
    if handle and handPart then
        pcall(function() handle.CanCollide = false; handle.Massless = true end)
        local vAtt = makeAttachment(handle, "vis_handle_att")
        local hAtt = makeAttachment(handPart, "vis_hand_att")
        if vAtt and hAtt then
            local ap = Instance.new("AlignPosition", handle)
            ap.Attachment0 = vAtt; ap.Attachment1 = hAtt; ap.Responsiveness = 150; ap.MaxForce = 5e4; ap.RigidityEnabled = true
            local ao = Instance.new("AlignOrientation", handle)
            ao.Attachment0 = vAtt; ao.Attachment1 = hAtt; ao.Responsiveness = 150; ao.MaxTorque = 5e4; ao.RigidityEnabled = true
        end
    end
    spawnedToolVisuals[tool] = cloneTool
    return cloneTool
end

local function cleanupTools()
    for t,inst in pairs(spawnedToolVisuals) do
        pcall(function() if inst and inst.Parent then inst:Destroy() end end)
    end
    spawnedToolVisuals = {}
    for k,c in pairs(toolConns) do
        if c and type(c.Disconnect) == "function" then pcall(function() c:Disconnect() end) end
    end
    toolConns = {}
end

-- create visual safely
local function createVisual()
    template = template or (workspace:FindFirstChild(MODEL_NAME) or (function()
        for _,m in ipairs(workspace:GetChildren()) do if m:IsA("Model") and string.find(string.lower(m.Name or ""), string.lower(MODEL_NAME)) then return m end end
        return nil
    end)())
    if not template then warn("Template not found:", MODEL_NAME); return nil end

    if visual and visual.Parent then pcall(function() visual:Destroy() end) end

    local ok, clone = pcall(function() return template:Clone() end)
    if not ok or not clone then warn("Clone failed:", clone); return nil end
    clone.Name = "LOCAL_VISUAL_"..tostring(lp.UserId)

    -- remove scripts & humanoid, keep parts and Motor6D
    for _,d in ipairs(clone:GetDescendants()) do
        if d:IsA("Script") or d:IsA("ModuleScript") then pcall(function() d:Destroy() end) end
        if d:IsA("Humanoid") then pcall(function() d:Destroy() end) end
        if d:IsA("BasePart") then pcall(function() d.CanCollide = false; d.Anchored = false end) end
    end

    local prim = clone:FindFirstChild("HumanoidRootPart", true) or clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart", true)
    if prim then clone.PrimaryPart = prim end
    clone.Parent = workspace
    visual = clone

    -- animator & humanoid for visual
    visualHum = Instance.new("Humanoid"); visualHum.Name = "VisualHumanoid"; visualHum.Parent = visual
    animator = Instance.new("Animator"); animator.Parent = visualHum

    -- compute bbox and desired ground y
    local bboxCFrame, bboxSize = computeBoundingBox(visual)
    if not bboxCFrame then
        bboxCFrame = visual.PrimaryPart and visual.PrimaryPart.CFrame or CFrame.new(0,0,0)
        bboxSize = Vector3.new(2,2,2)
    end
    local bboxBottomY = bboxCFrame.Y - bboxSize.Y*0.5

    local realChar = lp.Character
    local realHRP = realChar and (realChar:FindFirstChild("HumanoidRootPart") or realChar.PrimaryPart)
    local realHum = realChar and realChar:FindFirstChildOfClass("Humanoid")
    local desiredGroundY = (realHRP and realHRP.Position.Y - (realHum and realHum.HipHeight or 2)) or bboxBottomY
    local verticalOffset = desiredGroundY - bboxBottomY + (MANUAL_Y_OFFSET or 0)
    -- clamp to sane range
    if verticalOffset ~= verticalOffset then verticalOffset = 0 end -- NaN guard
    verticalOffset = math.max(-20, math.min(20, verticalOffset))

    print("[morph] verticalOffset:", verticalOffset, "bboxBottomY:", bboxBottomY, "desiredGroundY:", desiredGroundY)

    -- create attachment on real HRP (target) — this does NOT move real HRP
    if realHRP then
        if hrpAttach and hrpAttach.Parent ~= realHRP then pcall(function() hrpAttach:Destroy() end) hrpAttach = nil end
        if not hrpAttach then
            hrpAttach = Instance.new("Attachment")
            hrpAttach.Name = "VIS_HRP_ATTACH_"..tostring(lp.UserId)
            hrpAttach.Parent = realHRP
        end
        hrpAttach.Position = Vector3.new(0, verticalOffset, 0)
    else
        warn("No real HRP found; visual will not track properly.")
    end

    -- create attachment on visual primary
    if visual.PrimaryPart then
        if primAttach and primAttach.Parent ~= visual.PrimaryPart then pcall(function() primAttach:Destroy() end) primAttach = nil end
        if not primAttach then
            primAttach = Instance.new("Attachment")
            primAttach.Name = "VIS_PRIM_ATTACH"
            primAttach.Parent = visual.PrimaryPart
        end
        primAttach.Position = Vector3.new(0,0,0)
    else
        warn("Visual has no PrimaryPart")
    end

    -- create Aligns that apply force to visual.PrimaryPart only (Attachment0 on visual)
    if primAttach and hrpAttach and visual.PrimaryPart then
        alignPos = makeAlignPosition(visual.PrimaryPart, primAttach, hrpAttach)
        alignOri = makeAlignOrientation(visual.PrimaryPart, primAttach, hrpAttach)
        if not alignPos or not alignOri then warn("Align creation failed") end
    else
        warn("Cannot create aligns: primAttach, hrpAttach or primary part missing")
    end

    -- create billboard gui on visual head (local chat bubble) — НЕ трогаем реальную голову
    local vHead = visual:FindFirstChild("Head", true) or visual.PrimaryPart
    if vHead then
        local bi = Instance.new("BillboardGui")
        bi.Name = "VIS_LOCAL_CHAT"
        bi.Adornee = vHead
        bi.Size = UDim2.new(0,200,0,40)
        bi.StudsOffset = Vector3.new(0, (bboxSize.Y/2) + 0.5, 0)
        bi.AlwaysOnTop = true
        local tl = Instance.new("TextLabel", bi)
        tl.Size = UDim2.new(1,0,1,0)
        tl.BackgroundTransparency = 1
        tl.TextScaled = true
        tl.Text = ""
        tl.Visible = false
        bi.Parent = visual
        -- show local chat messages
        lp.Chatted:Connect(function(msg)
            pcall(function()
                tl.Text = msg
                tl.Visible = true
                delay(3, function() if tl and tl.Parent then tl.Visible = false end end)
            end)
        end)
    end

    -- load animations
    idleTrack = safeLoadAnimation(animator, IDLE_ID)
    walkTrack = safeLoadAnimation(animator, WALK_ID)
    if idleTrack then pcall(function() idleTrack.Looped = true; idleTrack:Play() end) end

    -- hide original local body
    if realChar then setLocalVisibility(realChar, false) end

    -- tools handling
    local function bindTool(tool)
        if not tool then return end
        toolConns[tool] = tool.Equipped:Connect(function()
            pcall(function() createToolVisual(tool) end)
        end)
        toolConns[tool.Name .. "_uneq"] = tool.Unequipped:Connect(function()
            pcall(function() local inst = spawnedToolVisuals[tool]; if inst and inst.Parent then inst:Destroy() end; spawnedToolVisuals[tool] = nil end)
        end)
    end

    local backpack = lp:FindFirstChildOfClass("Backpack")
    if backpack then
        for _,it in ipairs(backpack:GetChildren()) do if it:IsA("Tool") then bindTool(it) end end
        backpack.ChildAdded:Connect(function(c) if c:IsA("Tool") then bindTool(c) end end)
    end
    if lp.Character then
        for _,it in ipairs(lp.Character:GetChildren()) do if it:IsA("Tool") then bindTool(it) end end
    end
    lp.CharacterAdded:Connect(function(ch)
        for _,it in ipairs(ch:GetChildren()) do if it:IsA("Tool") then bindTool(it) end
    end)

    -- RenderStepped only toggles visibility for FP/TP; movement handled by Align
    if followConn then followConn:Disconnect() end
    followConn = RunService.RenderStepped:Connect(function()
        if not visual or not visual.Parent then return end
        if not lp.Character then return end
        local fp = isFirstPerson()
        if fp then
            for _,p in ipairs(visual:GetDescendants()) do if p:IsA("BasePart") then p.LocalTransparencyModifier = 1 end end
            setLocalVisibility(lp.Character, true)
            for t,inst in pairs(spawnedToolVisuals) do pcall(function() for _,pp in ipairs(inst:GetDescendants()) do if pp:IsA("BasePart") then pp.LocalTransparencyModifier = 1 end end end) end
        else
            for _,p in ipairs(visual:GetDescendants()) do if p:IsA("BasePart") then p.LocalTransparencyModifier = 0 end end
            setLocalVisibility(lp.Character, false)
            for t,inst in pairs(spawnedToolVisuals) do pcall(function() for _,pp in ipairs(inst:GetDescendants()) do if pp:IsA("BasePart") then pp.LocalTransparencyModifier = 0 end end end) end
        end
    end)

    return visual
end

-- cleanup and revert
local function cleanup()
    if followConn then pcall(function() followConn:Disconnect() end) followConn = nil end
    for k,v in pairs(spawnedToolVisuals) do pcall(function() if v and v.Parent then v:Destroy() end end) end
    spawnedToolVisuals = {}
    for k,c in pairs(toolConns) do if c and type(c.Disconnect) == "function" then pcall(function() c:Disconnect() end) end end
    toolConns = {}
    if hrpAttach and hrpAttach.Parent then pcall(function() hrpAttach:Destroy() end) end
    if primAttach and primAttach.Parent then pcall(function() primAttach:Destroy() end) end
    if alignPos then pcall(function() alignPos:Destroy() end) end
    if alignOri then pcall(function() alignOri:Destroy() end) end
    if visual and visual.Parent then pcall(function() visual:Destroy() end) end
    visual = nil; visualHum=nil; animator=nil; idleTrack=nil; walkTrack=nil
    setLocalVisibility(lp.Character, true)
end

function revertMorph()
    cleanup()
    print("revertMorph() executed")
end
_G.revertMorph = revertMorph

-- run
local ok, err = pcall(function()
    template = workspace:FindFirstChild(MODEL_NAME) or (function()
        for _,m in ipairs(workspace:GetChildren()) do if m:IsA("Model") and string.find(string.lower(m.Name or ""), string.lower(MODEL_NAME)) then return m end end
        return nil
    end)()
    if not template then error("Template not found: "..tostring(MODEL_NAME)) end
    local v = createVisual()
    if not v then error("createVisual returned nil") end
    print("Local visual spawned:", v:GetFullName(), "MANUAL_Y_OFFSET:", MANUAL_Y_OFFSET)
end)
if not ok then
    warn("Morph init error:", err)
end
