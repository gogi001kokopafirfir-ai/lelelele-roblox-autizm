-- fix-visual-follow-and-collisions.lua  (инжектор, локально)
-- Что делает: 1) возвращает CanCollide у реального чара (локально), 2) снимает Anchored у visual,
-- 3) добавляет Attachments + AlignPosition/AlignOrientation чтобы визуал стабильно следовал за HRP,
-- 4) (пере)запускает анимации через AnimationController->Animator если требуется.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local lp = Players.LocalPlayer
if not lp then warn("No LocalPlayer") return end

-- Имена (подкорректируй, если у тебя другие)
local VISUAL_NAMES = {"LOCAL_DEER_VISUAL", "Deer_LOCAL", "Deer"} -- попробует найти по этим именам
local IDLE_ID = "rbxassetid://138304500572165"
local WALK_ID = "rbxassetid://78826693826761"

-- параметры для Align
local ALIGN_MAX_FORCE = 1e6
local ALIGN_RESPONSIVENESS = 200
local ALIGN_MAX_VELOCITY = 1e6

-- helpers
local function findVisual()
    for _,n in ipairs(VISUAL_NAMES) do
        local v = workspace:FindFirstChild(n)
        if v and v:IsA("Model") then return v end
    end
    -- как fallback, попробуем найти Model, имя которого содержит 'Deer' и 'LOCAL'
    for _,m in ipairs(workspace:GetChildren()) do
        if m:IsA("Model") and tostring(m.Name):lower():find("deer") then
            return m
        end
    end
    return nil
end

local function restoreRealCollisions()
    local char = lp.Character
    if not char then return end
    for _,d in ipairs(char:GetDescendants()) do
        if d:IsA("BasePart") then
            pcall(function() d.CanCollide = true end)
        end
    end
    print("[fix] restored CanCollide=true on local character parts (client-side).")
end

local function unanchorVisualParts(model)
    for _,d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") then
            pcall(function()
                d.Anchored = false
                d.CanCollide = false -- keep visual non-collidable to avoid local blocking; you can set true if want collisions
                if d.Massless ~= nil then d.Massless = true end
            end)
        end
    end
    print("[fix] unanchored visual parts (Anchored=false).")
end

local function ensureAnimationController(model)
    if not model then return nil end
    local controller = model:FindFirstChildOfClass("AnimationController")
    if not controller then
        controller = Instance.new("AnimationController")
        controller.Name = "LocalVisualAnimController"
        controller.Parent = model
    end
    local animator = controller:FindFirstChildOfClass("Animator")
    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = controller
    end
    return controller, animator
end

local function safeLoadPlay(animator, id, looped)
    if not animator or not id then return nil end
    local a = Instance.new("Animation")
    a.AnimationId = id
    a.Parent = animator
    local ok, track = pcall(function() return animator:LoadAnimation(a) end)
    if not ok or not track then
        warn("[fix] LoadAnimation failed:", id, track)
        pcall(function() a:Destroy() end)
        return nil
    end
    track.Looped = looped and true or false
    track.Priority = Enum.AnimationPriority.Movement
    track:Play()
    return track
end

local function createAttachmentIfMissing(part, name)
    if not part or not part:IsA("BasePart") then return nil end
    local att = part:FindFirstChild(name)
    if att and att:IsA("Attachment") then return att end
    att = Instance.new("Attachment")
    att.Name = name
    att.Parent = part
    return att
end

local function createAligners(visualPrimary, targetPart)
    if not visualPrimary or not targetPart then return nil end
    -- clean old
    if visualPrimary:FindFirstChild("__VIS_AP") then visualPrimary.__VIS_AP:Destroy() end
    if visualPrimary:FindFirstChild("__VIS_AO") then visualPrimary.__VIS_AO:Destroy() end
    -- create attachments
    local attA = createAttachmentIfMissing(visualPrimary, "__VIS_attA")
    local attB = createAttachmentIfMissing(targetPart, "__VIS_attB")
    -- AlignPosition
    local ap = Instance.new("AlignPosition")
    ap.Name = "__VIS_AP"
    ap.MaxForce = ALIGN_MAX_FORCE
    ap.MaxVelocity = ALIGN_MAX_VELOCITY
    ap.Responsiveness = ALIGN_RESPONSIVENESS
    ap.ReactionForceEnabled = true
    ap.Attachment0 = attA
    ap.Attachment1 = attB
    ap.Parent = visualPrimary
    -- AlignOrientation
    local ao = Instance.new("AlignOrientation")
    ao.Name = "__VIS_AO"
    ao.MaxTorque = ALIGN_MAX_FORCE
    ao.Responsiveness = ALIGN_RESPONSIVENESS
    ao.Attachment0 = attA
    ao.Attachment1 = attB
    ao.Parent = visualPrimary

    print("[fix] created AlignPosition/AlignOrientation between visual.PrimaryPart and HRP.")
    return ap, ao
end

-- main
local visual = findVisual()
if not visual then
    warn("[fix] visual model not found (looked for LOCAL_DEER_VISUAL / Deer_LOCAL / Deer).")
    return
end

local char = lp.Character
if not char then warn("[fix] player character not found") return end
local hrp = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart
if not hrp then warn("[fix] player HRP/PrimaryPart not found") return end

-- 1) restore collisions on real character (client-side) so you stop passing through
restoreRealCollisions()

-- 2) unanchor visual parts so animations can affect them
unanchorVisualParts(visual)

-- 3) ensure animation controller & (re)start animations if needed
local controller, animator = ensureAnimationController(visual)
local idleTrack, walkTrack
if animator then
    idleTrack = safeLoadPlay(animator, IDLE_ID, true)
    walkTrack = safeLoadPlay(animator, WALK_ID, true)
    print("[fix] animator ensured; idle/walk tracks tried to play.")
end

-- 4) create Aligners so visual follows HRP but still animates
local prim = visual.PrimaryPart or visual:FindFirstChildWhichIsA("BasePart", true)
if not prim then warn("[fix] visual has no PrimaryPart or basepart") end
local ap, ao = createAligners(prim, hrp)

-- 5) tweak Align parameters on the fly for stability
if ap then
    -- stronger follow, less lag
    ap.MaxForce = 1e7
    ap.Responsiveness = 250
end
if ao then
    ao.MaxTorque = 1e7
    ao.Responsiveness = 250
end

print("[fix] fix applied. Visual:", visual:GetFullName(), "HRP:", hrp:GetFullName())
print("[fix] If animations still not visible: check animator/tracks exist. If you still pass through, call revert() from your old script or restart the client.")

-- Optional: a small monitor print to check positions for debugging (disabled by default)
-- RunService.RenderStepped:Connect(function()
--     if prim and hrp then
--         print("Y prim:", prim.Position.Y, "hrpY:", hrp.Position.Y)
--     end
-- end)
