-- morph-deep-diagnostic.lua
-- Поставь в инжектор и запуusti. Скопируй весь Output сюда.

local VISUAL_NAMES = {"LOCAL_VISUAL_DEER","LocalVisual_Deer","LOCAL_VISUAL","Deer"} -- варианты
local IDLE_ID = "rbxassetid://138304500572165"
local WALK_ID = "rbxassetid://78826693826761"

local function findVisual()
    for _,n in ipairs(VISUAL_NAMES) do
        local m = workspace:FindFirstChild(n)
        if m and m:IsA("Model") then return m end
    end
    for _,m in ipairs(workspace:GetChildren()) do
        if m:IsA("Model") and string.find(string.lower(m.Name or ""), "deer") then return m end
    end
    return nil
end

local visual = findVisual()
if not visual then
    warn("[diag] Visual model not found. Название в VISUAL_NAMES неверно или визуал не в workspace.")
    return
end

print("[diag] Visual found:", visual:GetFullName())

-- Motor6D list
local motors = {}
for _,v in ipairs(visual:GetDescendants()) do
    if v:IsA("Motor6D") then table.insert(motors, v) end
end
print("[diag] Motor6D count:", #motors)
for i,m in ipairs(motors) do
    print(string.format("  %d) %s  Part0=%s  Part1=%s", i, m.Name, (m.Part0 and m.Part0.Name or "nil"), (m.Part1 and m.Part1.Name or "nil")))
end

-- Detect rig by part names
local function detectRig()
    local names = {}
    for _,p in ipairs(visual:GetDescendants()) do if p:IsA("BasePart") then names[p.Name] = true end end
    if names["UpperTorso"] or names["LowerTorso"] or names["RightUpperArm"] then return "R15" end
    if names["Torso"] or names["Right Arm"] or names["Left Leg"] then return "R6" end
    return "unknown"
end
local rig = detectRig()
print("[diag] Detected rig:", rig)

-- Ensure parts that Motors control are not anchored (so animation can move them)
local changed = 0
for _,m in ipairs(motors) do
    for _,p in ipairs({m.Part0, m.Part1}) do
        if p and p:IsA("BasePart") and p.Anchored then
            pcall(function() p.Anchored = false end)
            changed = changed + 1
        end
    end
end
print("[diag] Un-anchored motorized parts count:", changed)

-- Ensure we have a Humanoid + Animator
local humanoid = visual:FindFirstChildOfClass("Humanoid")
if not humanoid then
    humanoid = Instance.new("Humanoid")
    humanoid.Name = "DiagHumanoid"
    humanoid.Parent = visual
    print("[diag] Created Humanoid in visual")
else
    print("[diag] Visual already has Humanoid")
end

local animator = humanoid:FindFirstChildOfClass("Animator")
if not animator then
    animator = Instance.new("Animator")
    animator.Parent = humanoid
    print("[diag] Created Animator under Humanoid")
else
    print("[diag] Animator exists under Humanoid")
end

-- Also try AnimationController route (some custom rigs expect it)
local controller = visual:FindFirstChildOfClass("AnimationController")
local ctrlAnimator = nil
if not controller then
    controller = Instance.new("AnimationController")
    controller.Name = "DiagAnimController"
    controller.Parent = visual
    ctrlAnimator = Instance.new("Animator"); ctrlAnimator.Parent = controller
    print("[diag] Created AnimationController + Animator")
else
    ctrlAnimator = controller:FindFirstChildOfClass("Animator") or (function() local a=Instance.new("Animator"); a.Parent=controller; return a end)()
    print("[diag] AnimationController exists")
end

local function tryLoadAndPlay(anId, who, animatorToUse)
    if not animatorToUse then print("[diag] no animator for", who); return nil end
    local a = Instance.new("Animation")
    a.AnimationId = anId
    a.Parent = visual
    print("[diag] Loading animation", anId, "via", who)
    local ok, track = pcall(function() return animatorToUse:LoadAnimation(a) end)
    if not ok then
        print("[diag] LoadAnimation pcall error for", who, track)
        return nil
    end
    if not track then
        print("[diag] animator:LoadAnimation returned nil for", who)
        return nil
    end
    print("[diag] -> Loaded track (name):", track.Name)
    -- attempt to play
    local ok2, err2 = pcall(function() track:Play() end)
    if not ok2 then print("[diag] track:Play failed:", err2); return nil end
    print("[diag] -> track.IsPlaying after Play:", track.IsPlaying)
    return track
end

-- try play via Humanoid.Animator
local trackA = tryLoadAndPlay(IDLE_ID, "Humanoid.Animator", animator)
task.wait(0.6)
local trackB = tryLoadAndPlay(WALK_ID, "Humanoid.Animator", animator)
task.wait(0.6)

-- try play via AnimationController.Animator
local trackC = tryLoadAndPlay(IDLE_ID, "AnimationController.Animator", ctrlAnimator)
task.wait(0.6)
local trackD = tryLoadAndPlay(WALK_ID, "AnimationController.Animator", ctrlAnimator)
task.wait(0.6)

print("[diag] Status: Humanoid-tracks:", (trackA and trackA.IsPlaying) and "idle-playing" or tostring(trackA), (trackB and trackB.IsPlaying) and "walk-playing" or tostring(trackB))
print("[diag] Status: Controller-tracks:", (trackC and trackC.IsPlaying) and "idle-playing" or tostring(trackC), (trackD and trackD.IsPlaying) and "walk-playing" or tostring(trackD))

-- manual Motor6D test: rotate first motor small amount back/forth
if #motors > 0 then
    local m = motors[1]
    local orig = m.C0
    print("[diag] Manual motor test on:", m.Name, "Part1:", (m.Part1 and m.Part1.Name or "nil"))
    for i=1,6 do
        local ang = (i%2==0) and 0.25 or -0.25
        pcall(function() m.C0 = orig * CFrame.Angles(ang,0,0) end)
        task.wait(0.18)
    end
    pcall(function() m.C0 = orig end)
    print("[diag] Manual motor test done")
else
    print("[diag] No Motor6D found - model cannot be animated by standard humanoid animations")
end

print("[diag] DIAGNOSTIC FINISHED - paste all output here.")
