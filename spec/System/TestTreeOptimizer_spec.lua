describe("Tree optimizer", function()
	local TreeOptimizer = require("Classes.TreeOptimizer")
	local first, alternative

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
			return { CombinedDPS = chosen and dps or 100, TotalEHP = chosen and ehp or 100 }
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

	it("rejects EHP loss in DPS mode and DPS loss in EHP mode", function()
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
			return { CombinedDPS = 100, TotalEHP = 100 }
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
			return { CombinedDPS = override.spec.allocNodes[target.id] and 200 or 100, TotalEHP = 100 }
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
			return { CombinedDPS = 100, TotalEHP = 100 }
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
			return {
				CombinedDPS = override.spec.allocNodes[first.id] and 1000 or 1,
				FullDPS = override.spec.allocNodes[alternative.id] and 200 or 100,
				TotalEHP = 100,
			}
		end
		assert(finish(optimizer).bestMetrics.dps == 200)
		optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS")
		optimizer.calculate = function(override)
			return {
				CombinedDPS = 1000,
				Minion = { CombinedDPS = override.spec.allocNodes[alternative.id] and 200 or 100 },
				TotalEHP = 100,
			}
		end
		assert(finish(optimizer).bestMetrics.dps == 200)
	end)

	it("discards tentative allocations when stopped", function()
		local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS")
		optimizer.calculate = function()
			return { CombinedDPS = 100, TotalEHP = 100 }
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
			return { CombinedDPS = 0, TotalEHP = 100 }
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
		popup.controls.save:Click()
		assert(#build.treeTab.specList == count + 1 and build.spec ~= source)
		assert(source.allocNodes[first.id] and source:CountAllocNodes() == 1)
		assert(build.spec:CountAllocNodes() == 1)
		assert(not main.popups[1])
	end)
end)
