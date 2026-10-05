---@diagnostic disable: undefined-global, undefined-field
-- ============================================================================
-- TRIUNE LDON RUNNER v1.0 (Standalone ImGui Script)
-- ----------------------------------------------------------------------------
-- Lua port of ldon.mac: runs Lost Dungeons of Norrath adventures in a loop.
-- Requests an adventure, travels to the entrance, runs the TAC as puller until
-- the adventure completes, leaves through the Bazaar and returns to camp.
-- Compatible with MacroQuest LuaJIT (Lua 5.1 safe).
--
-- Run via:  /lua run triune_ldon [camp] [skip]
--   camp: sro (Deepest Guk)   ep (Miragul's)   bm (Mistmoore)
--         ec  (Rujarkian)     nro (Takish-Hiz)        default: sro
--   skip: already have an adventure and standing at the recruiter,
--         so don't request one on the first loop
--   Passing a camp starts the loop right away; with no arguments the window
--   opens idle so you can pick a camp and press Start.
--
-- Commands:  /ldon start [camp] [skip] | stop | camp <name> | status
--            /ldon show | hide | toggle | quit
-- Requires MQ2Nav, MQ2MoveUtils, a navmesh for every zone on the route, the
-- Bazaar and Back AA, and triune.lua running (for the /ac puller commands).
-- ============================================================================

local mq = require('mq')
local ImGui = require('ImGui')

local VERSION = '1.0'
local cfg = mq.configDir
local TAG = '\ag[Triune LDoN]\ax '

-- ============================================================================
-- GENERAL CONFIG (defaults; the window saves your choices per character)
-- ============================================================================
local settings = {
    camp = 'sro',
    -- Optional safety check: only run on this character (empty = any)
    charName = '',
    -- Adventure window dropdowns, counting from the top (1 = first entry)
    riskIndex = 2,
    typeIndex = 3,
    -- Minutes to wait for the adventure to complete before leaving anyway
    maxClearMin = 90,
}

-- Triune auto combat puller
local PULLER_MODE_CMD   = '/ac puller'
local PULLER_ON_CMD     = '/ac run'
-- stops chasing new mobs but keeps fighting what's already on me
local PULLER_MANUAL_CMD = '/ac manual'
-- only sent once combat is completely over
local PULLER_OFF_CMD    = '/ac stop'

-- "Bazaar and Back" AA, and the map switch in the Bazaar
local BAZAAR_AA_ID  = 331
local MAP_Y, MAP_X, MAP_Z = -646.5, 2.9, 4.8
local MAP_SWITCH_ID = 146

-- ============================================================================
-- PER-CAMP CONFIG
-- ----------------------------------------------------------------------------
-- path:      zone short names in travel order (empty = same zone)
-- ent2Names: ent2 is only used when the adventure text contains one of these
--            (upper/lower case doesn't matter)
-- mapRow:    if set, picks the waypoint by its position in the list instead of by name
-- magus:     if set, said to the camp's Magus to port to the first entrance's zone
-- retMagus:  if set, said to the Magus in the landing zone to port to the camp
-- exit:      after a Magus port, walk straight to this clear spot first (tents)
-- An entrance z of nil means "let nav work out the height".
-- An entrance door is the switch ID to click (0 = nearest switch).
-- ============================================================================
local CAMP_ORDER = { 'sro', 'ep', 'bm', 'ec', 'nro' }

local CAMPS = {
    sro = {
        label     = 'Deepest Guk (South Ro)',
        campZone  = 'sro',
        questNPC  = 'Kallei Ribblok',
        campSpot  = { y = -1497.2, x = 998.3, z = -23.2 },
        ent1      = { zone = 'guktop', path = { 'innothule', 'guktop' }, y = 438.1, x = 224.2, z = -9.2, door = 0 },
        ent2Names = { 'Cauldron of Lost Souls' },
        ent2      = { zone = 'innothule', path = { 'innothule' }, y = 1353, x = 1186, door = 0 },
        -- Trip back: East Commonlands waypoint, then the Magus there ports to this camp
        map        = { continent = 1, waypoint = 'East Commonlands' },
        landZone   = 'ecommons',
        returnPath = {},
        retMagus   = { say = 'South Ro', name = 'Magus Zeir', exit = { y = -1458.2, x = 1069.9 } },
        -- Old trip back, running from Grobb:
        -- map = { continent = 1, waypoint = 'Grobb' }, landZone = 'grobb',
        -- returnPath = { 'innothule', 'sro' }, retMagus = nil,
    },
    ep = {
        label     = "Miragul's Menagerie (Everfrost)",
        -- both entrances are in Everfrost itself
        campZone  = 'everfrost',
        questNPC  = 'Mannis McGuyett',
        ent1      = { zone = 'everfrost', path = {}, y = -828, x = -5458, door = 0 },
        ent2Names = { 'Hushed Banquet', 'Heart of the Menagerie' },
        ent2      = { zone = 'everfrost', path = {}, y = 2771, x = -4725, door = 0 },
        -- GUESS - confirm the Everfrost waypoint lands in Everfrost Peaks
        map        = { continent = 1, waypoint = 'Everfrost' },
        landZone   = 'everfrost',
        returnPath = {},
    },
    bm = {
        label     = "Mistmoore's Catacombs (Butcherblock)",
        -- entrances are in Lesser Faydark
        campZone  = 'butcher',
        questNPC  = 'Xyzelauna',
        -- Ent1 (switch 7) is the crypt entrance, Ent2 (switch 10) is the grave entrance.
        ent1      = { zone = 'lfaydark', path = { 'gfaydark', 'lfaydark' }, y = -759.1, x = 3832.8, z = 2.5, door = 7 },
        ent2Names = { 'grave' },
        ent2      = { zone = 'lfaydark', path = { 'gfaydark', 'lfaydark' }, y = -111.0, x = 3861.8, z = -39.6, door = 10 },
        map        = { continent = 1, waypoint = 'East Commonlands' },
        landZone   = 'ecommons',
        returnPath = {},
        retMagus   = { say = 'Butcherblock', name = 'Magus Zeir' },
    },
    ec = {
        label     = 'Rujarkian Hills (East Commonlands)',
        -- entrance is in South Ro
        campZone  = 'ecommons',
        questNPC  = 'Periac Windfell',
        -- switch 1 = RUJPORTAL701 (switch 6, HUT1, is just a hut next to it)
        ent1      = { zone = 'sro', path = { 'nro', 'oasis', 'sro' }, y = -2111.9, x = 1331.6, z = -68.3, door = 1 },
        -- Shortcut: say this to the Magus at the camp to port to the entrance zone.
        -- Remove this line to go back to running ent1.path.
        magus     = { say = 'South Ro', name = 'Magus Zeir', exit = { y = -1458.2, x = 1069.9 } },
        map        = { continent = 1, waypoint = 'East Commonlands' },
        landZone   = 'ecommons',
        returnPath = {},
    },
    nro = {
        label     = 'Takish-Hiz (North Ro)',
        -- entrance is in North Ro itself
        campZone  = 'nro',
        questNPC  = 'Escon Quickbow',
        ent1      = { zone = 'nro', path = {}, y = -956.2, x = 119.7, z = -61.4, door = 3 },
        map        = { continent = 1, waypoint = 'East Commonlands' },
        landZone   = 'ecommons',
        returnPath = {},
        retMagus   = { say = 'North Ro', name = 'Magus Zeir' },
    },
}

-- ============================================================================
-- BUILT-IN ZONE CROSSINGS
-- ----------------------------------------------------------------------------
-- Taken from recorded runs: the last few points before the zone line (y, x),
-- the height there, and the heading used to run across.
-- ============================================================================
local ROUTES = {
    sro_to_innothule = { zone = 'sro', heading = 114.95, lastZ = -23.05, points = {
        { -3105.89, 1089.84 }, { -3134.52, 1059.16 }, { -3174.04, 1043.41 },
        { -3204.04, 1070.45 }, { -3197.69, 1113.27 }, { -3200.11, 1134.10 } } },
    innothule_to_guktop = { zone = 'innothule', heading = 235.41, lastZ = -7.73, points = {
        { 185.05, -714.98 }, { 176.92, -755.63 }, { 170.92, -797.48 }, { 138.19, -828.50 } } },
    grobb_to_innothule = { zone = 'grobb', heading = 180.77, lastZ = 3.75, points = {
        { -94.77, 8.86 }, { -108.73, 46.68 }, { -135.05, 55.18 } } },
    innothule_to_sro = { zone = 'innothule', heading = 321.73, lastZ = -23.77, points = {
        { 2425.42, 1012.50 }, { 2450.89, 1047.76 }, { 2475.87, 1082.32 },
        { 2501.13, 1118.18 }, { 2524.97, 1152.06 }, { 2567.59, 1137.51 } } },
    kaladima_to_butcher = { zone = 'kaladima', heading = 170.86, lastZ = 3.75, points = {
        { 101.04, 9.52 }, { 58.81, 6.92 }, { 15.22, 4.23 },
        { -27.14, 1.63 }, { -51.81, 35.02 }, { -76.47, 46.18 } } },
    butcher_to_gfaydark = { zone = 'butcher', heading = 246.08, lastZ = 3.75, points = {
        { -1151.15, -3056.88 }, { -1183.39, -3083.84 }, { -1225.25, -3082.91 },
        { -1262.50, -3063.90 }, { -1305.25, -3065.52 }, { -1325.96, -3082.54 } } },
    ecommons_to_nro = { zone = 'ecommons', heading = 261.66, lastZ = 3.75, points = {
        { -2366.93, 34.29 }, { -2390.62, -0.83 }, { -2413.88, -38.29 },
        { -2429.27, -77.48 }, { -2439.50, -119.63 }, { -2446.03, -155.41 } } },
    nro_to_oasis = { zone = 'nro', heading = 185.99, lastZ = 31.54, points = {
        { -1737.07, 974.34 }, { -1781.35, 965.01 }, { -1821.81, 958.58 },
        { -1864.33, 954.29 }, { -1886.70, 952.09 } } },
    oasis_to_sro = { zone = 'oasis', heading = 178.72, lastZ = 6.15, points = {
        { -1895.63, 201.02 }, { -1903.72, 201.22 } } },
    gfaydark_to_lfaydark = { zone = 'gfaydark', heading = 169.77, lastZ = 3.75, points = {
        { -2475.47, -983.32 }, { -2508.90, -1011.15 }, { -2544.38, -1033.92 },
        { -2577.02, -1061.64 }, { -2595.93, -1098.98 }, { -2626.51, -1109.55 } } },
}

-- ============================================================================
-- STATE
-- ============================================================================
local state = {
    isRunning = true,      -- script alive
    openGUI = true,
    active = false,        -- adventure loop in progress
    startRequested = false,
    stopRequested = false,
    skipGet = false,
    useEnt2 = false,
    advWon = false,
    died = false,
    runs = 0,
    step = 'Idle',
    startedAt = 0,
    log = {},
}

local function log(fmt, ...)
    local msg = select('#', ...) > 0 and string.format(fmt, ...) or fmt
    print(TAG .. msg)
    table.insert(state.log, os.date('%H:%M:%S') .. '  ' .. msg)
    while #state.log > 60 do table.remove(state.log, 1) end
end

local function setStep(fmt, ...)
    state.step = select('#', ...) > 0 and string.format(fmt, ...) or fmt
end

-- ============================================================================
-- CONFIG PERSISTENCE
-- ============================================================================
local function getConfigFilePath()
    local myName = 'Default'
    local ok, name = pcall(function() return mq.TLO.Me.CleanName() end)
    if ok and name and name ~= '' then myName = name end
    return string.format('%s/triune_ldon_%s.lua', cfg, myName)
end

local function saveConfig()
    local file = io.open(getConfigFilePath(), 'w')
    if not file then return end
    file:write('-- Triune LDoN Runner Config\nreturn {\n')
    file:write(string.format('    camp = %q,\n', settings.camp))
    file:write(string.format('    charName = %q,\n', settings.charName))
    file:write(string.format('    riskIndex = %d,\n', settings.riskIndex))
    file:write(string.format('    typeIndex = %d,\n', settings.typeIndex))
    file:write(string.format('    maxClearMin = %d,\n', settings.maxClearMin))
    file:write('}\n')
    file:close()
end

local function loadConfig()
    local chunk = loadfile(getConfigFilePath())
    if not chunk then return end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= 'table' then return end
    if CAMPS[data.camp] then settings.camp = data.camp end
    if type(data.charName) == 'string' then settings.charName = data.charName end
    settings.riskIndex = tonumber(data.riskIndex) or settings.riskIndex
    settings.typeIndex = tonumber(data.typeIndex) or settings.typeIndex
    settings.maxClearMin = tonumber(data.maxClearMin) or settings.maxClearMin
end

-- ============================================================================
-- TLO HELPERS
-- ============================================================================
local function tlo(fn, default)
    local ok, v = pcall(fn)
    if ok and v ~= nil then return v end
    return default
end

local function zoneShort() return string.lower(tlo(function() return mq.TLO.Zone.ShortName() end, '') or '') end
local function zoneId() return tlo(function() return mq.TLO.Zone.ID() end, 0) end
local function navActive() return tlo(function() return mq.TLO.Navigation.Active() end, false) == true end
local function meshLoaded() return tlo(function() return mq.TLO.Navigation.MeshLoaded() end, false) == true end
local function inZone(z) return zoneShort() == string.lower(z or '') end

local function distTo(y, x)
    local my = tlo(function() return mq.TLO.Me.Y() end)
    local mx = tlo(function() return mq.TLO.Me.X() end)
    if not my or not mx then return 99999 end
    return math.sqrt((my - y) ^ 2 + (mx - x) ^ 2)
end

local function spawnDist(id)
    return tlo(function() return mq.TLO.Spawn('id ' .. id).Distance() end, 99999)
end

local function windowOpen(name)
    return tlo(function() return mq.TLO.Window(name).Open() end, false) == true
end

local function pluginLoaded(name)
    return tlo(function() return mq.TLO.Plugin(name).IsLoaded() end, false) == true
end

local function triuneRunning()
    local status = tlo(function() return mq.TLO.Lua.Script('triune').Status() end, '')
    return tostring(status):lower() == 'running'
end

-- ============================================================================
-- ABORT + WAIT
-- ----------------------------------------------------------------------------
-- fail() ends the current session (the macro's /endmacro). The script itself
-- stays loaded so the window remains open and you can start again.
-- ============================================================================
local function fail(fmt, ...)
    local msg = select('#', ...) > 0 and string.format(fmt, ...) or fmt
    error({ ldonAbort = true, msg = msg }, 0)
end

local function checkInterrupt()
    if state.stopRequested then fail('Stopped.') end
    if state.died then fail('Died on run #%d. Ending.', state.runs) end
end

-- Wait up to ms for cond() to be true (cond nil = plain sleep).
-- Returns whether cond was met. Keeps events and stop requests flowing.
local function waitFor(ms, cond)
    local deadline = mq.gettime() + ms
    while true do
        if cond and tlo(cond, false) then return true end
        if mq.gettime() >= deadline then return cond == nil end
        mq.delay(100)
        mq.doevents()
        checkInterrupt()
    end
end

local function sleep(ms) waitFor(ms) end

local function cleanupMovement()
    mq.cmd('/nav stop')
    mq.cmd('/moveto off')
    mq.cmd('/keypress forward')
end

-- ============================================================================
-- ROUTES
-- ============================================================================
-- Report any zone crossing on this path that isn't built in
local function checkPath(fromZone, path)
    local missing = 0
    local prev = fromZone
    for _, z in ipairs(path or {}) do
        local name = prev .. '_to_' .. z
        if not ROUTES[name] then
            log('Missing zone crossing: %s is not built in (see ROUTES).', name)
            missing = missing + 1
        end
        prev = z
    end
    return missing
end

-- Travel one built-in route
local function runRoute(name)
    local r = ROUTES[name]
    if not r then fail('Zone crossing [%s] is not built in (see ROUTES). Ending.', name) end
    if not inZone(r.zone) then fail("Route [%s] starts in %s but I'm in %s. Ending.", name, r.zone, zoneShort()) end
    if not meshLoaded() then fail('Route [%s] needs a navmesh for %s, and none is loaded. Ending.', name, zoneShort()) end
    log('Running route [%s]', name)
    setStep('Route %s', name)

    local startZone = zoneId()
    local function left() return zoneId() ~= startZone end
    local pts = r.points
    local n = #pts

    -- Nav to the recorded zone line. If nav can't path to the very last point
    -- (it is often just off the mesh), fall back to an earlier recorded point
    -- and walk the rest.
    local i = n
    while true do
        local p = pts[i]
        if i == n and r.lastZ then
            mq.cmdf('/nav locyxz %.2f %.2f %.2f', p[1], p[2], r.lastZ)
        else
            mq.cmdf('/nav locyx %.2f %.2f', p[1], p[2])
        end
        sleep(2000)
        if not navActive() and not left() and distTo(p[1], p[2]) > 40 then
            i = i - 1
            if i < 1 or i < n - 10 then
                fail("Nav can't path to the end of route [%s]. Re-record it, or check this zone's mesh. Ending.", name)
            end
        else
            break
        end
    end
    if i < n then log('Nav is using point %d of %d, walking the rest.', i, n) end

    waitFor(15 * 60 * 1000, function() return not navActive() or left() end)
    if not left() then
        if distTo(pts[i][1], pts[i][2]) > 40 then
            fail('Nav stopped before reaching the zone line for [%s]. Ending.', name)
        end
        for j = i + 1, n do
            local p = pts[j]
            mq.cmdf('/moveto loc %.2f %.2f', p[1], p[2])
            waitFor(30000, function() return left() or distTo(p[1], p[2]) <= 12 end)
            if left() then break end
            if distTo(p[1], p[2]) > 12 then
                mq.cmd('/moveto off')
                fail('Stuck on route [%s] at point %d. Ending.', name, j)
            end
        end
    end

    if not left() then
        -- keep running the way you were facing until the zone line takes us
        mq.cmd('/moveto off')
        mq.cmdf('/face fast heading %.2f', r.heading)
        mq.cmd('/keypress forward hold')
        waitFor(20000, left)
        mq.cmd('/keypress forward')
        if not left() then fail("Route [%s] finished but I didn't zone. Ending.", name) end
    end
    sleep(5000)
end

-- Travel through a list of zones, one crossing at a time
local function travelPath(path)
    if not path or #path == 0 then return end
    -- if I'm already in one of the zones on the path, continue from there
    local first = 1
    for idx, z in ipairs(path) do
        if inZone(z) then first = idx + 1 end
    end
    for idx = first, #path do
        runRoute(zoneShort() .. '_to_' .. path[idx])
    end
end

-- ============================================================================
-- ADVENTURE STEPS
-- ============================================================================
local function camp() return CAMPS[settings.camp] end

local function getAdventure()
    local c = camp()
    setStep('Requesting adventure from %s', c.questNPC)
    local npcID = tlo(function() return mq.TLO.Spawn('npc ' .. c.questNPC).ID() end, 0)
    if npcID == 0 then fail("Can't find %s. Ending.", c.questNPC) end

    if c.campSpot then
        -- come in through the clear spot, then walk straight to the NPC
        if spawnDist(npcID) > 80 and meshLoaded() then
            mq.cmdf('/nav locyxz %.2f %.2f %.2f', c.campSpot.y, c.campSpot.x, c.campSpot.z)
            sleep(1000)
            waitFor(5 * 60 * 1000, function() return not navActive() end)
        end
        mq.cmdf('/moveto id %d', npcID)
        sleep(1000)
        waitFor(30000, function() return mq.TLO.MoveTo.Stopped() end)
    elseif spawnDist(npcID) > 15 then
        mq.cmdf('/nav id %d', npcID)
        sleep(1000)
        waitFor(5 * 60 * 1000, function() return not navActive() end)
    end
    if spawnDist(npcID) > 30 then fail("Couldn't get to %s. Ending.", c.questNPC) end

    mq.cmdf('/target id %d', npcID)
    waitFor(2000, function() return mq.TLO.Target.ID() == npcID end)
    mq.cmd('/face fast')

    mq.cmd('/click right target')
    waitFor(5000, function() return windowOpen('AdventureRequestWnd') end)
    if not windowOpen('AdventureRequestWnd') then fail("Adventure window didn't open. Ending.") end
    mq.cmdf('/notify AdventureRequestWnd AdvRqst_RiskCombobox listselect %d', settings.riskIndex)
    sleep(500)
    mq.cmdf('/notify AdventureRequestWnd AdvRqst_TypeCombobox listselect %d', settings.typeIndex)
    sleep(500)
    mq.cmd('/notify AdventureRequestWnd AdvRqst_RequestButton leftmouseup')
    waitFor(10000, function()
        return mq.TLO.Window('AdventureRequestWnd').Child('AdvRqst_AcceptButton').Enabled()
    end)
    sleep(500)

    -- Which entrance does this adventure use?
    state.useEnt2 = false
    if c.ent2Names then
        local text = tlo(function()
            return mq.TLO.Window('AdventureRequestWnd').Child('AdvRqst_NPCText').Text()
        end, '') or ''
        text = text:lower()
        for _, nm in ipairs(c.ent2Names) do
            if text:find(nm:lower(), 1, true) then state.useEnt2 = true end
        end
    end
    if state.useEnt2 then log('This adventure uses the second entrance.') end

    mq.cmd('/notify AdventureRequestWnd AdvRqst_AcceptButton leftmouseup')
    sleep(2000)
end

-- Port by talking to a Magus. m = { say, name, exit }
local function useMagus(m)
    setStep('Porting with %s (%s)', m.name or 'Magus', m.say)
    local startZone = zoneShort()
    local mid = tlo(function() return mq.TLO.NearestSpawn('npc ' .. (m.name or 'Magus')).ID() end, 0)
    -- if the named Magus isn't here, use whichever Magus is closest
    if mid == 0 then mid = tlo(function() return mq.TLO.NearestSpawn('npc Magus').ID() end, 0) end
    if mid == 0 then
        log('No Magus found in %s.', startZone)
        return
    end
    if spawnDist(mid) > 15 then
        mq.cmdf('/nav id %d', mid)
        sleep(1000)
        waitFor(3 * 60 * 1000, function() return not navActive() end)
    end
    mq.cmdf('/target id %d', mid)
    waitFor(2000, function() return mq.TLO.Target.ID() == mid end)
    mq.cmd('/face fast')
    sleep(500)
    mq.cmdf('/say %s', m.say)
    waitFor(30000, function() return not inZone(startZone) end)
    sleep(5000)
    if inZone(startZone) then
        log("The Magus didn't port me.")
        return
    end
    -- walk straight out of the arrival camp before nav takes over
    if m.exit then
        mq.cmdf('/moveto loc %.2f %.2f', m.exit.y, m.exit.x)
        waitFor(30000, function() return distTo(m.exit.y, m.exit.x) <= 15 end)
        mq.cmd('/moveto off')
        if distTo(m.exit.y, m.exit.x) > 15 then
            log("Didn't reach the clear spot after the port, carrying on from here.")
        end
    end
end

-- From the landing zone back to the camp: run the return path, then use
-- the Magus if this camp's trip back needs one
local function returnToCamp()
    local c = camp()
    travelPath(c.returnPath)
    if c.retMagus and not inZone(c.campZone) then useMagus(c.retMagus) end
    if not inZone(c.campZone) then
        fail("Couldn't get back to %s (I'm in %s). Ending.", c.campZone, zoneShort())
    end
end

-- Walk straight from the NPC to the clear spot outside the camp
local function leaveCamp()
    local s = camp().campSpot
    setStep('Leaving camp')
    mq.cmdf('/moveto loc %.2f %.2f', s.y, s.x)
    waitFor(30000, function() return distTo(s.y, s.x) <= 15 end)
    mq.cmd('/moveto off')
    if distTo(s.y, s.x) > 15 then fail("Couldn't reach the spot outside the camp. Ending.") end
end

local function enterDungeon()
    local c = camp()
    local e = state.useEnt2 and c.ent2 or c.ent1
    local startZone = zoneShort()
    setStep('Entering dungeon')

    if not inZone(e.zone) then fail("The entrance is in %s but I'm in %s. Ending.", e.zone, startZone) end
    if not meshLoaded() then fail("No navmesh for %s, can't get to the entrance. Ending.", startZone) end
    if e.z then
        mq.cmdf('/nav locyxz %.2f %.2f %.2f', e.y, e.x, e.z)
    else
        mq.cmdf('/nav locyx %.2f %.2f', e.y, e.x)
    end
    sleep(1000)
    waitFor(10 * 60 * 1000, function() return not navActive() end)
    if distTo(e.y, e.x) > 40 then fail("Couldn't reach the dungeon entrance. Ending.") end

    for _ = 1, 3 do
        -- use the entrance's switch ID if the camp gives one, otherwise the nearest switch
        if e.door and e.door > 0 then
            mq.cmdf('/doortarget id %d', e.door)
        else
            mq.cmd('/doortarget')
        end
        sleep(500)
        -- walk up to the switch if it's out of click range
        local dy = tlo(function() return mq.TLO.DoorTarget.Y() end)
        local dx = tlo(function() return mq.TLO.DoorTarget.X() end)
        if dy and dx and tlo(function() return mq.TLO.DoorTarget.Distance() end, 0) > 15 then
            mq.cmdf('/moveto loc %.2f %.2f', dy, dx)
            waitFor(10000, function() return mq.TLO.DoorTarget.Distance() < 15 end)
            mq.cmd('/moveto off')
        end
        mq.cmd('/face fast door')
        sleep(300)
        mq.cmd('/click left door')
        waitFor(20000, function() return not inZone(startZone) end)
        if not inZone(startZone) then break end
    end
    if inZone(startZone) then fail("Couldn't enter the dungeon. Ending.") end
    sleep(5000)
end

local function clearDungeon()
    state.advWon = false
    setStep('Clearing dungeon (TAC puller)')
    mq.cmd(PULLER_MODE_CMD)
    sleep(1000)
    mq.cmd(PULLER_ON_CMD)

    waitFor(settings.maxClearMin * 60 * 1000, function() return state.advWon end)
    if not state.advWon then log('Timed out without a win message, leaving anyway.') end

    -- stop pulling, but keep fighting whatever is still on me
    setStep('Finishing combat')
    mq.cmd(PULLER_MANUAL_CMD)

    -- wait until I've been out of combat for 5 seconds straight
    local calm = 0
    local deadline = mq.gettime() + 10 * 60 * 1000
    while calm < 5 and mq.gettime() < deadline do
        if tlo(function() return mq.TLO.Me.CombatState() end, '') == 'COMBAT' then
            calm = 0
        else
            calm = calm + 1
        end
        sleep(1000)
    end
    if calm < 5 then
        fail("Still in combat 10 minutes after the adventure ended. Ending here so I don't port out mid-fight.")
    end

    mq.cmd(PULLER_OFF_CMD)
    sleep(2000)
end

-- In the Bazaar: walk to the map and port to this camp's waypoint
local function mapPort()
    local c = camp()
    setStep('Bazaar map to %s', c.map.waypoint)

    -- Walk to the map. The landing spot is random, so try nav, and if it
    -- can't start from here, step toward the map and try again.
    local tries = 0
    while distTo(MAP_Y, MAP_X) > 15 and tries < 15 do
        tries = tries + 1
        local navigated = false
        if meshLoaded() then
            mq.cmdf('/nav locyxz %.2f %.2f %.2f', MAP_Y, MAP_X, MAP_Z)
            sleep(1000)
            if navActive() then
                waitFor(3 * 60 * 1000, function() return not navActive() end)
                navigated = true
            end
        end
        if not navigated then
            mq.cmdf('/moveto loc %.2f %.2f', MAP_Y, MAP_X)
            waitFor(4000, function() return distTo(MAP_Y, MAP_X) < 15 end)
            mq.cmd('/moveto off')
        end
    end
    if distTo(MAP_Y, MAP_X) > 25 then fail("Couldn't get to the map from here. Ending.") end

    -- Click the map and pick this camp's waypoint
    mq.cmdf('/doortarget id %d', MAP_SWITCH_ID)
    sleep(500)
    mq.cmd('/face fast door')
    mq.cmd('/click left door')
    waitFor(5000, function() return windowOpen('WaypointsWnd') end)
    if not windowOpen('WaypointsWnd') then fail("The map window didn't open. Ending.") end
    mq.cmdf('/notify WaypointsWnd ContinentsList listselect %d', c.map.continent)
    sleep(1000)
    -- a camp can give the row number directly; otherwise look the waypoint up by name
    local row = c.map.row or tlo(function()
        return mq.TLO.Window('WaypointsWnd').Child('WaypointsList').List('=' .. c.map.waypoint)()
    end, 0)
    if not row or row == 0 then fail("Couldn't find %s in the waypoint list. Ending.", c.map.waypoint) end
    mq.cmdf('/notify WaypointsWnd WaypointsList listselect %d', row)
    sleep(500)
    mq.cmd('/notify WaypointsWnd SelectedWaypointButton leftmouseup')
    sleep(2000)
    -- answer a confirmation box if one pops up
    if windowOpen('ConfirmationDialogBox') then mq.cmd('/notify ConfirmationDialogBox Yes_Button leftmouseup') end
    if windowOpen('LargeDialogWindow') then mq.cmd('/notify LargeDialogWindow LDW_YesButton leftmouseup') end
    waitFor(60000, function() return inZone(c.landZone) end)
    sleep(5000)
    if not inZone(c.landZone) then
        fail("Expected to land in %s but I'm in %s. Ending.", c.landZone, zoneShort())
    end
end

local function leaveDungeon()
    setStep('Bazaar and Back')
    waitFor(3 * 60 * 1000, function() return mq.TLO.Me.AltAbilityReady(BAZAAR_AA_ID)() end)
    mq.cmdf('/alt activate %d', BAZAAR_AA_ID)
    waitFor(60000, function() return inZone('bazaar') end)
    sleep(5000)
    if not inZone('bazaar') then fail("Bazaar and Back didn't take me to the Bazaar. Ending.") end
    mapPort()
end

-- ============================================================================
-- SESSION
-- ============================================================================
local function preflight()
    local c = camp()
    if settings.charName ~= '' then
        local me = tlo(function() return mq.TLO.Me.CleanName() end, '')
        if me:lower() ~= settings.charName:lower() then
            fail('This is set up for %s. Ending.', settings.charName)
        end
    end
    if not c.map or not c.map.waypoint then
        fail("The return trip for camp [%s] isn't set up yet (map waypoint, landing zone, path back). Ending.", settings.camp)
    end
    if not pluginLoaded('MQ2Nav') then fail('MQ2Nav is not loaded (/plugin mq2nav). Ending.') end
    if not pluginLoaded('MQ2MoveUtils') then fail('MQ2MoveUtils is not loaded (/plugin mq2moveutils). Ending.') end
    if not triuneRunning() then
        log('Warning: triune.lua does not look like it is running, so the /ac puller commands may do nothing.')
    end
    local missing = 0
    -- with a Magus shortcut the run to the entrance is only a fallback, so don't require its routes
    if not c.magus then missing = missing + checkPath(c.campZone, c.ent1.path) end
    if c.ent2 then missing = missing + checkPath(c.campZone, c.ent2.path) end
    missing = missing + checkPath(c.landZone, c.returnPath)
    if missing > 0 then fail('%d zone crossing(s) missing for camp [%s]. Ending.', missing, settings.camp) end
end

local function getToCamp()
    local c = camp()
    if inZone('bazaar') then
        log('Starting in the Bazaar: taking the map and heading to camp.')
        mapPort()
        returnToCamp()
    end
    if not inZone(c.campZone) then
        local onReturnPath = false
        for _, z in ipairs(c.returnPath) do
            if inZone(z) then onReturnPath = true end
        end
        if inZone(c.landZone) or onReturnPath then
            log('Starting in %s: heading to camp.', zoneShort())
            returnToCamp()
        end
    end
    if not inZone(c.campZone) then
        log('Starting in %s: going to the Bazaar, then to camp.', zoneShort())
        leaveDungeon()
        returnToCamp()
    end
    if not inZone(c.campZone) then
        fail("Couldn't get to %s (I'm in %s). Ending.", c.campZone, zoneShort())
    end
end

local function adventureLoop()
    local c = camp()
    preflight()
    log('Running camp [%s] with recruiter %s.', settings.camp, c.questNPC)
    getToCamp()

    while true do
        if state.skipGet then
            log('Skipping the adventure request for this loop (assuming the first entrance).')
            state.useEnt2 = false
        else
            getAdventure()
        end
        state.skipGet = false
        if c.campSpot then leaveCamp() end
        if state.useEnt2 then
            setStep('Travelling to entrance')
            travelPath(c.ent2.path)
        else
            if c.magus then useMagus(c.magus) end
            setStep('Travelling to entrance')
            -- does nothing if the Magus already put us in the entrance zone
            travelPath(c.ent1.path)
        end
        enterDungeon()
        clearDungeon()
        leaveDungeon()
        returnToCamp()
        state.runs = state.runs + 1
        log('Finished run #%d', state.runs)
    end
end

local function runSession()
    state.active = true
    state.stopRequested = false
    state.died = false
    state.advWon = false
    state.startedAt = mq.gettime()
    local ok, err = pcall(adventureLoop)
    if not ok then
        if type(err) == 'table' and err.ldonAbort then
            log(err.msg)
        else
            log('Error: %s', tostring(err))
        end
    end
    cleanupMovement()
    state.active = false
    state.stopRequested = false
    state.skipGet = false
    setStep('Idle')
end

local function requestStart(campName, skip)
    if state.active then
        log('Already running camp [%s]. Use /ldon stop first.', settings.camp)
        return
    end
    if campName then
        if not CAMPS[campName] then
            log('Unknown camp [%s]. Use one of: sro ep bm ec nro', campName)
            return
        end
        settings.camp = campName
        saveConfig()
    end
    state.skipGet = skip and true or false
    state.startRequested = true
end

local function requestStop()
    if state.active then
        state.stopRequested = true
        log('Stopping after the current step...')
    end
end

-- ============================================================================
-- EVENTS
-- ============================================================================
mq.event('LDoN_AdvWon', '#*#You have successfully completed your adventure#*#', function()
    if state.active then state.advWon = true end
end)
mq.event('LDoN_Slain', '#*#You have been slain#*#', function()
    if state.active then state.died = true end
end)

-- ============================================================================
-- COMMANDS
-- ============================================================================
local function parseStartArgs(a, b)
    local campName, skip = nil, false
    for _, v in ipairs({ a, b }) do
        if v and v ~= '' then
            v = v:lower()
            if v == 'skip' then skip = true else campName = v end
        end
    end
    return campName, skip
end

local function ldonCommand(...)
    local args = { ... }
    local cmd = (args[1] or ''):lower()
    if cmd == 'start' or cmd == 'run' then
        local campName, skip = parseStartArgs(args[2], args[3])
        requestStart(campName, skip)
    elseif cmd == 'stop' then
        requestStop()
    elseif cmd == 'camp' then
        local campName = (args[2] or ''):lower()
        if state.active then
            log("Can't change camp while running.")
        elseif CAMPS[campName] then
            settings.camp = campName
            saveConfig()
            log('Camp set to [%s] %s.', campName, CAMPS[campName].label)
        else
            log('Unknown camp [%s]. Use one of: sro ep bm ec nro', campName)
        end
    elseif cmd == 'status' then
        log('%s | camp [%s] | runs %d | %s', state.active and 'Running' or 'Idle', settings.camp, state.runs, state.step)
    elseif cmd == 'show' then
        state.openGUI = true
    elseif cmd == 'hide' then
        state.openGUI = false
    elseif cmd == 'toggle' or cmd == '' then
        state.openGUI = not state.openGUI
    elseif cmd == 'quit' or cmd == 'exit' then
        requestStop()
        state.isRunning = false
    else
        print(TAG .. 'usage: /ldon [start [camp] [skip]|stop|camp <sro|ep|bm|ec|nro>|status|show|hide|toggle|quit]')
    end
end

-- ============================================================================
-- THEME (matches the other Triune tools)
-- ============================================================================
local _colN, _varN = 0, 0
local function pushCol(id, r, g, b, a)
    if id == nil then return end
    if pcall(ImGui.PushStyleColor, id, r, g, b, a) then _colN = _colN + 1 end
end
local function pushVar(id, a, b)
    if id == nil then return end
    local ok
    if b ~= nil then
        if type(_G.ImVec2) == 'function' then
            ok = pcall(ImGui.PushStyleVar, id, ImVec2(a, b))
        else
            ok = pcall(ImGui.PushStyleVar, id, a, b)
        end
    else
        ok = pcall(ImGui.PushStyleVar, id, a)
    end
    if ok then _varN = _varN + 1 end
end

local function pushTheme()
    _colN, _varN = 0, 0
    if ImGuiCol then
        pushCol(ImGuiCol.WindowBg, 0.059, 0.086, 0.133, 1)
        pushCol(ImGuiCol.ChildBg, 0.055, 0.082, 0.125, 1)
        pushCol(ImGuiCol.PopupBg, 0.047, 0.075, 0.118, 1)
        pushCol(ImGuiCol.Border, 0.157, 0.251, 0.345, 1)
        pushCol(ImGuiCol.Text, 0.851, 0.898, 0.953, 1)
        pushCol(ImGuiCol.TextDisabled, 0.490, 0.561, 0.651, 1)
        pushCol(ImGuiCol.TitleBg, 0.043, 0.067, 0.106, 1)
        pushCol(ImGuiCol.TitleBgActive, 0.047, 0.078, 0.125, 1)
        pushCol(ImGuiCol.FrameBg, 0.047, 0.078, 0.125, 1)
        pushCol(ImGuiCol.FrameBgHovered, 0.090, 0.150, 0.220, 1)
        pushCol(ImGuiCol.FrameBgActive, 0.120, 0.190, 0.270, 1)
        pushCol(ImGuiCol.Button, 0.086, 0.125, 0.196, 1)
        pushCol(ImGuiCol.ButtonHovered, 0.300, 0.700, 1.000, 0.35)
        pushCol(ImGuiCol.ButtonActive, 0.300, 0.700, 1.000, 0.60)
        pushCol(ImGuiCol.Header, 0.078, 0.129, 0.204, 1)
        pushCol(ImGuiCol.HeaderHovered, 0.160, 0.440, 0.700, 0.50)
        pushCol(ImGuiCol.HeaderActive, 0.160, 0.500, 0.750, 0.70)
        pushCol(ImGuiCol.CheckMark, 0.370, 0.880, 0.640, 1)
        pushCol(ImGuiCol.Separator, 0.157, 0.251, 0.345, 1)
    end
    if ImGuiStyleVar then
        pushVar(ImGuiStyleVar.WindowRounding, 6)
        pushVar(ImGuiStyleVar.ChildRounding, 5)
        pushVar(ImGuiStyleVar.FrameRounding, 4)
        pushVar(ImGuiStyleVar.FrameBorderSize, 1)
        pushVar(ImGuiStyleVar.FramePadding, 7, 4)
        pushVar(ImGuiStyleVar.ItemSpacing, 8, 6)
        pushVar(ImGuiStyleVar.WindowPadding, 12, 10)
    end
end

local function popTheme()
    if _varN > 0 then pcall(ImGui.PopStyleVar, _varN); _varN = 0 end
    if _colN > 0 then pcall(ImGui.PopStyleColor, _colN); _colN = 0 end
end

-- ============================================================================
-- IMGUI DRAW CALLBACK
-- ============================================================================
local CAMP_LABELS = {}
for i, key in ipairs(CAMP_ORDER) do CAMP_LABELS[i] = string.format('%s - %s', key, CAMPS[key].label) end

local function campIndex()
    for i, key in ipairs(CAMP_ORDER) do
        if key == settings.camp then return i end
    end
    return 1
end

local function statusDot(ok, label)
    if ok then
        ImGui.TextColored(0.37, 0.88, 0.64, 1, '[OK]')
    else
        ImGui.TextColored(0.95, 0.35, 0.35, 1, '[!!]')
    end
    ImGui.SameLine()
    ImGui.Text(label)
end

local function formatElapsed(ms)
    local s = math.floor(ms / 1000)
    return string.format('%d:%02d:%02d', math.floor(s / 3600), math.floor(s / 60) % 60, s % 60)
end

local function DrawLDoNUI()
    if not state.openGUI then return end

    pushTheme()
    local open, draw = ImGui.Begin('Triune LDoN Runner v' .. VERSION .. '##TriuneLDoN', state.openGUI)
    state.openGUI = open
    if draw and open then
        -- Status
        if state.active then
            ImGui.TextColored(0.37, 0.88, 0.64, 1, 'RUNNING')
            ImGui.SameLine()
            ImGui.Text(string.format('[%s]  runs: %d  elapsed: %s', settings.camp, state.runs,
                formatElapsed(mq.gettime() - state.startedAt)))
        else
            ImGui.TextDisabled('IDLE')
            ImGui.SameLine()
            ImGui.Text(string.format('runs this session: %d', state.runs))
        end
        ImGui.TextColored(0.30, 0.70, 1.00, 1, 'Step:')
        ImGui.SameLine()
        ImGui.Text(state.step)
        ImGui.Separator()

        -- Settings (locked while running)
        if state.active then ImGui.BeginDisabled() end
        ImGui.PushItemWidth(260)
        local idx, changed = ImGui.Combo('Camp##ldonCamp', campIndex(), CAMP_LABELS)
        if changed and CAMP_ORDER[idx] then
            settings.camp = CAMP_ORDER[idx]
            saveConfig()
        end
        ImGui.PopItemWidth()

        ImGui.PushItemWidth(110)
        local risk, rChanged = ImGui.InputInt('Risk row##ldonRisk', settings.riskIndex)
        if rChanged then settings.riskIndex = math.max(1, risk); saveConfig() end
        if ImGui.IsItemHovered() then ImGui.SetTooltip('Position in the adventure window Risk dropdown (2 = High)') end
        ImGui.SameLine()
        local typ, tChanged = ImGui.InputInt('Type row##ldonType', settings.typeIndex)
        if tChanged then settings.typeIndex = math.max(1, typ); saveConfig() end
        if ImGui.IsItemHovered() then ImGui.SetTooltip('Position in the adventure window Type dropdown (3 = Mob Count)') end
        local mins, mChanged = ImGui.InputInt('Max clear (min)##ldonMax', settings.maxClearMin)
        if mChanged then settings.maxClearMin = math.max(1, mins); saveConfig() end
        ImGui.PopItemWidth()

        local skip, sChanged = ImGui.Checkbox('Skip first request (already have an adventure)##ldonSkip', state.skipGet)
        if sChanged then state.skipGet = skip end
        if state.active then ImGui.EndDisabled() end

        ImGui.Separator()
        if state.active then
            if ImGui.Button('Stop##ldonStop', 120, 0) then requestStop() end
        else
            if ImGui.Button('Start##ldonStart', 120, 0) then requestStart(nil, state.skipGet) end
        end

        -- Requirements
        ImGui.Separator()
        statusDot(pluginLoaded('MQ2Nav'), 'MQ2Nav')
        ImGui.SameLine()
        statusDot(meshLoaded(), 'Mesh (' .. zoneShort() .. ')')
        ImGui.SameLine()
        statusDot(pluginLoaded('MQ2MoveUtils'), 'MoveUtils')
        ImGui.SameLine()
        statusDot(triuneRunning(), 'TAC')

        -- Log
        ImGui.Separator()
        if ImGui.BeginChild('##ldonLog', 0, 0, true) then
            for _, line in ipairs(state.log) do ImGui.TextWrapped(line) end
            if ImGui.GetScrollY() >= ImGui.GetScrollMaxY() then ImGui.SetScrollHereY(1.0) end
        end
        ImGui.EndChild()
    end
    ImGui.End()
    popTheme()
end

-- ============================================================================
-- MAIN
-- ============================================================================
loadConfig()
mq.unbind('/ldon')
mq.bind('/ldon', ldonCommand)
mq.imgui.init('TriuneLDoNUI', DrawLDoNUI)

log('Loaded v%s -- /ldon start [camp] [skip] to begin, /ldon to show or hide the window.', VERSION)

-- /lua run triune_ldon <camp> [skip] starts right away, like /mac ldon <camp> [skip]
local startArgs = { ... }
if #startArgs > 0 then
    local campName, skip = parseStartArgs(startArgs[1], startArgs[2])
    requestStart(campName or settings.camp, skip)
end

while state.isRunning do
    mq.doevents()
    if state.startRequested then
        state.startRequested = false
        runSession()
    end
    mq.delay(100)
end

mq.unbind('/ldon')
print(TAG .. 'Unloaded.')
