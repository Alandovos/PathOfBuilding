describe("Tree optimizer", function()
	local TreeOptimizer = require("Classes.TreeOptimizer")
	local first, alternative
	local function feasibleOutput(values)
		local output = {
			CombinedDPS = 100, TotalEHP = 100,
			ManaUnreserved = 100, LifeUnreserved = 100,
			ManaCastingCapacityRatio = 2, ManaCastingSustainRatio = 2,
			ExtraPoints = 0,
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
		local _, ascendancyUsed = optimizer.spec:CountAllocNodes()
		assert(ascendancyUsed == optimizer.ascendancyBudget, "Ascendancy point budget changed")
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

	local function socketFireCluster()
		local spec = build.spec
		local socket
		for nodeId in pairs(spec.tree.sockets) do
			local node = spec.nodes[nodeId]
			if node and node.expansionJewel and node.expansionJewel.size == 2 and node.path
				and (not socket or #node.path < #socket.path or #node.path == #socket.path and node.id < socket.id) then
				socket = node
			end
		end
		assert(socket)
		spec:AllocNode(socket)
		local jewel = new("Item"):Item([[Rarity: RARE
Optimizer Fire Cluster
Large Cluster Jewel
Cluster Jewel Skill: affliction_fire_damage
Cluster Jewel Node Count: 8
Implicits: 3
Adds 8 Passive Skills
2 Added Passive Skills are Jewel Sockets
Added Small Passive Skills grant: 12% increased Fire Damage
1 Added Passive Skill is Prismatic Heart
1 Added Passive Skill is Widespread Destruction
1 Added Passive Skill is Burning Bright]])
		build.itemsTab:AddItem(jewel, true)
		spec.jewels[socket.id] = jewel.id
		spec:BuildClusterJewelGraphs()
		for _, graph in pairs(spec.subGraphs) do
			if graph.parentSocket.id == socket.id then
				return socket, jewel, graph
			end
		end
		error("Fire cluster graph was not built")
	end

	local function allocateSpareAttribute()
		for _, node in pairs(build.spec.nodes) do
			if not node.alloc and node.path and #node.path == 1
				and (node.dn == "Strength" or node.dn == "Dexterity" or node.dn == "Intelligence") then
				build.spec:AllocNode(node)
				return node
			end
		end
		error("No spare attribute passive found")
	end

	local function accessMastery(name)
		local mastery, notable
		for _, node in pairs(build.spec.nodes) do
			if node.type == "Mastery" and not node.alloc and node.masteryEffects and #node.masteryEffects > 1
				and not node.ascendancyName and (not name or node.name == name) then
				for _, linked in ipairs(node.linked) do
					if linked.type == "Notable" and linked.path and (not notable or #linked.path < #notable.path) then
						mastery, notable = node, linked
					end
				end
			end
		end
		assert(mastery and notable, "No accessible mastery fixture found")
		build.spec:AllocNode(notable)
		assert(#mastery.path == 1)
		return mastery
	end

	local function lockAllocated()
		for id, node in pairs(build.spec.allocNodes) do
			if TreeOptimizer.CanChange(node, build.spec) then
				build.spec.optimizerLocks[id] = true
			end
		end
	end

	local function selectWitchAscendancy()
		for id, class in pairs(build.spec.tree.classes) do
			if class.name == "Witch" then
				build.spec:SelectClass(id)
				build.spec:SelectAscendClass(1)
				return
			end
		end
		error("No Witch ascendancy fixture found")
	end

	local function ascendancyBranches(name, depth)
		local choices = { }
		for _, node in pairs(build.spec.nodes) do
			local normal, ascendancy = build.spec:CountAllocNodes(node.path or {})
			if not node.alloc and node.ascendancyName == name and node.path and normal == 0 and ascendancy == depth
				and TreeOptimizer.CanChange(node, build.spec) then
				table.insert(choices, node)
			end
		end
		table.sort(choices, function(a, b) return a.id < b.id end)
		for _, a in ipairs(choices) do
			for _, b in ipairs(choices) do
				if a.path[#a.path].id ~= b.path[#b.path].id then
					return a, b
				end
			end
		end
	end

	local function reliquarianRelic(name)
		local selected
		for id, class in pairs(build.spec.curClass.classes) do
			if class.name == "Reliquarian" then
				build.spec:SelectAscendClass(id)
				selected = true
				break
			end
		end
		assert(selected, "Reliquarian ascendancy is missing")
		for _, node in pairs(build.spec.nodes) do
			if node.ascendancyName == build.spec.curAscendClassBaseName and node.dn == (name or "Foulborn Tremor Rod") then
				build.spec:AllocNode(node)
				return node
			end
		end
		error("Reliquarian relic choice is missing")
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

	it("keeps locked mastery effects, locked ascendancy passives and occupied sockets fixed", function()
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
		build.spec.optimizerLocks[mastery.id] = true
		build.spec:AllocNode(socket)
		local jewel = new("Item"):Item([[Rarity: RARE
Optimizer Jewel
Crimson Jewel
Implicits: 0
+10 to Strength]])
		build.itemsTab:AddItem(jewel, true)
		build.spec.jewels[socket.id] = jewel.id
		build.spec:AllocNode(ascendancy)
		build.spec.optimizerLocks[ascendancy.id] = true
		local optimizer = build.treeTab:CreateTreeOptimizer("BALANCED", 1, "CombinedDPS")
		optimizer.calculate = function(override)
			assert(override.spec.allocNodes[socket.id] and override.spec.jewels[socket.id] == jewel.id)
			return feasibleOutput()
		end
		finish(optimizer)
		assert(optimizer.spec.curAscendClassId == build.spec.curAscendClassId)
		assert(optimizer.spec.curSecondaryAscendClassId == build.spec.curSecondaryAscendClassId)
		assert(optimizer.spec.masterySelections[mastery.id] == effect)
		assert(optimizer.spec.allocNodes[mastery.id] and optimizer.spec.allocNodes[socket.id])
		assert(optimizer.spec.jewels[socket.id] == jewel.id)
		for id, node in pairs(build.spec.nodes) do
			if node.ascendancyName or node.type == "Mastery" or node.type == "Socket" and build.spec:GetSocketedJewel(id) then
				assert(not not optimizer.spec.allocNodes[id] == not not build.spec.allocNodes[id])
			end
		end
	end)

	it("exchanges connected ascendancy branches while respecting locks and blocks", function()
		selectWitchAscendancy()
		local from, target = ascendancyBranches(build.spec.curAscendClassBaseName, 2)
		assert(from and target, "No two-point ascendancy branches found")
		build.spec:AllocNode(from)
		local normalBudget, ascendancyBudget = build.spec:CountAllocNodes()
		local ascendClassId = build.spec.curAscendClassId
		for _, restriction in ipairs({ "none", "lock", "block" }) do
			build.spec.optimizerLocks[from.id] = restriction == "lock" or nil
			build.spec.optimizerBlocks[target.id] = restriction == "block" or nil
			local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 2, "CombinedDPS")
			optimizer.calculate = function(override)
				local used, ascendancyUsed = override.spec:CountAllocNodes()
				assert(used == normalBudget and ascendancyUsed == ascendancyBudget)
				assert(override.spec.curAscendClassId == ascendClassId)
				return feasibleOutput({ CombinedDPS = override.spec.allocNodes[target.id] and 200 or 100 })
			end
			finish(optimizer)
			if restriction == "none" then
				assert(optimizer.spec.allocNodes[target.id] and not optimizer.spec.allocNodes[from.id])
				assert(optimizer.bestMetrics.dps == 200)
			else
				assert(optimizer.spec.allocNodes[from.id] and not optimizer.spec.allocNodes[target.id])
				assert(optimizer.improvements == 0)
			end
			assert(build.spec.allocNodes[from.id] and not build.spec.allocNodes[target.id], "Original ascendancy was changed")
		end
	end)

	it("shares ascendancy points with an already selected secondary ascendancy without changing either selection", function()
		selectWitchAscendancy()
		local from = ascendancyBranches(build.spec.curAscendClassBaseName, 1)
		assert(from)
		build.spec:AllocNode(from)
		local target
		for id, ascendancy in pairs(build.spec.tree.alternate_ascendancies or {}) do
			if id ~= 0 then
				build.spec:SelectSecondaryAscendClass(id)
				target = ascendancyBranches(ascendancy.id, 1)
				if target then break end
			end
		end
		assert(target, "No secondary ascendancy branches found")
		local primary, secondary = build.spec.curAscendClassId, build.spec.curSecondaryAscendClassId
		local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS")
		optimizer.calculate = function(override)
			assert(override.spec.curAscendClassId == primary and override.spec.curSecondaryAscendClassId == secondary)
			for _, node in pairs(override.spec.allocNodes) do
				assert(not node.ascendancyName or node.ascendancyName == override.spec.curAscendClassBaseName
					or node.ascendancyName == override.spec.curSecondaryAscendClass.id)
			end
			return feasibleOutput({ CombinedDPS = override.spec.allocNodes[target.id] and 200 or 100 })
		end
		finish(optimizer)
		local _, total, secondaryUsed = optimizer.spec:CountAllocNodes()
		assert(total == 1 and secondaryUsed == 1)
		assert(optimizer.spec.allocNodes[target.id] and not optimizer.spec.allocNodes[from.id])
		assert(build.spec.allocNodes[from.id] and not build.spec.allocNodes[target.id])
	end)

	it("cannot spend normal points as ascendancy points or change ascendancy identifiers", function()
		build.spec:SelectAscendClass(1)
		local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS")
		optimizer.calculate = function(override)
			local _, ascendancyUsed = override.spec:CountAllocNodes()
			assert(ascendancyUsed == 0, "A normal point was converted into an ascendancy point")
			return feasibleOutput({ CombinedDPS = override.spec.allocNodes[alternative.id] and 200 or 100 })
		end
		finish(optimizer)
		assert(optimizer.spec.allocNodes[alternative.id] and optimizer.ascendancyBudget == 0)
		for _, node in pairs(optimizer.spec.nodes) do
			if node.ascendancyName and node.ascendancyName ~= optimizer.spec.curAscendClassBaseName then
				assert(not TreeOptimizer.CanChange(node, optimizer.spec, true), "A foreign ascendancy was unlocked")
			end
		end
		assert(optimizer:IsValid())
		optimizer.spec.curAscendClassId = optimizer.ascendClassId + 1
		assert(not optimizer:IsValid())
		optimizer.spec.curAscendClassId = optimizer.ascendClassId
		optimizer.spec.curSecondaryAscendClassId = (optimizer.secondaryAscendClassId or 0) + 1
		assert(not optimizer:IsValid())
	end)

	it("preserves passive-point grants only when needed for the allocated normal-point budget", function()
		local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS")
		build.characterLevel = 1
		optimizer.budget = 26
		optimizer:SetTargets(feasibleOutput({ ExtraPoints = 5 }))
		assert(not optimizer:ConstraintFailure(feasibleOutput({ ExtraPoints = 3 })))
		assert(optimizer:ConstraintFailure(feasibleOutput({ ExtraPoints = 2 })):match("Passive%-point grants"))
		optimizer.budget = 23
		optimizer.targets = {}
		optimizer:SetTargets(feasibleOutput({ ExtraPoints = 5 }))
		assert(not optimizer:ConstraintFailure(feasibleOutput({ ExtraPoints = 0 })))
	end)

	it("optimizes zero-cost relic choices while respecting choice locks and blocks", function()
		local from = reliquarianRelic()
		local parent = from.linked[1]
		local target
		for _, option in ipairs(parent.linked) do
			if option.isMultipleChoiceOption and option ~= from then
				target = option
				break
			end
		end
		assert(target)
		local primary = build.spec.curAscendClassId
		for _, restriction in ipairs({ "none", "lock", "block" }) do
			build.spec.optimizerLocks[from.id] = restriction == "lock" or nil
			build.spec.optimizerBlocks[target.id] = restriction == "block" or nil
			local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS")
			optimizer.calculate = function(override)
				return feasibleOutput({ CombinedDPS = override.spec.allocNodes[target.id] and 200 or 100 })
			end
			finish(optimizer)
			assert(optimizer.spec.curAscendClassId == primary and optimizer.spec.allocNodes[parent.id])
			local choices = 0
			for _, option in ipairs(parent.linked) do
				if option.isMultipleChoiceOption and optimizer.spec.allocNodes[option.id] then
					choices = choices + 1
				end
			end
			assert(choices == 1, "Relic choices must remain mutually exclusive")
			assert((optimizer.spec.allocNodes[target.id] ~= nil) == (restriction == "none"))
			assert(build.spec.allocNodes[from.id] and not build.spec.allocNodes[target.id])
		end
	end)

	it("refunds a Reliquarian display and its zero-cost child at the actual spent-point depth", function()
		local from = reliquarianRelic("The Arkhon's Tools")
		local parent = from.linked[1]
		for _, node in pairs(build.spec.allocNodes) do
			if node.ascendancyName == build.spec.curAscendClassBaseName and node.dn == "Passive Point" then
				build.spec.optimizerLocks[node.id] = true
			end
		end
		local probe = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS")
		probe.spec:DeallocNode(probe.spec.nodes[parent.id])
		local target
		for _, node in pairs(probe.spec.nodes) do
			if not node.alloc and node.path and node.ascendancyName == probe.spec.curAscendClassBaseName then
				local normal, ascendancy = probe.spec:CountAllocNodes(node.path)
				local allowed = normal == 0 and ascendancy == 1
				for _, pathNode in ipairs(node.path) do
					allowed = allowed and pathNode.id ~= parent.id and TreeOptimizer.CanChange(pathNode, probe.spec)
				end
				if allowed then
					target = node
					break
				end
			end
		end
		assert(target, "Fixture needs another reachable one-point ascendancy path")
		local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS")
		optimizer.calculate = function(override)
			return feasibleOutput({ CombinedDPS = override.spec.allocNodes[target.id] and 200 or 100 })
		end
		finish(optimizer)
		assert(optimizer.spec.allocNodes[target.id], "The one-point exchange did not reach its target")
		assert(not optimizer.spec.allocNodes[from.id] and not optimizer.spec.allocNodes[parent.id])
		assert(optimizer.bestMetrics.dps == 200)
		assert(build.spec.allocNodes[from.id] and build.spec.allocNodes[parent.id])
	end)

	it("adds an accessible mastery and tries each effect at the same point budget", function()
		local mastery = accessMastery()
		local effect = mastery.masteryEffects[2].effect
		lockAllocated()
		local spare
		for _, node in pairs(build.spec.nodes) do
			if node.type == "Normal" and not node.alloc and node.path and #node.path == 1
				and TreeOptimizer.CanChange(node, build.spec) then
				spare = node
				break
			end
		end
		assert(spare)
		build.spec:AllocNode(spare)
		local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS")
		optimizer.calculate = function(override)
			return feasibleOutput({ CombinedDPS = override.spec.masterySelections[mastery.id] == effect and 200 or 100 })
		end
		finish(optimizer)
		assert(optimizer.spec.allocNodes[mastery.id] and optimizer.spec.masterySelections[mastery.id] == effect)
		assert(not optimizer.spec.allocNodes[spare.id])
		assert(not build.spec.allocNodes[mastery.id] and not build.spec.masterySelections[mastery.id])
	end)

	it("refunds a mastery and clears its effect when another passive is better", function()
		local mastery = accessMastery()
		lockAllocated()
		build.spec.masterySelections[mastery.id] = mastery.masteryEffects[1].effect
		build.spec:AllocNode(mastery)
		local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS")
		optimizer.calculate = function(override)
			return feasibleOutput({ CombinedDPS = not override.spec.allocNodes[mastery.id] and 200 or 100 })
		end
		finish(optimizer)
		assert(not optimizer.spec.allocNodes[mastery.id] and not optimizer.spec.masterySelections[mastery.id])
		assert(build.spec.allocNodes[mastery.id] and build.spec.masterySelections[mastery.id])
	end)

	it("changes a mastery effect, applies its real stats and preserves it through save/load", function()
		local mastery = accessMastery("Life Mastery")
		local targetEffect, originalEffect
		for _, option in ipairs(mastery.masteryEffects) do
			local effect = build.spec.tree.masteryEffects[option.effect]
			for _, line in ipairs(effect.sd) do
				if line:match("^%+%d+ to maximum Life$") then
					targetEffect = option.effect
				end
			end
		end
		assert(targetEffect)
		for _, option in ipairs(mastery.masteryEffects) do
			if option.effect ~= targetEffect then
				originalEffect = option.effect
				break
			end
		end
		lockAllocated()
		build.spec.masterySelections[mastery.id] = originalEffect
		build.spec:AllocNode(mastery)
		build.buildFlag = true
		runCallback("OnFrame")
		local calculate, baseline = build.calcsTab:GetMiscCalculator()
		local optimizer = build.treeTab:CreateTreeOptimizer("EHP", 1, "CombinedDPS")
		optimizer.calculate = function(override)
			return feasibleOutput({ TotalEHP = override.spec.masterySelections[mastery.id] == targetEffect and 200 or 100 })
		end
		finish(optimizer)
		assert(optimizer.spec.masterySelections[mastery.id] == targetEffect)
		assert(build.spec.masterySelections[mastery.id] == originalEffect)
		local output = calculate({ spec = optimizer.spec })
		assert(output.Life > baseline.Life, "Selected life mastery must affect actual calculations")
		local xml = { }
		optimizer.spec:Save(xml)
		local loaded = new("PassiveSpec"):PassiveSpec(build, build.spec.treeVersion)
		loaded:Load(xml, "mastery optimizer test")
		loaded:PostLoad()
		assert(loaded.allocNodes[mastery.id] and loaded.masterySelections[mastery.id] == targetEffect)
		assert(loaded:CountAllocNodes() == optimizer.budget)
		assert(math.abs(calculate({ spec = loaded }).Life - output.Life) < 1e-8)
	end)

	it("credits simulated nearby-mine damage taken when comparing mine mastery effects", function()
		local mastery = accessMastery("Mine Mastery")
		lockAllocated()
		build.spec.masterySelections[mastery.id] = 533
		build.spec:AllocNode(mastery)
		for id, node in pairs(build.spec.nodes) do
			if not node.alloc and TreeOptimizer.CanChange(node, build.spec) then
				build.spec.optimizerBlocks[id] = true
			end
		end
		build.skillsTab:PasteSocketGroup("Pyroclast Mine 1/0  1")
		build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 1/0  1")
		build.configTab.input.pyroclastMineManaLimited = false
		build.configTab.input.customMods = "+1000 to all Attributes"
		build.configTab:BuildModList()
		build.buildFlag = true
		runCallback("OnFrame")
		local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS", { castingHeadroom = 100 })
		local calculate, damageTakenDPS = optimizer.calculate
		optimizer.calculate = function(override)
			local output = calculate(override)
			if override.spec.masterySelections[mastery.id] == 29161 then
				damageTakenDPS = output.CombinedDPS
			end
			return output
		end
		finish(optimizer)
		assert(damageTakenDPS and damageTakenDPS > optimizer.base.dps, "Offensive mine mastery received no DPS credit")
		assert(optimizer.bestMetrics.dps >= damageTakenDPS)
		assert(optimizer.bestMetrics.ehp == optimizer.base.ehp)
		assert(build.spec.masterySelections[mastery.id] == 533)
	end)

	it("does not duplicate a mastery effect already selected at another locked mastery", function()
		local firstMastery = accessMastery("Life Mastery")
		local firstEffect = firstMastery.masteryEffects[1].effect
		build.spec.masterySelections[firstMastery.id] = firstEffect
		build.spec:AllocNode(firstMastery)
		local secondMastery = accessMastery("Life Mastery")
		local originalEffect = secondMastery.masteryEffects[2].effect
		local targetEffect = secondMastery.masteryEffects[3].effect
		lockAllocated()
		build.spec.masterySelections[secondMastery.id] = originalEffect
		build.spec:AllocNode(secondMastery)
		local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS")
		optimizer.calculate = function(override)
			local selected = override.spec.masterySelections[secondMastery.id]
			assert(selected ~= firstEffect, "Duplicate mastery effect reached the calculator")
			return feasibleOutput({ CombinedDPS = selected == targetEffect and 200 or 100 })
		end
		finish(optimizer)
		assert(optimizer.spec.masterySelections[firstMastery.id] == firstEffect)
		assert(optimizer.spec.masterySelections[secondMastery.id] == targetEffect)
	end)

	it("excludes blocked nodes and paths through them", function()
		local target, extension
		for _, node in ipairs(alternative.linked) do
			if node.type == "Normal" and node.path and #node.path == 2 then
				target = node
				break
			end
		end
		for _, node in ipairs(first.linked) do
			if node.type == "Normal" and not node.alloc and node.path and #node.path == 1 then
				extension = node
				break
			end
		end
		assert(target and extension)
		build.spec:AllocNode(extension)
		build.spec.optimizerBlocks[alternative.id] = true
		local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 3, "CombinedDPS")
		optimizer.calculate = function(override)
			assert(not override.spec.allocNodes[alternative.id])
			return feasibleOutput({ CombinedDPS = override.spec.allocNodes[target.id] and 200 or 100 })
		end
		finish(optimizer)
		assert(not optimizer.spec.allocNodes[alternative.id] and not optimizer.spec.allocNodes[target.id])
	end)

	it("refunds blocked allocated nodes before accepting a result, even at lower DPS", function()
		build.spec.optimizerBlocks[first.id] = true
		local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS")
		optimizer.calculate = function(override)
			return feasibleOutput({ CombinedDPS = override.spec.allocNodes[first.id] and 100 or 90 })
		end
		finish(optimizer)
		assert(optimizer.initialFailure:match("Blocked passive"))
		assert(optimizer.bestFeasible and not optimizer.spec.allocNodes[first.id])
		assert(optimizer.bestMetrics.dps == 90)
		assert(build.spec.allocNodes[first.id], "Blocking must not modify the source tree")
	end)

	it("does not offer an infeasible result when all replacements for a blocked node are forbidden", function()
		for id, node in pairs(build.spec.nodes) do
			if TreeOptimizer.CanChange(node, build.spec, true) then
				build.spec.optimizerBlocks[id] = true
			end
		end
		local optimizer = search("DPS", 200, 100)
		assert(not optimizer.bestFeasible and optimizer.improvements == 0)
		assert(optimizer.initialFailure:match("Blocked passive"))
	end)

	it("moves a main-tree point into an equipped fire cluster and preserves it through save/load", function()
		local socket, jewel, graph = socketFireCluster()
		local target = graph.entranceNode
		assert(target.expansionSkill and not target.alloc and #target.path == 1)
		for id, node in pairs(build.spec.allocNodes) do
			if TreeOptimizer.CanChange(node, build.spec) then
				build.spec.optimizerLocks[id] = true
			end
		end
		local spare = allocateSpareAttribute()
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.buildFlag = true
		runCallback("OnFrame")
		local source = build.spec
		local calculate, baseline = build.calcsTab:GetMiscCalculator()
		local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS")
		optimizer.calculate = function(override)
			return feasibleOutput({ CombinedDPS = override.spec.allocNodes[target.id] and 200 or 100 })
		end
		finish(optimizer)
		assert(optimizer.spec.allocNodes[target.id] and not optimizer.spec.allocNodes[spare.id])
		assert(optimizer.spec.allocNodes[socket.id] and optimizer.spec.jewels[socket.id] == jewel.id)
		assert(source.allocNodes[spare.id] and not source.allocNodes[target.id])
		local output = calculate({ spec = optimizer.spec })
		assert(output.CombinedDPS > baseline.CombinedDPS, "Cluster fire damage must increase actual Fireball DPS")
		local targetId, socketId, jewelId, budget = target.id, socket.id, jewel.id, optimizer.budget
		optimizer.spec:ResetUndo()
		table.insert(build.treeTab.specList, optimizer.spec)
		build.treeTab:SetActiveSpec(#build.treeTab.specList)
		local xml = build:SaveDB("Optimized fire cluster")
		loadBuildFromXML(xml)
		assert(build.spec.allocNodes[targetId] and build.spec:CountAllocNodes() == budget)
		assert(build.spec.allocNodes[socketId] and build.spec.jewels[socketId] == jewelId)
		runCallback("OnFrame")
		assert(math.abs(build.calcsTab.mainOutput.CombinedDPS - output.CombinedDPS) < 1e-8)
	end)

	it("exchanges a branch for a multi-point path to a cluster notable", function()
		local socket, jewel, graph = socketFireCluster()
		local target
		for _, node in ipairs(graph.nodes) do
			if node.type == "Notable" and (not target or #node.path < #target.path) then
				target = node
			end
		end
		assert(target and #target.path > 1)
		local cost = #target.path
		for _, node in ipairs(target.path) do
			assert(TreeOptimizer.CanChange(node, build.spec), "Cluster path crosses a fixed "..node.type)
		end
		for id, node in pairs(build.spec.allocNodes) do
			if TreeOptimizer.CanChange(node, build.spec) then
				build.spec.optimizerLocks[id] = true
			end
		end
		local branch
		for _, node in pairs(build.spec.nodes) do
			if not node.alloc and not node.expansionSkill and node.path and #node.path == cost then
				local allowed = true
				for _, pathNode in ipairs(node.path) do
					if not TreeOptimizer.CanChange(pathNode, build.spec) then
						allowed = false
						break
					end
				end
				if allowed then
					branch = node
					break
				end
			end
		end
		assert(branch)
		local budget = build.spec:CountAllocNodes()
		build.spec:AllocNode(branch)
		assert(build.spec:CountAllocNodes() == budget + cost, "Spare branch must provide the cluster path's point cost")
		local optimizer = build.treeTab:CreateTreeOptimizer("DPS", cost, "CombinedDPS")
		optimizer.calculate = function(override)
			return feasibleOutput({ CombinedDPS = override.spec.allocNodes[target.id] and 200 or 100 })
		end
		finish(optimizer)
		assert(optimizer.improvements > 0 and optimizer.spec.allocNodes[target.id],
			"Cluster path cost "..cost.."; tested "..optimizer.tested.."; rejected "..optimizer.rejected)
		for _, node in ipairs(target.path) do
			assert(optimizer.spec.allocNodes[node.id], "The entire cluster path must be allocated")
		end
		assert(optimizer.spec.allocNodes[socket.id] and optimizer.spec.jewels[socket.id] == jewel.id)
	end)

	it("can refund cluster passives but respects cluster locks and keeps occupied sockets fixed", function()
		local socket, jewel, graph = socketFireCluster()
		local target = graph.entranceNode
		build.spec:AllocNode(target)
		local function optimize()
			local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS")
			optimizer.calculate = function(override)
				assert(override.spec.allocNodes[socket.id] and override.spec.jewels[socket.id] == jewel.id)
				return feasibleOutput({ CombinedDPS = not override.spec.allocNodes[target.id] and 200 or 100 })
			end
			return finish(optimizer)
		end
		local optimizer = optimize()
		assert(optimizer.improvements > 0 and not optimizer.spec.allocNodes[target.id])
		build.spec.optimizerLocks[target.id] = true
		optimizer = optimize()
		assert(optimizer.improvements == 0 and optimizer.spec.allocNodes[target.id])
	end)

	for _, clustered in ipairs({ false, true }) do
		for _, zeroId in ipairs({ false, true }) do
			it("adds and refunds an empty " .. (clustered and "cluster" or "main-tree") .. " socket with " .. (zeroId and "zero" or "no") .. " item ID", function()
				local nodes = build.spec.nodes
				if clustered then
					local _, _, graph = socketFireCluster()
					nodes = graph.nodes
				end
				local socket
				for _, node in pairs(nodes) do
					if node.type == "Socket" and node.path and not node.ascendancyName
						and (not socket or #node.path < #socket.path) then
						socket = node
					end
				end
				assert(socket)
				local socketId = socket.id
				build.spec.jewels[socketId] = zeroId and 0 or nil
				build.spec:AllocNode(socket)
				lockAllocated()
				build.spec.optimizerLocks[socketId] = nil
				local spareId
				for id, node in pairs(build.spec.nodes) do
					if not node.alloc and node.type == "Normal" and node.path and #node.path == 1
						and TreeOptimizer.CanChange(node, build.spec) then
						spareId = id
						build.spec:AllocNode(node)
						break
					end
				end
				assert(spareId, "No spare passive found")
				build.spec:DeallocNode(build.spec.nodes[socketId])
				local function optimize(targetId)
					local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS")
					optimizer.calculate = function(override)
						return feasibleOutput({ CombinedDPS = override.spec.allocNodes[targetId] and 200 or 100 })
					end
					return finish(optimizer)
				end
				build.spec.optimizerBlocks[socketId] = true
				local blocked = optimize(socketId)
				assert(not blocked.spec.allocNodes[socketId] and blocked.spec.allocNodes[spareId])
				build.spec.optimizerBlocks[socketId] = nil
				local optimizer = optimize(socketId)
				assert(optimizer.spec.allocNodes[socketId] and not optimizer.spec.allocNodes[spareId])
				assert(not build.spec.allocNodes[socketId] and build.spec.allocNodes[spareId])
				assert(not optimizer.spec:GetSocketedJewel(socketId))
				build.spec:DeallocNode(build.spec.nodes[spareId])
				build.spec:AllocNode(build.spec.nodes[socketId])
				build.spec.optimizerLocks[socketId] = true
				local locked = optimize(spareId)
				assert(locked.spec.allocNodes[socketId] and not locked.spec.allocNodes[spareId])
				build.spec.optimizerLocks[socketId] = nil
				optimizer = optimize(spareId)
				assert(not optimizer.spec.allocNodes[socketId] and optimizer.spec.allocNodes[spareId])
				assert(build.spec.allocNodes[socketId] and not build.spec.allocNodes[spareId])
				assert(not optimizer.spec:GetSocketedJewel(socketId))
			end)
		end
	end

	it("allocates passives in a nested equipped cluster without disconnecting either jewel", function()
		local socket, jewel, graph = socketFireCluster()
		local nestedSocket
		for _, node in ipairs(graph.nodes) do
			if node.type == "Socket" then
				nestedSocket = node
				break
			end
		end
		assert(nestedSocket)
		build.spec:AllocNode(nestedSocket)
		local nestedJewel = new("Item"):Item([[Rarity: UNIQUE
One With Nothing
Small Cluster Jewel
Implicits: 0
Adds Hollow Palm Technique]])
		build.itemsTab:AddItem(nestedJewel, true)
		build.spec.jewels[nestedSocket.id] = nestedJewel.id
		build.spec:BuildClusterJewelGraphs()
		local target
		for _, subgraph in pairs(build.spec.subGraphs) do
			if subgraph.parentSocket.id == nestedSocket.id then
				target = subgraph.entranceNode
			end
		end
		assert(target and not target.alloc and #target.path == 1)
		allocateSpareAttribute()
		local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 3, "CombinedDPS")
		optimizer.calculate = function(override)
			assert(override.spec.allocNodes[socket.id] and override.spec.jewels[socket.id] == jewel.id)
			assert(override.spec.allocNodes[nestedSocket.id] and override.spec.jewels[nestedSocket.id] == nestedJewel.id)
			return feasibleOutput({ CombinedDPS = override.spec.allocNodes[target.id] and 200 or 100 })
		end
		finish(optimizer)
		assert(optimizer.improvements > 0 and optimizer.spec.allocNodes[target.id])
		assert(not build.spec.allocNodes[target.id], "Original nested cluster must be unchanged")
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
		local mastery = accessMastery()
		local effect = mastery.masteryEffects[1].effect
		build.spec.masterySelections[mastery.id] = effect
		build.spec:AllocNode(mastery)
		local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS")
		optimizer.calculate = function()
			return feasibleOutput()
		end
		assert(coroutine.resume(optimizer.worker))
		assert(not optimizer.done)
		optimizer:Stop()
		assert(optimizer.done and optimizer.spec.allocNodes[first.id])
		assert(optimizer.spec:CountAllocNodes() == optimizer.budget)
		assert(optimizer.spec.masterySelections[mastery.id] == effect)
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

	it("persists locks and blocks through save/load, copying and undo states", function()
		build.spec.optimizerLocks[first.id] = true
		build.spec.optimizerBlocks[alternative.id] = true
		local state = build.spec:CreateUndoState()
		build.spec.optimizerLocks[first.id] = nil
		build.spec.optimizerBlocks[alternative.id] = nil
		build.spec:RestoreUndoState(state)
		assert(build.spec.optimizerLocks[first.id])
		assert(build.spec.optimizerBlocks[alternative.id])
		local xml = { }
		build.spec:Save(xml)
		local loaded = new("PassiveSpec"):PassiveSpec(build, build.spec.treeVersion)
		loaded:Load(xml, "optimizer test")
		loaded:PostLoad()
		assert(loaded.optimizerLocks[first.id] and loaded.allocNodes[first.id])
		assert(loaded.optimizerBlocks[alternative.id])
		local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS")
		assert(optimizer.spec.optimizerLocks[first.id])
		assert(optimizer.spec.optimizerLocks ~= build.spec.optimizerLocks)
		assert(optimizer.spec.optimizerBlocks[alternative.id])
		assert(optimizer.spec.optimizerBlocks ~= build.spec.optimizerBlocks)
	end)

	it("toggles required and blocked nodes with distinct gestures without replacing ordinary right-click", function()
		build.buildFlag = true
		runCallback("OnFrame")
		local viewer = build.treeTab.viewer
		local viewport = { x = 0, y = 0, width = 1000, height = 800 }
		viewer:Focus(first.x, first.y, viewport, build)
		local cursor, keyDown = GetCursorPos, IsKeyDown
		local zoom, zoomCalls = viewer.Zoom, 0
		viewer.Zoom = function(self, ...)
			zoomCalls = zoomCalls + 1
			return zoom(self, ...)
		end
		local alt = true
		local ctrl = false
		GetCursorPos = function() return 500, 400 end
		IsKeyDown = function(key) return key == "ALT" and alt or key == "CTRL" and ctrl end
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
			ctrl = true
			rightClick()
			assert(build.spec.optimizerBlocks[first.id] and not build.spec.optimizerLocks[first.id])
			ctrl = false
			rightClick()
			assert(build.spec.optimizerLocks[first.id] and not build.spec.optimizerBlocks[first.id])
			ctrl = true
			rightClick()
			assert(build.spec.optimizerBlocks[first.id] and not build.spec.optimizerLocks[first.id])
			rightClick()
			assert(not build.spec.optimizerBlocks[first.id])
			viewer:Focus(alternative.x, alternative.y, viewport, build)
			rightClick()
			assert(build.spec.optimizerBlocks[alternative.id] and not alternative.alloc)
			assert(zoomCalls == 0, "The blocking gesture must not zoom")
			alt = false
			rightClick()
			assert(zoomCalls == 1, "Ordinary Ctrl-right-click must still zoom")
		end, debug.traceback)
		GetCursorPos, IsKeyDown = cursor, keyDown
		viewer.Zoom = zoom
		assert(ok, err)
	end)

	it("uses actual PoB calculations for an improved result", function()
		build.buildFlag = true
		runCallback("OnFrame")
		local calculate = build.calcsTab:GetMiscCalculator()
		local startingMana = calculate({ spec = build.spec }).ManaUnreserved
		local protected = finish(build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS"))
		local optimizer = finish(build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS", { castingHeadroom = 100 }))
		assert(optimizer.tested > 0 and optimizer.improvements > 0)
		assert(optimizer.bestMetrics.dps > optimizer.base.dps)
		assert(optimizer.bestMetrics.ehp >= optimizer.base.ehp)
		assert(protected.bestMetrics.dps == optimizer.bestMetrics.dps, "A mana-free attack should not require unused mana capacity")
		local output = calculate({ spec = optimizer.spec })
		assert(math.abs(output.CombinedDPS - optimizer.bestMetrics.dps) < 1e-8)
		assert(output.ManaUnreserved < startingMana * 0.995,
			string.format("Expected mana loss: starting %g, optimized %g", startingMana, output.ManaUnreserved))
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

	it("enforces percentage reductions at their boundaries for every slider", function()
		for _, case in ipairs({
			{ option = "elementalRes", stat = "ColdResist", start = 75 },
			{ option = "chaosRes", stat = "ChaosResist", start = -60 },
			{ option = "block", stat = "SpellBlockChance", start = 75 },
			{ option = "suppression", stat = "SpellSuppressionChance", start = 100 },
			{ option = "ailmentAvoidance", stat = "BrittleAvoidChance", start = 100 },
			{ option = "castingHeadroom", stat = "ManaCastingCapacityRatio", start = 2 },
			{ option = "castingHeadroom", stat = "ManaCastingSustainRatio", start = 2 },
		}) do
			local function run(reduction, value)
				local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS", { [case.option] = reduction })
				optimizer.calculate = function(override)
					local candidate = override.spec.allocNodes[alternative.id]
					return feasibleOutput({ CombinedDPS = candidate and 200 or 100, [case.stat] = candidate and value or case.start })
				end
				return finish(optimizer)
			end
			for _, reduction in ipairs({ 0, 10 }) do
				local minimum = case.start - math.abs(case.start) * (reduction == 0 and 0.005 or 0.1)
				assert(run(reduction, minimum).bestMetrics.dps == 200, case.option.." rejected the boundary")
				assert(run(reduction, minimum - 0.001).improvements == 0, case.option.." exceeded the reduction")
			end
			assert(run(100, case.start - math.abs(case.start)).bestMetrics.dps == 200, case.option.." should be unrestricted")
		end
	end)

	it("anchors reduction targets to the initial tree and preserves both headroom components by default", function()
		local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS", { elementalRes = 10 })
		optimizer:SetTargets(feasibleOutput())
		assert(not optimizer:ConstraintFailure(feasibleOutput({ FireResist = 67.5, ManaCastingCapacityRatio = 1.99, ManaCastingSustainRatio = 1.99 })))
		assert(optimizer:ConstraintFailure(feasibleOutput({ FireResist = 67.499 })))
		assert(optimizer:ConstraintFailure(feasibleOutput({ ManaCastingCapacityRatio = 1.989 })):match("burst capacity"))
		assert(optimizer:ConstraintFailure(feasibleOutput({ ManaCastingSustainRatio = 1.989 })):match("sustained recovery"))
		local unrestricted = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS", { castingHeadroom = 100 })
		unrestricted:SetTargets(feasibleOutput())
		assert(not unrestricted:ConstraintFailure(feasibleOutput({ ManaUnreserved = 0 })))
		assert(unrestricted:ConstraintFailure(feasibleOutput({ ManaUnreserved = -1 })):match("Mana reservation"))
	end)

	it("rejects invalid allowable reductions", function()
		for _, value in ipairs({ -1, 101, math.huge, 0 / 0 }) do
			local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS", { castingHeadroom = value })
			assert(not pcall(function() optimizer:SetTargets(feasibleOutput()) end))
		end
	end)

	it("budgets shared recurring costs, emergency utilities and temporary reservation separately", function()
		local calcs = require("Modules.Calcs")
		local skills = {
			{ cost = 10, sustained = 100, recurring = true },
			{ cost = 20, sustained = 40, recurring = true },
			{ cost = 30, upkeep = 0, movement = true },
			{ cost = 25, upkeep = 0, movement = true },
			{ cost = 40, upkeep = 0, guard = true },
			{ cost = 5, upkeep = 0 },
			{ cost = 15, upkeep = 5 },
		}
		local output = calcs.manaCastingHeadroom(skills, 400, 290, 170)
		assert(output.ManaCastingEmergency == 85 and output.ManaCastingBurst == 115)
		assert(output.ManaCastingSustainedCost == 145)
		assert(output.ManaCastingCapacityRatio == 2 and output.ManaCastingSustainRatio == 2)
		local free = calcs.manaCastingHeadroom({}, 0, 0, 0)
		assert(free.ManaCastingCapacityRatio == 1 and free.ManaCastingSustainRatio == 1)
		assert(calcs.manaCastingHeadroom({}, 0, 0, 10).ManaCastingCapacityRatio == 0,
			"Zero casting cost must not hide unaffordable temporary reservation")
	end)

	it("rejects cost increases and recovery losses even when unreserved mana stays unchanged", function()
		local calcs = require("Modules.Calcs")
		for _, change in ipairs({ "cost", "recovery" }) do
			local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS")
			optimizer.calculate = function(override)
				local candidate = override.spec.allocNodes[alternative.id]
				local cost = candidate and change == "cost" and 20 or 10
				local recovery = candidate and change == "recovery" and 98 or 100
				local headroom = calcs.manaCastingHeadroom({ { cost = cost, sustained = cost * 5, recurring = true } }, 100, recovery, 20)
				headroom.CombinedDPS = candidate and 200 or 100
				return feasibleOutput(headroom)
			end
			finish(optimizer)
			assert(optimizer.improvements == 0 and optimizer.rejected > 0, change.." was not protected")
		end
	end)

	it("requires an unsafe baseline to cover its budget instead of preserving its deficit", function()
		local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS")
		optimizer:SetTargets(feasibleOutput({ ManaCastingCapacityRatio = 0.4, ManaCastingSustainRatio = 0.4 }))
		assert(optimizer:ConstraintFailure(feasibleOutput({ ManaCastingCapacityRatio = 0.999 })):match("burst capacity"))
		assert(optimizer:ConstraintFailure(feasibleOutput({ ManaCastingSustainRatio = 0.999 })):match("sustained recovery"))
		assert(not optimizer:ConstraintFailure(feasibleOutput({ ManaCastingCapacityRatio = 1, ManaCastingSustainRatio = 1 })))
		local relaxed = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS", { castingHeadroom = 50 })
		relaxed:SetTargets(feasibleOutput({ ManaCastingCapacityRatio = 0.4, ManaCastingSustainRatio = 0.4 }))
		assert(not relaxed:ConstraintFailure(feasibleOutput({ ManaCastingCapacityRatio = 0.5, ManaCastingSustainRatio = 0.5 })))
		assert(relaxed:ConstraintFailure(feasibleOutput({ ManaCastingSustainRatio = 0.499 })))
		for _, invalid in ipairs({ math.huge, -math.huge, 0 / 0 }) do
			assert(optimizer:ConstraintFailure(feasibleOutput({ ManaCastingCapacityRatio = invalid })):match("not finite"))
			assert(optimizer:ConstraintFailure(feasibleOutput({ ManaCastingSustainRatio = invalid })):match("not finite"))
		end
		optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS")
		optimizer.calculate = function(override)
			local ratio = override.spec.allocNodes[alternative.id] and 1 or 0.4
			return feasibleOutput({ ManaCastingCapacityRatio = ratio, ManaCastingSustainRatio = ratio })
		end
		finish(optimizer)
		assert(optimizer.bestFeasible and optimizer.improvements > 0 and optimizer.spec.allocNodes[alternative.id],
			"An unsafe start must still be able to improve into full budget coverage")
	end)

	it("reports unsupported payment and only skips the audit when explicitly unrestricted", function()
		for _, reduction in ipairs({ 0, 100 }) do
			local optimizer = build.treeTab:CreateTreeOptimizer("DPS", 1, "CombinedDPS", { castingHeadroom = reduction })
			optimizer.calculate = function(override)
				assert(override.castingHeadroom == (reduction ~= 100))
				return feasibleOutput({ ManaCastingUnsupported = "ES payment is unsupported." })
			end
			finish(optimizer)
			assert(optimizer.bestFeasible == (reduction == 100))
			if reduction == 0 then
				assert(optimizer.initialFailure:match("ES payment is unsupported"))
			end
		end
	end)

	it("uses modified utility costs and real triggered cadence without leaking candidate caches", function()
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.skillsTab:PasteSocketGroup("Flame Dash 1/0  1")
		build.skillsTab:PasteSocketGroup("Molten Shell 1/0  1")
		build.skillsTab:PasteSocketGroup("Steelskin 1/0  1\nAutomation 20/0  1")
		local function headroom(mods)
			build.configTab.input.customMods = mods or ""
			build.configTab:BuildModList()
			build.buildFlag = true
			runCallback("OnFrame")
			return build.calcsTab:GetMiscCalculator()({ spec = build.spec, castingHeadroom = true })
		end
		local baseline = headroom()
		assert(baseline.ManaCastingEmergency > 0 and baseline.ManaCastingBurst > baseline.ManaCastingEmergency)
		local cheaper = headroom("50% reduced Mana Cost of Skills")
		assert(cheaper.ManaUnreserved == baseline.ManaUnreserved)
		assert(cheaper.ManaCastingBurst < baseline.ManaCastingBurst)
		assert(cheaper.ManaCastingSustainedCost < baseline.ManaCastingSustainedCost)
		assert(headroom().ManaCastingBurst == baseline.ManaCastingBurst)
		local slowerRecovery = headroom("50% reduced Mana Regeneration Rate")
		assert(slowerRecovery.ManaUnreserved == baseline.ManaUnreserved)
		assert(slowerRecovery.ManaCastingSustainRatio < baseline.ManaCastingSustainRatio)
		build.skillsTab.socketGroupList[4].enabled = false
		local noTrigger = headroom()
		assert(noTrigger.ManaCastingSustainedCost < baseline.ManaCastingSustainedCost,
			"Enabled Automation must contribute its actual triggered mana spending")
		build.skillsTab.socketGroupList[2].enabled = false
		build.skillsTab.socketGroupList[3].enabled = false
		local noUtilities = headroom()
		assert(noUtilities.ManaCastingEmergency == 0 and noUtilities.ManaCastingBurst < noTrigger.ManaCastingBurst)
		assert(noUtilities.ManaCastingSustainedCost == noTrigger.ManaCastingSustainedCost,
			"On-demand utilities must not be assumed continuously spammed")
		local refunded = headroom("Every second time you Cast each Spell, gain Mana equal to its Upfront Cost")
		assert(refunded.ManaCastingCost == noUtilities.ManaCastingCost and refunded.ManaCastingBurst == noUtilities.ManaCastingBurst)
		assert(math.abs(refunded.ManaFullRateCost * 2 - noUtilities.ManaFullRateCost) < 1e-8,
			"Guaranteed refunds reduce recurring spending, not upfront affordability")
		assert(headroom("Eldritch Battery").ManaCastingUnsupported:match("ES payment"))
	end)

	it("converts percentage costs and includes enabled ongoing drains from other skills", function()
		build.skillsTab:PasteSocketGroup("Manabond 1/0  1")
		build.skillsTab:PasteSocketGroup("Bladefall of Trarthus 1/0  1")
		local function headroom()
			build.buildFlag = true
			runCallback("OnFrame")
			return build.calcsTab:GetMiscCalculator()({ spec = build.spec, castingHeadroom = true })
		end
		local withDrain = headroom()
		assert(withDrain.ManaPercentCost > 0)
		assert(math.abs(withDrain.ManaCastingCost - withDrain.ManaCost - withDrain.ManaPercentCost * withDrain.Mana / 100) < 1e-8)
		build.skillsTab.socketGroupList[2].enabled = false
		local withoutDrain = headroom()
		assert(math.abs(withDrain.ManaCastingSustainedCost - withoutDrain.ManaCastingSustainedCost - withDrain.Mana * 0.05) < 1e-8,
			"Bladefall of Trarthus's enabled 5%-mana-per-second drain must contribute even when it is not selected")
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
			popup.controls.suppression:SetVal(0)
			popup.controls.start:Click()
			local frames = 0
			while not popup.controls.status:GetProperty("label"):match("Finished") do
				popup:Draw(main.viewPort)
				frames = frames + 1
				assert(frames < 1000)
			end
			assert(not popup.controls.status:GetProperty("label"):match("Search failed"))
			assert(popup.controls.status:GetProperty("width") <= width - 40)
			popup.controls.close:Click()
		end, debug.traceback)
		DrawStringWidth = measure
		assert(ok, err)
	end)

	it("keeps popup labels readable after a disabled slider draws black", function()
		build.treeTab:OpenOptimizerPopup()
		local popup = main.popups[1]
		local drawString, setDrawColor = DrawString, SetDrawColor
		local colour, drawn = { 0, 0, 0 }, 0
		SetDrawColor = function(r, g, b)
			colour = { r, g, b }
		end
		DrawString = function(_, _, _, _, _, text)
			local effective = text:match("^%^7") and { 1, 1, 1 } or colour
			assert(effective[1] == 1 and effective[2] == 1 and effective[3] == 1,
				"Optimizer text inherited a dark drawing colour: "..text)
			drawn = drawn + 1
		end
		local ok, err = xpcall(function()
			popup.controls.start:Click()
			assert(not popup.controls.castingHeadroom:IsEnabled())
			for name, control in pairs(popup.controls) do
				if name == "info" or name == "status" or name == "warning" or name:match("Label$") or name:match("Value$") then
					popup.controls.castingHeadroom:Draw(main.viewPort)
					assert(colour[1] == 0 and colour[2] == 0 and colour[3] == 0)
					control:Draw()
				end
			end
			assert(drawn > 10)
		end, debug.traceback)
		DrawString, SetDrawColor = drawString, setDrawColor
		popup.controls.close:Click()
		assert(ok, err)
	end)

	it("passes reduction sliders to the search and remembers them when reopened", function()
		build.treeTab:OpenOptimizerPopup()
		local popup = main.popups[1]
		local reductions = { elementalRes = 0, chaosRes = 100, block = 10, suppression = 20, ailmentAvoidance = 30, castingHeadroom = 5 }
		for key in pairs(reductions) do
			assert(popup.controls[key].val == 0, key.." must default to 0% allowable reduction")
		end
		for key, reduction in pairs(reductions) do
			popup.controls[key]:SetVal(reduction / 100)
			assert(popup.controls[key.."Value"]:GetProperty("label") == "^7"..reduction.."%")
		end
		popup.controls.maxHit.state = true
		popup.controls.start:Click()
		for key, reduction in pairs(reductions) do
			assert(build.treeTab.optimizerConstraints[key] == reduction)
			assert(not popup.controls[key]:IsEnabled())
		end
		assert(not popup.controls.maxHit:IsEnabled())
		popup.controls.stop:Click()
		popup.controls.close:Click()
		build.treeTab:OpenOptimizerPopup()
		popup = main.popups[1]
		for key, reduction in pairs(reductions) do
			local control = popup.controls[key]
			assert(math.abs(control.val * 100 - reduction) < 1e-8)
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
		popup.controls.castingHeadroom:SetVal(1)
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
