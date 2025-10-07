-- embed-morph.lua  (client)
-- Вставь в инжектор, запусти. Откат: run revertEmbedMorph() в клиентской консоли.

local VISUAL_NAME = "LOCAL_VISUAL_DEER" -- имя локального визуала в workspace
local PLAYER_OFFSET_Y = -1.2            -- начальный вертикальный оффсет (подбери: + вверх, - вниз)
local SMOOTH_TELEPORT = false           -- true = плавный переход (Lerp), false = мгновенно
local LERP_ALPHA = 0.55                 -- если плавно, скорость (0..1)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local lp = Players.LocalPlayer
if not lp then return end

local visual = workspace:FindFirstChild(VISUAL_NAME)
if not visual then warn("visual not found: "..VISUAL_NAME); return end
local prim = visual.PrimaryPart or visual:FindFirstChild("HumanoidRootPart", true)
if not prim then warn("visual has no PrimaryPart/HumanoidRootPart"); return end

-- state store for revert
local _state = {}
_state.origHRPCFrame = nil
_state.hiddenParts = {}
_state.followConn = nil

local function hidePlayerLocal(hide)
    local ch = lp.Character
    if not ch then return end
    for _,p in ipairs(ch:GetDescendants()) do
        if p:IsA("BasePart") then
            p.LocalTransparencyModifier = (hide and 1 or 0)
            if hide then _state.hiddenParts[p] = true end
        end
    end
end

local function teleportPlayerIntoVisual()
    local ch = lp.Character
    if not ch then return end
    local hrp = ch:FindFirstChild("HumanoidRootPart") or ch.PrimaryPart
    if not hrp then warn("No HRP"); return end

    -- save original
    if not _state.origHRPCFrame then _state.origHRPCFrame = hrp.CFrame end

    -- compute target position: visual PrimaryPart position + offset
    local target = prim.CFrame * CFrame.new(0, PLAYER_OFFSET_Y, 0)

    if not SMOOTH_TELEPORT then
        pcall(function() hrp.CFrame = target end)
    else
        -- плавный телепорт (короткий Lerp)
        local t0 = tick()
        local dur = 0.25
        while tick() - t0 < dur do
            local a = (tick() - t0) / dur
            local cf = hrp.CFrame:Lerp(target, a * LERP_ALPHA)
            pcall(function() hrp.CFrame = cf end)
            RunService.RenderStepped:Wait()
        end
        pcall(function() hrp.CFrame = target end)
    end

    -- прячем реальные части локально
    hidePlayerLocal(true)

    -- следим: если визуал двигается, пусть он уже продолжает следовать hrp (мы делали это раньше),
    -- но чтобы избежать "под ногами", после установки HRP внутри, визуал должен следовать hrp.
    -- Если у тебя уже есть follow loop, ничего не делаем. Иначе привяжем простой follow:
    if not _state.followConn then
        _state.followConn = RunService.RenderStepped:Connect(function()
            if not visual.PrimaryPart or not hrp then return end
            -- держим visual вокруг hrp (визуал уже настроен у тебя ранее)
            local targetC = hrp.CFrame * CFrame.new(0, 0, 0) -- можно тонко подкорректировать
            visual:SetPrimaryPartCFrame(targetC)
        end)
    end

    print("[embed] Teleported HRP into visual. Если надо поднять/опустить, измените PLAYER_OFFSET_Y и заново запустите скрипт.")
end

function revertEmbedMorph()
    -- restore HRP
    local ch = lp.Character
    if ch and _state.origHRPCFrame then
        local hrp = ch:FindFirstChild("HumanoidRootPart") or ch.PrimaryPart
        if hrp then pcall(function() hrp.CFrame = _state.origHRPCFrame end)
        end
    end
    -- restore visibility
    for p,_ in pairs(_state.hiddenParts) do
        pcall(function() p.LocalTransparencyModifier = 0 end)
    end
    _state.hiddenParts = {}
    if _state.followConn then _state.followConn:Disconnect(); _state.followConn = nil end
    print("[embed] reverted.")
end

-- run
teleportPlayerIntoVisual()
print("[embed] Done. Если Deer всё ещё стоит не там — открой скрипт и подбирай PLAYER_OFFSET_Y ( +/- 0.2 ).")
