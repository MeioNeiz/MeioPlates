-- Options panel (Esc > Options > AddOns > MeioPlates, or /meioplates). Settings write
-- straight into MeioPlatesDB.
local _, ns = ...

local category

local function Header(layout, title, tip)
    if layout and CreateSettingsListSectionHeaderInitializer then
        layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(title, tip))
    end
end

-- redraw the plates as soon as a box is ticked
-- (read the table: callback arguments differ between client builds)
local function Checkbox(category, key, label, default, tip)
    local variable = "MEIOPLATES_" .. key:upper()
    local setting = Settings.RegisterAddOnSetting(category, variable, key, ns.db,
        Settings.VarType.Boolean, label, default)
    Settings.CreateCheckbox(category, setting, tip)
    if Settings.SetOnValueChangedCallback then
        Settings.SetOnValueChangedCallback(variable, function() ns.Refresh() end)
    end
end

local function Register()
    if category or not (Settings and Settings.RegisterVerticalLayoutCategory) then
        return
    end
    local layout
    category, layout = Settings.RegisterVerticalLayoutCategory("MeioPlates")

    Checkbox(category, "enabled", "MeioPlates on", true, "Bands on enemy nameplates showing "
        .. "the damage still coming from you. Off: plates are left alone. /meioplates on||off")

    local toggles = {}
    for _, t in ipairs(ns.TOGGLES) do toggles[t.key] = t end
    local function Toggle(key)
        local t = toggles[key]
        Checkbox(category, key, t.label, true, t.tip .. " /meioplates " .. (t.cmd or t.key)
            .. " on||off")
    end

    Header(layout, "Bands", "What eats back from the health fill's edge. "
        .. "/meioplates attack||dots||cast on||off does the same.")
    Toggle("attack")
    if Settings.CreateDropdown and Settings.CreateControlTextContainer then
        local setting = Settings.RegisterAddOnSetting(category, "MEIOPLATES_COUNT", "count",
            ns.db, Settings.VarType.String, "Count in", "auto")
        Settings.CreateDropdown(category, setting, function()
            local c = Settings.CreateControlTextContainer()
            for _, choice in ipairs(ns.COUNTS) do c:Add(choice[1], choice[2]) end
            return c:GetData()
        end, "What the attack band and \"xN\" count in. Auto: wand shots for a caster with "
            .. "a wand, else your main spell (the direct damage spell you cast most); Auto "
            .. "Shots for hunters; melee swings for the rest (Druids: in cat or bear form). "
            .. "The mob's tooltip lists each. /meioplates count auto||wand||shot||melee||spell")
        if Settings.SetOnValueChangedCallback then
            Settings.SetOnValueChangedCallback("MEIOPLATES_COUNT", function() ns.Refresh() end)
        end
    end
    Toggle("pet")
    Toggle("dots")
    Toggle("cast")
    -- the legend: your class's DoT colours, three to a row (a header line is not wrapped)
    local names = ns.ColouredDots()
    for i = 1, #names, 3 do
        Header(layout, table.concat(names, "   ", i, math.min(i + 2, #names)), "Your class's "
            .. "DoT colours on the plate. Grey: a DoT DoesItDie tracks that MeioPlates doesn't "
            .. "know. Yellow: your cast.")
    end

    Header(layout, "Text", "Beside the plate and on the mob's tooltip. "
        .. "/meioplates text||tooltip on||off")
    Toggle("text")
    Toggle("tooltip")

    if ns.ToggleShown(toggles.cc) then
        Header(layout, "Crowd control", "Your Fear, Banish, Polymorph and so on, timed "
            .. "from your casts. /meioplates cc on||off")
        Toggle("cc")
    end

    if ns.isWarlock then
        Header(layout, "Drain Soul", "A soul shard icon when Drain Soul would finish the "
            .. "mob. /meioplates drainsoul on||off, /meioplates shards N")
        Toggle("drainSoul")
        if Settings.CreateSlider and Settings.CreateSliderOptions then
            local setting = Settings.RegisterAddOnSetting(category, "MEIOPLATES_SHARDCAP",
                "shardCap", ns.db, Settings.VarType.Number, "Shards to carry", 20)
            local options = Settings.CreateSliderOptions(1, 40, 1)
            if options.SetLabelFormatter and MinimalSliderWithSteppersMixin then
                options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
            end
            local tip = "The Drain Soul cue shows only while you carry fewer soul shards "
                .. "than this. /meioplates shards N"
            local sk = ns.UsesMeioShards()
            if sk then
                tip = "Not used: MeioShards is loaded, so its cap applies (Esc > Options > "
                    .. "AddOns > MeioShards, /shards cap N)."
            end
            local slider = Settings.CreateSlider(category, setting, options, tip)
            if sk and slider and slider.AddModifyPredicate then
                slider:AddModifyPredicate(function() return false end)
            end
            if Settings.SetOnValueChangedCallback then
                Settings.SetOnValueChangedCallback("MEIOPLATES_SHARDCAP",
                    function() ns.Refresh() end)
            end
        end
    end
    Settings.RegisterAddOnCategory(category)
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    local ok, err = pcall(Register)
    if not ok then geterrorhandler()(err) end
end)

function ns.OpenSettings()
    if not category then return false end
    Settings.OpenToCategory(category:GetID())
    return true
end

function MeioPlates_OnAddonCompartmentClick()
    if not ns.OpenSettings() then SlashCmdList.MEIOPLATES("help") end
end
