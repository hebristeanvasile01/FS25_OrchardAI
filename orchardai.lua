-- Orchard AI: drives your vineyard / olive / coffee machine row by row on its own.
-- Author: FS Modding
OrchardAI = {}

-- ---------------------------------------------------------------- settings
OrchardAI.WORK_SPEED = 10          -- km/h in the rows
OrchardAI.TURN_SPEED = 7          -- km/h on the headland
OrchardAI.TURN_RADIUS = 4.0       -- m, smallest turn the machine can drive
OrchardAI.HEADLAND = 7.0          -- m driven past the row end before turning (also the straight run into the next row)
OrchardAI.ENTRY_SPEED = 4         -- km/h while lining up with the next row
OrchardAI.DEFAULT_SPACING = 2.8   -- m between rows, used when rows are taught by hand
OrchardAI.LOOKAHEAD = 3.5         -- m, how far ahead the steering looks
OrchardAI.STEER_GAIN = 2.2
OrchardAI.STEER_SIGN = -1         -- flip with vaSteerSign if the machine steers the wrong way
OrchardAI.SEARCH_RADIUS = 80      -- m, vine rows searched around the machine
OrchardAI.FULL_LEVEL = 0.97       -- stop when the tank is this full
OrchardAI.APPROACH = 10           -- m before the first row where the drive from the farm ends
OrchardAI.OBSTACLE_DISTANCE = 8   -- m in front of the machine checked for vehicles
OrchardAI.OBSTACLE_TIMEOUT = 20000 -- ms waiting for an obstacle before giving up
OrchardAI.STUCK_TIME = 2500       -- ms with throttle but no movement = stuck
OrchardAI.REVERSE_TIME = 3000     -- ms driving back when stuck
OrchardAI.MAX_TRIES = 4           -- free-up attempts before skipping ahead

-- ---------------------------------------------------------------- state
OrchardAI.vehicle = nil
OrchardAI.path = nil              -- { {x=, z=, work=, row=}, ... }
OrchardAI.index = 1
OrchardAI.working = false
OrchardAI.rowsTotal = 0
OrchardAI.teach = {}              -- hand taught points A, B, C
OrchardAI.loggedInput = false

-- small math helpers (do not depend on game helpers that may be missing)
local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function len2(x, z)
    return math.sqrt(x * x + z * z)
end

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local function notify(text)
    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO, text)
end

local function warn(text)
    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL, text)
end

local function getControlledVehicle()
    if g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
        local v = g_localPlayer:getCurrentVehicle()
        if v ~= nil then return v end
    end
    local m = g_currentMission
    if m ~= nil and m.controlledVehicle ~= nil then return m.controlledVehicle end
    return nil
end

local function collect(vehicle, list, seen)
    if vehicle == nil or seen[vehicle] then return end
    seen[vehicle] = true
    table.insert(list, vehicle)
    if vehicle.getAttachedImplements ~= nil then
        for _, impl in ipairs(vehicle:getAttachedImplements()) do
            collect(impl.object, list, seen)
        end
    end
end

local function allVehicles(root)
    local list = {}
    collect(root, list, {})
    return list
end

local function steerNode(vehicle)
    return vehicle.steeringCenterNode or vehicle.rootNode
end

-- ---------------------------------------------------------------- rows from the game (vine system)

-- returns list of rows { ax, az, bx, bz } (centre lines) or nil
function OrchardAI:rowsFromVineSystem(vehicle, atX, atZ)
    local system = g_currentMission.vineSystem
    if system == nil or system.nodes == nil then
        Logging.info("[OrchardAI] no vine system found")
        return nil
    end

    local vx, _, vz = getWorldTranslation(vehicle.rootNode)
    if atX ~= nil then vx, vz = atX, atZ end
    local segments = {}
    for node, placeable in pairs(system.nodes) do
        if type(node) == "number" and entityExists(node) and placeable ~= nil and placeable.getVineAreaByNode ~= nil then
            local sx, sz, wx, wz, hx, hz = placeable:getVineAreaByNode(node)
            if sx ~= nil and hx ~= nil then
                -- area = parallelogram start / width / height
                local cx = sx + (wx - sx) * 0.5 + (hx - sx) * 0.5
                local cz = sz + (wz - sz) * 0.5 + (hz - sz) * 0.5
                -- all segments are kept: rows can be much longer than the search radius.
                -- the radius is only used to find the plantation the machine stands in
                table.insert(segments, { sx = sx, sz = sz, wx = wx, wz = wz, hx = hx, hz = hz, cx = cx, cz = cz, placeable = placeable })
            end
        end
    end
    if #segments == 0 then
        Logging.info("[OrchardAI] vine system found, but no rows near the machine")
        return nil
    end

    -- plantation of the segment closest to the machine
    local nearest, nearestD = nil, math.huge
    for _, sg in ipairs(segments) do
        local d = len2(sg.cx - vx, sg.cz - vz)
        if d < nearestD then nearest, nearestD = sg, d end
    end
    if nearestD > self.SEARCH_RADIUS then
        Logging.info("[OrchardAI] nearest plantation is %.0f m away, too far", nearestD)
        return nil
    end
    local kept = {}
    for _, sg in ipairs(segments) do
        if sg.placeable == nearest.placeable then table.insert(kept, sg) end
    end
    segments = kept

    -- row direction: one of the two edges of the area. The right one lines the segment
    -- centres up into few long rows, the wrong one into many short lines across the rows.
    local function countLines(dx, dz)
        local px, pz = -dz, dx
        local offs = {}
        for _, sg in ipairs(segments) do table.insert(offs, sg.cx * px + sg.cz * pz) end
        table.sort(offs)
        local lines = 1
        for i = 2, #offs do
            if offs[i] - offs[i - 1] > 0.6 then lines = lines + 1 end
        end
        return lines
    end
    local e1x, e1z = nearest.wx - nearest.sx, nearest.wz - nearest.sz
    local e2x, e2z = nearest.hx - nearest.sx, nearest.hz - nearest.sz
    local l1, l2 = len2(e1x, e1z), len2(e2x, e2z)
    e1x, e1z, e2x, e2z = e1x / l1, e1z / l1, e2x / l2, e2z / l2
    local n1, n2 = countLines(e1x, e1z), countLines(e2x, e2z)
    local useSecond = n2 < n1
    -- strongest hint: the machine stands in a row, so the row runs the way the machine faces
    local fx, _, fz = localDirectionToWorld(vehicle.rootNode, 0, 0, 1)
    local d1, d2 = math.abs(fx * e1x + fz * e1z), math.abs(fx * e2x + fz * e2z)
    local how = "line test"
    if math.max(d1, d2) > 0.8 then
        useSecond = d2 > d1
        how = "machine heading"
    end
    local dx, dz = e1x, e1z
    if useSecond then dx, dz = e2x, e2z end
    local px, pz = -dz, dx                     -- perpendicular
    Logging.info("[OrchardAI] row direction: edge 1 -> %d lines (heading %.2f), edge 2 -> %d lines (heading %.2f), using edge %d by %s",
        n1, d1, n2, d2, useSecond and 2 or 1, how)

    -- merge segments that lie on the same line into one row
    local rows = {}
    for _, sg in ipairs(segments) do
        local off = sg.cx * px + sg.cz * pz
        local corners = {
            { sg.sx, sg.sz }, { sg.wx, sg.wz }, { sg.hx, sg.hz },
            { sg.wx + sg.hx - sg.sx, sg.wz + sg.hz - sg.sz },
        }
        local tmin, tmax = math.huge, -math.huge
        for _, c in ipairs(corners) do
            local t = c[1] * dx + c[2] * dz
            tmin, tmax = math.min(tmin, t), math.max(tmax, t)
        end
        local row = nil
        for _, r in ipairs(rows) do
            if math.abs(r.off - off) < 1.0 then row = r break end
        end
        if row == nil then
            table.insert(rows, { off = off, tmin = tmin, tmax = tmax })
        else
            row.tmin = math.min(row.tmin, tmin)
            row.tmax = math.max(row.tmax, tmax)
        end
    end
    table.sort(rows, function(a, b) return a.off < b.off end)

    local out = {}
    for _, r in ipairs(rows) do
        table.insert(out, {
            ax = px * r.off + dx * r.tmin, az = pz * r.off + dz * r.tmin,
            bx = px * r.off + dx * r.tmax, bz = pz * r.off + dz * r.tmax,
        })
    end
    local gaps = {}
    for i = 2, #rows do
        local g = rows[i].off - rows[i - 1].off
        if g > 1.0 then table.insert(gaps, g) end
    end
    table.sort(gaps)
    self.spacing = gaps[math.max(1, math.floor(#gaps / 2 + 0.5))] or self.DEFAULT_SPACING
    Logging.info("[OrchardAI] %d vine segments merged into %d rows, spacing %.2f m", #segments, #out, self.spacing)
    return out
end

-- ---------------------------------------------------------------- rows taught by hand

-- A = start of first row, B = end of first row, C = any point in the last row
function OrchardAI:rowsFromTeach()
    local t = self.teach
    if t.A == nil or t.B == nil or t.C == nil then return nil end
    local dx, dz = t.B.x - t.A.x, t.B.z - t.A.z
    local len = len2(dx, dz)
    if len < 5 then return nil end
    dx, dz = dx / len, dz / len
    local px, pz = -dz, dx
    local side = (t.C.x - t.A.x) * px + (t.C.z - t.A.z) * pz
    local spacing = self.DEFAULT_SPACING
    local count = math.floor(math.abs(side) / spacing + 0.5) + 1
    local sign = side >= 0 and 1 or -1
    local rows = {}
    for i = 0, count - 1 do
        local o = i * spacing * sign
        table.insert(rows, { ax = t.A.x + px * o, az = t.A.z + pz * o, bx = t.B.x + px * o, bz = t.B.z + pz * o })
    end
    self.spacing = spacing
    local trimmed = self:trimRowsToVines(rows, dx, dz, px, pz)
    Logging.info("[OrchardAI] taught rows: %d rows, %.1f m long, %.2f m apart, %d rows measured from the plants", count, len, spacing, trimmed)
    return rows
end

-- each row gets its own length: start and end are taken from the plants found on that row line
function OrchardAI:trimRowsToVines(rows, dx, dz, px, pz)
    local system = g_currentMission.vineSystem
    if system == nil or system.nodes == nil then return 0 end
    local centres = {}
    for node, placeable in pairs(system.nodes) do
        if type(node) == "number" and entityExists(node) and placeable ~= nil and placeable.getVineAreaByNode ~= nil then
            local sx, sz, wx, wz, hx, hz = placeable:getVineAreaByNode(node)
            if sx ~= nil and hx ~= nil then
                local corners = { { sx, sz }, { wx, wz }, { hx, hz }, { wx + hx - sx, wz + hz - sz } }
                local tmin, tmax, off = math.huge, -math.huge, 0
                for _, c in ipairs(corners) do
                    local t = c[1] * dx + c[2] * dz
                    tmin, tmax = math.min(tmin, t), math.max(tmax, t)
                    off = off + (c[1] * px + c[2] * pz) * 0.25
                end
                table.insert(centres, { off = off, tmin = tmin, tmax = tmax })
            end
        end
    end
    local trimmed = 0
    for _, r in ipairs(rows) do
        local roff = r.ax * px + r.az * pz
        local tmin, tmax = math.huge, -math.huge
        for _, c in ipairs(centres) do
            if math.abs(c.off - roff) < 1.0 then
                tmin, tmax = math.min(tmin, c.tmin), math.max(tmax, c.tmax)
            end
        end
        if tmax > tmin then
            r.ax, r.az = px * roff + dx * tmin, pz * roff + dz * tmin
            r.bx, r.bz = px * roff + dx * tmax, pz * roff + dz * tmax
            trimmed = trimmed + 1
        end
    end
    return trimmed
end

-- ---------------------------------------------------------------- path

local function addTurn(path, ex, ez, dx, dz, nx, nz, radius, headland, row, direct)
    -- from row end (ex, ez) heading (dx, dz) to next row start (nx, nz) heading back.
    -- rows can end at different places, so the turn starts past the end that sticks out more
    local te, tn = ex * dx + ez * dz, nx * dx + nz * dz
    local tmax = math.max(te, tn) + headland
    local p1x, p1z = ex + dx * (tmax - te), ez + dz * (tmax - te)
    local p2x, p2z = nx + dx * (tmax - tn), nz + dz * (tmax - tn)
    -- straight out of the row
    local outSteps = math.max(1, math.floor((tmax - te) / 3))
    for i = 1, outSteps do
        local f = i / outSteps
        table.insert(path, { x = ex + (p1x - ex) * f, z = ez + (p1z - ez) * f, work = false, row = row })
    end
    local cx, cz = (p1x + p2x) * 0.5, (p1z + p2z) * 0.5
    local half = len2(p1x - cx, p1z - cz)
    if half < 0.01 then return end
    local lx, lz = (p2x - cx) / half, (p2z - cz) / half      -- sideways, towards the next row

    if half >= radius or direct then
        -- next row far enough away (or the other way round is blocked): a plain U-turn straight towards it
        for i = 1, 11 do
            local a = math.pi * i / 12
            table.insert(path, {
                x = cx - lx * half * math.cos(a) + dx * radius * math.sin(a),
                z = cz - lz * half * math.cos(a) + dz * radius * math.sin(a),
                work = false, row = row,
            })
        end
    else
        -- next row too close for the turning circle: bulb turn.
        -- swing out away from the next row, go round a big circle on the headland, come back into the next row
        local k = math.sqrt(radius * radius - half * half)
        local ox, oz = cx + dx * k, cz + dz * k               -- centre of the big circle
        local a1 = atan2(-k, -half)                           -- angle of the exit point
        local a2 = atan2(-k, half) - 2 * math.pi              -- angle of the entry point, going the long way round
        local steps = 20
        for i = 1, steps - 1 do
            local a = a1 + (a2 - a1) * i / steps
            table.insert(path, {
                x = ox + lx * radius * math.cos(a) + dx * radius * math.sin(a),
                z = oz + lz * radius * math.cos(a) + dz * radius * math.sin(a),
                work = false, row = row,
            })
        end
    end
    table.insert(path, { x = p2x, z = p2z, work = false, row = row })

    -- straight run into the next row, with points close together so it lines up exactly
    local inSteps = math.max(2, math.floor((tmax - tn) / 1.5))
    for i = 0, inSteps - 1 do
        local f = i / inSteps
        table.insert(path, { x = p2x + (nx - p2x) * f, z = p2z + (nz - p2z) * f, work = false, row = row, entry = true })
    end
end

-- order of the rows: every second row going out, then the rows left out on the way back
local function rowOrder(n, first)
    local dir = (n - first) >= (first - 1) and 1 or -1
    local order, used = {}, {}
    local i = first
    while i >= 1 and i <= n do
        table.insert(order, i); used[i] = true
        i = i + 2 * dir
    end
    local last = order[#order]
    local back = last + dir
    if back < 1 or back > n or used[back] then back = last - dir end
    i = back
    while i >= 1 and i <= n do
        if not used[i] then table.insert(order, i); used[i] = true end
        i = i - 2 * dir
    end
    -- anything still left (rows behind the starting row): nearest first
    local current = order[#order]
    while true do
        local best, bestD = nil, math.huge
        for k = 1, n do
            if not used[k] and math.abs(k - current) < bestD then best, bestD = k, math.abs(k - current) end
        end
        if best == nil then break end
        table.insert(order, best); used[best] = true
        current = best
    end
    return order
end

function OrchardAI:buildPath(vehicle, rows)
    local vx, _, vz = getWorldTranslation(vehicle.rootNode)
    local n = #rows
    local spacing = self.spacing or self.DEFAULT_SPACING

    -- start on the row closest to the machine, from where it stands, in the direction it faces
    local fx, _, fz = localDirectionToWorld(vehicle.rootNode, 0, 0, 1)
    local first, firstDist, startAtA, startT = 1, math.huge, true, 0
    for i, r in ipairs(rows) do
        local rx, rz = r.bx - r.ax, r.bz - r.az
        local rl = len2(rx, rz)
        if rl > 0.01 then
            local ux, uz = rx / rl, rz / rl
            local t = clamp((vx - r.ax) * ux + (vz - r.az) * uz, 0, rl)
            local cx, cz = r.ax + ux * t, r.az + uz * t
            local d = len2(vx - cx, vz - cz)
            if d < firstDist then
                first, firstDist = i, d
                startAtA = (fx * ux + fz * uz) >= 0      -- facing towards B: drive A -> B
                startT = startAtA and t or (rl - t)
            end
        end
    end
    self.startSkip = startT
    self.plan = { rows = rows, order = rowOrder(n, first), startAtA = startAtA, spacing = spacing }
    self.turnVariant = {}
    return self:generatePath()
end

-- turn shapes tried one after another when a turn is blocked: { extra radius, extra headland }
OrchardAI.TURN_VARIANTS = {
    { 0, 0 },      -- normal
    { 0, 3 },      -- further out on the headland
    { 2, 0 },      -- wider circle
    { 2, 4 },      -- wider and further out
    { 0, 3, true },  -- turn the other way: straight towards the next row, further out
    { -1, -1.5 },  -- tighter and closer to the rows
}

function OrchardAI:generatePath()
    local plan = self.plan
    local rows, order = plan.rows, plan.order
    local path = {}
    self.turnStarts = {}
    local fromA = plan.startAtA
    local count = 0
    for k, current in ipairs(order) do
        count = count + 1
        local r = rows[current]
        local sx, sz, ex, ez = r.ax, r.az, r.bx, r.bz
        if not fromA then sx, sz, ex, ez = r.bx, r.bz, r.ax, r.az end
        local len = len2(ex - sx, ez - sz)
        if len < 0.5 then len = 0.5 end
        local dx, dz = (ex - sx) / len, (ez - sz) / len
        -- points along the row every 3 m
        local steps = math.max(1, math.floor(len / 3))
        local skipLen = (count == 1) and (self.startSkip or 0) + 2 or 0
        for i = 0, steps do
            local t = i / steps
            if t * len >= skipLen or i == steps then
                table.insert(path, { x = sx + (ex - sx) * t, z = sz + (ez - sz) * t, work = true, row = count })
            end
        end

        local nextRow = order[k + 1]
        if nextRow ~= nil then
            local nr = rows[nextRow]
            -- next row starts at the same end where we are now
            local nax, naz = nr.ax, nr.az
            local da = len2(nr.ax - ex, nr.az - ez)
            local db = len2(nr.bx - ex, nr.bz - ez)
            local nextFromA = da <= db
            if not nextFromA then nax, naz = nr.bx, nr.bz end

            local variant = self.TURN_VARIANTS[self.turnVariant[count] or 1]
            local radius = math.max(3, self.TURN_RADIUS + variant[1])
            local headland = math.max(1.5, self.HEADLAND + variant[2])
            local first = #path + 1
            addTurn(path, ex, ez, dx, dz, nax, naz, radius, headland, count, variant[3] == true)
            for i = first, #path do path[i].turn = count end
            self.turnStarts[count] = first
            fromA = nextFromA
        end
    end
    self.rowsTotal = count
    Logging.info("[OrchardAI] path: %d rows, %d points, row spacing %.2f m, every second row out and the others on the way back", count, #path, plan.spacing)
    return path
end

-- ---------------------------------------------------------------- machine control

function OrchardAI:setWorking(work)
    if self.working == work then return end
    self.working = work
    for _, v in ipairs(allVehicles(self.vehicle)) do
        if work then
            if v.aiImplementStartLine ~= nil then v:aiImplementStartLine() end
            if v.setIsTurnedOn ~= nil and v.getCanBeTurnedOn ~= nil and v:getCanBeTurnedOn()
                and v.getIsTurnedOn ~= nil and not v:getIsTurnedOn() then
                v:setIsTurnedOn(true)
            end
        else
            if v.aiImplementEndLine ~= nil then v:aiImplementEndLine() end
        end
    end
end

function OrchardAI:setSpeed(kmh)
    -- speed is held by the AI throttle (see update)
end

-- only the harvest tank counts (not fuel, DEF or air)
function OrchardAI:isFull()
    for _, v in ipairs(allVehicles(self.vehicle)) do
        local combine = v.spec_combine
        local spec = v.spec_fillUnit
        if combine ~= nil and combine.fillUnitIndex ~= nil and spec ~= nil and spec.fillUnits ~= nil then
            local unit = spec.fillUnits[combine.fillUnitIndex]
            if unit ~= nil and unit.capacity ~= nil and unit.capacity > 0
                and v:getFillUnitFillLevel(combine.fillUnitIndex) / unit.capacity >= self.FULL_LEVEL then
                return true
            end
        end
    end
    return false
end

function OrchardAI:start(vehicleArg)
    local vehicle = vehicleArg or getControlledVehicle()
    if vehicle == nil then
        warn(g_i18n:getText("oa_needVehicle"))
        return
    end
    local rows = self:rowsFromVineSystem(vehicle)
    if rows == nil or #rows == 0 then
        warn(g_i18n:getText("oa_noRows"))
        return
    end
    self.vehicle = vehicle
    self.path = self:buildPath(vehicle, rows)
    self.index = 1
    self.working = nil
    self.reverseTimer, self.stuckTimer, self.waitTimer, self.tries, self.waitNotified = nil, 0, 0, 0, false
    self.helperShown = false

    if vehicle.getIsMotorStarted ~= nil and not vehicle:getIsMotorStarted() and vehicle.startMotor ~= nil then
        vehicle:startMotor()
    end
    self:setSpeed(self.TURN_SPEED)
    notify(string.format(g_i18n:getText("oa_started"), self.rowsTotal))
end

function OrchardAI:stop(textKey)
    local v = self.vehicle
    if v == nil then return end
    Logging.info("[OrchardAI] stopped: %s", tostring(textKey or "by player"))
    self:hideHelper()
    self:setWorking(false)
    self.axisForward, self.axisSide = 0, 0
    self.vehicle = nil
    self.path = nil
    notify(g_i18n:getText(textKey or "oa_stopped"))
end

-- ---------------------------------------------------------------- steering (virtual driver)

-- the machine is driven through the game's own vehicle physics call:
-- while Orchard AI is active, the driver's inputs are replaced by the AI's throttle and steering
local function speedKmh(vehicle)
    if vehicle.getLastSpeed ~= nil then return vehicle:getLastSpeed() end
    return (vehicle.lastSpeedReal or 0) * 3600
end

function OrchardAI.updateVehiclePhysics(vehicle, superFunc, axisForward, axisSide, doHandbrake, dt)
    local self = OrchardAI
    if vehicle == self.vehicle and self.path ~= nil then
        if not self.loggedInput then
            self.loggedInput = true
            Logging.info("[OrchardAI] driving through updateVehiclePhysics")
        end
        return superFunc(vehicle, self.axisForward or 0, self.axisSide or 0, self.handbrake == true, dt)
    end
    return superFunc(vehicle, axisForward, axisSide, doHandbrake, dt)
end

-- ---------------------------------------------------------------- obstacles

-- another vehicle in front of the machine? returns its name
function OrchardAI:obstacleAhead(v)
    local system = g_currentMission.vehicleSystem
    if system == nil or system.vehicles == nil then return nil end
    local own = {}
    for _, o in ipairs(allVehicles(v)) do own[o] = true end
    local size = v.size or {}
    local halfW = (size.width or 3) * 0.5
    local front = (size.length or 6) * 0.5 + (size.lengthOffset or 0)
    for _, other in ipairs(system.vehicles) do
        if not own[other] and other.rootNode ~= nil and entityExists(other.rootNode) then
            local ox, oy, oz = getWorldTranslation(other.rootNode)
            local lx, _, lz = worldToLocal(v.rootNode, ox, oy, oz)
            local os = other.size or {}
            local r = math.max(os.width or 2, os.length or 2) * 0.5
            if math.abs(lx) < halfW + r + 0.3 and lz > front - r and lz < front + self.OBSTACLE_DISTANCE + r then
                return other.getName ~= nil and other:getName() or "vehicle"
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------- driving to the plantation

-- nearest plantation of your farm: a point in it
function OrchardAI:findPlantation(vehicle)
    local system = g_currentMission.vineSystem
    if system == nil or system.nodes == nil then return nil end
    local farmId = g_currentMission.getFarmId ~= nil and g_currentMission:getFarmId() or 1
    local vx, _, vz = getWorldTranslation(vehicle.rootNode)
    local best, bestD = nil, math.huge
    local anyBest, anyD = nil, math.huge
    for node, placeable in pairs(system.nodes) do
        if type(node) == "number" and entityExists(node) and placeable ~= nil and placeable.getVineAreaByNode ~= nil then
            local owner = placeable.getOwnerFarmId ~= nil and placeable:getOwnerFarmId() or farmId
            local sx0, sz0, wx0, wz0, hx0, hz0 = placeable:getVineAreaByNode(node)
            if sx0 ~= nil and hx0 ~= nil then
                local cx0 = sx0 + (wx0 - sx0) * 0.5 + (hx0 - sx0) * 0.5
                local cz0 = sz0 + (wz0 - sz0) * 0.5 + (hz0 - sz0) * 0.5
                local d0 = len2(cx0 - vx, cz0 - vz)
                if d0 < anyD then anyBest, anyD = { x = cx0, z = cz0 }, d0 end
            end
            if owner == farmId then
                local sx, sz, wx, wz, hx, hz = placeable:getVineAreaByNode(node)
                if sx ~= nil and hx ~= nil then
                    local cx = sx + (wx - sx) * 0.5 + (hx - sx) * 0.5
                    local cz = sz + (wz - sz) * 0.5 + (hz - sz) * 0.5
                    local d = len2(cx - vx, cz - vz)
                    if d < bestD then best, bestD = { x = cx, z = cz }, d end
                end
            end
        end
    end
    if best == nil and anyBest ~= nil then
        -- plantation not registered to your farm (owner check failed): use the nearest one anyway
        if not self.loggedOwner then
            self.loggedOwner = true
            Logging.info("[OrchardAI] no plantation owned by farm %s found, using the nearest plantation", tostring(farmId))
        end
        return anyBest, anyD
    end
    return best, bestD
end

-- send the machine with the game's own helper (GoTo job) to the start of the nearest row
function OrchardAI:startTravel(vehicle)
    local target = self:findPlantation(vehicle)
    if target == nil then
        warn(g_i18n:getText("oa_noPlantation"))
        return
    end
    local rows = self:rowsFromVineSystem(vehicle, target.x, target.z)
    if rows == nil or #rows == 0 then
        warn(g_i18n:getText("oa_noRows"))
        return
    end
    -- the row end closest to the machine, and the direction into that row
    local vx, _, vz = getWorldTranslation(vehicle.rootNode)
    local bestD, ex, ez, ox, oz = math.huge, 0, 0, 0, 0
    for _, r in ipairs(rows) do
        for _, e in ipairs({ { r.ax, r.az, r.bx, r.bz }, { r.bx, r.bz, r.ax, r.az } }) do
            local d = len2(e[1] - vx, e[2] - vz)
            if d < bestD then bestD, ex, ez, ox, oz = d, e[1], e[2], e[3], e[4] end
        end
    end
    local dl = len2(ox - ex, oz - ez)
    if dl < 0.5 then return end
    local dx, dz = (ox - ex) / dl, (oz - ez) / dl
    local tx, tz = ex - dx * self.APPROACH, ez - dz * self.APPROACH

    if AIJobType == nil or AIJobStartRequestEvent == nil or g_currentMission.aiJobTypeManager == nil then
        warn(g_i18n:getText("oa_travelFail"))
        return
    end
    local job = g_currentMission.aiJobTypeManager:createJob(AIJobType.GOTO)
    if job == nil then
        warn(g_i18n:getText("oa_travelFail"))
        return
    end
    job.vehicleParameter:setVehicle(vehicle)
    job.positionAngleParameter:setPosition(tx, tz)
    job.positionAngleParameter:setAngle(atan2(dx, dz))
    if job.setValues ~= nil then job:setValues() end
    local farmId = g_currentMission:getFarmId()
    local ok = job:validate(farmId)
    if not ok then
        warn(g_i18n:getText("oa_travelFail"))
        Logging.info("[OrchardAI] GoTo job not valid")
        return
    end
    g_client:getServerConnection():sendEvent(AIJobStartRequestEvent.new(job, farmId))
    self.travel = { vehicle = vehicle, x = tx, z = tz, grace = 4000 }
    notify(string.format(g_i18n:getText("oa_travel"), math.floor(bestD)))
    Logging.info("[OrchardAI] driving to the plantation, %.0f m to the first row", bestD)
end

function OrchardAI:updateTravel(dt)
    local t = self.travel
    local v = t.vehicle
    if v == nil or v.rootNode == nil or not entityExists(v.rootNode) then
        self.travel = nil
        return
    end
    t.grace = t.grace - dt
    local active = v.getIsAIActive ~= nil and v:getIsAIActive()
    if active or t.grace > 0 then return end
    -- the helper has finished: arrived?
    local x, _, z = getWorldTranslation(v.rootNode)
    self.travel = nil
    if len2(x - t.x, z - t.z) < 25 then
        Logging.info("[OrchardAI] arrived at the plantation, starting the rows")
        self:start(v)
    else
        warn(g_i18n:getText("oa_travelFail"))
        Logging.info("[OrchardAI] helper stopped %.0f m before the plantation", len2(x - t.x, z - t.z))
    end
end

function OrchardAI:update(dt)
    if self.travel ~= nil then self:updateTravel(dt) end
    local v = self.vehicle
    if v == nil or self.path == nil then return end
    if v.rootNode == nil or not entityExists(v.rootNode) then
        self.vehicle, self.path = nil, nil
        return
    end

    local node = steerNode(v)
    local x, _, z = getWorldTranslation(node)

    -- advance past points we reached
    while self.index < #self.path do
        local p = self.path[self.index]
        local lx, _, lz = worldToLocal(node, p.x, getTerrainHeightAtWorldPos(g_terrainNode, p.x, 0, p.z), p.z)
        -- reached, or just passed close by. Points far behind are NOT skipped: in a turn
        -- and on the next row the route runs behind the machine.
        local d = len2(p.x - x, p.z - z)
        if d < 1.5 or (lz < 0 and d < 4) then
            self.index = self.index + 1
        else
            break
        end
    end
    if self.index >= #self.path then
        self:stop("oa_done")
        return
    end

    -- look ahead point along the path
    local target = self.path[self.index]
    for i = self.index, #self.path do
        local p = self.path[i]
        target = p
        if len2(p.x - x, p.z - z) >= self.LOOKAHEAD then break end
    end
    local ty = getTerrainHeightAtWorldPos(g_terrainNode, target.x, 0, target.z)
    local lx, _, lz = worldToLocal(node, target.x, ty, target.z)
    if lz < -1 and self.reverseTimer == nil then
        -- lost the route (target behind us): continue from the closest point in front
        local best, bestD = nil, math.huge
        for i = self.index, math.min(#self.path, self.index + 80) do
            local p = self.path[i]
            local py = getTerrainHeightAtWorldPos(g_terrainNode, p.x, 0, p.z)
            local _, _, pz = worldToLocal(node, p.x, py, p.z)
            local d = len2(p.x - x, p.z - z)
            if pz > 1 and d < bestD then best, bestD = i, d end
        end
        if best ~= nil and best ~= self.index then
            Logging.info("[OrchardAI] route point %d is behind, continuing from point %d", self.index, best)
            self.index = best
            target = self.path[math.min(#self.path, best + 1)]
            ty = getTerrainHeightAtWorldPos(g_terrainNode, target.x, 0, target.z)
            lx, _, lz = worldToLocal(node, target.x, ty, target.z)
        end
    end
    self.targetX, self.targetZ = target.x, target.z
    local angle = atan2(lx, math.max(lz, 0.1))
    self.axisSide = clamp(angle * self.STEER_GAIN * self.STEER_SIGN, -1, 1)

    -- throttle: hold the wanted speed, slower in sharp steering
    local wanted = (self.path[self.index].work and self.WORK_SPEED or self.TURN_SPEED)
    if self.path[self.index].entry then wanted = math.min(wanted, self.ENTRY_SPEED) end
    -- first metres of a row: still slow, until the machine sits straight in the row
    if self.path[self.index].work and self.index > 1 and self.path[self.index - 1].entry then
        wanted = math.min(wanted, self.ENTRY_SPEED)
    end
    self.wantedSpeed = wanted
    if math.abs(self.axisSide) > 0.7 then wanted = math.min(wanted, 4) end
    local speed = speedKmh(v)
    self.axisForward = clamp((wanted - speed) * 0.25 + 0.15, -1, 1)
    self.handbrake = false

    -- 1) freeing itself: drive back with the steering turned the other way, then try again
    if self.reverseTimer ~= nil then
        self.reverseTimer = self.reverseTimer - dt
        self.axisForward = -0.6
        self.axisSide = -(self.stuckSteer or 0)
        if self.reverseTimer <= 0 then
            self.reverseTimer = nil
            self.stuckTimer = 0
        end
        self:driveWithoutDriver(v, dt)
        return
    end

    -- 2) vehicle in front: stop and wait, give up after a while
    local blocker = self:obstacleAhead(v)
    if blocker ~= nil then
        self.axisForward = 0
        self.handbrake = true
        self.waitTimer = (self.waitTimer or 0) + dt
        if not self.waitNotified then
            self.waitNotified = true
            warn(string.format(g_i18n:getText("oa_obstacle"), blocker))
            Logging.info("[OrchardAI] obstacle ahead: %s, waiting", blocker)
        end
        local t = self.path[self.index].turn
        if t ~= nil and self.waitTimer > 4000 and (self.turnVariant[t] or 1) < #self.TURN_VARIANTS then
            -- on the headland: do not wait, go round it with another turn shape
            self.turnVariant[t] = (self.turnVariant[t] or 1) + 1
            self.path = self:generatePath()
            self.index = self.turnStarts[t] or self.index
            self.reverseTimer = self.REVERSE_TIME
            self.stuckSteer = self.axisSide
            self.waitTimer = 0
            notify(string.format(g_i18n:getText("oa_newRoute"), self.turnVariant[t], #self.TURN_VARIANTS))
            return
        end
        if self.waitTimer > self.OBSTACLE_TIMEOUT then
            self:stop("oa_blocked")
            return
        end
        self:driveWithoutDriver(v, dt)
        return
    end
    self.waitTimer, self.waitNotified = 0, false

    -- 3) stuck (vine post, slope, ditch...): throttle on but not moving
    if self.axisForward > 0.5 and speed < 0.5 then
        self.stuckTimer = (self.stuckTimer or 0) + dt
    else
        self.stuckTimer = 0
        if speed > 2 then self.tries = 0 end
    end
    if self.stuckTimer > self.STUCK_TIME and self.path[self.index].turn ~= nil then
        -- blocked on the headland: back up and try the next turn shape
        local t = self.path[self.index].turn
        local nextVariant = (self.turnVariant[t] or 1) + 1
        self.stuckSteer = self.axisSide
        self.stuckTimer = 0
        if nextVariant > #self.TURN_VARIANTS then
            Logging.info("[OrchardAI] turn %d blocked, all %d turn shapes tried", t, #self.TURN_VARIANTS)
            self:stop("oa_blocked")
            return
        end
        self.turnVariant[t] = nextVariant
        self.path = self:generatePath()
        self.index = self.turnStarts[t] or self.index
        self.reverseTimer = self.REVERSE_TIME
        Logging.info("[OrchardAI] turn %d blocked, backing up and trying turn shape %d", t, nextVariant)
        notify(string.format(g_i18n:getText("oa_newRoute"), nextVariant, #self.TURN_VARIANTS))
        return
    end
    if self.stuckTimer > self.STUCK_TIME then
        self.tries = (self.tries or 0) + 1
        self.stuckSteer = self.axisSide
        Logging.info("[OrchardAI] stuck at point %d, attempt %d", self.index, self.tries)
        if self.tries > self.MAX_TRIES * 2 then
            self:stop("oa_blocked")
            return
        elseif self.tries > self.MAX_TRIES then
            -- several attempts failed: skip a few points of the route
            self.index = math.min(#self.path - 1, self.index + 3)
            notify(g_i18n:getText("oa_skip"))
        else
            notify(g_i18n:getText("oa_stuck"))
        end
        self.reverseTimer = self.REVERSE_TIME
        self.stuckTimer = 0
        return
    end

    self.logTimer = (self.logTimer or 0) - dt
    if self.logTimer <= 0 then
        self.logTimer = 3000
        Logging.info("[OrchardAI] point %d/%d steer %.2f throttle %.2f speed %.1f km/h",
            self.index, #self.path, self.axisSide, self.axisForward, speed)
    end

    -- work on / off and speed
    local current = self.path[self.index]
    if current.work ~= self.working then
        self:setWorking(current.work)
        self:setSpeed(current.work and self.WORK_SPEED or self.TURN_SPEED)
        if current.work then
            notify(string.format(g_i18n:getText("oa_row"), current.row, self.rowsTotal))
        end
    end

    if self:isFull() then
        self:stop("oa_full")
        return
    end

    self:driveWithoutDriver(v, dt)
end

-- a farmer sitting in the cab while the AI drives (only for the looks)
function OrchardAI:showHelper(v)
    if self.helperShown then return end
    self.helperShown = true
    if v.setRandomVehicleCharacter ~= nil then
        local helper = nil
        if g_helperManager ~= nil and g_helperManager.getRandomHelper ~= nil then
            helper = g_helperManager:getRandomHelper()
        end
        v:setRandomVehicleCharacter(helper)
        self.helperVehicle = v
        Logging.info("[OrchardAI] helper character shown in the cab")
    else
        Logging.info("[OrchardAI] setRandomVehicleCharacter not found, no character in the cab")
    end
end

function OrchardAI:hideHelper()
    local v = self.helperVehicle
    self.helperVehicle = nil
    self.helperShown = false
    if v == nil or v.rootNode == nil or not entityExists(v.rootNode) then return end
    if v.getIsEntered ~= nil and v:getIsEntered() then return end
    if v.restoreVehicleCharacter ~= nil then
        v:restoreVehicleCharacter()
    elseif v.deleteVehicleCharacter ~= nil then
        v:deleteVehicleCharacter()
    end
end

-- leaving the cab switches the machine off (key B): while the AI works in a row, switch it on again
function OrchardAI:keepWorking(dt)
    if not self.working then return end
    self.keepTimer = (self.keepTimer or 0) - dt
    if self.keepTimer > 0 then return end
    self.keepTimer = 500
    for _, v in ipairs(allVehicles(self.vehicle)) do
        if v.getIsTurnedOn ~= nil and v.setIsTurnedOn ~= nil and not v:getIsTurnedOn()
            and v.getCanBeTurnedOn ~= nil and v:getCanBeTurnedOn() then
            v:setIsTurnedOn(true)
            if not self.loggedKeepOn then
                self.loggedKeepOn = true
                Logging.info("[OrchardAI] %s was switched off (driver left), switched on again", v:getName())
            end
        end
    end
end

-- with nobody in the cab the game does not drive the vehicle, so the AI does it itself
function OrchardAI:driveWithoutDriver(v, dt)
    local entered = v.getIsEntered ~= nil and v:getIsEntered()
    if v.raiseActive ~= nil then v:raiseActive() end
    if entered then
        self.helperShown = false          -- the player sits in the cab, the game shows the player
        return
    end
    self:showHelper(v)
    self:keepWorking(dt)
    if v.getIsMotorStarted ~= nil and not v:getIsMotorStarted() and v.startMotor ~= nil then
        v:startMotor()
    end
    local axisForward, axisSide = self.axisForward or 0, self.axisSide or 0

    -- best: the function the game's own helpers drive with (steers to a point and holds the speed)
    if AIVehicleUtil ~= nil and AIVehicleUtil.driveToPoint ~= nil and self.targetX ~= nil then
        local allowed = not self.handbrake
        local forwards = axisForward >= 0
        local tx, tz = self.targetX, self.targetZ
        local speed = self.wantedSpeed or self.WORK_SPEED
        if math.abs(axisSide) > 0.7 then speed = math.min(speed, 4) end
        if not forwards then
            -- backing up to get free: aim behind the machine
            local x, _, z = getWorldTranslation(v.rootNode)
            local fx, _, fz = localDirectionToWorld(v.rootNode, 0, 0, 1)
            tx, tz = x - fx * 6, z - fz * 6
            speed = 3
        end
        -- driveToPoint wants the target in the vehicle's own coordinates (like the game's helpers)
        local dirNode = (v.getAIDirectionNode ~= nil and v:getAIDirectionNode()) or v.steeringCenterNode or v.rootNode
        local ty = getTerrainHeightAtWorldPos(g_terrainNode, tx, 0, tz)
        local lx, _, lz = worldToLocal(dirNode, tx, ty, tz)

        self.signTimer = (self.signTimer or 0) + dt
        if self.signTimer > 1500 then
            self.signTimer = 0
            Logging.info("[OrchardAI] no driver: target local x %.1f z %.1f, steering angle %.2f, speed %.1f",
                lx, lz, v.rotatedTime or 0, speedKmh(v))
        end
        AIVehicleUtil.driveToPoint(v, dt, 1, allowed, forwards, lx, lz, speed)
        if not self.loggedNoDriver then
            self.loggedNoDriver = true
            Logging.info("[OrchardAI] driving without a driver in the cab (game helper steering)")
        end
        return
    end

    -- fallback: set the steering angle, then update the wheels
    if WheelsUtil ~= nil and WheelsUtil.updateWheelsPhysics ~= nil and v.maxRotTime ~= nil and v.minRotTime ~= nil then
        -- same mapping as the driver's steering input (negative = left)
        local target
        if axisSide < 0 then
            target = math.min(-v.maxRotTime * axisSide, v.maxRotTime)
        else
            target = math.max(v.minRotTime * axisSide, v.minRotTime)
        end
        local current = v.rotatedTime or 0
        local step = (v.maxRotTime - v.minRotTime) * dt / 1500       -- full lock to lock in 1.5 s
        if target > current then
            current = math.min(target, current + step)
        else
            current = math.max(target, current - step)
        end
        v.rotatedTime = current
        local speed = (v.lastSpeedReal or 0) * (v.movingDirection or 1)
        WheelsUtil.updateWheelsPhysics(v, dt, speed, axisForward, self.handbrake == true, true)
        if not self.loggedNoDriver then
            self.loggedNoDriver = true
            Logging.info("[OrchardAI] driving without a driver in the cab (helper steering)")
        end
    elseif v.updateVehiclePhysics ~= nil then
        v:updateVehiclePhysics(axisForward, axisSide, self.handbrake == true, dt)
        if not self.loggedNoDriver then
            self.loggedNoDriver = true
            Logging.info("[OrchardAI] driving without a driver in the cab (vehicle physics)")
        end
    end
end

function OrchardAI:draw()
    if self.path == nil or drawDebugLine == nil then return end
    local from = math.max(1, self.index - 1)
    for i = from, math.min(#self.path - 1, self.index + 40) do
        local a, b = self.path[i], self.path[i + 1]
        local ay = getTerrainHeightAtWorldPos(g_terrainNode, a.x, 0, a.z) + 0.3
        local by = getTerrainHeightAtWorldPos(g_terrainNode, b.x, 0, b.z) + 0.3
        local r, g = 1, 0.6
        if a.work then r, g = 0.2, 1 end
        drawDebugLine(a.x, ay, a.z, r, g, 0.1, b.x, by, b.z, r, g, 0.1)
    end
end

-- ---------------------------------------------------------------- keys

function OrchardAI:onToggle()
    if g_currentMission == nil then return end
    local v = getControlledVehicle()
    if self.vehicle == nil and v ~= nil then
        local _, dist = self:findPlantation(v)
        if dist ~= nil and dist > self.SEARCH_RADIUS and self.travel == nil then
            self:startTravel(v)
            return
        end
    end
    local now = g_time or 0
    if self.lastKeyTime ~= nil and now - self.lastKeyTime < 600 then return end
    self.lastKeyTime = now
    if self.vehicle ~= nil then self:stop() else self:start() end
end

local function teachPoint(name, textKey)
    local v = getControlledVehicle()
    if v == nil then
        warn(g_i18n:getText("oa_needVehicle"))
        return
    end
    local x, _, z = getWorldTranslation(steerNode(v))
    OrchardAI.teach[name] = { x = x, z = z }
    notify(g_i18n:getText(textKey))
end

function OrchardAI:onTeachA() OrchardAI.teach = {}; teachPoint("A", "oa_teachA") end
function OrchardAI:onTeachB() teachPoint("B", "oa_teachB") end
function OrchardAI:onTeachC() teachPoint("C", "oa_teachC") end

-- ---------------------------------------------------------------- console

function OrchardAI:consoleSpacing(v)
    local n = tonumber(v)
    if n == nil then return "usage: vaSpacing 2.8" end
    OrchardAI.DEFAULT_SPACING = n
    return "row spacing " .. n .. " m"
end
addConsoleCommand("vaSpacing", "Row spacing for taught rows", "consoleSpacing", OrchardAI)

function OrchardAI:consoleSpeed(w, t)
    OrchardAI.WORK_SPEED = tonumber(w) or OrchardAI.WORK_SPEED
    OrchardAI.TURN_SPEED = tonumber(t) or OrchardAI.TURN_SPEED
    return string.format("work %s km/h, turn %s km/h", OrchardAI.WORK_SPEED, OrchardAI.TURN_SPEED)
end
addConsoleCommand("vaSpeed", "Work and turn speed", "consoleSpeed", OrchardAI)

function OrchardAI:consoleRadius(r)
    OrchardAI.TURN_RADIUS = tonumber(r) or OrchardAI.TURN_RADIUS
    return "turn radius " .. OrchardAI.TURN_RADIUS .. " m"
end
addConsoleCommand("vaRadius", "Turning radius", "consoleRadius", OrchardAI)

function OrchardAI:consoleSteerSign()
    OrchardAI.STEER_SIGN = -OrchardAI.STEER_SIGN
    return "steer sign " .. OrchardAI.STEER_SIGN
end
addConsoleCommand("vaSteerSign", "Flip steering direction", "consoleSteerSign", OrchardAI)

-- ---------------------------------------------------------------- hooks and input

-- without a driver the game centres the steering of vehicles that are not helper-driven.
-- While Orchard AI drives with nobody in the cab, the machine counts as helper-driven.
local function aiDrivesAlone(vehicle)
    local ai = OrchardAI.vehicle
    return ai ~= nil and vehicle == ai and OrchardAI.path ~= nil
        and not (vehicle.getIsEntered ~= nil and vehicle:getIsEntered())
end
OrchardAI.aiDrivesAlone = aiDrivesAlone

for _, className in ipairs({ "AIJobVehicle", "AIVehicle", "AIDrivable" }) do
    local class = _G[className]
    if type(class) == "table" and class.getIsAIActive ~= nil then
        class.getIsAIActive = Utils.overwrittenFunction(class.getIsAIActive, function(vehicle, superFunc, ...)
            if aiDrivesAlone(vehicle) then return true end
            return superFunc(vehicle, ...)
        end)
        Logging.info("[OrchardAI] %s.getIsAIActive hooked", className)
    end
end

-- the game switches machines off when the driver leaves: not while Orchard AI works
local function isOrchardWorking(vehicle)
    local ai = OrchardAI.vehicle
    if ai == nil then return false end
    if vehicle == ai then return true end
    local root = vehicle.rootVehicle or (vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle()) or nil
    return root == ai
end

if TurnOnVehicle ~= nil then
    for _, name in ipairs({ "onLeaveRootVehicle", "onLeave" }) do
        if TurnOnVehicle[name] ~= nil then
            TurnOnVehicle[name] = Utils.overwrittenFunction(TurnOnVehicle[name], function(vehicle, superFunc, ...)
                if isOrchardWorking(vehicle) then return end
                return superFunc(vehicle, ...)
            end)
        end
    end
end

if Motorized ~= nil and Motorized.getStopMotorOnLeave ~= nil then
    Motorized.getStopMotorOnLeave = Utils.overwrittenFunction(Motorized.getStopMotorOnLeave, function(vehicle, superFunc, ...)
        if vehicle == OrchardAI.vehicle then return false end
        return superFunc(vehicle, ...)
    end)
end

if Drivable ~= nil and Drivable.updateVehiclePhysics ~= nil then
    Drivable.updateVehiclePhysics = Utils.overwrittenFunction(Drivable.updateVehiclePhysics, OrchardAI.updateVehiclePhysics)
else
    Logging.warning("[OrchardAI] Drivable.updateVehiclePhysics not found")
end

-- H (start helper): on an orchard machine start Orchard AI instead of the normal helper
local function isOrchardMachine(root)
    for _, v in ipairs(allVehicles(root)) do
        for key, _ in pairs(v) do
            if type(key) == "string" and string.sub(key, 1, 5) == "spec_" then
                local k = string.lower(key)
                if string.find(k, "vine", 1, true) or string.find(k, "olive", 1, true)
                    or string.find(k, "coffee", 1, true) or string.find(k, "grape", 1, true) then
                    return true
                end
            end
        end
    end
    return false
end
OrchardAI.isOrchardMachine = isOrchardMachine

local function hookHelperKey(class, className, name)
    class[name] = Utils.overwrittenFunction(class[name], function(vehicle, superFunc, ...)
        -- one key press can reach this handler several times: react only once
        local now = g_time or 0
        if OrchardAI.lastKeyTime ~= nil and now - OrchardAI.lastKeyTime < 600
            and type(vehicle) == "table" and (OrchardAI.vehicle == vehicle or isOrchardMachine(vehicle)) then
            return
        end
        if type(vehicle) == "table" and (OrchardAI.vehicle == vehicle or isOrchardMachine(vehicle)) then
            OrchardAI.lastKeyTime = now
        end
        if OrchardAI.vehicle ~= nil and OrchardAI.vehicle == vehicle then
            OrchardAI:stop()
            return
        end
        if type(vehicle) == "table" and vehicle.rootNode ~= nil and isOrchardMachine(vehicle) then
            -- driving to the plantation: H stops the drive
            if OrchardAI.travel ~= nil and OrchardAI.travel.vehicle == vehicle then
                OrchardAI.travel = nil
                return superFunc(vehicle, ...)
            end
            -- in the plantation: work the rows; far away: drive there first
            local _, dist = OrchardAI:findPlantation(vehicle)
            if dist ~= nil and dist > OrchardAI.SEARCH_RADIUS then
                OrchardAI:startTravel(vehicle)
            else
                OrchardAI:start(vehicle)
            end
            return
        end
        return superFunc(vehicle, ...)
    end)
    Logging.info("[OrchardAI] helper key hooked: %s.%s", className, name)
end

-- hook every action handler that toggles / starts the helper (names differ between game versions)
local hookedCount = 0
for _, className in ipairs({ "AIJobVehicle", "AIVehicle", "AIFieldWorker", "AIDrivable", "AIModeSelection" }) do
    local class = _G[className]
    if type(class) == "table" then
        local names = {}
        for name, fn in pairs(class) do
            if type(fn) == "function" and type(name) == "string" and string.sub(name, 1, 11) == "actionEvent" then
                table.insert(names, name)
                local l = string.lower(name)
                if string.find(l, "toggleai", 1, true) or string.find(l, "startai", 1, true)
                    or string.find(l, "helper", 1, true) or string.find(l, "aistate", 1, true) then
                    hookHelperKey(class, className, name)
                    hookedCount = hookedCount + 1
                end
            end
        end
        if #names > 0 then
            table.sort(names)
            Logging.info("[OrchardAI] %s action handlers: %s", className, table.concat(names, ", "))
        end
    end
end
if hookedCount == 0 then
    Logging.warning("[OrchardAI] helper key (H) could not be hooked, use Alt + V")
end

local function registerAll(register)
    local ids = {}
    for _, e in ipairs({
        { InputAction.ORCHARD_AI, OrchardAI.onToggle },
    }) do
        if e[1] ~= nil then
            local _, id = register(e[1], OrchardAI, e[2])
            if id ~= nil then
                g_inputBinding:setActionEventTextPriority(id, GS_PRIO_VERY_LOW)
                g_inputBinding:setActionEventTextVisibility(id, e[2] == OrchardAI.onToggle)
            end
        end
    end
end

if Enterable ~= nil and Enterable.onRegisterActionEvents ~= nil then
    Enterable.onRegisterActionEvents = Utils.appendedFunction(Enterable.onRegisterActionEvents,
        function(vehicle, isActiveForInput, isActiveForInputIgnoreSelection)
            if vehicle.isClient and isActiveForInputIgnoreSelection then
                local spec = vehicle.spec_enterable
                -- only on vine / olive / coffee machines: in a normal tractor Alt + V does not exist
                if spec ~= nil and spec.actionEvents ~= nil and isOrchardMachine(vehicle) then
                    registerAll(function(action, target, func)
                        return vehicle:addActionEvent(spec.actionEvents, action, target, func, false, true, false, true, nil)
                    end)
                end
            end
        end)
end

addModEventListener(OrchardAI)
