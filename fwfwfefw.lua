-- attach-tool-to-deer-simple.lua  (локальный, инжектор)
-- Минимальный: ловим ToolHandle именно для локального игрока и один раз клонируем + weld к LOCAL_DEER_VISUAL

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local lp = Players.LocalPlayer
if not lp then return end

local VISUAL_NAME = "LOCAL_DEER_VISUAL"    -- имя визуала
local HAND_OFFSET = CFrame.new(0, -0.15, -0.5) -- подгоняй при необходимости
local TRY_ATTEMPTS = 8
local TRY_DELAY = 0.06
local MIN_VOLUME = 0.0001 -- минимальный объём, чтобы считать деталь "реальной"

local visual = Workspace:FindFirstChild(VISUAL_NAME)
if not visual then warn("[attach-simple] visual not found:", VISUAL_NAME) end

local activeClone = nil
local activeSource = nil
local attached = false

local function findTarget()
    if not visual then visual = Workspace:FindFirstChild(VISUAL_NAME) end
    if not visual then return nil, nil end
    local att = visual:FindFirstChild("RightGripAttachment", true) or visual:FindFirstChild("RightHandAttachment", true)
    if att and att.Parent and att.Parent:IsA("BasePart") then return att.Parent, att end
    return visual:FindFirstChild("HumanoidRootPart") or visual.PrimaryPart, nil
end

local function hasRenderablePart(folder)
    for _, d in ipairs(folder:GetDescendants()) do
        if d:IsA("BasePart") then
            local vol = d.Size.X * d.Size.Y * d.Size.Z
            if vol > MIN_VOLUME then return true end
            -- также считаем mesh как валидный признак
            local m = d:FindFirstChildWhichIsA("SpecialMesh", true)
            if m and ((m.MeshId and m.MeshId ~= "") or (m.TextureId and m.TextureId ~= "")) then return true end
            if d.Transparency and d.Transparency < 0.98 then return true end
        end
    end
    return false
end

local function cleanupClone()
    if activeClone and activeClone.Parent then
        pcall(function() activeClone:Destroy() end)
    end
    activeClone = nil
    activeSource = nil
    attached = false
end

local function attachCloneFrom(folder)
    if not folder or not folder.Parent then return false end
    if attached and activeSource == folder then return true end

    -- try detect renderable parts with small retries
    local ok = false
    for i=1, TRY_ATTEMPTS do
        if hasRenderablePart(folder) then ok = true; break end
        task.wait(TRY_DELAY)
    end
    if not ok then
        -- ничего рендерного не появилось — не будем клонировать
        -- но не удаляем: игра может позже заново создать ToolHandle, мы слушаем события
        print("[attach-simple] ToolHandle found but empty / not renderable (will ignore):", folder:GetFullName())
        return false
    end

    -- готово: клонируем и attach один раз
    cleanupClone()
    local okc, cloned = pcall(function() return folder:Clone() end)
    if not okc or not cloned then
        warn("[attach-simple] clone failed", cloned)
        return false
    end

    -- sanitize: убрать скрипты и сделать невидимый для физики
    for _, v in ipairs(cloned:GetDescendants()) do
        if v:IsA("Script") or v:IsA("LocalScript") or v:IsA("ModuleScript") then
            pcall(function() v:Destroy() end)
        elseif v:IsA("BasePart") then
            pcall(function()
                v.CanCollide = false
                v.LocalTransparencyModifier = 0
                v.Transparency = 0
                if v.Massless ~= nil then v.Massless = true end
            end)
        end
    end

    -- parent clone into workspace (or visual)
    cloned.Parent = Workspace

    -- set primary part
    local prim = cloned.PrimaryPart or cloned:FindFirstChildWhichIsA("BasePart", true)
    if not prim then
        warn("[attach-simple] cloned has no BasePart")
        pcall(function() cloned:Destroy() end)
        return false
    end

    -- position & weld
    local targetPart, targetAttachment = findTarget()
    if not targetPart then
        warn("[attach-simple] no targetPart in visual")
        pcall(function() cloned:Destroy() end)
        return false
    end

    local baseCFrame = targetPart.CFrame
    if targetAttachment and targetAttachment:IsA("Attachment") then baseCFrame = targetPart.CFrame * targetAttachment.CFrame end
    pcall(function() cloned:SetPrimaryPartCFrame(baseCFrame * HAND_OFFSET) end)

    local weld = Instance.new("WeldConstraint")
    weld.Part0 = prim
    weld.Part1 = targetPart
    weld.Parent = prim

    activeClone = cloned
    activeSource = folder
    attached = true

    print("[attach-simple] attached clone from:", folder:GetFullName())
    -- watch removal of source to cleanup
    local conn
    conn = folder.AncestryChanged:Connect(function(_, newParent)
        if not newParent then
            cleanupClone()
            if conn then conn:Disconnect() end
        end
    end)
    return true
end

-- primary watcher: ToolHandle inside workspace.<PlayerName> OR inside character
local function checkExistingHandleAndAttach()
    local container = Workspace:FindFirstChild(lp.Name)
    if container then
        local th = container:FindFirstChild("ToolHandle")
        if th and th.Parent then attachCloneFrom(th) end
    end
    if lp.Character then
        local th2 = lp.Character:FindFirstChild("ToolHandle")
        if th2 and th2.Parent then attachCloneFrom(th2) end
    end
end

-- listen for ToolHandle created anywhere but only process those that belong to this player (by parent name or proximity)
Workspace.DescendantAdded:Connect(function(obj)
    if not obj then return end
    if obj.Name ~= "ToolHandle" then return end
    -- quick ownership check: parent name == player name OR inside player's character
    local par = obj.Parent
    if par and (par == lp.Character or par.Name == lp.Name or par:IsDescendantOf(lp.Character)) then
        -- schedule attach attempt (non-blocking)
        task.defer(function() attachCloneFrom(obj) end)
    end
end)

-- also check immediately if already present
task.defer(checkExistingHandleAndAttach)

print("[attach-simple] ready — watching ToolHandle for player:", lp.Name)
