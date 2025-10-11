-- attach-tool-via-inventory.lua  (локальный, краткий)
-- Минимум: когда игра экипует предмет (EquipItemHandle), клонируем ToolHandle и привязываем к LOCAL_DEER_VISUAL

local Players = game:GetService("Players")
local lp = Players.LocalPlayer
if not lp then return end

-- require client module (игра уже использует его)
local ok, Client = pcall(function() return require(lp.PlayerScripts:WaitForChild("Client")) end)
if not ok or not Client or not Client.Events then
    warn("[attach] не удалось require Client module")
    Client = nil
end

local VISUAL_NAME = "LOCAL_DEER_VISUAL"    -- имя визуала
local HAND_OFFSET = CFrame.new(0, -0.15, -0.5)  -- подгоняй при необходимости
local myClone = nil

local function findVisualTarget()
    local visual = workspace:FindFirstChild(VISUAL_NAME)
    if not visual then return nil end
    -- попробуем найти attachment / руку
    local att = visual:FindFirstChild("RightGripAttachment", true) or visual:FindFirstChild("RightHandAttachment", true)
    if att and att.Parent and att.Parent:IsA("BasePart") then
        return att.Parent, att
    end
    return visual:FindFirstChild("HumanoidRootPart") or visual.PrimaryPart, nil
end

local function cloneAndAttachToolHandle(originalHandleFolder)
    if not originalHandleFolder then return end
    local visualTarget, visualAttachment = findVisualTarget()
    if not visualTarget then return end

    -- сначала очистим прошлый клон
    if myClone and myClone.Parent then
        pcall(function() myClone:Destroy() end)
        myClone = nil
    end

    -- клонируем весь ToolHandle (модель/папку)
    local ok, cloned = pcall(function() return originalHandleFolder:Clone() end)
    if not ok or not cloned then return end
    cloned.Name = "LOCAL_TOOL_HANDLE_CLONE"
    -- sanitize: выключаем скрипты и коллизии, делаем видимым
    for _, v in ipairs(cloned:GetDescendants()) do
        if v:IsA("BasePart") then
            pcall(function()
                v.CanCollide = false
                v.LocalTransparencyModifier = 0
                v.Transparency = 0
                if v.Massless ~= nil then v.Massless = true end
            end)
        elseif v:IsA("Script") or v:IsA("LocalScript") or v:IsA("ModuleScript") then
            pcall(function() v:Destroy() end)
        end
    end

    -- parent to visual (so it moves with player & easy cleanup)
    cloned.Parent = workspace -- parent ставим в workspace, затем привяжем к visualTarget
    -- определяем первичную часть
    local prim = cloned.PrimaryPart or cloned:FindFirstChildWhichIsA("BasePart", true)
    if not prim then
        cloned:Destroy()
        return
    end

    -- позиционируем и weld
    local base = visualTarget.CFrame
    if visualAttachment and visualAttachment:IsA("Attachment") then
        base = visualTarget.CFrame * visualAttachment.CFrame
    end
    pcall(function() cloned:SetPrimaryPartCFrame(base * HAND_OFFSET) end)

    local weld = Instance.new("WeldConstraint")
    weld.Part0 = prim
    weld.Part1 = visualTarget
    weld.Parent = prim

    myClone = cloned
    print("[attach] tool clone attached to visual")
end

local function tryFindToolHandleForLocalPlayer()
    -- game-specific paths you observed: workspace.<playername>.ToolHandle
    local folderParent = workspace:FindFirstChild(lp.Name)
    if folderParent then
        local th = folderParent:FindFirstChild("ToolHandle")
        if th then return th end
    end
    -- fallback: check character
    if lp.Character then
        local th2 = lp.Character:FindFirstChild("ToolHandle")
        if th2 then return th2 end
    end
    -- fallback: any ToolHandle in workspace that has OriginalItem pointing to an item in inventory
    for _,inst in ipairs(workspace:GetDescendants()) do
        if inst.Name == "ToolHandle" and inst:IsA("Model") then
            local ov = inst:FindFirstChild("OriginalItem")
            if ov and ov.Value and ov.Value.Parent == lp:FindFirstChild("Inventory") then
                return inst
            end
        end
    end
    return nil
end

-- Если есть клиентский модуль — подпишемся на его события
if Client and Client.Events and Client.Events.EquipItemHandle then
    Client.Events.EquipItemHandle:Connect(function(playerArg, itemArg)
        -- Аргументы: (player, item) — проверяем, наш ли игрок
        if playerArg ~= lp and playerArg ~= lp and playerArg.UserId ~= lp.UserId then
            return
        end
        -- небольшая задержка, чтобы игра успела собрать ToolHandle
        task.delay(0.06, function()
            local th = tryFindToolHandleForLocalPlayer()
            if th then
                cloneAndAttachToolHandle(th)
            end
        end)
    end)

    Client.Events.UnequipItemHandle:Connect(function(playerArg, itemArg)
        if playerArg ~= lp and (not playerArg.UserId or playerArg.UserId ~= lp.UserId) then return end
        -- удаляем локальную копию при снятии
        if myClone and myClone.Parent then pcall(function() myClone:Destroy() end) end
        myClone = nil
    end)
else
    -- fallback: если не удалось require Client, просто следим за появлением ToolHandle в workspace.<playerName>
    workspace.DescendantAdded:Connect(function(inst)
        if inst.Name == "ToolHandle" then
            -- если нашли ToolHandle для нашего игрока — attach
            task.delay(0.06, function()
                local th = tryFindToolHandleForLocalPlayer()
                if th then cloneAndAttachToolHandle(th) end
            end)
        end
    end)
    -- и слушаем их удаление/ун экип
    workspace.DescendantRemoving:Connect(function(inst)
        if inst.Name == "ToolHandle" and myClone and myClone.Parent then
            pcall(function() myClone:Destroy() end)
            myClone = nil
        end
    end)
end

print("[attach] ready — will clone ToolHandle to LOCAL_DEER_VISUAL on equip")
