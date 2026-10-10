---@diagnostic disable: undefined-global, undefined-field
-- ============================================================================
-- TRIUNE LDON RUNNER v1.0 (Standalone ImGui Script)
-- ----------------------------------------------------------------------------
-- Lua port of ldon.mac: runs Lost Dungeons of Norrath adventures in a loop.
-- Requests an adventure, travels to the entrance, runs the TAC as puller until
-- the adventure completes, leaves through the Bazaar and returns to camp.
-- Compatible with MacroQuest LuaJIT (Lua 5.1 safe).
--
-- Run via:  /lua run triune_ldon [camp] [skip] [loop] [bail]
--   camp: sro (Deepest Guk)   ep (Miragul's)   bm (Mistmoore)
--         ec  (Rujarkian)     nro (Takish-Hiz)        default: sro
--   skip: already have an adventure and standing at the recruiter,
--         so don't request one on the first loop
--   loop: run one adventure at each camp in turn (sro ep bm ec nro, round
--         and round), starting at <camp>
--   bail: if nothing has been hit for BAIL_AFTER_MIN inside the dungeon (stuck
--         on a mob or a mesh trap), leave, drop the adventure and get a new one
--   If the recruiter refuses an adventure, a Magus ports me to another camp
--   (random unless a fallback camp is set), one loop is run there, then it goes back.
--   Passing a camp starts the loop right away; with no arguments the window
--   opens idle so you can pick a camp and press Start.
--
-- Commands:  /ldon start [camp] [skip] [loop] [bail] | stop | camp <name> | status
--            /ldon fallback <camp|random|none>
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
    -- If the recruiter refuses to give an adventure, run one loop at this camp
    -- instead (getting there by Magus), then go back.
    -- 'random' = any other camp, 'none' = just stop.
    fallbackCamp = 'random',
}

-- Triune auto combat puller
local PULLER_MODE_CMD   = '/ac puller'
local PULLER_ON_CMD     = '/ac run'
-- stops chasing new mobs but keeps fighting what's already on me
local PULLER_MANUAL_CMD = '/ac manual'
-- only sent once combat is completely over
local PULLER_OFF_CMD    = '/ac stop'

-- After the adventure is won: if I'm still in combat with no hits either way
-- for this many seconds, something is stuck on the hate list (it blocks Bazaar
-- and Back), so use the first of these I have that's ready to drop aggro.
local AGGRO_DROP_AFTER_SEC = 30

-- With bail on: minutes inside the dungeon with no hits either way before
-- giving up on the adventure (stuck on a mob or a mesh trap)
local BAIL_AFTER_MIN = 5

-- Adventures to turn down (Everfrost and Guk mesh trouble): if the
-- offer text names one, decline it and request again, as many times as it
-- takes. Only a real request error moves on to another camp.
local AVOID_DUNGEONS = { 'Maw of the Menagerie', 'Spider Den', 'Root Garden', 'Drowning Crypt' }
local AGGRO_DROP_LIST = { 'Fading Memories', 'Imitate Death', 'Death Peace', 'Escape', 'Feign Death' }

-- "Bazaar and Back" AA, and the map switch in the Bazaar
local BAZAAR_AA_ID  = 331
local MAP_Y, MAP_X, MAP_Z = -646.5, 2.9, 4.8
-- East Commonlands has the same map (Bazaar and Back can be set to land there)
local EC_MAP_Y, EC_MAP_X, EC_MAP_Z = -1511.4, -184.0, 4.4
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
-- magusSay:  what to say to a Magus to get to this camp's zone (used to reach a
--            fallback camp; the arrival spot is retMagus.exit)
-- An entrance z of nil means "let nav work out the height".
-- An entrance door is the switch ID to click (0 = nearest switch).
-- ============================================================================
local CAMP_ORDER = { 'sro', 'ep', 'bm', 'ec', 'nro' }

local CAMPS = {
    sro = {
        label     = 'Deepest Guk (South Ro)',
        campZone  = 'sro',
        magusSay  = 'South Ro',
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
        magusSay  = 'Everfrost',
        questNPC  = 'Mannis McGuyett',
        ent1      = { zone = 'everfrost', path = {}, y = -828, x = -5458, door = 0 },
        ent2Names = { 'Hushed Banquet', 'Heart of the Menagerie' },
        ent2      = { zone = 'everfrost', path = {}, y = 2771, x = -4725, door = 0 },
        -- Trip back: East Commonlands waypoint, then the Magus there ports to this camp
        -- (faster than the Everfrost waypoint and running).
        -- GUESS - confirm 'Everfrost' is the phrase Magus Zeir answers to
        map        = { continent = 1, waypoint = 'East Commonlands' },
        landZone   = 'ecommons',
        returnPath = {},
        retMagus   = { say = 'Everfrost', name = 'Magus Zeir' },
        -- Old trip back, the Everfrost waypoint:
        -- map = { continent = 1, waypoint = 'Everfrost' }, landZone = 'everfrost', retMagus = nil,
    },
    bm = {
        label     = "Mistmoore's Catacombs (Butcherblock)",
        -- entrances are in Lesser Faydark
        campZone  = 'butcher',
        magusSay  = 'Butcherblock',
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
        magusSay  = 'East Commonlands',
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
        magusSay  = 'North Ro',
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
    rotate = false,        -- loop: one adventure at each camp in turn
    bail = false,          -- give up on a stuck adventure
    bailed = false,        -- the last adventure was given up and is still active
    useEnt2 = false,
    advWon = false,
    died = false,
    lastHit = 0,
    runs = 0,
    step = 'Idle',
    startedAt = 0,
    log = {},
}

-- Debug log file (config\triune_ldon_debug.log): everything the window log
-- shows plus every chat line that mentions an adventure
local function dlog(fmt, ...)
    local msg = select('#', ...) > 0 and string.format(fmt, ...) or fmt
    local f = io.open(mq.configDir .. '/triune_ldon_debug.log', 'a')
    if f then
        f:write(string.format('%s run#%d [%s] %s: %s\n', os.date('%Y-%m-%d %H:%M:%S'), state.runs,
            tostring(state.campKey or settings.camp), tostring(mq.TLO.Zone.ShortName() or '?'), msg))
        f:close()
    end
end

local function log(fmt, ...)
    local msg = select('#', ...) > 0 and string.format(fmt, ...) or fmt
    print(TAG .. msg)
    table.insert(state.log, os.date('%H:%M:%S') .. '  ' .. msg)
    while #state.log > 60 do table.remove(state.log, 1) end
    dlog('%s', msg)
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
    file:write(string.format('    fallbackCamp = %q,\n', settings.fallbackCamp))
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
    if CAMPS[data.fallbackCamp] or data.fallbackCamp == 'random' or data.fallbackCamp == 'none' then
        settings.fallbackCamp = data.fallbackCamp
    end
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
-- state.campKey is the camp being run right now; it differs from settings.camp
-- only during a fallback loop
local function camp() return CAMPS[state.campKey or settings.camp] end

-- The camp to run one loop at when the recruiter at key refuses (nil = stop)
local function fallbackFor(key)
    local fb = settings.fallbackCamp
    if fb == 'none' then return nil end
    if CAMPS[fb] and fb ~= key then return fb end
    local others = {}
    for _, k in ipairs(CAMP_ORDER) do
        if k ~= key then table.insert(others, k) end
    end
    return others[math.random(#others)]
end

local function npcText()
    local text = tlo(function()
        return mq.TLO.Window('AdventureRequestWnd').Child('AdvRqst_NPCText').Text()
    end, '') or ''
    if text == '' then return '(no text in the adventure window)' end
    return text
end

-- Drop invisibility so NPCs will talk to me
local function makeVisible()
    if not tlo(function() return mq.TLO.Me.Invis() end, false) then return end
    log('Dropping invisibility so the NPC will answer.')
    mq.cmd('/makemevisible')
    waitFor(3000, function() return not mq.TLO.Me.Invis() end)
    sleep(500)
end

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

    -- NPCs ignore me while I'm invisible (Imitate Death, Fading Memories, ...);
    -- if there's no answer, drop any invis that slipped through and try once more
    for _ = 1, 2 do
        makeVisible()
        mq.cmd('/click right target')
        if waitFor(15000, function() return windowOpen('AdventureRequestWnd') end) then break end
    end
    if not windowOpen('AdventureRequestWnd') then fail("Adventure window didn't open. Ending.") end
    local function advChild(name) return mq.TLO.Window('AdventureRequestWnd').Child(name) end
    -- after a bail the old adventure is still mine, so leave it first
    -- (the Decline button is "Leave" while I have one)
    if state.bailed then
        sleep(1000)
        if tlo(function() return advChild('AdvRqst_DeclineButton').Enabled() end, false) then
            log('Leaving the unfinished adventure.')
            mq.cmd('/notify AdventureRequestWnd AdvRqst_DeclineButton leftmouseup')
            waitFor(5000, function() return windowOpen('ConfirmationDialogBox') or windowOpen('LargeDialogWindow') end)
            if windowOpen('ConfirmationDialogBox') then mq.cmd('/notify ConfirmationDialogBox Yes_Button leftmouseup') end
            if windowOpen('LargeDialogWindow') then mq.cmd('/notify LargeDialogWindow LDW_YesButton leftmouseup') end
            sleep(3000)
        end
        state.bailed = false
        if not windowOpen('AdventureRequestWnd') then
            mq.cmd('/click right target')
            waitFor(15000, function() return windowOpen('AdventureRequestWnd') end)
        end
    end
    -- wait for each dropdown to take before the next click (laggy zones)
    local function setDropdowns()
        sleep(1000)
        mq.cmdf('/notify AdventureRequestWnd AdvRqst_RiskCombobox listselect %d', settings.riskIndex)
        waitFor(5000, function() return advChild('AdvRqst_RiskCombobox').GetCurSel() == settings.riskIndex end)
        mq.cmdf('/notify AdventureRequestWnd AdvRqst_TypeCombobox listselect %d', settings.typeIndex)
        waitFor(5000, function() return advChild('AdvRqst_TypeCombobox').GetCurSel() == settings.typeIndex end)
        sleep(500)
    end
    setDropdowns()

    -- The Accept button only lights up when the server offers an adventure.
    -- On an error (already have one, not eligible, ...) the server puts the
    -- reason in the window text and Accept stays greyed out, so retry a couple
    -- of times and then stop instead of travelling without an adventure.
    local function acceptEnabled()
        return mq.TLO.Window('AdventureRequestWnd').Child('AdvRqst_AcceptButton').Enabled()
    end
    local function avoidHit()
        local text = npcText():lower()
        for _, nm in ipairs(AVOID_DUNGEONS) do
            if text:find(nm:lower(), 1, true) then return nm end
        end
    end
    -- Only a real request error counts as a try; an offer on the avoid list is
    -- declined and asked again as many times as it takes.
    local offered = false
    local attempt, avoided = 0, 0
    while attempt < 3 do
        mq.cmd('/notify AdventureRequestWnd AdvRqst_RequestButton leftmouseup')
        if waitFor(20000, acceptEnabled) then
            sleep(500)
            -- turn down an adventure in a dungeon on the avoid list and ask again
            local hit = avoidHit()
            if not hit then
                offered = true
                break
            end
            avoided = avoided + 1
            log('Offer %d is in %s, which is on the avoid list. Declining it and asking again.', avoided, hit)
            mq.cmd('/notify AdventureRequestWnd AdvRqst_DeclineButton leftmouseup')
            waitFor(5000, function() return not acceptEnabled() end)
            -- after Decline the window greys everything out, so close it and
            -- talk to the recruiter again for a fresh one
            sleep(2000)
            mq.cmd('/windowstate AdventureRequestWnd close')
            waitFor(5000, function() return not windowOpen('AdventureRequestWnd') end)
            sleep(1000)
            mq.cmdf('/target id %d', npcID)
            waitFor(2000, function() return mq.TLO.Target.ID() == npcID end)
            for _ = 1, 2 do
                makeVisible()
                mq.cmd('/click right target')
                if waitFor(15000, function() return windowOpen('AdventureRequestWnd') end) then break end
            end
            if not windowOpen('AdventureRequestWnd') then
                fail("Adventure window didn't open again after declining. Ending.")
            end
            setDropdowns()
        else
            attempt = attempt + 1
            log('Adventure request %d of 3 was refused: %s', attempt, npcText())
            if attempt < 3 then sleep(5000) end
        end
    end
    if not offered then
        -- the main loop decides whether to try the fallback camp
        mq.cmd('/windowstate AdventureRequestWnd close')
        return false
    end
    sleep(500)

    -- Which entrance does this adventure use?
    state.useEnt2 = false
    if c.ent2Names then
        local text = npcText():lower()
        for _, nm in ipairs(c.ent2Names) do
            if text:find(nm:lower(), 1, true) then state.useEnt2 = true end
        end
    end
    if state.useEnt2 then log('This adventure uses the second entrance.') end

    -- Accept, and check it took: the button greys out (or the window closes)
    -- once the adventure is ours
    local function accepted()
        return not windowOpen('AdventureRequestWnd') or not acceptEnabled()
    end
    mq.cmd('/notify AdventureRequestWnd AdvRqst_AcceptButton leftmouseup')
    if not waitFor(5000, accepted) then
        mq.cmd('/notify AdventureRequestWnd AdvRqst_AcceptButton leftmouseup')
        if not waitFor(5000, accepted) then
            fail("Accepted the adventure but the window didn't confirm it: %s Ending.", npcText())
        end
    end
    log('Adventure accepted.')
    sleep(2000)
    return true
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
    -- NPCs ignore me while I'm invisible (Imitate Death, Fading Memories, ...);
    -- if there's no answer, drop any invis that slipped through and try once more
    for _ = 1, 2 do
        makeVisible()
        mq.cmdf('/say %s', m.say)
        if waitFor(30000, function() return not inZone(startZone) end) then break end
    end
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

-- Use the first aggro drop in AGGRO_DROP_LIST that I have and is ready
-- (AAs like Fading Memories / Imitate Death, or a skill like Feign Death)
local function dropAggro()
    for _, a in ipairs(AGGRO_DROP_LIST) do
        local aaId = tlo(function()
            if mq.TLO.Me.AltAbility(a)() and mq.TLO.Me.AltAbilityReady(a)() then
                return mq.TLO.Me.AltAbility(a).ID()
            end
        end)
        local skill = not aaId and tlo(function()
            return mq.TLO.Me.Ability(a)() and mq.TLO.Me.AbilityReady(a)()
        end, false)
        if aaId or skill then
            log('In combat with no hits for %ds, using %s to drop aggro.', AGGRO_DROP_AFTER_SEC, a)
            if aaId then mq.cmdf('/alt activate %d', aaId) else mq.cmdf('/doability "%s"', a) end
            waitFor(5000, function() return mq.TLO.Me.CombatState() ~= 'COMBAT' end)
            sleep(2000)
            -- feign death abilities leave me on the floor
            if tlo(function() return mq.TLO.Me.Feigning() end, false) then mq.cmd('/stand') end
            return
        end
    end
    log('In combat with no hits for %ds, but none of these is ready: %s', AGGRO_DROP_AFTER_SEC,
        table.concat(AGGRO_DROP_LIST, ', '))
end

local function clearDungeon()
    state.advWon = false
    setStep('Clearing dungeon (TAC puller)')
    dlog('clear start, sending %s and %s', PULLER_MODE_CMD, PULLER_ON_CMD)
    mq.cmd(PULLER_MODE_CMD)
    sleep(1000)
    mq.cmd(PULLER_ON_CMD)

    state.bailed = false
    state.lastHit = mq.gettime()
    local started = mq.gettime()
    local runSends, lastRunAt = 1, mq.gettime()
    waitFor(settings.maxClearMin * 60 * 1000, function()
        local now = mq.gettime()
        -- Triune pauses itself when it handles the zone-in, and in a laggy zone
        -- that can land after my run command. Send run again a few times early
        -- on, and again whenever a minute goes by with no hits ("already
        -- running" is harmless).
        if (runSends < 4 and now - started >= runSends * 10000)
            or (now - state.lastHit >= 60000 and now - lastRunAt >= 60000) then
            mq.cmd(PULLER_ON_CMD)
            runSends = runSends + 1
            lastRunAt = now
        end
        -- with bail on, give up when nothing has been hit for BAIL_AFTER_MIN
        if state.bail and now - state.lastHit >= BAIL_AFTER_MIN * 60 * 1000 then
            state.bailed = true
        end
        return state.advWon or state.bailed
    end)
    if state.bailed and not state.advWon then
        log('No hits for %d minutes (stuck?), giving up on this adventure.', BAIL_AFTER_MIN)
    elseif not state.advWon then
        log('Timed out without a win message, leaving anyway.')
    else
        log("Adventure complete, switching Triune to manual to finish what's on me.")
    end
    dlog('clear loop done: won=%s bailed=%s, sending %s', tostring(state.advWon), tostring(state.bailed), PULLER_MANUAL_CMD)

    -- stop pulling, but keep fighting whatever is still on me
    setStep('Finishing combat')
    mq.cmd(PULLER_MANUAL_CMD)

    -- wait until I've been out of combat for 5 seconds straight, and if a
    -- fight goes quiet (no hits either way) for AGGRO_DROP_AFTER_SEC, drop
    -- aggro so a stuck mob doesn't block Bazaar and Back
    local calm = 0
    local deadline = mq.gettime() + 10 * 60 * 1000
    state.lastHit = mq.gettime()
    local chasing = 0
    while calm < 5 and mq.gettime() < deadline do
        -- Triune should only be finishing what's on me now. If nothing is on
        -- my extended target list and it's still running somewhere, it's
        -- still pulling (the manual switch didn't take), so pause it.
        if tlo(function() return mq.TLO.Me.XTarget() end, 0) == 0 and navActive() then
            chasing = chasing + 1
            if chasing == 5 then
                log('Triune is still pulling after the adventure ended, pausing it.')
                mq.cmd(PULLER_OFF_CMD)
                mq.cmd('/nav stop')
            end
        else
            chasing = 0
        end
        if tlo(function() return mq.TLO.Me.CombatState() end, '') == 'COMBAT' then
            calm = 0
            if mq.gettime() - state.lastHit >= AGGRO_DROP_AFTER_SEC * 1000 then
                dropAggro()
                state.lastHit = mq.gettime()
            end
        else
            calm = calm + 1
            state.lastHit = mq.gettime()
        end
        sleep(1000)
    end
    if calm < 5 then
        fail("Still in combat 10 minutes after the adventure ended. Ending here so I don't port out mid-fight.")
    end

    dlog('out of combat, sending %s', PULLER_OFF_CMD)
    mq.cmd(PULLER_OFF_CMD)
    sleep(2000)
end

-- In the Bazaar: walk to the map and port to this camp's waypoint
local function mapPort()
    -- the map in East Commonlands is the same, just somewhere else
    local hub = zoneShort()
    local my, mx, mz = MAP_Y, MAP_X, MAP_Z
    if hub == 'ecommons' then my, mx, mz = EC_MAP_Y, EC_MAP_X, EC_MAP_Z end
    local c = camp()
    setStep('Bazaar map to %s', c.map.waypoint)

    -- Walk to the map. The landing spot is random, so try nav, and if it
    -- can't start from here, step toward the map and try again.
    local tries = 0
    while distTo(my, mx) > 15 and tries < 15 do
        tries = tries + 1
        local navigated = false
        if meshLoaded() then
            mq.cmdf('/nav locyxz %.2f %.2f %.2f', my, mx, mz)
            sleep(1000)
            if navActive() then
                waitFor(3 * 60 * 1000, function() return not navActive() end)
                navigated = true
            end
        end
        if not navigated then
            mq.cmdf('/moveto loc %.2f %.2f', my, mx)
            waitFor(4000, function() return distTo(my, mx) < 15 end)
            mq.cmd('/moveto off')
        end
    end
    if distTo(my, mx) > 25 then fail("Couldn't get to the map from here. Ending.") end

    -- Click the map and pick this camp's waypoint. A full Bazaar can lag badly,
    -- so wait for each window and list to be ready before the next click.
    local function child(name) return mq.TLO.Window('WaypointsWnd').Child(name) end
    for _ = 1, 3 do
        mq.cmdf('/doortarget id %d', MAP_SWITCH_ID)
        waitFor(5000, function() return mq.TLO.DoorTarget.ID() == MAP_SWITCH_ID end)
        mq.cmd('/face fast door')
        sleep(500)
        mq.cmd('/click left door')
        if waitFor(15000, function() return windowOpen('WaypointsWnd') end) then break end
    end
    if not windowOpen('WaypointsWnd') then fail("The map window didn't open. Ending.") end
    sleep(1000)
    mq.cmdf('/notify WaypointsWnd ContinentsList listselect %d', c.map.continent)
    waitFor(10000, function() return child('ContinentsList').GetCurSel() == c.map.continent end)
    waitFor(10000, function() return (child('WaypointsList').Items() or 0) > 0 end)
    sleep(1000)
    -- a camp can give the row number directly; otherwise look the waypoint up by name
    local function findRow() return child('WaypointsList').List('=' .. c.map.waypoint)() end
    local row = c.map.row
    if not row then
        waitFor(10000, function() return (findRow() or 0) > 0 end)
        row = tlo(findRow, 0)
    end
    if not row or row == 0 then fail("Couldn't find %s in the waypoint list. Ending.", c.map.waypoint) end
    mq.cmdf('/notify WaypointsWnd WaypointsList listselect %d', row)
    waitFor(5000, function() return child('WaypointsList').GetCurSel() == row end)
    sleep(500)
    mq.cmd('/notify WaypointsWnd SelectedWaypointButton leftmouseup')
    -- wait for a confirmation box, or for the port itself
    waitFor(10000, function()
        return windowOpen('ConfirmationDialogBox') or windowOpen('LargeDialogWindow') or not inZone(hub)
    end)
    sleep(500)
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
    local landZone = camp().landZone
    waitFor(60000, function() return inZone('bazaar') or inZone('ecommons') or inZone(landZone) end)
    sleep(5000)
    -- Bazaar and Back can be set to East Commonlands; if it already put us in
    -- this camp's landing zone, skip the walk to the map
    if inZone(landZone) then
        log('Bazaar and Back put me in %s, skipping the map.', landZone)
        return
    end
    -- otherwise use the map there (the Bazaar and East Commonlands both have one)
    if not inZone('bazaar') and not inZone('ecommons') then
        fail("Bazaar and Back didn't take me to the Bazaar, East Commonlands or %s. Ending.", landZone)
    end
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
        fail("The return trip for camp [%s] isn't set up yet (map waypoint, landing zone, path back). Ending.", state.campKey)
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
    if missing > 0 then fail('%d zone crossing(s) missing for camp [%s]. Ending.', missing, state.campKey) end
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

-- The camp after key in CAMP_ORDER, wrapping round
local function nextInRotation(key)
    for i, k in ipairs(CAMP_ORDER) do
        if k == key then return CAMP_ORDER[i % #CAMP_ORDER + 1] end
    end
    return CAMP_ORDER[1]
end

-- Port to a camp by the Magus right here (the Bazaar route in getToCamp is
-- only a backup if that doesn't work)
local function goToCamp(key)
    state.campKey = key
    local fc = camp()
    if not inZone(fc.campZone) then
        useMagus({ say = fc.magusSay, name = 'Magus', exit = fc.retMagus and fc.retMagus.exit })
    end
    getToCamp()
end

local function adventureLoop()
    local home = settings.camp
    local onFallback = false
    local refusals = 0
    state.campKey = home
    preflight()
    if state.rotate then
        log('Looping through every camp (%s), starting at [%s] with recruiter %s.',
            table.concat(CAMP_ORDER, ' '), home, camp().questNPC)
    else
        log('Running camp [%s] with recruiter %s (fallback camp: %s).', home, camp().questNPC, settings.fallbackCamp)
    end
    getToCamp()

    while true do
        local c = camp()
        local got = true
        if state.skipGet then
            log('Skipping the adventure request for this loop (assuming the first entrance).')
            state.useEnt2 = false
        else
            got = getAdventure()
        end
        state.skipGet = false
        if got then refusals = 0 end

        if not got and state.rotate then
            -- looping through every camp: a refusal just moves on to the next camp
            refusals = refusals + 1
            if refusals >= #CAMP_ORDER then
                fail('Every camp refused an adventure. If you already have one, start with skip. Ending.')
            end
            local nxt = nextInRotation(state.campKey)
            log("Couldn't get an adventure at [%s], moving on to [%s].", state.campKey, nxt)
            goToCamp(nxt)
        elseif not got then
            -- run one loop at the fallback camp, then come back here
            local fallback = not onFallback and fallbackFor(home)
            if not fallback then
                fail("Couldn't get an adventure from %s. If you already have one, start with skip. Ending.", c.questNPC)
            end
            log("Couldn't get an adventure at [%s], running one loop at [%s] instead.", home, fallback)
            onFallback = true
            goToCamp(fallback)
        else
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
            -- after a fallback loop, head back to the original camp
            if onFallback then
                log('Fallback loop done, heading back to [%s].', home)
                onFallback = false
                state.campKey = home
            end
            -- looping through every camp: the trip back goes to the next one
            if state.rotate then
                state.campKey = nextInRotation(state.campKey)
                log('Next camp: [%s].', state.campKey)
            end
            leaveDungeon()
            returnToCamp()
            state.runs = state.runs + 1
            log('Finished run #%d', state.runs)
        end
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
    state.campKey = nil
    state.active = false
    state.stopRequested = false
    state.skipGet = false
    setStep('Idle')
end

local function requestStart(campName, skip, rotate, bail)
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
    if rotate ~= nil then state.rotate = rotate and true or false end
    if bail ~= nil then state.bail = bail and true or false end
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
-- The client words the end of an adventure several ways (eqstr_us.txt).
-- Finishing after the time limit, for the lesser reward, gives the "points
-- for successfully completing" line instead of the usual one. Running out of
-- time with no reward left also ends it, so leave then too.
local function onAdvOver(why, msg)
    return function(line)
        -- "Complete your adventure goal within N minutes to receive a lesser
        -- reward": still worth finishing, so keep clearing
        if tostring(line or ''):lower():find('lesser reward', 1, true) then
            dlog('out of time, still clearing for the lesser reward')
            return
        end
        if state.active then state.advWon = true end
        if msg then log(msg) end
        dlog(why)
    end
end
mq.event('LDoN_AdvWon', '#*#You have successfully completed your adventure#*#', onAdvOver('win message seen'))
mq.event('LDoN_AdvWon2', '#*#for successfully completing the adventure#*#', onAdvOver('win message seen (late completion)'))
mq.event('LDoN_AdvWon3', '#*#Your Adventure was a success#*#', onAdvOver('win message seen (adventure was a success)'))
mq.event('LDoN_AdvFail', '#*#You failed to complete your adventure in time#*#',
    onAdvOver('adventure failed (out of time)', 'The adventure ran out of time with nothing left to win, leaving.'))
mq.event('LDoN_AdvFail2', '#*#You have failed your Adventure#*#', onAdvOver('adventure failed', 'The adventure failed, leaving.'))
-- debug: every chat line that mentions an adventure goes to the debug log,
-- so a completion message worded differently shows up there
mq.event('LDoN_AdvAny', '#*#adventure#*#', function(line) dlog('chat: %s', line) end)
-- any hit landing either way, used to spot a mob stuck on the hate list
local function onHit() if state.active then state.lastHit = mq.gettime() end end
mq.event('LDoN_HitOut', '#*#You #*# for #*# point#*# of damage#*#', onHit)
mq.event('LDoN_HitIn', '#*# YOU for #*# point#*# of damage#*#', onHit)
mq.event('LDoN_MissIn', '#*# YOU, but #*#', onHit)
mq.event('LDoN_Slain', '#*#You have been slain#*#', function()
    if state.active then state.died = true end
end)

-- ============================================================================
-- COMMANDS
-- ============================================================================
local function parseStartArgs(a, b, c, d)
    local campName, skip, rotate, bail = nil, false, false, false
    for _, v in ipairs({ a or '', b or '', c or '', d or '' }) do
        if v ~= '' then
            v = v:lower()
            if v == 'skip' then
                skip = true
            elseif v == 'loop' then
                rotate = true
            elseif v == 'bail' then
                bail = true
            else
                campName = v
            end
        end
    end
    return campName, skip, rotate, bail
end

local function ldonCommand(...)
    local args = { ... }
    local cmd = (args[1] or ''):lower()
    if cmd == 'start' or cmd == 'run' then
        local campName, skip, rotate, bail = parseStartArgs(args[2], args[3], args[4], args[5])
        requestStart(campName, skip, rotate, bail)
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
    elseif cmd == 'fallback' then
        local fb = (args[2] or ''):lower()
        if CAMPS[fb] or fb == 'random' or fb == 'none' then
            settings.fallbackCamp = fb
            saveConfig()
            log('Fallback camp set to [%s].', fb)
        else
            log('Fallback camp is [%s]. Use: /ldon fallback <sro|ep|bm|ec|nro|random|none>', settings.fallbackCamp)
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
        print(TAG .. 'usage: /ldon [start [camp] [skip] [loop] [bail]|stop|camp <sro|ep|bm|ec|nro>|fallback <camp|random|none>|status|show|hide|toggle|quit]')
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

local FALLBACK_KEYS = { 'random', 'none' }
local FALLBACK_LABELS = { 'random - any other camp', 'none - just stop' }
for _, key in ipairs(CAMP_ORDER) do
    table.insert(FALLBACK_KEYS, key)
    table.insert(FALLBACK_LABELS, string.format('%s - %s', key, CAMPS[key].label))
end

local function fallbackIndex()
    for i, key in ipairs(FALLBACK_KEYS) do
        if key == settings.fallbackCamp then return i end
    end
    return 1
end

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
            ImGui.Text(string.format('[%s]  runs: %d  elapsed: %s', state.campKey or settings.camp, state.runs,
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
        local fbIdx, fbChanged = ImGui.Combo('If refused, run##ldonFallback', fallbackIndex(), FALLBACK_LABELS)
        if fbChanged and FALLBACK_KEYS[fbIdx] then
            settings.fallbackCamp = FALLBACK_KEYS[fbIdx]
            saveConfig()
        end
        if ImGui.IsItemHovered() then
            ImGui.SetTooltip('If the recruiter refuses an adventure, run one loop at this camp, then go back')
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
        local rot, rotChanged = ImGui.Checkbox('Loop through every camp, starting at this one##ldonLoop', state.rotate)
        if rotChanged then state.rotate = rot end
        local bl, blChanged = ImGui.Checkbox(string.format('Give up after %d minutes with no hits##ldonBail', BAIL_AFTER_MIN), state.bail)
        if blChanged then state.bail = bl end
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
math.randomseed(os.time())
loadConfig()
mq.unbind('/ldon')
mq.bind('/ldon', ldonCommand)
mq.imgui.init('TriuneLDoNUI', DrawLDoNUI)

log('Loaded v%s -- /ldon start [camp] [skip] to begin, /ldon to show or hide the window.', VERSION)

-- /lua run triune_ldon <camp> [skip] starts right away, like /mac ldon <camp> [skip]
local startArgs = { ... }
if #startArgs > 0 then
    local campName, skip, rotate, bail = parseStartArgs(startArgs[1], startArgs[2], startArgs[3], startArgs[4])
    requestStart(campName or settings.camp, skip, rotate, bail)
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
