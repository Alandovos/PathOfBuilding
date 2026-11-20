-- Path of Building
--
-- Search-only damage profiles, evaluated through an isolated Configuration tab.
local profiles = { }
profiles.mixedTitle = "Feared-style mixed pressure (approx)"
profiles.degenTitle = "Synthetic background ground damage (raw DPS)"
profiles.degenText = "500 Cold Damage taken per second\n300 Fire Damage taken per second\n300 Chaos Damage taken per second"
profiles.mixedInput = {
	enemyIsBoss = "Pinnacle", enemyLevel = 84, presetBossSkills = "None", enemyDamageType = "Average",
	enemySpeed = 500, enemyCritChance = 5, enemyCritDamage = 30,
	enemyPhysicalDamage = 3500, enemyPhysicalOverwhelm = 0,
	enemyColdDamage = 3500, enemyColdPen = 25,
	enemyLightningDamage = 2000, enemyLightningPen = 10,
	enemyFireDamage = 1500, enemyFirePen = 10, enemyChaosDamage = 1500,
}

function profiles.List(build)
	local list = {
		{ id = "CURRENT", label = "Current Configuration: "..(build.configTab.configSets[build.configTab.activeConfigSetId].title or "Default"),
			description = "Uses your active Configuration, including its buffs and custom modifiers." },
		{ id = "MIXED", label = "Mixed bosses / Feared-style (approximate)",
			description = "Synthetic mixed hits + background degeneration. Not calibrated encounter data.\n12k raw hits / 500 ms base; 25% cold, 10% fire/lightning penetration. No Memory Game." },
		{ id = "PINNACLE", label = "Guardian / Pinnacle boss (generic)",
			description = "PoB's generic normal-pinnacle defaults. Not an actual boss rotation." },
	}
	for _, id in ipairs(build.configTab.configSetOrderList) do
		local config = build.configTab.configSets[id]
		if id ~= build.configTab.activeConfigSetId then
			table.insert(list, { id = "CONFIG:"..id, configSetId = id, label = "Saved Configuration: "..(config.title or "Default"),
				description = "Uses all settings from this saved Configuration, including buffs and custom modifiers." })
		end
	end
	for _, skill in ipairs(data.bossSkillsList) do
		if skill.val ~= "None" and skill.val ~= "Maven Memory Game" then
			table.insert(list, { id = "BOSS:"..skill.val, bossSkill = skill.val, label = "Boss skill: "..skill.label,
				description = "Native normal-pinnacle skill preset, maximum damage roll. One skill, not the whole fight." })
		end
	end
	return list
end

function profiles.CreateCalculator(build, profile)
	local snapshot = setmetatable(copyTable(build, true), getmetatable(build))
	snapshot.calcsTab = copyTable(build.calcsTab, true)
	snapshot.calcsTab.input = copyTable(build.calcsTab.input)
	snapshot.configTab = new("ConfigTab"):ConfigTab(snapshot)
	local config = snapshot.configTab
	local source = assert(build.configTab.configSets[profile.configSetId or build.configTab.activeConfigSetId], "Damage profile Configuration no longer exists.")
	local selected = copyTable(source)
	config.configSets = { [1] = selected }
	config.configSetOrderList = { 1 }
	config.activeConfigSetId = 1
	selected.id = 1
	config.input, config.placeholder = selected.input, selected.placeholder
	if profile.id ~= "CURRENT" and not profile.configSetId then
		for _, stat in ipairs({ "enemyLevel", "enemySpeed", "enemyCritChance", "enemyCritDamage", "enemyDamageRollRange", "enemyPhysicalOverwhelm" }) do
			config.input[stat] = nil
		end
		for _, damageType in ipairs({ "Physical", "Fire", "Cold", "Lightning", "Chaos" }) do
			config.input["enemy"..damageType.."Damage"] = nil
			config.input["enemy"..damageType.."Pen"] = nil
		end
		for index = #selected.customModsList, 1, -1 do
			if selected.customModsList[index].title == profiles.degenTitle then
				table.remove(selected.customModsList, index)
			end
		end
		config.input.enemyIsBoss = "Pinnacle"
		config.input.enemyLevel = 84
		config.input.presetBossSkills = profile.bossSkill or "None"
		config.input.enemyDamageType = "Average"
		if profile.bossSkill then
			assert(data.bossSkills[profile.bossSkill], "Unknown boss skill damage profile.")
			config.input.enemyDamageRollRange = 100
		elseif profile.id == "MIXED" then
			for key, value in pairs(profiles.mixedInput) do
				config.input[key] = value
			end
			table.insert(selected.customModsList, { title = profiles.degenTitle, enabled = true, text = profiles.degenText })
		else
			assert(profile.id == "PINNACLE", "Unknown optimizer damage profile.")
		end
	end
	config:UpdateControls()
	config:BuildModList()
	local calculate, output = require("Modules.Calcs").getMiscCalculator(snapshot)
	return calculate, output
end

return profiles
