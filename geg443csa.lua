-- morph-diagnostic-play.lua
-- Диагностика: проверяет Motor6D, снимает Anchored с моторизированных частей и пытается проиграть анимацию.
-- Вставь в инжектор и запусти. Скопируй вывод из Output сюда.

local VISUAL_NAMES = {"LOCAL_VISUAL_DEER", "LocalVisual_Deer", "Deer", "LOCAL_VISUAL"} -- варианты
local IDLE_ID = "rbxassetid://138304500572165" -- твой idle
local WALK_ID = "rbxassetid://78826693826761" -- твой walk

local function findVisual()
    for _,n in ipairs(VISUAL_NAMES) do
        local m = workspace:FindFirstChild(n)
        if m and m:IsA("Model") then return m end
    end
    -- fallback: найти модель, у которой в имени 'deer'
    for _,m in ipairs(workspace:GetChildren()) do
        if m:IsA("Model") and string.find(string.lower(m.Name), "deer") then return m end
    end
    return nil
end

local visual = findVisual()
if not visual then
    warn("[diag] visual model not found. Add name to VISUAL_NAMES or ensure visual exists in workspace.")
    return
end

print("[diag] visual found:", visual:GetFullName())

-- 1) Собираем Motor6D
local motors = {}
for _,v in ipairs(visual:GetDescendants()) do
    if v:IsA("Motor6D") then
        table.insert(motors, v)
    end
end

print(string.format("[diag] Motor6D count = %d", #motors))
if #motors > 0 then
    for i,m in ipairs(motors) do
        local p0 = m.Part0 and m.Part0:GetFullName() or "nil"
        local p1 = m.Part1 and m.Part1:GetFullName() or "nil"
        print(string.format("  %d) %s  -- Part0: %s  Part1: %s", i, m.Name, p0, p1))
    end
else
    print("[diag] Warning: no Motor6D found in visual. Это значит анимации не смогут двигать кости.")
end

-- 2) Проверка типа рига по именам частей (простая эвристика)
local function detectRig()
    local names = {}
    for _,p in ipairs(visual:GetDescendants()) do if p:IsA("BasePart") then names[p.Name] = true end end
    -- простая проверка
    if names["UpperTorso"] or names["LowerTorso"] or names["RightUpperArm"] then
        return "R15"
    elseif names["Torso"] or names["Right Arm"] or names["Left Leg"] then
        return "R6"
    else
        return "unknown"
    end
end

local rigType = detectRig()
print("[diag] Detected rig (heuristic):", rigType)

-- 3) Убираем Anchored у частей, которые контролируются Motor6D (локально)
local changed = 0
for _,m in ipairs(motors) do
    local p0, p1 = m.Part0, m.Part1
    for _,t in ipairs({p0, p1}) do
        if t and t:IsA("BasePart") then
            if t.Anchored then
                pcall(function() t.Anchored = false end)
                changed = changed + 1
            end
        end
    end
end
print("[diag] Removed Anchored from motorized parts (count changed):", changed)

-- 4) Ensure Animator + Humanoid present
local humanoid = visual:FindFirstChildOfClass("Humanoid")
if not humanoid then
    humanoid = Instance.new("Humanoid")
    humanoid.Name = "VisualHumanoid"
    humanoid.Parent = visual
    print("[diag] Created Visual Humanoid")
else
    print("[diag] Visual has Humanoid")
end

local animator = humanoid:FindFirstChildOfClass("Animator")
if not animator then
    animator = Instance.new("Animator")
    animator.Parent = humanoid
    print("[diag] Created Animator under VisualHumanoid")
else
    print("[diag] Animator exists")
end

-- helper load/play function with logging
local function tryPlay(animId, label)
    local anim = Instance.new("Animation")
    anim.AnimationId = animId
    anim.Parent = visual
    print("[diag] Trying to LoadAnimation for", label, animId)
    local ok, trackOrErr = pcall(function() return animator:LoadAnimation(anim) end)
    if not ok then
        warn("[diag] LoadAnimation pcall failed:", trackOrErr)
        return nil
    end
    local track = trackOrErr
    if not track then
        warn("[diag] animator:LoadAnimation returned nil for", animId)
        return nil
    end
    print("[diag] Loaded track:", track.Name, "Looped:", track.Looped, "Length (may be 0 until loaded):", track.Length)
    -- connect some signals
    track.Stopped:Connect(function() print("[diag] track stopped:", label) end)
    track.KeyframeReached:Connect(function(marker) print("[diag] KeyframeReached:", marker) end)
    -- play it
    local ok2, err2 = pcall(function() track:Play() end)
    if not ok2 then
        warn("[diag] track:Play failed:", err2)
        return nil
    end
    print("[diag] track.IsPlaying (after Play):", track.IsPlaying, "Weight:", track:GetStackPriority and track:GetStackPriority() or "n/a")
    return track
end

-- 5) Попробуем проиграть idle и walk по очереди (с таймаутом)
local idleTrack = tryPlay(IDLE_ID, "idle")
task.wait(0.6)
local walkTrack = tryPlay(WALK_ID, "walk")
task.wait(0.6)

print("[diag] After Play: idleTrack.IsPlaying:", idleTrack and idleTrack.IsPlaying or "nil", "walkTrack.IsPlaying:", walkTrack and walkTrack.IsPlaying or "nil")

-- 6) Простейший тест управления Motor6D: коротким циклом изменим C0 первого моторчика, чтобы увидеть движение
if #motors > 0 then
    local m = motors[1]
    local origC0 = m.C0
    print("[diag] Testing manual Motor6D movement on:", m.Name, "Part1:", m.Part1 and m.Part1.Name)
    -- small rotation test
    for i=1,6 do
        local a = (i%2==0) and 0.15 or -0.15
        pcall(function() m.C0 = origC0 * CFrame.Angles(a,0,0) end)
        task.wait(0.25)
    end
    pcall(function() m.C0 = origC0 end)
    print("[diag] Manual Motor6D test done")
else
    print("[diag] No motors to test manual movement")
end

print("[diag] DIAGNOSTIC COMPLETE. If animation still doesn't move the model, copy all above output and paste here.")
