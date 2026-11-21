describe("Measured stat weights", function()
	local weights = require("Modules.StatWeights")
	local originalCopy

	before_each(function()
		newBuild()
		originalCopy = Copy
	end)

	after_each(function()
		Copy = originalCopy
		while main.popups[1] do
			main:ClosePopup()
		end
	end)

	it("replaces profile mouseover text each frame and describes the hovered option", function()
		build.calcsTab:OpenStatWeights()
		local profile = main.popups[1].controls.profile
		local tooltip = profile.tooltip
		local selected = profile.selIndex
		local function text()
			local lines = { }
			for _, line in ipairs(tooltip.lines) do
				table.insert(lines, line.text)
			end
			return table.concat(lines, "\n")
		end
		for _ = 1, 100 do
			profile.tooltipFunc(tooltip, "BODY", selected, profile.list[selected])
		end
		assert.are.equal(profile.list[selected].description, text())
		for _ = 1, 100 do
			profile.tooltipFunc(tooltip, "HOVER", 2, profile.list[2])
		end
		assert.are.equal(profile.list[2].description, text())
		assert.are.equal(selected, profile.selIndex)
		profile.tooltipFunc(tooltip, "OUT", selected, profile.list[selected])
		assert.are.equal(0, #tooltip.lines)
		profile.tooltipFunc(tooltip, "BODY", selected, profile.list[selected])
		assert.are.equal(profile.list[selected].description, text())
	end)

	it("averages the top four tier gaps on the lowest-roll eligible slot, excluding unspawnable mods", function()
		local pools = { Explicit = { }, Eldritch = { } }
		for index, range in ipairs({ "(10-20)", "(20-40)", "(40-60)", "(60-80)", "(80-120)", "(180-220)", "(1000-1200)" }) do
			pools.Explicit["Life"..index] = {
				"+"..range.." to maximum Life", type = "Prefix", group = "Life", affix = "Life",
				weightKey = { "ring", "body_armour", "default" },
				weightVal = { index <= 4 and 1000 or 0, index <= 6 and 1000 or 0, 0 },
			}
		end
		local steps = weights.BuildSteps(pools, {
			["Small ring"] = { type = "Ring", tags = { ring = true, default = true } },
			["Large chest"] = { type = "Body Armour", tags = { body_armour = true, default = true } },
		})
		local life = steps[1]
		assert.are.equal("Ring", life.slot)
		assert.are.equal(4, life.tierCount)
		assert.near(55 / 3, tonumber(life.increment:match("([%d%.]+)")), 0.01)
		assert.near(55 / 3, life.mods[1].value, 1e-8)
	end)

	it("uses three tiers where necessary and retains zero gaps between duplicate-valued implicit tiers", function()
		local pools = { Explicit = { }, Eldritch = { } }
		for index, value in ipairs({ 10, 20, 45 }) do
			pools.Explicit["Regen"..index] = {
				"Regenerate "..value.." Life per second", type = "Suffix", group = "Regen", affix = "Regen",
				weightKey = { "ring", "default" }, weightVal = { 1000, 0 },
			}
		end
		for index, value in ipairs({ 4, 4, 5, 5, 6, 6 }) do
			pools.Eldritch["Action"..index] = {
				value.."% increased Action Speed", type = "Exarch", group = "Action", affix = "",
				weightKey = { "boots", "default" }, weightVal = { 1000, 0 },
			}
		end
		local steps = weights.BuildSteps(pools, {
			["Ring"] = { type = "Ring", tags = { ring = true, default = true } },
			["Boots"] = { type = "Boots", tags = { boots = true, default = true } },
		})
		local regen, action, gemLevel
		for _, step in ipairs(steps) do
			if step.label == "Life regeneration / second" then regen = step end
			if step.label == "Action speed" then action = step end
			if step.label == "Spell gem level" then gemLevel = step end
		end
		assert.are.equal(3, regen.tierCount)
		assert.near(17.5, tonumber(regen.increment:match("([%d%.]+)")), 1e-8)
		assert.are.equal(4, action.tierCount)
		assert.near(1 / 3, tonumber(action.increment:match("([%d%.]+)")), 0.0001)
		assert.near(1 / 3, action.mods[1].value, 1e-8)
		assert.is_nil(gemLevel.slot)
	end)

	it("does not mistake overlapping influence variants for additional tiers", function()
		local pools = { Explicit = { }, Eldritch = { } }
		for _, influence in ipairs({ "shaper", "elder" }) do
			for index, value in ipairs({ 5, 10 }) do
				pools.Explicit[influence..index] = {
					value.."% increased maximum Life", type = "Prefix", group = "Life", affix = "Life",
					weightKey = { "ring_"..influence, "default" }, weightVal = { 1000, 0 },
				}
			end
		end
		local steps = weights.BuildSteps(pools, {
			["Ring"] = { type = "Ring", tags = { ring = true, default = true },
				influenceTags = { shaper = "ring_shaper", elder = "ring_elder" } },
		})
		assert.is_nil(steps[2].slot)
	end)

	it("measures whole tier steps and includes minion damage without doubling Full DPS", function()
		local function calculate(override)
			local changed = override.extraMods ~= nil
			assert.is_true(override.survivability)
			return {
				CombinedDPS = changed and 115 or 100, Minion = { CombinedDPS = 50 },
				FullDPS = changed and 770 or 700,
				TotalEHP = changed and 1200 or 1000, ConfiguredSurvivalTime = changed and 12 or 10,
				ConfiguredSurvivalWindow = 30,
			}
		end
		local report = weights.Calculate(calculate, "CombinedDPS")
		assert.are.equal(150, report.baseline.dps)
		assert.near(15, report.rows[1].dps.delta, 1e-8)
		assert.near(10, report.rows[1].dps.percent, 1e-8)
		assert.near(200, report.rows[1].ehp.delta, 1e-8)
		assert.near(2, report.rows[1].time.delta, 1e-8)
		report = weights.Calculate(calculate, "FullDPS")
		assert.are.equal(700, report.baseline.dps)
		assert.near(70, report.rows[1].dps.delta, 1e-8)
		assert.near(10, report.rows[1].dps.percent, 1e-8)
	end)

	it("distinguishes undefined percentages and infinite EHP from capped zero survival gain", function()
		local report = weights.Calculate(function(override)
			return {
				CombinedDPS = override.extraMods and 10 or 0, TotalEHP = math.huge,
				ConfiguredSurvivalTime = 30, ConfiguredSurvivalWindow = 30,
			}
		end, "CombinedDPS")
		assert.are.equal(10, report.rows[1].dps.delta)
		assert.is_nil(report.rows[1].dps.percent)
		assert.is_nil(report.rows[1].ehp.delta)
		assert.are.equal("N/A", weights.Format(report.rows[1].ehp.delta))
		assert.are.equal(0, report.rows[1].time.percent)
	end)

	it("applies temporary modifiers to native Full DPS and defences without leaking between calculations", function()
		build.skillsTab:PasteSocketGroup("Fireball 20/0  1")
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		runCallback("OnFrame")
		local calculate = build.calcsTab:GetMiscCalculator()
		local base = calculate({ survivability = true }, true)
		local mods = { }
		for _, line in ipairs({ "+100 to maximum Life", "20% increased Spell Damage", "+1 to Level of all Spell Skill Gems" }) do
			for _, mod in ipairs(assert(modLib.parseMod(line))) do
				table.insert(mods, mod)
			end
		end
		local changed = calculate({ extraMods = mods, survivability = true }, true)
		assert(changed.Life >= base.Life + 100)
		assert(changed.FullDPS > base.FullDPS)
		local again = calculate({ survivability = true }, true)
		assert.near(base.FullDPS, again.FullDPS, 1e-8)
		assert.near(base.TotalEHP, again.TotalEHP, 1e-8)
		assert.near(base.ConfiguredSurvivalTime, again.ConfiguredSurvivalTime, 1e-8)
		build.configTab.input.customMods = "+100 to maximum Life\n20% increased Spell Damage\n+1 to Level of all Spell Skill Gems"
		build.configTab:BuildModList()
		runCallback("OnFrame")
		calculate = build.calcsTab:GetMiscCalculator()
		local expected = calculate({ survivability = true }, true)
		assert.near(expected.FullDPS, changed.FullDPS, 1e-8)
		assert.near(expected.TotalEHP, changed.TotalEHP, 1e-8)
		assert.near(expected.ConfiguredSurvivalTime, changed.ConfiguredSurvivalTime, 1e-8)
	end)

	it("shows sortable mine weights, copies the selected units and keeps the live build unchanged", function()
		build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		build.configTab.input.customMods = "+5000 to maximum Life\n+75% to all Elemental Resistances"
		build.configTab:BuildModList()
		runCallback("OnFrame")
		local config = copyTable(build.configTab.input)
		local allocation = copyTable(build.spec.allocNodes, true)
		local itemSet = copyTable(build.itemsTab.activeItemSet)
		local revision, dirty = build.outputRevision, build.buildFlag
		build.calcsTab.controls.statWeights:Click()
		local popup = main.popups[1]
		local controls = popup.controls
		controls.profile:SelByValue("MIXED", "id")
		controls.metric:SelByValue("FullDPS", "stat")
		controls.calculate:Click()
		for _ = 1, 100 do
			popup.resizeFunc()
			if controls.copy:IsEnabled() then
				break
			end
		end
		assert.are.equal(popup, main.popups[1])
		assert.is_true(controls.copy:IsEnabled())
		assert.are.equal(#weights.stats, #controls.list.list)
		assert(controls.status.label:match("Baseline: DPS"))
		local life, mineSpeed, actionSpeed
		for _, row in ipairs(controls.list.list) do
			if row.label == "Maximum life" then life = row end
			if row.label == "Mine throwing speed" then mineSpeed = row end
			if row.label == "Action speed" then actionSpeed = row end
		end
		assert(life.ehp.delta > 0 and life.time.delta >= 0)
		assert(mineSpeed.dps.delta > 0 and actionSpeed.dps.delta > 0)
		controls.list:ReSort(3)
		assert(controls.list.list[1].ehp.percent >= life.ehp.percent)
		popup:Draw({ x = 0, y = 0, width = 1920, height = 1080 })
		local copied
		Copy = function(text) copied = text end
		controls.units.selIndex = 2
		controls.units.selFunc(2)
		controls.copy:Click()
		assert(copied:match("Time %(s%) gain"))
		assert(copied:find("Mixed bosses / Feared-style", 1, true))
		assert(copied:find(life.increment, 1, true))
		assert(not copied:find("Reference tiers", 1, true))
		assert(not controls.list:GetRowValue(1, 0, life):find("[", 1, true))
		assert.are.same(config, build.configTab.input)
		assert.are.same(allocation, build.spec.allocNodes)
		assert.are.same(itemSet, build.itemsTab.activeItemSet)
		assert.are.equal(revision, build.outputRevision)
		assert.are.equal(dirty, build.buildFlag)
		controls.metric.selFunc()
		assert.is_false(controls.copy:IsEnabled())
		assert.are.equal(0, #controls.list.list)
		controls.close:Click()
	end)
end)
