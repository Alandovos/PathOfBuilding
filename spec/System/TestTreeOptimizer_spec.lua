describe("Tree optimizer", function()
	local TreeOptimizer = require("Classes.TreeOptimizer")
	local first, alternative
	local function feasibleOutput(values)
		local output = {
			CombinedDPS = 100, TotalEHP = 100,
			ManaUnreserved = 100, LifeUnreserved = 100,
			Str = 100, Dex = 100, Int = 100, Omni = 100,
			ReqStr = 100, ReqDex = 100, ReqInt = 100, ReqOmni = 100,
			FireResist = 75, ColdResist = 75, LightningResist = 75, ChaosResist = 75,
			MissingFireResist = 0, MissingColdResist = 0, MissingLightningResist = 0, MissingChaosResist = 0,
			BlockChance = 75, BlockChanceMax = 75, SpellBlockChance = 75, SpellBlockChanceMax = 75,
			SpellSuppressionChance = 100,
		}
		for _, ailment in ipairs(data.elementalAilmentTypeList) do
			output[ailment.."AvoidChance"] = 100
		end
		for _, damageType in ipairs({ "Physical", "Fire", "Cold", "Lightning", "Chaos" }) do
			output[damageType.."MaximumHitTaken"] = 100
		end
		for key, value in pairs(values or { }) do
			output[key] = value
		end
		return output
	end

	before_each(function()
		newBuild()
		local start
		for _, node in pairs(build.spec.allocNodes) do
			if node.type == "ClassStart" then
				start = node
				break
			end
		end
		local choices = { }
		for _, node in ipairs(start.linked) do
			if node.type == "Normal" and not node.ascendancyName then
				table.insert(choices, node)
			end
		end
		table.sort(choices, function(a, b) return a.id < b.id end)
		first, alternative = choices[1], choices[2]
		assert(first and alternative)
		build.spec:AllocNode(first)
	end)

	local function finish(optimizer)
		local steps = 0
		while not optimizer.done do
			local ok, err = coroutine.resume(optimizer.worker)
			assert(ok, err)
			steps = steps + 1
			assert(steps < 10000, "Optimizer did not terminate")
		end
		assert(optimizer.spec:CountAllocNodes() == optimizer.budget, "Point budget changed")
		return optimizer
	end

	local function search(goal, dps, ehp)
		local optimizer = build.treeTab:CreateTreeOptimizer(goal, 1, "CombinedDPS")
		optimizer.calculate = function(override)
			local chosen = override.spec.allocNodes[alternative.id]
			return feasibleOutput({ CombinedDPS = chosen and dps or 100, TotalEHP = chosen and ehp or 100 })
		end
		return finish(optimizer)
	end

	it("balances relative DPS and EHP on a separate tree", function()
		local source = build.spec
		local optimizer = search("BALANCED", 150, 80)
		assert(optimizer.spec.allocNodes[alternative.id])
		assert(not optimizer.spec.allocNodes[first.id])
		assert(optimizer.bestMetrics.dps == 150 and optimizer.bestMetrics.ehp == 80)
		assert(build.spec == source and source.allocNodes[first.id] and not source.allocNodes[alternative.id])
		assert(optimizer.tested > 0)
	end)

	it("allows at most 0.5% EHP loss in DPS mode and DPS loss in EHP mode", function()
		assert(search("DPS", 150, 99.6).bestMetrics.ehp == 99.6)
		assert(search("EHP", 99.6, 150).bestMetrics.dps == 99.6)
		assert(search("DPS", 150, 99.5).bestMetrics.ehp == 99.5)
		assert(search("EHP", 99.5, 150).bestMetrics.dps == 99.5)
		assert(search("DPS", 150, 99.499).improvements == 0)
		assert(search("EHP", 99.499, 150).improvements == 0)
		assert(search("DPS", 150, 80).improvements == 0)
		assert(search("EHP", 80, 150).improvements == 0)
		assert(search("DPS", 120, 110).bestMetrics.dps == 120)
		assert(search("EHP", 110, 120).bestMetrics.ehp == 120)
	end)

	it("preserves locked nodes and their connecting path", function()
		local dependent
		for _, node in ipairs(first.linked) do
			if node.type == "Normal" and node.path and #node.path == 1 and not node.alloc then
				dependent = node
				break
			end
		end
		assert(dependent)
		build.spec:AllocNode(dependent)
		build.spec.optimizerLocks[dependent.id] = true
		local optimizer = build.treeTab:CreateTreeOptimizer("BALANCED", 3, "CombinedDPS")
		optimizer.calculate = function()
			return feasibleOutput()
		end
		finish(optimizer)
		assert(optimizer.spec.allocNodes[first.id] and optimizer.spec.allocNodes[dependent.id])
		assert(optimizer.tested == 0)
	end)

	it("can exchange a multi-point branch without exceeding the budget", function()
		local target
		for _, node in ipairs(alternative.linked) do
			if node.type == "Normal" and node.path and #node.path == 2 then
				target = node
				break
			end
		end
		assert(target)
		local extension
		for _, node in ipairs(first.linked) do
			if node.type == "Normal" and node.path and #node.path == 1 and not node.alloc then
				extension = node
				break
			end
		end
		assert(extension)
		build.spec:AllocNode(extension)
		local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 3, "CombinedDPS")
		optimizer.calculate = function(override)
			return feasibleOutput({ CombinedDPS = override.spec.allocNodes[target.id] and 200 or 100 })
		end
		finish(optimizer)
		assert(optimizer.bestMetrics.dps == 200)
		assert(optimizer.spec.allocNodes[target.id])
		assert(optimizer.spec:CountAllocNodes() == 2)
	end)

	it("keeps mastery effects, ascendancies and sockets fixed", function()
		build.spec:SelectAscendClass(1)
		for id in pairs(build.spec.tree.alternate_ascendancies or { }) do
			if id ~= 0 then
				build.spec:SelectSecondaryAscendClass(id)
				break
			end
		end
		local mastery, socket, ascendancy
		for _, node in pairs(build.spec.nodes) do
			if node.path and not node.ascendancyName then
				if node.type == "Mastery" and node.masteryEffects and (not mastery or #node.path < #mastery.path) then
					mastery = node
				elseif node.type == "Socket" and (not socket or #node.path < #socket.path) then
					socket = node
				end
			elseif node.ascendancyName and node.path and node.type ~= "AscendClassStart" then
				ascendancy = node
			end
		end
		assert(mastery and socket and ascendancy)
		local effect = mastery.masteryEffects[1].effect
		build.spec.masterySelections[mastery.id] = effect
		build.spec:AllocNode(mastery)
		build.spec:AllocNode(socket)
		build.spec:AllocNode(ascendancy)
		local optimizer = build.treeTab:CreateTreeOptimizer("BALANCED", 1, "CombinedDPS")
		optimizer.calculate = function()
			return feasibleOutput()
		end
		finish(optimizer)
		assert(optimizer.spec.curAscendClassId == build.spec.curAscendClassId)
		assert(optimizer.spec.curSecondaryAscendClassId == build.spec.curSecondaryAscendClassId)
		assert(optimizer.spec.masterySelections[mastery.id] == effect)
		assert(optimizer.spec.allocNodes[mastery.id] and optimizer.spec.allocNodes[socket.id])
		for id, node in pairs(build.spec.nodes) do
			if node.ascendancyName or node.type == "Mastery" or node.type == "Socket" then
				assert(not not optimizer.spec.allocNodes[id] == not not build.spec.allocNodes[id])
			end
		end
	end)

	it("uses the chosen Full DPS or minion metric rather than player DPS", function()
		local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "FullDPS")
		optimizer.calculate = function(override)
			return feasibleOutput({
				CombinedDPS = override.spec.allocNodes[first.id] and 1000 or 1,
				FullDPS = override.spec.allocNodes[alternative.id] and 200 or 100,
				TotalEHP = 100,
			})
		end
		assert(finish(optimizer).bestMetrics.dps == 200)
		optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS")
		optimizer.calculate = function(override)
			return feasibleOutput({
				CombinedDPS = 1000,
				Minion = { CombinedDPS = override.spec.allocNodes[alternative.id] and 200 or 100 },
				TotalEHP = 100,
			})
		end
		assert(finish(optimizer).bestMetrics.dps == 200)
	end)

	it("discards tentative allocations when stopped", function()
		local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS")
		optimizer.calculate = function()
			return feasibleOutput()
		end
		assert(coroutine.resume(optimizer.worker))
		assert(not optimizer.done)
		optimizer:Stop()
		assert(optimizer.done and optimizer.spec.allocNodes[first.id])
		assert(optimizer.spec:CountAllocNodes() == 1)
	end)

	it("rejects an invalid baseline and reports non-finite candidates", function()
		local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS")
		optimizer.calculate = function()
			return feasibleOutput({ CombinedDPS = 0 })
		end
		local ok, err = coroutine.resume(optimizer.worker)
		assert(not ok and err:match("positive DPS and EHP"))
		optimizer = search("BALANCED", math.huge, 100)
		assert(optimizer.rejected > 0 and optimizer.improvements == 0)
	end)

	it("persists locks through save/load, copying and undo states", function()
		build.spec.optimizerLocks[first.id] = true
		local state = build.spec:CreateUndoState()
		build.spec.optimizerLocks[first.id] = nil
		build.spec:RestoreUndoState(state)
		assert(build.spec.optimizerLocks[first.id])
		local xml = { }
		build.spec:Save(xml)
		local loaded = new("PassiveSpec"):PassiveSpec(build, build.spec.treeVersion)
		loaded:Load(xml, "optimizer test")
		loaded:PostLoad()
		assert(loaded.optimizerLocks[first.id] and loaded.allocNodes[first.id])
		local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS")
		assert(optimizer.spec.optimizerLocks[first.id])
		assert(optimizer.spec.optimizerLocks ~= build.spec.optimizerLocks)
	end)

	it("toggles required nodes with Alt-right-click without replacing ordinary right-click", function()
		build.buildFlag = true
		runCallback("OnFrame")
		local viewer = build.treeTab.viewer
		local viewport = { x = 0, y = 0, width = 1000, height = 800 }
		viewer:Focus(first.x, first.y, viewport, build)
		local cursor, keyDown = GetCursorPos, IsKeyDown
		local alt = true
		GetCursorPos = function() return 500, 400 end
		IsKeyDown = function(key) return key == "ALT" and alt end
		local ok, err = xpcall(function()
			local function rightClick()
				viewer:Draw(build, viewport, { { type = "KeyUp", key = "RIGHTBUTTON" } })
			end
			rightClick()
			assert(build.spec.optimizerLocks[first.id])
			alt = false
			rightClick()
			assert(build.spec.optimizerLocks[first.id])
			alt = true
			rightClick()
			assert(not build.spec.optimizerLocks[first.id])
		end, debug.traceback)
		GetCursorPos, IsKeyDown = cursor, keyDown
		assert(ok, err)
	end)

	it("uses actual PoB calculations for an improved result", function()
		build.buildFlag = true
		runCallback("OnFrame")
		local optimizer = finish(build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS"))
		assert(optimizer.tested > 0 and optimizer.improvements > 0)
		assert(optimizer.bestMetrics.dps > optimizer.base.dps)
		assert(optimizer.bestMetrics.ehp >= optimizer.base.ehp)
		local calculate = build.calcsTab:GetMiscCalculator()
		local output = calculate({ spec = optimizer.spec })
		assert(math.abs(output.CombinedDPS - optimizer.bestMetrics.dps) < 1e-8)
	end)

	it("rejects reservation and attribute violations even when DPS is higher", function()
		for _, invalid in ipairs({
			{ ManaUnreserved = -1 },
			{ LifeUnreserved = 0 },
			{ Str = 99 },
			{ Dex = 99 },
			{ Int = 99 },
			{ Omni = 99 },
			{ ReqInt = 101 },
		}) do
			local optimizer = build.treeTab:CreateTreeOptimizer("BALANCED", 1, "CombinedDPS")
			optimizer.calculate = function(override)
				local output = feasibleOutput()
				if override.spec.allocNodes[alternative.id] then
					output.CombinedDPS = 200
					for key, value in pairs(invalid) do
						output[key] = value
					end
				end
				return output
			end
			finish(optimizer)
			assert(optimizer.improvements == 0 and optimizer.rejected > 0)
			assert(optimizer.spec.allocNodes[first.id])
		end
	end)

	it("allows exact reservation and attribute boundaries", function()
		local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS")
		optimizer.calculate = function(override)
			return feasibleOutput({
				CombinedDPS = override.spec.allocNodes[alternative.id] and 200 or 100,
				ManaUnreserved = 0, LifeUnreserved = 1,
			})
		end
		assert(finish(optimizer).bestMetrics.dps == 200 and optimizer.bestFeasible)
	end)

	it("enforces every selected defensive target without lowering caps", function()
		for _, case in ipairs({
			{ option = "elementalRes", invalid = { FireResist = 74, MissingFireResist = 1 } },
			{ option = "elementalRes", invalid = { ColdResist = 74, MissingColdResist = 0 } },
			{ option = "elementalRes", invalid = { LightningResist = 74, MissingLightningResist = 1 } },
			{ option = "chaosRes", invalid = { ChaosResist = 74, MissingChaosResist = 1 } },
			{ option = "block", invalid = { BlockChance = 74 } },
			{ option = "block", invalid = { SpellBlockChance = 74 } },
			{ option = "block", invalid = { BlockChance = 65, BlockChanceMax = 65 } },
			{ option = "block", invalid = { SpellBlockChanceMax = 80 } },
			{ option = "suppression", invalid = { SpellSuppressionChance = 99.999 } },
			{ option = "ailmentAvoidance", invalid = { ShockAvoidChance = 99 } },
			{ option = "ailmentAvoidance", invalid = { BrittleAvoidChance = 99 } },
			{ option = "maxHit", invalid = { PhysicalMaximumHitTaken = 99 } },
			{ option = "maxHit", invalid = { ChaosMaximumHitTaken = 99 } },
		}) do
			local optimizer = build.treeTab:CreateTreeOptimizer("BALANCED", 1, "CombinedDPS", { [case.option] = true })
			optimizer.calculate = function(override)
				local output = feasibleOutput()
				if override.spec.allocNodes[alternative.id] then
					output.CombinedDPS = 200
					for key, value in pairs(case.invalid) do
						output[key] = value
					end
				end
				return output
			end
			finish(optimizer)
			assert(optimizer.improvements == 0 and optimizer.rejected > 0, case.option)
		end
		local allOptions = { elementalRes = "CAP", chaosRes = "CAP", block = "CAP", suppression = "CAP", ailmentAvoidance = "CAP", maxHit = true }
		local optimizer = build.treeTab:CreateTreeOptimizer("BALANCED", 1, "CombinedDPS", allOptions)
		optimizer.calculate = function(override)
			return feasibleOutput({ CombinedDPS = override.spec.allocNodes[alternative.id] and 200 or 100 })
		end
		assert(finish(optimizer).bestMetrics.dps == 200)
	end)

	it("distinguishes don't-reduce, cap and unrestricted for every defence", function()
		for _, case in ipairs({
			{
				option = "elementalRes",
				start = { FireResist = 40, MissingFireResist = 35, ColdResist = 30, MissingColdResist = 45, LightningResist = 20, MissingLightningResist = 55 },
				lower = { ColdResist = 29, MissingColdResist = 46 },
			},
			{
				option = "chaosRes",
				start = { ChaosResist = -60, MissingChaosResist = 135 },
				lower = { ChaosResist = -61, MissingChaosResist = 136 },
			},
			{
				option = "block",
				start = { BlockChance = 25, SpellBlockChance = 15 },
				lower = { SpellBlockChance = 14 },
			},
			{
				option = "suppression",
				start = { SpellSuppressionChance = 60 },
				lower = { SpellSuppressionChance = 59 },
			},
			{
				option = "ailmentAvoidance",
				start = { ShockAvoidChance = 40, FreezeAvoidChance = 60, BrittleAvoidChance = 10 },
				lower = { BrittleAvoidChance = 9 },
			},
		}) do
			local function run(mode, lower)
				local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS", { [case.option] = mode })
				optimizer.calculate = function(override)
					local output = feasibleOutput(case.start)
					if override.spec.allocNodes[alternative.id] then
						output.CombinedDPS = 200
						for key, value in pairs(lower and case.lower or { }) do
							output[key] = value
						end
					end
					return output
				end
				return finish(optimizer)
			end
			local keep = run("KEEP")
			assert(keep.bestFeasible and keep.bestMetrics.dps == 200, case.option.." should allow unchanged sub-cap values")
			local lower = run("KEEP", true)
			assert(lower.improvements == 0 and lower.rejected > 0, case.option.." should reject a decrease")
			assert(run("NONE", true).bestMetrics.dps == 200, case.option.." should be unrestricted")
			local cap = run("CAP")
			assert(not cap.bestFeasible and cap.improvements == 0, case.option.." should still require the cap")
		end
	end)

	it("can find a feasible result from an infeasible start without returning invalid trees", function()
		local optimizer = build.treeTab:CreateTreeOptimizer("BALANCED", 1, "CombinedDPS", { suppression = true })
		optimizer.calculate = function(override)
			return feasibleOutput({
				CombinedDPS = 100,
				SpellSuppressionChance = override.spec.allocNodes[alternative.id] and 100 or 99,
			})
		end
		finish(optimizer)
		assert(optimizer.bestFeasible and optimizer.spec.allocNodes[alternative.id])
		assert(optimizer.improvements > 0)

		optimizer = build.treeTab:CreateTreeOptimizer("BALANCED", 1, "CombinedDPS", { suppression = true })
		optimizer.calculate = function()
			return feasibleOutput({ CombinedDPS = 200, SpellSuppressionChance = 99 })
		end
		finish(optimizer)
		assert(not optimizer.bestFeasible and optimizer.improvements == 0)
	end)

	it("checks reservation and gem/item requirements from real PoB outputs", function()
		build.itemsTab:CreateDisplayItemFromRaw("Rarity: NORMAL\nHubris Circlet")
		local item = build.itemsTab.displayItem
		build.itemsTab:AddDisplayItem()
		build.itemsTab.slots.Helmet:SetSelItemId(item.id)
		build.buildFlag = true
		runCallback("OnFrame")
		local optimizer = build.treeTab:CreateTreeOptimizer("BALANCED", 1, "CombinedDPS")
		local calculate = build.calcsTab:GetMiscCalculator()
		local itemOutput = calculate({ spec = optimizer.spec })
		assert(itemOutput.ReqInt > itemOutput.Int and itemOutput.ReqIntItem.source == "Item")
		assert(optimizer:ConstraintFailure(itemOutput):match("requirement"))

		build.skillsTab:PasteSocketGroup("Fireball 20/0  1\nDetermination 20/0  1\nGrace 20/0  1\nDiscipline 20/0  1\n")
		build.buildFlag = true
		runCallback("OnFrame")
		calculate = build.calcsTab:GetMiscCalculator()
		local output = calculate({ spec = optimizer.spec })
		assert(output.ManaUnreserved < 0, "Test must actually over-reserve mana")
		assert(optimizer:ConstraintFailure(output):match("Mana reservation"))
		local noReservation = copyTable(output, true)
		noReservation.ManaUnreserved = 0
		noReservation.LifeUnreserved = math.max(output.LifeUnreserved, 1)
		assert(output.ReqInt > output.Int and output.ReqDex > output.Dex)
		assert(optimizer:ConstraintFailure(noReservation):match("requirement"))
		assert(output.ReqDexItem.source == "Gem")
	end)

	it("keeps all popup text and controls inside its window", function()
		local measure = DrawStringWidth
		DrawStringWidth = function(height, _, text)
			local longest = 0
			for line in text:gmatch("[^\n]+") do
				longest = math.max(longest, #line:gsub("%^%d", "") * height * 0.65)
			end
			return longest
		end
		local ok, err = xpcall(function()
			build.treeTab:OpenOptimizerPopup()
			local popup = main.popups[1]
			local left, top = popup:GetPos()
			local width, height = popup:GetSize()
			for name, control in pairs(popup.controls) do
				local x, y = control:GetPos()
				local w, h = control:GetSize()
				if control.labelRight then
					w = w + control.labelWidth
				elseif name == "info" or name == "status" or name == "warning" then
					local _, lines = control:GetProperty("label"):gsub("\n", "")
					h = h * (lines + 1)
				end
				assert(x >= left and y >= top and x + w <= left + width and y + h <= top + height, name.." exceeds popup bounds")
			end
			popup.controls.suppression:SelByValue("CAP", "value")
			popup.controls.start:Click()
			local frames = 0
			while not popup.controls.status:GetProperty("label"):match("Finished") do
				popup:Draw(main.viewPort)
				frames = frames + 1
				assert(frames < 1000)
			end
			assert(not popup.controls.save:GetProperty("enabled"), "Uncapped suppression result must not be applicable")
			assert(popup.controls.status:GetProperty("label"):match("no feasible tree"))
			assert(popup.controls.status:GetProperty("width") <= width - 40)
			popup.controls.close:Click()
		end, debug.traceback)
		DrawStringWidth = measure
		assert(ok, err)
	end)

	it("passes defence modes to the search and remembers them when reopened", function()
		build.treeTab:OpenOptimizerPopup()
		local popup = main.popups[1]
		local modes = { elementalRes = "KEEP", chaosRes = "NONE", block = "CAP", suppression = "KEEP", ailmentAvoidance = "KEEP" }
		for key, mode in pairs(modes) do
			popup.controls[key]:SelByValue(mode, "value")
		end
		popup.controls.maxHit.state = true
		popup.controls.start:Click()
		for key, mode in pairs(modes) do
			assert(build.treeTab.optimizerConstraints[key] == mode)
			assert(not popup.controls[key]:IsEnabled())
		end
		assert(not popup.controls.maxHit:IsEnabled())
		popup.controls.stop:Click()
		popup.controls.close:Click()
		build.treeTab:OpenOptimizerPopup()
		popup = main.popups[1]
		for key, mode in pairs(modes) do
			local control = popup.controls[key]
			assert(control.list[control.selIndex].value == mode)
		end
		assert(popup.controls.maxHit.state)
		popup.controls.close:Click()
	end)

	it("runs the popup and applies the result only as a new tree", function()
		build.buildFlag = true
		runCallback("OnFrame")
		local source = build.spec
		local count = #build.treeTab.specList
		build.treeTab:OpenOptimizerPopup()
		local popup = main.popups[1]
		popup.controls.start:Click()
		local frames = 0
		repeat
			popup:Draw(main.viewPort)
			frames = frames + 1
			assert(frames < 1000, "Optimizer popup did not finish")
			assert(not popup.controls.status:GetProperty("label"):match("Search failed"))
		until popup.controls.status:GetProperty("label"):match("Finished")
		assert(build.spec == source and #build.treeTab.specList == count)
		assert(popup.controls.save:GetProperty("enabled"))
		local beforeSave = os.date("%Y%m%d%H%M%S")
		popup.controls.save:Click()
		local afterSave = os.date("%Y%m%d%H%M%S")
		assert(#build.treeTab.specList == count + 1 and build.spec ~= source)
		local prefix = (source.title or "Default").." (optimized "
		assert(build.spec.title == prefix..beforeSave..")" or build.spec.title == prefix..afterSave..")")
		assert(source.allocNodes[first.id] and source:CountAllocNodes() == 1)
		assert(build.spec:CountAllocNodes() == 1)
		assert(not main.popups[1])
	end)
end)
