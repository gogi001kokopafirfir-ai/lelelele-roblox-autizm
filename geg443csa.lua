-- visual-deer-morph-fixed7.lua  (client / injector) — use AnimationController to avoid Humanoid physics conflict
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local lp = Players.LocalPlayer
if not lp then warn("No LocalPlayer") return end

-- SETTINGS
local TEMPLATE_NAME = "Deer"
local IDLE_ID = "rbxassetid://138304500572165"
local WALK_ID = "rbxassetid://78826693826761"
local VISUAL_NAME = "LOCAL_DEER_VISUAL"
local LERP_ALPHA = 0.45        -- 0..1, 1 = instant
local FP_HIDE_DISTANCE = 0.6
local HIP_MANUAL_OFFSET = nil  -- set number to force, otherwise auto-calc

-- internals
local template = workspace:FindFirstChild(TEMPLATE_NAME)
if not template then warn("Deer template not found in workspace ("..tostring(TEMPLATE_NAME)..")") return end

local visual, animController, animator, idleTrack, walkTrack
local followConn
local connections = {}        -- list of all connections to cleanup
local toolConns = {}         -- tool -> { equip = conn, unequip = conn }
local childAddedConns = {}   -- container -> conn

local cam = workspace.CurrentCamera

local function addConn(conn)
    if conn then table.insert(connections, conn) end
end
local function disconnectAll()
    for _,c in ipairs(connections) do
        pcall(function() c:Disconnect() end)
    end
    connections = {}
end

local function setLocalVisibility(model, visible)
    if not model then return end
    for _, v in ipairs(model:GetDescendants()) do
        if v:IsA("BasePart") then
            pcall(function()
                v.LocalTransparencyModifier = visible and 0 or 1
                v.CanCollide = false  -- keep visual parts non-collidable
                -- make visual parts massless to reduce physics jitter
                if v:IsA("BasePart") and v.Massless ~= nil then
                    v.Massless = true
                end
            end)
        end
    end
end

local function isFirstPerson()
    local char = lp.Character
    local head = char and char:FindFirstChild("Head")
    if not head or not cam then return false end
    return (cam.CFrame.Position - head.Position).Magnitude < FP_HIDE_DISTANCE
end

local function loadTrack(animatorObj, id, looped)
    if not animatorObj or not id then return nil end
    local anim = Instance.new("Animation")
    anim.Name = "visual_anim"
    anim.AnimationId = id
    anim.Parent = animatorObj
    local ok, track = pcall(function() return animatorObj:LoadAnimation(anim) end)
    if not ok or not track then
        warn("[visual] LoadAnimation failed:", id, track)
        pcall(function() anim:Destroy() end)
        return nil
    end
    track.Looped = looped and true or false
    track.Priority = Enum.AnimationPriority.Movement
    return track
end

local function cleanupTools()
    for tool, tbl in pairs(toolConns) do
        if tbl.equip then pcall(function() tbl.equip:Disconnect() end) end
        if tbl.unequip then pcall(function() tbl.unequip:Disconnect() end) end
        toolConns[tool] = nil
    end
    for container, conn in pairs(childAddedConns) do
        pcall(function() conn:Disconnect() end)
        childAddedConns[container] = nil
    end
end

local function bindTools(container)
    if not container then return end
    for _, t in ipairs(container:GetChildren()) do
        if t:IsA("Tool") and not toolConns[t] then
            toolConns[t] = {}
            toolConns[t].equip = t.Equipped:Connect(function()
                setLocalVisibility(t, false)
            end)
            toolConns[t].unequip = t.Unequipped:Connect(function()
                setLocalVisibility(t, true)
            end)
            addConn(toolConns[t].equip); addConn(toolConns[t].unequip)
        end
    end
    if not childAddedConns[container] then
        childAddedConns[container] = container.ChildAdded:Connect(function(child)
            if child:IsA("Tool") and not toolConns[child] then
                toolConns[child] = {}
                toolConns[child].equip = child.Equipped:Connect(function() setLocalVisibility(child, false) end)
                toolConns[child].unequip = child.Unequipped:Connect(function() setLocalVisibility(child, true) end)
                addConn(toolConns[child].equip); addConn(toolConns[child].unequip)
            end
        end)
        addConn(childAddedConns[container])
    end
end

local function createVisual()
    if visual then return end

    local ok, clone = pcall(function() return template:Clone() end)
    if not ok or not clone then warn("[visual] clone failed:", clone) return end
    clone.Name = VISUAL_NAME

    -- sanitize clone: remove Scripts/ModuleScripts and Humanoid (only in clone)
    for _, d in ipairs(clone:GetDescendants()) do
        if d:IsA("Script") or d:IsA("ModuleScript") or d:IsA("Humanoid") then
            pcall(function() d:Destroy() end)
        end
        if d:IsA("BasePart") then
            pcall(function()
                d.CanCollide = false
                d.Anchored = false
                if d.Massless ~= nil then d.Massless = true end
            end)
        end
    end

    local prim = clone:FindFirstChild("HumanoidRootPart") or clone:FindFirstChildWhichIsA("BasePart", true)
    if prim then clone.PrimaryPart = prim end

    clone.Parent = workspace
    visual = clone

    -- IMPORTANT: use AnimationController (no Humanoid) to avoid physics control conflicts
    animController = Instance.new("AnimationController")
    animController.Name = "LocalVisualAnimController"
    animController.Parent = visual
    animator = Instance.new("Animator")
    animator.Parent = animController

    idleTrack = loadTrack(animator, IDLE_ID, true)
    walkTrack = loadTrack(animator, WALK_ID, true)
    if idleTrack then pcall(function() idleTrack:Play() end) end

    local char = lp.Character or lp.CharacterAdded:Wait()
    setLocalVisibility(char, false)

    -- compute hip offset auto or manual
    local successReal, realHeight = pcall(function() return char:GetExtentsSize().Y end)
    local successVisual, visualHeight = pcall(function() return visual:GetExtentsSize().Y end)
    local HIP_OFFSET = HIP_MANUAL_OFFSET
    if not HIP_OFFSET then
        if successReal and successVisual then
            HIP_OFFSET = (visualHeight - realHeight) / 2 - 3
        else
            HIP_OFFSET = 5.0
        end
    end
    if type(HIP_OFFSET) ~= "number" or math.abs(HIP_OFFSET) > 50 then HIP_OFFSET = 5.0 end
    print("[visual] HIP_OFFSET =", HIP_OFFSET)

    -- bind tools
    pcall(function() bindTools(lp:FindFirstChildOfClass("Backpack")) end)
    pcall(function() bindTools(char) end)
    addConn(lp.CharacterAdded:Connect(function(newChar)
        pcall(function() bindTools(newChar) end)
        pcall(function() setLocalVisibility(newChar, false) end)
    end))

    -- follow loop
    local hrp = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
    if not hrp then warn("[visual] No HRP on real char") end

    followConn = RunService.RenderStepped:Connect(function()
        if not visual or not visual.PrimaryPart or not hrp then return end
        local fp = isFirstPerson()
        if fp then
            setLocalVisibility(visual, false)
            setLocalVisibility(char, false)
        else
            setLocalVisibility(visual, true)
            setLocalVisibility(char, false)
        end
        local target = hrp.CFrame * CFrame.new(0, HIP_OFFSET, 0)
        local cur = visual.PrimaryPart.CFrame
        visual:SetPrimaryPartCFrame(cur:Lerp(target, math.clamp(LERP_ALPHA, 0, 1)))
    end)
    addConn(followConn)

    -- link real humanoid Running -> switch anims
    local realHum = char:FindFirstChildOfClass("Humanoid")
    if realHum and walkTrack then
        local runC = realHum.Running:Connect(function(speed)
            if speed > 0.5 then
                if idleTrack then pcall(function() idleTrack:Stop(0.12) end) end
                if walkTrack and not walkTrack.IsPlaying then pcall(function() walkTrack:Play() end) end
            else
                if walkTrack and walkTrack.IsPlaying then pcall(function() walkTrack:Stop(0.12) end) end
                if idleTrack and not idleTrack.IsPlaying then pcall(function() idleTrack:Play() end) end
            end
        end)
        addConn(runC)
    end

    print("[visual] created. Call revertVisual() to cleanup.")
end

local function revertVisual()
    -- disconnect everything
    disconnectAll()
    cleanupTools()

    if visual and visual.Parent then
        pcall(function() visual:Destroy() end)
    end
    visual, animController, animator, idleTrack, walkTrack = nil, nil, nil, nil, nil

    -- restore local visibility for real char
    local char = lp.Character
    if char then pcall(function() setLocalVisibility(char, true) end) end

    print("[visual] reverted.")
end

-- run
createVisual()
_G.revertVisual = revertVisual
