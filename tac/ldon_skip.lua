---@diagnostic disable: undefined-global, undefined-field
-- ============================================================================
-- lua/tac/ldon_skip.lua — LDoN Skip (Triune plugin)
-- ============================================================================
-- Some LDoN dungeons have one copy of a mob that can't be attacked, mixed in
-- with normal copies of the same name (e.g. one "a feral snow cougar" in Maw of
-- the Menagerie). Triune's ignore list works by name, so it would skip all of
-- them. This plugin skips just the stuck one:
--
--   A watched mob with a loc is skipped as soon as a spawn with that name is
--   within <radius> of the loc.
--
--   Any watched mob: when Triune has it targeted, within melee range, and its HP stays
--   at 100% for <Stuck seconds>, that one spawn is put on Triune's per-spawn
--   ignore (the same as the Extended Target window's ignore toggle). Triune
--   drops it and pulls the next mob. Every other mob with that name is still
--   pulled, and a mob that has ever taken damage is never skipped.
--
-- Settings: Triune's plugin settings page. Commands:
--   /ac ldonskip        skip the current target now (just that spawn)
--   /ac ldonskip list   show the watch list
--
-- Not one of Triune's own files, so the updater leaves it alone.
-- ============================================================================

local plugin = {
    id                 = 'ldon_skip',
    name               = 'LDoN Skip',
    version            = '1.0.0',
    author             = 'matth',
    description        = 'Skips the one unattackable copy of a mob (e.g. a feral snow cougar in Maw of the Menagerie) without ignoring the rest.',
    defaultEnabled     = true,
    tickInterval       = 0.5,
    runOutOfCombatOnly = false,
    hasThread          = false,
}

local core, mq, ImGui = nil, nil, nil
local GOLD, MUTED = nil, nil
local TAG = '\ag[LDoN Skip]\ax '

-- Saved settings (ctrl.plugins.ldon_skip.settings)
local S = {
    auto     = true,
    stuckSec = 20, -- seconds in range at 100% HP before skipping
    range    = 40, -- "in range" distance
    -- Mobs to watch. zone is optional: a zone short name or (part of) the long
    -- name; empty = every zone. x/y (with radius) are optional: the spot where
    -- the bad copy stands, so it is skipped right away.
    watch    = {
        -- the unattackable one; MQ2Nav reported "Reached destination at: (616.00, 736.00, 2.50)" next to it
        { name = 'a feral snow cougar', zone = 'Maw of the Menagerie', x = 616, y = 736, radius = 30 },
    },
}

-- Runtime state
local cur = { id = 0, since = nil }
local damaged = {}  -- spawn ids seen below 100% HP: attackable, never skip
local skipped = {}  -- spawn id -> name, for the settings page
local inputName, inputZone = '', ''

local function zoneMatches(z)
    if not z or z == '' then return true end
    z = z:lower()
    local short = (mq.TLO.Zone.ShortName() or ''):lower()
    local long = (mq.TLO.Zone.Name() or ''):lower()
    return short == z or long:find(z, 1, true) ~= nil
end

local function isWatched(name)
    if not name or name == '' then return false end
    name = name:lower()
    for _, w in ipairs(S.watch) do
        if (w.name or ''):lower() == name and zoneMatches(w.zone) then return true end
    end
    return false
end

local function skipSpawn(id, why)
    local s = mq.TLO.Spawn(id)
    local exists = s and s()
    local name = (exists and s.CleanName()) or ('#' .. id)
    core.setXtIgnore(id, true)
    skipped[id] = name
    print(string.format('%sSkipping %s #%d at %.0f, %.0f (%s). Other mobs with that name are still pulled.',
        TAG, name, id, exists and s.Y() or 0, exists and s.X() or 0, why))
end

-- Distance from spawn s to the watch entry's spot. Both x/y orders are
-- checked, since MQ2Nav and /loc print the two axes in opposite orders.
local function nearSpot(s, w)
    local sx, sy = s.X() or 0, s.Y() or 0
    local r = w.radius or 30
    local function d(x, y) return math.sqrt((sx - x) ^ 2 + (sy - y) ^ 2) end
    return d(w.x, w.y) <= r or d(w.y, w.x) <= r
end

-- Skip any spawn of a watched name that stands at its entry's spot
local function checkSpots()
    for _, w in ipairs(S.watch) do
        if w.x and w.y and zoneMatches(w.zone) then
            local search = 'npc =' .. w.name
            local n = mq.TLO.SpawnCount(search)() or 0
            for i = 1, n do
                local sp = mq.TLO.NearestSpawn(i, search)
                local id = (sp and sp() and sp.ID()) or 0
                if id > 0 and not skipped[id] and not damaged[id] and nearSpot(sp, w) then
                    skipSpawn(id, 'at its listed spot')
                end
            end
        end
    end
end

local function check()
    local t = mq.TLO.Target
    local id = (t and t() and t.ID()) or 0
    if id == 0 or t.Type() ~= 'NPC' or not isWatched(t.CleanName()) or core.isXtIgnoredId(id) then
        cur.id, cur.since = 0, nil
        return
    end
    if (t.PctHPs() or 100) < 100 then damaged[id] = true end
    if damaged[id] then
        cur.id, cur.since = 0, nil
        return
    end
    if cur.id ~= id then cur.id, cur.since = id, nil end
    if (t.Distance3D() or 9999) > S.range then
        cur.since = nil
        return
    end
    cur.since = cur.since or os.clock()
    if os.clock() - cur.since >= S.stuckSec then
        skipSpawn(id, string.format('in range %ds at 100%% HP', S.stuckSec))
        cur.id, cur.since = 0, nil
    end
end

-- ---------------------------------------------------------------------------
-- Plugin hooks
-- ---------------------------------------------------------------------------
function plugin.onInit(coreApi)
    core = coreApi
    mq = core.mq
    ImGui = core.ImGui
    local colors = core.colors or {}
    GOLD  = colors.GOLD  or { 1.0, 0.70, 0.54, 1 }
    MUTED = colors.MUTED or { 0.6, 0.6, 0.6, 1 }
end

function plugin.onTick()
    if not core or not S.auto then return end
    pcall(checkSpots)
    local ok = pcall(check)
    if not ok then cur.id, cur.since = 0, nil end
end

function plugin.onZoned()
    -- spawn ids are per zone; Triune clears its per-spawn ignores on zoning too
    cur.id, cur.since = 0, nil
    damaged, skipped = {}, {}
end

function plugin.onDrawSettings()
    if not core or not ImGui then return end
    local changed = false
    core.accent(GOLD, 'LDoN Skip')
    ImGui.TextWrapped('Skips one copy of a watched mob when it sits in range at 100% HP, without ignoring the others with the same name.')
    local v
    v = ImGui.Checkbox('Skip stuck mobs automatically##lsAuto', S.auto)
    if v ~= S.auto then S.auto = v; changed = true end
    ImGui.PushItemWidth(core.px(180))
    v = ImGui.SliderInt('Stuck seconds##lsSec', S.stuckSec, 5, 120, '%ds')
    if v ~= S.stuckSec then S.stuckSec = v; changed = true end
    v = ImGui.SliderInt('In range##lsRange', S.range, 10, 150)
    if v ~= S.range then S.range = v; changed = true end
    ImGui.PopItemWidth()

    ImGui.Separator()
    ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], 'Watched mobs (zone empty = every zone)')
    local removeAt = nil
    for i, w in ipairs(S.watch) do
        ImGui.PushID('lsw_' .. i)
        if ImGui.Button('x') then removeAt = i end
        ImGui.SameLine()
        ImGui.Text(string.format('%s%s%s', w.name, (w.zone and w.zone ~= '') and ('  (' .. w.zone .. ')') or '',
            w.x and string.format('  at %.0f, %.0f', w.x, w.y) or ''))
        ImGui.PopID()
    end
    if removeAt then table.remove(S.watch, removeAt); changed = true end
    ImGui.PushItemWidth(core.px(170))
    inputName = ImGui.InputText('Name##lsName', inputName or '', 128)
    ImGui.SameLine()
    inputZone = ImGui.InputText('Zone##lsZone', inputZone or '', 128)
    ImGui.PopItemWidth()
    ImGui.SameLine()
    if ImGui.Button('Add##lsAdd') and inputName ~= '' then
        table.insert(S.watch, { name = inputName, zone = inputZone })
        inputName, inputZone = '', ''
        changed = true
    end

    local any = false
    for id, name in pairs(skipped) do
        if not any then
            ImGui.Separator()
            ImGui.TextColored(MUTED[1], MUTED[2], MUTED[3], MUTED[4], 'Skipped in this zone')
            any = true
        end
        ImGui.PushID('lss_' .. id)
        if ImGui.Button('Unskip') then
            core.setXtIgnore(id, false)
            skipped[id] = nil
        end
        ImGui.SameLine()
        ImGui.Text(string.format('%s #%d', name, id))
        ImGui.PopID()
    end

    if changed then core.saveLoadout(true) end
end

function plugin.onSaveSettings()
    local t = {}
    for k, v in pairs(S) do t[k] = v end
    return t
end

function plugin.onLoadSettings(t)
    if type(t) ~= 'table' then return end
    local defaults = S.watch
    for k, v in pairs(t) do
        if S[k] ~= nil and type(v) == type(S[k]) then S[k] = v end
    end
    -- a list saved before an entry had a spot picks the spot up from the defaults
    for _, w in ipairs(S.watch) do
        for _, d in ipairs(defaults) do
            if not w.x and d.x and (w.name or ''):lower() == d.name:lower() and (w.zone or '') == (d.zone or '') then
                w.x, w.y, w.radius = d.x, d.y, d.radius
            end
        end
    end
end

-- /ac ldonskip [list]
function plugin.onCommand(cmd, args)
    if cmd ~= 'ldonskip' then return false end
    local sub = args and args[2] and tostring(args[2]):lower() or ''
    if sub == 'list' then
        print(TAG .. 'Watching:')
        for _, w in ipairs(S.watch) do
            print(string.format('  %s%s%s', w.name, (w.zone and w.zone ~= '') and ('  (' .. w.zone .. ')') or '',
                w.x and string.format('  at %.0f, %.0f', w.x, w.y) or ''))
        end
    else
        local id = mq.TLO.Target.ID() or 0
        if id > 0 and mq.TLO.Target.Type() == 'NPC' then
            skipSpawn(id, 'by command')
        else
            print(TAG .. 'Target the mob to skip first.')
        end
    end
    return true
end

plugin.help = {
    '  \ag/ac ldonskip\ax - Skip just the targeted spawn (other mobs with that name are still pulled)',
    '  \ag/ac ldonskip list\ax - Show the mobs LDoN Skip watches for',
}

return plugin
