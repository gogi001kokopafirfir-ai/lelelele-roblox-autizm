-- morph-fix-anim-patch.lua
-- Патч: разрешает работу анимаций и снижает дерганье.
local VISUAL_NAMES = {"LOCAL_VISUAL_DEER","LocalVisual_Deer","LocalVisual_Deer","Deer"}
local IDLE_ID = "rbxassetid://138304500572165"
local WALK_ID = "rbxassetid://78826693826761"

local RS = game:GetService("RunService")
local visual
for _,n in ipairs(VISUAL_NAMES) do
    local m = workspace:FindFirstChild(n)
    if m and m:IsA("Model") then visual = m; break end
end
if not visual then
    warn("[patch] visual model not found. Убедись, что визуал в workspace и назван как в VISUAL_NAMES.")
    return
end

print("[patch] applying animation fix to", visual:GetFullName())

-- 1) Найдём Motor6D и части которые они контролируют
local motorParts = {}
local motors = {}
for _,desc in ipairs(visual:GetDescendants()) do
    if desc:IsA("Motor6D") then
        table.insert(motors, desc)
        if desc.Part0 and desc.Part0:IsA("BasePart") then motorParts[desc.Part0] = true end
        if desc.Part1 and desc.Part1:IsA("BasePart") then motorParts[desc.Part1] = true end
    end
end
print("[patch] found Motor6D count:", #motors)

-- 2) Снимаем Anchored у моторных частей, ставим Anchored=true у остальных (чтобы минимизировать физику)
local touched = 0; local anchoredSet = 0
for _,part in ipairs(visual:GetDescendants()) do
    if part:IsA("BasePart") then
        if motorParts[part] then
            if part.Anchored then
                pcall(function() part.Anchored = false end)
                touched = touched + 1
            end
            pcall(function() part.CanCollide = false end)
        else
            -- для остальных частей можно оставить Anchored true, чтобы уменьшить физ. конфликты
            if not part.Anchored then
                pcall(function() part.Anchored = true end)
                anchoredSet = anchoredSet + 1
            end
            pcall(function() part.CanCollide = false end)
        end
    end
end
print(string.format("[patch] motor parts un-anchored: %d, non-motor anchored: %d", touched, anchoredSet))

-- 3) Перезапустим/создадим Humanoid + Animator у визуала и загрузим треки заново
local function ensureAnimatorOnVisual()
    local hum = visual:FindFirstChildOfClass("Humanoid")
    if not hum then
        hum = Instance.new("Humanoid")
        hum.Name = "VisualHumanoid"
        hum.Parent = visual
        print("[patch] created Visual Humanoid")
    end
    -- remove any stray AnimationController to avoid conflict
    local ac = visual:FindFirstChildOfClass("AnimationController")
    if ac then
        pcall(function() ac:Destroy() end)
    end
    local animator = hum:FindFirstChildOfClass("Animator")
    if animator then
        pcall(function() animator:Destroy() end)
    end
    animator = Instance.new("Animator")
    animator.Parent = hum
    return hum, animator
end

local hum, animator = ensureAnimatorOnVisual()

-- helper load track
local function loadTrack(animatorObj, animId)
    if not animatorObj or not animId then return nil end
    local anim = Instance.new("Animation")
    anim.AnimationId = animId
    anim.Parent = visual
    local ok, track = pcall(function() return animatorObj:LoadAnimation(anim) end)
    if not ok or not track then
        warn("[patch] LoadAnimation failed for", animId, track)
        pcall(function() anim:Destroy() end)
        return nil
    end
    track.Priority = Enum.AnimationPriority.Movement
    return track
end

-- stop existing tracks if any
pcall(function()
    for _,t in ipairs(hum:GetDescendants()) do
        if t:IsA("AnimationTrack") then
            pcall(function() t:Stop() end)
        end
    end
end)

local idleTrack = loadTrack(animator, IDLE_ID)
local walkTrack = loadTrack(animator, WALK_ID)
if idleTrack then pcall(function() idleTrack.Looped = true; idleTrack:Play() end) end
print("[patch] idleTrack loaded:", tostring(idleTrack), "walkTrack:", tostring(walkTrack))

-- 4) Плавное перемещение: будем использовать PivotTo вместо SetPrimaryPartCFrame и экспоненциальное сглаживание
--    для вертикальной позиции используем lastGroundY, обновляем реже чтобы не дергало
local hrp = (game.Players.LocalPlayer.Character and (game.Players.LocalPlayer.Character:FindFirstChild("HumanoidRootPart") or game.Players.LocalPlayer.Character.PrimaryPart))
if not hrp then hrp = game.Players.LocalPlayer.CharacterAdded:Wait():WaitForChild("HumanoidRootPart", 3) end
if not hrp then warn("[patch] HRP not found for LocalPlayer"); end

local lastGroundY = hrp and hrp.Position.Y or 0
local baseOffset = visual.PrimaryPart and (visual.PrimaryPart.Position.Y - (function() local minY=math.huge; for _,p in ipairs(visual:GetDescendants()) do if p:IsA("BasePart") then minY = math.min(minY, p.Position.Y - p.Size.Y/2) end end; if minY==math.huge then return 0 else return minY end end)()) or 0
local smoothGroundY = lastGroundY + baseOffset

local function expAlpha(speed, dt)
    if dt <= 0 then return 1 end
    return 1 - math.exp(-speed * dt)
end

local FOLLOW_SPEED = 14
local VERT_SPEED = 6
local PREFERRED_DT = 1/60

local lastTime = tick()
local conn
conn = RS.Heartbeat:Connect(function(dt)
    local ok, err = pcall(function()
        if not visual or not visual.PrimaryPart or not hrp then return end
        -- update ground Y less frequently
        lastGroundY = (function()
            local rayParams = RaycastParams.new()
            rayParams.FilterType = Enum.RaycastFilterType.Blacklist
            rayParams.FilterDescendantsInstances = {game.Players.LocalPlayer.Character}
            local res = workspace:Raycast(hrp.Position + Vector3.new(0,0.5,0), Vector3.new(0,-400,0), rayParams)
            if res and res.Position then return res.Position.Y else return hrp.Position.Y - 2 end
        end)()
        local targetPrimaryY = lastGroundY + baseOffset
        local a_v = expAlpha(VERT_SPEED, dt)
        smoothGroundY = smoothGroundY + (targetPrimaryY - smoothGroundY) * a_v

        -- yaw
        local _, yaw, _ = hrp.CFrame:ToOrientation()
        if type(yaw) ~= "number" then yaw = 0 end

        local targetPos = Vector3.new(hrp.Position.X, smoothGroundY, hrp.Position.Z)
        local targetC = CFrame.new(targetPos) * CFrame.Angles(0, yaw, 0)

        -- smooth interp towards target using exp alpha
        local a = expAlpha(FOLLOW_SPEED, dt)
        local newC = visual.PrimaryPart.CFrame:Lerp(targetC, a)
        -- use PivotTo for smoother movement
        pcall(function() visual:PivotTo(newC) end)
    end)
    if not ok then
        warn("[patch] follow pcall failed:", err)
    end
end)

-- 5) ensure animations will switch on player Running
local realHum = game.Players.LocalPlayer.Character and game.Players.LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
if realHum and walkTrack then
    realHum.Running:Connect(function(speed)
        if speed and speed > 0.5 then
            pcall(function() if idleTrack and idleTrack.IsPlaying then idleTrack:Stop(0.12) end end)
            pcall(function() if walkTrack and not walkTrack.IsPlaying then walkTrack:Play() end end)
        else
            pcall(function() if walkTrack and walkTrack.IsPlaying then walkTrack:Stop(0.12) end end)
            pcall(function() if idleTrack and not idleTrack.IsPlaying then idleTrack:Play() end end)
        end
    end)
end

print("[patch] patch applied. If animation не начались — перезапусти визуал и/или пришли вывод следующих строк:")
print(" - idleTrack:", tostring(idleTrack), " walkTrack:", tostring(walkTrack))
print(" - попробуй встать и походить, скопируй в Output любые 'LoadAnimation failed' или предупреждения.")
