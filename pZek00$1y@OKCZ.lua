--!strict
-- Midgard Mirror Keeper Travel System

export type Deps = {
    Players: Players,
    Workspace: Workspace,
    ReplicatedStorage: ReplicatedStorage,
    GetLocalPlayer: () -> Player,
    GetChar: () -> (Model?, BasePart?, Humanoid?),
    IsDeadOrRespawning: () -> boolean,
    GetData: () -> { [string]: any }?,
    GetMainModules: () -> { [string]: any }?,
    GetGameModules: () -> { [string]: any }?,
    GetPlayability: (name: string) -> Instance?,
    ResolveAreaName: ((name: string?) -> string?)?,
    ValuePosition: (val: any) -> Vector3?,
    GetInterestPoint: (key: string) -> any,
    GetNpcFrontCFrame: (npcName: string, fallbackPos: Vector3?, distFromNpc: number?) -> CFrame?,
    GetDialogueClient: () -> { [string]: any }?,
    FireNet: (remoteName: string, ...any) -> (boolean, string?),
    BeginInteract: ((abortFn: (() -> boolean)?, minWait: number?) -> boolean)?,
    WaitPostTeleport: (waitSec: number?, abortFn: (() -> boolean)?, statusMsg: string?) -> boolean,
    GetPostTeleportWait: () -> number,
    TweenTo: (cf: CFrame, abortFn: (() -> boolean)?) -> boolean,
    CancelTween: () -> (),
    SetStatus: (msg: string) -> (),
    LogDebug: (fileName: string, msg: string) -> (),
}

export type KeeperEntry = {
    Name: string,
    Position: Vector3,
    Island: string?,
}

export type TravelPlan = {
    TargetArea: Instance,
    TargetCenter: Vector3?,
    Price: number,
    Gold: number,
    KeeperName: string,
    KeeperPos: Vector3,
    KeeperDist: number,
    TotalDist: number,
    PostMirrorDist: number?,
}

local MirrorSystem = {}

local _deps: Deps? = nil
local _keeperCache: { KeeperEntry } = {}
local _keeperCacheAt = 0
local _failCooldownUntil: { [string]: number } = {}
local _lastSkipKey = ""
local _lastSkipAt = 0

local KEEPER_CACHE_TTL = 15
local MIN_TRAVEL_DISTANCE = 2600
local SAME_ISLAND_RADIUS = 2600
local SKY_ALTITUDE_THRESHOLD = 2500
local MIN_DISTANCE_SAVINGS = 800
local ARRIVAL_MIN_DELTA = 1200

local function logMirror(msg: string)
    if _deps and _deps.LogDebug then
        _deps.LogDebug("mirror_debug.txt", msg)
    end
end

local function logMirrorThrottled(key: string, msg: string)
    local now = os.clock()
    if key == _lastSkipKey and (now - _lastSkipAt) < 5 then
        return
    end
    _lastSkipKey, _lastSkipAt = key, now
    logMirror(msg)
end

local function xzDistance(a: Vector3, b: Vector3): number
    local dx = a.X - b.X
    local dz = a.Z - b.Z
    return math.sqrt(dx * dx + dz * dz)
end

local function setStatus(msg: string)
    if _deps and _deps.SetStatus then
        _deps.SetStatus(msg)
    end
end

function MirrorSystem.Init(deps: Deps)
    _deps = deps
    table.clear(_keeperCache)
    _keeperCacheAt = 0
    table.clear(_failCooldownUntil)
end

function MirrorSystem.ClearCache()
    table.clear(_keeperCache)
    _keeperCacheAt = 0
    table.clear(_failCooldownUntil)
end

local function rebuildKeeperCache(): { KeeperEntry }
    local deps = _deps
    if not deps then
        return _keeperCache
    end

    local entries: { KeeperEntry } = {}
    local seen: { [string]: boolean } = {}

    local function addEntry(name: string?, pos: Vector3?, island: string?)
        if not (name and pos) or name == "" then
            return
        end
        if seen[name] then
            return
        end
        seen[name] = true
        table.insert(entries, {
            Name = name,
            Position = pos,
            Island = island,
        })
    end

    local ign = deps.Workspace:FindFirstChild("IgnoreList")
    local intF = ign and ign:FindFirstChild("Int")
    local npcsF = intF and intF:FindFirstChild("NPCs")
    local shops = npcsF and npcsF:FindFirstChild("Shops")
    if shops then
        for _, grp in ipairs(shops:GetChildren()) do
            for _, npc in ipairs(grp:GetChildren()) do
                if npc:IsA("Model") and string.match(npc.Name, " Mirror Keeper$") then
                    local okPivot, pivot = pcall(npc.GetPivot, npc)
                    if okPivot and typeof(pivot) == "CFrame" then
                        local islAttr = npc:GetAttribute("Island")
                        addEntry(npc.Name, pivot.Position, type(islAttr) == "string" and islAttr or nil)
                    end
                end
            end
        end
    end

    local mainModules = deps.GetMainModules()
    local points = mainModules and mainModules.InterestPoints and mainModules.InterestPoints.Points
    if type(points) == "table" then
        for key, point in pairs(points) do
            if type(key) == "string" and string.match(key, "^Character_.* Mirror Keeper$") then
                local pos = deps.ValuePosition(point)
                if pos then
                    addEntry(string.sub(key, 11), pos, nil)
                end
            end
        end
    end

    local chars = deps.GetPlayability("Characters")
    if chars then
        for _, npc in ipairs(chars:GetChildren()) do
            local original = npc:GetAttribute("OriginalName") or npc.Name
            if npc:IsA("Model") and type(original) == "string" and string.match(original, " Mirror Keeper$") then
                local okPivot, pivot = pcall(npc.GetPivot, npc)
                if okPivot and typeof(pivot) == "CFrame" then
                    addEntry(original, pivot.Position, nil)
                end
            end
        end
    end

    _keeperCache = entries
    _keeperCacheAt = os.clock()
    return _keeperCache
end

local function getKeepers(forceRefresh: boolean?): { KeeperEntry }
    if forceRefresh or #_keeperCache == 0 or (os.clock() - _keeperCacheAt) >= KEEPER_CACHE_TTL then
        return rebuildKeeperCache()
    end
    return _keeperCache
end

function MirrorSystem.FindDestination(destPos: Vector3, targetIslandName: string?): Instance?
    local deps = _deps
    if not deps then
        return nil
    end
    local mainModules = deps.GetMainModules()
    local travelUtils = mainModules and mainModules.TravelUtils
    if not (travelUtils and typeof(destPos) == "Vector3") then
        return nil
    end

    local resolvedName = targetIslandName
    if resolvedName and deps.ResolveAreaName then
        local r = deps.ResolveAreaName(resolvedName)
        if r then
            resolvedName = r
        end
    end

    local targetArea: Instance? = nil
    if type(resolvedName) == "string" and resolvedName ~= "" then
        local okIsl, isl = pcall(travelUtils.GetIsland, resolvedName)
        if okIsl and isl then
            local tmc = isl:GetAttribute("MapCenter")
            if typeof(tmc) ~= "Vector3" or xzDistance(tmc, destPos) <= SAME_ISLAND_RADIUS then
                targetArea = isl
            end
        end
    end

    if not targetArea then
        local mapF = deps.Workspace:FindFirstChild("Map")
        local areasF = mapF and mapF:FindFirstChild("Areas")
        if areasF then
            local bestDiscD, bestDiscArea: Instance? = math.huge, nil
            local bestAnyD, bestAnyArea: Instance? = math.huge, nil
            local wantSky = destPos.Y > SKY_ALTITUDE_THRESHOLD

            for _, area in ipairs(areasF:GetChildren()) do
                local okDest, isDest = pcall(travelUtils.IsDestination, area)
                if okDest and isDest then
                    local alt = area:GetAttribute("MapAltitude")
                    local isSky = (type(alt) == "number" and alt or 0) > SKY_ALTITUDE_THRESHOLD
                    if isSky == wantSky then
                        local mc = area:GetAttribute("MapCenter")
                        if typeof(mc) == "Vector3" then
                            local d = xzDistance(mc, destPos)
                            local okDisc, isDisc = pcall(travelUtils.IsDiscovered, nil, area.Name)
                            if okDisc and isDisc and d < bestDiscD then
                                bestDiscD, bestDiscArea = d, area
                            end
                            if d < bestAnyD then
                                bestAnyD, bestAnyArea = d, area
                            end
                        end
                    end
                end
            end

            targetArea = bestDiscArea or bestAnyArea
        end
    end

    return targetArea
end

function MirrorSystem.GetPriceForPos(destPos: Vector3, targetIslandName: string?): number?
    local deps = _deps
    if not deps then
        return nil
    end
    local mainModules = deps.GetMainModules()
    local travelUtils = mainModules and mainModules.TravelUtils
    if not travelUtils then
        return nil
    end

    local targetArea = MirrorSystem.FindDestination(destPos, targetIslandName)
    if not targetArea then
        return nil
    end

    local okDisc, isDisc = pcall(travelUtils.IsDiscovered, nil, targetArea.Name)
    if not (okDisc and isDisc) then
        return nil
    end

    local okPrice, price = pcall(travelUtils.GetPrice, targetArea)
    return (okPrice and type(price) == "number") and price or nil
end

function MirrorSystem.FindKeeperNear(
    originPos: Vector3,
    maxDist: number?,
    preferredName: string?,
    horizontalOnly: boolean?
): (string?, Vector3?, number?)
    local deps = _deps
    if not (deps and typeof(originPos) == "Vector3") then
        return nil, nil, nil
    end

    local bestName: string? = nil
    local bestPos: Vector3? = nil
    local bestDist: number = maxDist or math.huge

    local function consider(name: string?, pos: Vector3?)
        if not (name and pos) then
            return
        end
        local dist = horizontalOnly and xzDistance(pos, originPos) or (pos - originPos).Magnitude
        if dist < bestDist then
            bestName, bestPos, bestDist = name, pos, dist
        end
    end

    if type(preferredName) == "string" and preferredName ~= "" then
        local pPos = deps.ValuePosition(deps.GetInterestPoint("Character_" .. preferredName))
        consider(preferredName, pPos)
        if bestName == preferredName then
            return bestName, bestPos, bestDist
        end
    end

    local mainModules = deps.GetMainModules()
    if mainModules and mainModules.TravelUtils and mainModules.TravelUtils.FindKeeper then
        local okK, keeper = pcall(mainModules.TravelUtils.FindKeeper, originPos)
        if okK and keeper then
            local okPivot, pivot = pcall(keeper.GetPivot, keeper)
            if okPivot and typeof(pivot) == "CFrame" then
                consider(keeper.Name, pivot.Position)
            end
        end
    end

    for _, entry in ipairs(getKeepers(false)) do
        consider(entry.Name, entry.Position)
    end

    if not bestName then
        for _, entry in ipairs(getKeepers(true)) do
            consider(entry.Name, entry.Position)
        end
    end

    return bestName, bestPos, bestName and bestDist or nil
end

function MirrorSystem.PlanTravel(destPos: Vector3, targetIslandName: string?): (TravelPlan?, string?)
    local deps = _deps
    if not deps then
        return nil, "not_initialized"
    end
    local mainModules = deps.GetMainModules()
    local travelUtils = mainModules and mainModules.TravelUtils
    if not travelUtils then
        logMirrorThrottled("no_travelutils", "SKIP: MainModules.TravelUtils indisponível")
        return nil, "no_travelutils"
    end
    if deps.IsDeadOrRespawning() then
        return nil, "dead_or_respawning"
    end

    local char, hrp = deps.GetChar()
    if not (char and hrp and typeof(destPos) == "Vector3") then
        logMirrorThrottled("no_char", "SKIP: sem char/hrp/destPos")
        return nil, "no_char"
    end

    local totalDist = (hrp.Position - destPos).Magnitude
    if totalDist < MIN_TRAVEL_DISTANCE then
        return nil, "too_close"
    end
    if char:GetAttribute("CarriedChest") ~= nil then
        logMirrorThrottled("carried_chest", "SKIP: CarriedChest ativo")
        return nil, "carried_chest"
    end
    if char:GetAttribute("BossTether") ~= nil or char:GetAttribute("BossArenaLock") ~= nil then
        logMirrorThrottled("boss_lock", "SKIP: BossTether/BossArenaLock ativo")
        return nil, "boss_lock"
    end
    if char:GetAttribute("InCombat") ~= nil then
        logMirrorThrottled("in_combat", "SKIP: InCombat ativo (ActionGate bloqueia Teleport)")
        return nil, "in_combat"
    end
    if char:GetAttribute("IslandTraveling") ~= nil then
        logMirrorThrottled("island_traveling", "SKIP: IslandTraveling já em andamento")
        return nil, "island_traveling"
    end

    local targetArea = MirrorSystem.FindDestination(destPos, targetIslandName)
    if not targetArea then
        logMirrorThrottled(
            "no_target:" .. tostring(targetIslandName),
            ("FAIL: targetArea nil (island=%s dest=(%.0f,%.0f,%.0f))"):format(
                tostring(targetIslandName),
                destPos.X,
                destPos.Y,
                destPos.Z
            )
        )
        return nil, "no_target"
    end

    local cdUntil = _failCooldownUntil[targetArea.Name]
    if cdUntil and os.clock() < cdUntil then
        return nil, "cooldown"
    end

    local targetCenter = targetArea:GetAttribute("MapCenter")
    local postMirrorDist: number? = nil
    if typeof(targetCenter) == "Vector3" then
        local curIslandDist = xzDistance(hrp.Position, targetCenter)
        local wantSky = destPos.Y > SKY_ALTITUDE_THRESHOLD
        local alt = targetArea:GetAttribute("MapAltitude")
        local isSky = (type(alt) == "number" and alt or 0) > SKY_ALTITUDE_THRESHOLD
        if curIslandDist <= SAME_ISLAND_RADIUS and wantSky == isSky then
            logMirrorThrottled(
                "same_island:" .. targetArea.Name,
                ("SKIP: já está na ilha %s (dist=%.0f)"):format(targetArea.Name, curIslandDist)
            )
            return nil, "same_island"
        end
        postMirrorDist = xzDistance(targetCenter, destPos)
        if postMirrorDist >= totalDist - MIN_DISTANCE_SAVINGS then
            logMirrorThrottled(
                "no_save:" .. targetArea.Name,
                ("SKIP: Mirror %s não economiza distância (atual=%.0f pós=%.0f)"):format(
                    targetArea.Name,
                    totalDist,
                    postMirrorDist
                )
            )
            return nil, "no_save"
        end
    end

    local okDisc, isDisc = pcall(travelUtils.IsDiscovered, nil, targetArea.Name)
    if not (okDisc and isDisc) then
        _failCooldownUntil[targetArea.Name] = os.clock() + 6
        logMirrorThrottled("undiscovered:" .. targetArea.Name, ("FAIL: ilha não descoberta (%s)"):format(targetArea.Name))
        return nil, "undiscovered"
    end

    local okPrice, price = pcall(travelUtils.GetPrice, targetArea)
    local data = deps.GetData()
    local gold = data and data.Monetization and data.Monetization.Gold
    if not okPrice or type(gold) ~= "number" or type(price) ~= "number" or gold < price then
        _failCooldownUntil[targetArea.Name] = os.clock() + 6
        logMirrorThrottled(
            "no_gold:" .. targetArea.Name,
            ("FAIL: gold insuficiente (%s < %s) para %s"):format(tostring(gold), tostring(price), targetArea.Name)
        )
        return nil, "no_gold"
    end

    local searchCap = math.min(totalDist * 0.75, 6500)
    local keeperName, kPos, keeperDist = MirrorSystem.FindKeeperNear(hrp.Position, searchCap)
    if not (keeperName and kPos and keeperDist) then
        logMirrorThrottled(
            "no_keeper:" .. targetArea.Name,
            ("FAIL: nenhum Mirror Keeper próximo (dest=%s dist=%.0f)"):format(targetArea.Name, totalDist)
        )
        return nil, "no_keeper"
    end

    if postMirrorDist and (keeperDist + postMirrorDist) >= totalDist - MIN_DISTANCE_SAVINGS then
        logMirrorThrottled(
            "no_save_total:" .. targetArea.Name,
            ("SKIP: Mirror %s não compensa (direto=%.0f keeper=%.0f pós=%.0f)"):format(
                targetArea.Name,
                totalDist,
                keeperDist,
                postMirrorDist
            )
        )
        return nil, "no_save_total"
    end

    return {
        TargetArea = targetArea,
        TargetCenter = typeof(targetCenter) == "Vector3" and targetCenter or nil,
        Price = price,
        Gold = gold,
        KeeperName = keeperName,
        KeeperPos = kPos,
        KeeperDist = keeperDist,
        TotalDist = totalDist,
        PostMirrorDist = postMirrorDist,
    }, nil
end

function MirrorSystem.CanTravel(destPos: Vector3, targetIslandName: string?): boolean
    local plan = MirrorSystem.PlanTravel(destPos, targetIslandName)
    return plan ~= nil
end

local function clearDialogueAndTravelUi(deps: Deps)
    local dlg = deps.GetDialogueClient and deps.GetDialogueClient()
    if dlg and type(dlg.GetBlockReason) == "function" then
        local okBlk, blkReason = pcall(dlg.GetBlockReason)
        if okBlk and blkReason == "Converse" then
            local gameModules = deps.GetGameModules()
            local stP = gameModules and gameModules.States and gameModules.States.Player and gameModules.States.Player()
            if stP and stP.Set then
                pcall(stP.Set, stP, "Converse", false)
            end
        end
    end

    pcall(function()
        local areasMod = deps.ReplicatedStorage:FindFirstChild("Modules")
        areasMod = areasMod and areasMod:FindFirstChild("Addons")
        areasMod = areasMod and areasMod:FindFirstChild("AreasSystem")
        if areasMod then
            local travelUi = require(areasMod).IsClient.Travel
            if travelUi and type(travelUi.Close) == "function" then
                travelUi.Close()
            end
        end
    end)
end

local function waitForArrivalAndAnimation(
    deps: Deps,
    targetName: string,
    abortIf: (() -> boolean)?
): boolean
    local mainModules = deps.GetMainModules()
    local screenTransition = mainModules and mainModules.ScreenTransition

    local function isAborted(): boolean
        return deps.IsDeadOrRespawning() or (abortIf ~= nil and abortIf())
    end

    -- 1) Aguarda o ScreenTransition terminar o carregamento da ilha (Arrival.lua espera até 10s)
    if screenTransition and type(screenTransition.IsCovered) == "function" then
        local coverDeadline = os.clock() + 10
        while not isAborted() and os.clock() < coverDeadline do
            local okCov, covered = pcall(screenTransition.IsCovered, screenTransition)
            if not (okCov and covered == true) then
                break
            end
            task.wait(0.05)
        end
    end
    if isAborted() then
        return false
    end

    -- 2) Aguarda o ciclo OnHold (0.35s) + Launch/Fly (0.15s + 0.7s) e limpeza de IslandTraveling
    -- para não disputar CFrame com Travel.Arrival enquanto o personagem sai do espelho.
    local animDeadline = os.clock() + 3.0
    local minAnimUntil = os.clock() + 1.25
    while not isAborted() and os.clock() < animDeadline do
        local char = deps.GetChar()
        local traveling = char and char:GetAttribute("IslandTraveling") ~= nil
        if not traveling and os.clock() >= minAnimUntil then
            break
        end
        task.wait(0.05)
    end
    if isAborted() then
        return false
    end

    local postWait = deps.GetPostTeleportWait and deps.GetPostTeleportWait() or 0
    if postWait > 0 then
        return deps.WaitPostTeleport(
            math.min(postWait, 1.0),
            abortIf,
            ("Mirror Keeper: chegou em %s..."):format(targetName)
        )
    end
    return true
end

local function arrivedAtDestination(posNow: Vector3, beforePos: Vector3, targetCenter: Vector3?): boolean
    if (posNow - beforePos).Magnitude >= ARRIVAL_MIN_DELTA then
        return true
    end
    if targetCenter and xzDistance(posNow, targetCenter) <= SAME_ISLAND_RADIUS and xzDistance(beforePos, targetCenter) > SAME_ISLAND_RADIUS then
        return true
    end
    return false
end

function MirrorSystem.Travel(destPos: Vector3, targetIslandName: string?, abortIf: (() -> boolean)?): boolean
    local deps = _deps
    if not deps then
        return false
    end

    local plan = MirrorSystem.PlanTravel(destPos, targetIslandName)
    if not plan then
        return false
    end

    local targetName = plan.TargetArea.Name
    local keeperName = plan.KeeperName
    local kPos = plan.KeeperPos
    local mainModules = deps.GetMainModules()
    local maxKeeperRange = ((mainModules and mainModules.TravelUtils and tonumber(mainModules.TravelUtils.KeeperRange)) or 25) - 3
    local lp = deps.GetLocalPlayer()

    logMirror(("TRY: keeper=%s (d=%.0f) -> %s (price=%d gold=%d)"):format(
        keeperName,
        plan.KeeperDist,
        targetName,
        plan.Price,
        plan.Gold
    ))
    setStatus(("Mirror Keeper: indo até %s (-%d Gold)..."):format(targetName, plan.Price))

    local function getFrontCF(dist: number): CFrame
        local cf = deps.GetNpcFrontCFrame and deps.GetNpcFrontCFrame(keeperName, kPos, dist)
        return cf or CFrame.new(kPos + Vector3.new(0, 2, 3))
    end

    if plan.KeeperDist > 6 then
        task.spawn(function()
            pcall(function()
                lp:RequestStreamAroundAsync(kPos)
            end)
        end)
        local tTw = os.clock()
        deps.TweenTo(getFrontCF(3), abortIf)
        logMirror(("TWEEN_KEEPER done in %.1fs"):format(os.clock() - tTw))
        if deps.IsDeadOrRespawning() or (abortIf and abortIf()) then
            logMirror(("ABORT: %s durante tween até keeper %s"):format(
                deps.IsDeadOrRespawning() and "morreu" or "abortado",
                keeperName
            ))
            return false
        end
        task.wait(0.05)
    end

    local _, hrpNow = deps.GetChar()
    if deps.IsDeadOrRespawning() or not hrpNow then
        logMirror(("ABORT: morreu/sem HRP antes de falar com keeper %s"):format(keeperName))
        return false
    end

    local distToKeeper = (hrpNow.Position - kPos).Magnitude
    if distToKeeper > 8 and distToKeeper <= 80 then
        deps.TweenTo(getFrontCF(2), abortIf)
        if deps.IsDeadOrRespawning() or (abortIf and abortIf()) then
            logMirror(("ABORT: %s no ajuste fino até keeper %s"):format(
                deps.IsDeadOrRespawning() and "morreu" or "abortado",
                keeperName
            ))
            return false
        end
        _, hrpNow = deps.GetChar()
        distToKeeper = hrpNow and (hrpNow.Position - kPos).Magnitude or math.huge
    end

    if not hrpNow or distToKeeper > maxKeeperRange then
        logMirror(("ABORT: longe do keeper %s após tween (d=%.0f > %.0f)"):format(keeperName, distToKeeper, maxKeeperRange))
        return false
    end

    deps.CancelTween()
    hrpNow.AssemblyLinearVelocity = Vector3.zero
    setStatus(("Mirror Keeper: viajando até %s..."):format(targetName))

    -- Aguarda o cooldown universal uma única vez antes de disparar o Converse
    if deps.BeginInteract and not deps.BeginInteract(abortIf) then
        return false
    end

    local _, hrpBefore = deps.GetChar()
    if deps.IsDeadOrRespawning() or not hrpBefore then
        return false
    end
    local beforePos = hrpBefore.Position

    for attempt = 1, 2 do
        if attempt == 2 then
            local _, hRetry = deps.GetChar()
            if hRetry and (hRetry.Position - kPos).Magnitude > maxKeeperRange then
                deps.TweenTo(getFrontCF(2), abortIf)
                deps.CancelTween()
                if deps.IsDeadOrRespawning() or (abortIf and abortIf()) then
                    return false
                end
            end
            logMirror(("RETRY: reenviando Travel para %s via %s"):format(targetName, keeperName))
        end

        clearDialogueAndTravelUi(deps)
        local okTravel, errTravel = deps.FireNet("Elysium_Converse", "Mirror Keeper", "Travel", targetName)
        if okTravel then
            logMirror(("ATTEMPT_%d: Travel sent -> %s"):format(attempt, targetName))
        else
            logMirror(("ATTEMPT_%d: Travel failed -> %s (%s)"):format(attempt, targetName, tostring(errTravel)))
        end

        local tWait = os.clock() + (attempt == 1 and 2.0 or 2.5)
        while os.clock() < tWait do
            if deps.IsDeadOrRespawning() then
                logMirror(("ABORT: morreu aguardando TP para %s"):format(targetName))
                return false
            end
            if abortIf and abortIf() then
                logMirror(("ABORT: aguardando TP para %s"):format(targetName))
                return false
            end
            local _, hNow = deps.GetChar()
            if hNow and arrivedAtDestination(hNow.Position, beforePos, plan.TargetCenter) then
                deps.CancelTween()
                clearDialogueAndTravelUi(deps)
                _failCooldownUntil[targetName] = nil
                logMirror(("SUCCESS: teleportou para %s (delta=%.0f)"):format(targetName, (hNow.Position - beforePos).Magnitude))
                setStatus(("Mirror Keeper: chegou em %s (aguardando animação/carregamento)..."):format(targetName))
                return waitForArrivalAndAnimation(deps, targetName, abortIf)
            end
            task.wait(0.15)
        end
    end

    _failCooldownUntil[targetName] = os.clock() + 4
    logMirror(("TIMEOUT: servidor não teleportou para %s via %s"):format(targetName, keeperName))
    return false
end

return MirrorSystem

