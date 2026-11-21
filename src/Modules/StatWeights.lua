-- Path of Building
--
-- Local, one-sided stat sensitivities measured through native calculations.
local weights = { }

-- Parsing exemplars identify stat shapes; their amounts are replaced with derived tier gaps.
weights.stats = {
	{ "Maximum life", "+100 to maximum Life" },
	{ "Increased life", "10% increased maximum Life" },
	{ "Maximum energy shield", "+100 to maximum Energy Shield" },
	{ "Increased energy shield", "50% increased maximum Energy Shield" },
	{ "Maximum mana", "+100 to maximum Mana" },
	{ "Increased mana", "20% increased maximum Mana" },
	{ "Strength", "+50 to Strength" },
	{ "Dexterity", "+50 to Dexterity" },
	{ "Intelligence", "+50 to Intelligence" },
	{ "Increased damage", "30% increased Damage" },
	{ "Increased spell damage", "50% increased Spell Damage" },
	{ "Increased fire damage", "30% increased Fire Damage" },
	{ "Increased damage over time", "30% increased Damage over Time" },
	{ "Damage over time multiplier", "+15% to Damage over Time Multiplier" },
	{ "Attack speed", "10% increased Attack Speed" },
	{ "Cast speed", "10% increased Cast Speed" },
	{ "Mine throwing speed", "10% increased Mine Throwing Speed" },
	{ "Action speed", "4% increased Action Speed" },
	{ "Critical strike chance", "80% increased Global Critical Strike Chance" },
	{ "Critical strike multiplier", "+30% to Global Critical Strike Multiplier" },
	{ "Fire penetration", "Damage Penetrates 10% Fire Resistance" },
	{ "Spell gem level", "+1 to Level of all Spell Skill Gems" },
	{ "Armour", "+500 to Armour" },
	{ "Increased armour", "50% increased Armour" },
	{ "Evasion", "+500 to Evasion Rating" },
	{ "Increased evasion", "50% increased Evasion Rating" },
	{ "Fire resistance", "+35% to Fire Resistance" },
	{ "Cold resistance", "+35% to Cold Resistance" },
	{ "Lightning resistance", "+35% to Lightning Resistance" },
	{ "Chaos resistance", "+25% to Chaos Resistance" },
	{ "Maximum elemental resistances", "+1% to all maximum Elemental Resistances" },
	{ "Spell suppression chance", "+10% chance to Suppress Spell Damage" },
	{ "Attack block chance", "+5% Chance to Block Attack Damage" },
	{ "Spell block chance", "+5% Chance to Block Spell Damage" },
	{ "Life regeneration / second", "Regenerate 100 Life per second" },
	{ "Mana regeneration / second", "Regenerate 10 Mana per second" },
	{ "Mana regeneration rate", "50% increased Mana Regeneration Rate" },
	{ "Life recovery rate", "10% increased Life Recovery rate" },
	{ "Energy shield recovery rate", "15% increased Energy Shield Recovery rate" },
}

local function template(line)
	return line:gsub("%(%-?%d+%.?%d*%-%-?%d+%.?%d*%)", "#"):gsub("%-?%d+%.?%d*", "#"):gsub("^%+", ""):lower()
end

local function midpoint(line)
	local averaged = line:gsub("%((%-?%d+%.?%d*)%-(%-?%d+%.?%d*)%)", function(low, high)
		return tostring((tonumber(low) + tonumber(high)) / 2)
	end)
	local value, count
	averaged, count = averaged:gsub("%-?%d+%.?%d*", function(number)
		value = tonumber(number)
		return "#"
	end)
	return count == 1 and value or nil
end

local slotOrder = {
	Ring = 1, Amulet = 2, Belt = 3, Gloves = 4, Boots = 5, Helmet = 6, Shield = 7, Quiver = 8,
	Wand = 9, Dagger = 10, ["Rune Dagger"] = 11, Claw = 12, Sceptre = 13,
	["One Handed Sword"] = 14, ["Thrusting One Handed Sword"] = 15, ["One Handed Axe"] = 16, ["One Handed Mace"] = 17,
	["Body Armour"] = 18, Bow = 19, Staff = 20, Warstaff = 21,
	["Two Handed Sword"] = 22, ["Two Handed Axe"] = 23, ["Two Handed Mace"] = 24,
}

function weights.BuildSteps(modPools, bases)
	local byTemplate, steps = { }, { }
	for _, stat in ipairs(weights.stats) do
		local step = { label = stat[1], increment = stat[2], families = { } }
		byTemplate[template(stat[2])] = step
		table.insert(steps, step)
	end
	for _, source in ipairs({ "Explicit", "Eldritch" }) do
		for id, mod in pairs(modPools[source]) do
			local step = #mod == 1 and byTemplate[template(mod[1])]
			local value = step and midpoint(mod[1])
			if value and (source == "Eldritch" or mod.type == "Prefix" or mod.type == "Suffix") then
				local key = source..":"..mod.group..":"..mod.type
				step.families[key] = step.families[key] or { }
				table.insert(step.families[key], { id = id, mod = mod, value = value, source = source })
			end
		end
	end
	local seen, candidates = { }, { }
	local names = { }
	for name, base in pairs(bases) do
		if slotOrder[base.type] then
			table.insert(names, name)
		end
	end
	table.sort(names)
	for _, name in ipairs(names) do
		local base = bases[name]
		local tags = { }
		for tag in pairs(base.tags) do
			table.insert(tags, tag)
		end
		table.sort(tags)
		local signature = base.type..":"..table.concat(tags, ",")
		if not seen[signature] then
			seen[signature] = true
			local item = new("Item"):Item("")
			item.base = base
			table.insert(candidates, { item = item, name = name })
			for _, tag in pairs(base.influenceTags or { }) do
				table.insert(candidates, { item = item, name = name, influenceTags = { [tag] = true }, influence = tag })
			end
		end
	end
	for _, step in ipairs(steps) do
		local best
		for _, candidate in ipairs(candidates) do
			for _, family in pairs(step.families) do
				local tiers = { }
				for _, tier in ipairs(family) do
					if candidate.item:GetModSpawnWeight(tier.mod, candidate.influenceTags) > 0 then
						table.insert(tiers, tier)
					end
				end
				table.sort(tiers, function(a, b)
					return a.value > b.value or a.value == b.value and a.id < b.id
				end)
				if #tiers >= 3 then
					-- Average the adjacent gaps between the top four tier midpoints (or three if necessary).
					-- The lowest top-tier roll identifies the smallest base; smaller equipment slots break ties.
					local count = math.min(4, #tiers)
					local delta = (tiers[1].value - tiers[count].value) / (count - 1)
					local order = slotOrder[candidate.item.base.type]
					local key = candidate.name..":"..(candidate.influence or "")..":"..tiers[1].source..":"..tiers[1].id
					if delta > 0 and (not best or tiers[1].value < best.top
						or tiers[1].value == best.top and (order < best.order or order == best.order and key < best.key)) then
						best = { top = tiers[1].value, order = order, key = key, delta = delta,
							candidate = candidate, count = count }
					end
				end
			end
		end
		step.families = nil
		if best then
			local mods, extra = modLib.parseMod(step.increment)
			assert(mods and #mods > 0 and not extra, "Cannot parse stat weight modifier: "..step.increment)
			step.mods = copyTable(mods)
			local scale = best.delta / midpoint(step.increment)
			-- Scale parsed values rather than rounding fractional tier gaps to parser-supported text precision.
			for _, mod in ipairs(step.mods) do
				if mod.name == "GemProperty" and mod.type == "LIST" then
					mod.value.value = mod.value.value * scale
				else
					assert(type(mod.value) == "number", "Unsupported tier stat: "..step.label)
					mod.value = mod.value * scale
				end
			end
			step.increment = step.increment:gsub("%d+%.?%d*", function() return string.format("%.4g", best.delta) end)
			step.slot = best.candidate.item.base.type
			step.tierCount = best.count
		end
	end
	return steps
end

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function metrics(output, dpsStat)
	return {
		dps = data.powerStatList.GetFromOutput(output, { stat = dpsStat }),
		ehp = output.TotalEHP,
		time = output.ConfiguredSurvivalTime,
		window = output.ConfiguredSurvivalWindow,
	}
end

function weights.Calculate(calculate, dpsStat, onRow)
	assert(dpsStat == "CombinedDPS" or dpsStat == "FullDPS", "Unknown stat weight DPS metric.")
	local report = { baseline = metrics(calculate({ survivability = true }, true), dpsStat), rows = { } }
	local steps = weights.BuildSteps(data.itemMods, data.itemBases)
	for index, row in ipairs(steps) do
		local values
		if row.slot then
			values = metrics(calculate({ extraMods = row.mods, survivability = true }, true), dpsStat)
		end
		for _, key in ipairs({ "dps", "ehp", "time" }) do
			local base, value = report.baseline[key], values and values[key]
			row[key] = { }
			if finite(base) and finite(value) then
				row[key].delta = value - base
				if base ~= 0 then
					row[key].percent = row[key].delta / math.abs(base) * 100
				end
			end
		end
		table.insert(report.rows, row)
		if onRow then
			onRow(row, index, #steps)
		end
	end
	return report
end

function weights.Format(value, percent)
	if not finite(value) then
		return "N/A"
	end
	return string.format("%+.5g%s", value, percent and "%" or "")
end

return weights
