-- Path of Building
--
-- Fixed-budget local search over connected passive branch exchanges.
local TreeOptimizer = { }
TreeOptimizer.__index = TreeOptimizer
local minimumMetricRatio = 0.995

function TreeOptimizer.DefaultConstraints(output)
	local recoveryOnBlock = (output.LifeOnBlock or 0) + (output.ManaOnBlock or 0)
		+ (output.EnergyShieldOnBlock or 0) + (output.EnergyShieldOnSpellBlock or 0)
	local block = math.max(output.BlockChance or 0, output.SpellBlockChance or 0) >= 50 or recoveryOnBlock > 0
	local avoidance = false
	for _, ailment in ipairs(data.elementalAilmentTypeList) do
		avoidance = avoidance or (output[ailment.."AvoidChance"] or 0) >= 100
	end
	return {
		elementalRes = 0, chaosRes = output.Life == 1 and output.ChaosResist == 100 and 100 or 0,
		block = block and 0 or 100,
		suppression = (output.SpellSuppressionChance or 0) >= 50 and 0 or 100,
		ailmentAvoidance = avoidance and 0 or 100,
		castingHeadroom = 0, maxHit = true, protectCaps = true,
	}
end

function TreeOptimizer.DefenceSummary(output)
	local elemental = math.min(output.FireMaximumHitTaken or 0, output.ColdMaximumHitTaken or 0, output.LightningMaximumHitTaken or 0)
	return {
		physical = output.PhysicalMaximumHitTaken or 0, elemental = elemental,
		regen = output.LifeRegenRecovery or 0, leech = output.LifeLeechGainRate or 0,
		netLife = output.NetLifeRegen or 0, netES = output.NetEnergyShieldRegen or 0,
	}
end

function TreeOptimizer.CanChange(node, spec, ignoreLocks)
	local original = spec.tree.nodes[node.id]
	return node.type ~= "ClassStart" and node.type ~= "AscendClassStart"
		and (node.type ~= "Mastery" or node.masteryEffects and #node.masteryEffects > 0)
		and not (original and original.type == "Mastery" and spec.hashOverrides[node.id])
		and (not node.ascendancyName or node.ascendancyName == spec.curAscendClassBaseName
			or spec.curSecondaryAscendClass and node.ascendancyName == spec.curSecondaryAscendClass.id)
		and not ((node.type == "Socket" or node.isJewelSocket) and spec:GetSocketedJewel(node.id))
		and (not node.isMultipleChoiceOption or node.ascendancyName)
		and (ignoreLocks or not spec.optimizerLocks[node.id])
end

local function allocationKey(allocation, masteries)
	local ids = { }
	for id in pairs(allocation) do
		table.insert(ids, id)
	end
	table.sort(ids)
	for index, id in ipairs(ids) do
		if masteries[id] then
			ids[index] = id..":"..masteries[id]
		end
	end
	return table.concat(ids, ",")
end

local function validMetric(value)
	return type(value) == "number" and value == value and value >= 0 and value < math.huge
end

function TreeOptimizer.new(spec, calculate, goal, depth, dpsStat, constraints)
	assert(goal == "BALANCED" or goal == "DPS" or goal == "EHP", "Unknown optimizer goal")
	assert(type(depth) == "number" and depth >= 1 and depth == math.floor(depth), "Invalid branch depth")
	assert(dpsStat == "FullDPS" or dpsStat == "CombinedDPS", "Unknown optimizer DPS metric")
	for id in pairs(spec.optimizerLocks) do
		assert(spec.allocNodes[id], "A required node is unallocated. Alt + right-click it to unlock it before optimizing.")
	end
	local budget, ascendancyBudget = spec:CountAllocNodes()
	local self = setmetatable({
		spec = spec,
		calculate = calculate,
		goal = goal,
		depth = depth,
		dpsStat = dpsStat,
		constraints = copyTable(constraints or { }),
		targets = { },
		budget = budget,
		ascendancyBudget = ascendancyBudget,
		classId = spec.curClassId,
		ascendClassId = spec.curAscendClassId,
		secondaryAscendClassId = spec.curSecondaryAscendClassId,
		required = { },
		requiredMasteries = { },
		bestMasteries = copyTable(spec.masterySelections),
		best = copyTable(spec.allocNodes, true),
		tested = 0,
		rejected = 0,
		improvements = 0,
		pass = 0,
	}, TreeOptimizer)
	for id, node in pairs(spec.allocNodes) do
		if not TreeOptimizer.CanChange(node, spec) then
			self.required[id] = true
			self.requiredMasteries[id] = spec.masterySelections[id]
		end
	end
	self.worker = coroutine.create(function() self:Run() end)
	return self
end

function TreeOptimizer:Restore(allocation, masteries)
	local restored = { }
	for id in pairs(allocation) do
		-- Cluster graph rebuilds replace node objects, including those in saved allocations.
		restored[id] = assert(self.spec.nodes[id], "Cannot restore missing passive: "..id)
	end
	for _, node in pairs(self.spec.nodes) do
		node.alloc = allocation[node.id] ~= nil
	end
	self.spec.allocNodes = restored
	self.spec.masterySelections = copyTable(masteries)
	self.spec:BuildAllDependsAndPaths()
end

function TreeOptimizer:IsValid()
	local used, ascendancyUsed = self.spec:CountAllocNodes()
	if used ~= self.budget or ascendancyUsed ~= self.ascendancyBudget
		or self.spec.curClassId ~= self.classId or self.spec.curAscendClassId ~= self.ascendClassId
		or self.spec.curSecondaryAscendClassId ~= self.secondaryAscendClassId then
		return false
	end
	for id in pairs(self.required) do
		if not self.spec.allocNodes[id] then
			return false
		end
	end
	for id in pairs(self.spec.optimizerBlocks) do
		if self.spec.allocNodes[id] then
			return false
		end
	end
	for id, effect in pairs(self.requiredMasteries) do
		if self.spec.masterySelections[id] ~= effect then
			return false
		end
	end
	local effects = { }
	for id, node in pairs(self.spec.allocNodes) do
		if node ~= self.spec.nodes[id] or not node.alloc
			or node.type ~= "ClassStart" and node.type ~= "AscendClassStart"
			and not node.connectedToStart and #node.intuitiveLeapLikesAffecting == 0 then
			return false
		end
		if node.type == "Mastery" and node.masteryEffects and #node.masteryEffects > 0 and not self.spec.hashOverrides[id] then
			local effect = self.spec.masterySelections[id]
			local allowed, accessible = false, false
			for _, option in ipairs(node.masteryEffects) do
				allowed = allowed or option.effect == effect
			end
			for _, linked in ipairs(node.linked) do
				accessible = accessible or linked.alloc and linked.type == "Notable"
			end
			if not effect or not self.spec.tree.masteryEffects[effect] or not allowed or not accessible or effects[effect] then
				return false
			end
			effects[effect] = true
		end
	end
	return true
end

function TreeOptimizer:MasteryEffects(node)
	local effects = { }
	for _, option in ipairs(node.masteryEffects) do
		local assigned = isValueInTable(self.spec.masterySelections, option.effect)
		if self.spec.tree.masteryEffects[option.effect] and (not assigned or assigned == node.id) then
			table.insert(effects, option.effect)
		end
	end
	table.sort(effects)
	return effects
end

function TreeOptimizer:Metrics()
	local mode = TreeOptimizer.GetConstraintMode(self.constraints.castingHeadroom)
	local output = self.calculate({ spec = self.spec, castingHeadroom = mode ~= 100 and mode ~= "NONE", survivability = true })
	local dps = output[self.dpsStat]
	if self.dpsStat == "FullDPS" and dps == nil then
		dps = data.powerStatList.GetFromOutput(output, { stat = "FullDPS" })
	end
	if self.dpsStat == "CombinedDPS" and output.Minion then
		dps = output.Minion.CombinedDPS
	end
	local ehp = output.ConfiguredSurvivalScore
	if not validMetric(dps) or not validMetric(ehp) or not validMetric(output.ConfiguredSurvivalTime) then
		return nil
	end
	return { dps = dps, ehp = ehp, survivalTime = output.ConfiguredSurvivalTime, defences = TreeOptimizer.DefenceSummary(output) }, output
end

function TreeOptimizer.GetConstraintMode(value)
	if type(value) == "number" then
		assert(value == value and value >= 0 and value <= 100, "Allowable reduction must be between 0 and 100")
		return value
	elseif value == nil then
		return 0
	elseif value == false then
		return "NONE"
	elseif value == true then
		return "CAP"
	end
	assert(value == "NONE" or value == "KEEP" or value == "CAP", "Unknown defensive constraint mode")
	return value
end

function TreeOptimizer:SetTargets(output)
	assert(validMetric(output.ExtraPoints), "Cannot determine passive-point grants")
	-- Match EstimatePlayerProgress's maximum quest-point allowance, without worsening an over-budget starting tree.
	self.minimumExtraPoints = math.min(output.ExtraPoints, math.max(0, self.budget - (self.spec.build.characterLevel - 1 + 23)))
	local function add(mode, stat, label, capStat, missingStat, cap)
		if mode == "NONE" or mode == 100 then
			return
		end
		local minimum = output[stat]
		assert(type(minimum) == "number" and minimum == minimum and math.abs(minimum) < math.huge,
			"Cannot determine optimizer target: "..label)
		if type(mode) == "number" then
			minimum = minimum - math.abs(minimum) * math.max(0.5, mode) / 100
			if self.constraints.protectCaps and mode == 0 and output[stat] >= 100
				and (stat == "SpellSuppressionChance" or stat:match("AvoidChance$")) then
				minimum = math.max(minimum, 100)
			end
		elseif mode == "CAP" then
			minimum = cap or (capStat and output[capStat]) or (minimum + output[missingStat])
		elseif mode == "KEEP" then
			-- Preserve the floor apart from floating-point roundoff.
			minimum = minimum - math.abs(minimum) * 1e-9
		end
		if mode ~= "CAP" then
			capStat, missingStat = nil, nil
		end
		table.insert(self.targets, { stat = stat, minimum = minimum, label = label, capStat = capStat, missingStat = missingStat })
	end
	for _, damageType in ipairs({ "Fire", "Cold", "Lightning", "Chaos" }) do
		local mode = TreeOptimizer.GetConstraintMode(self.constraints[damageType == "Chaos" and "chaosRes" or "elementalRes"])
		if mode ~= "NONE" then
			local stat = damageType.."Resist"
			add(mode, stat, damageType.." resistance", nil, "Missing"..stat)
		end
	end
	local blockMode = TreeOptimizer.GetConstraintMode(self.constraints.block)
	if blockMode ~= "NONE" then
		add(blockMode, "BlockChance", "Attack block", "BlockChanceMax")
		add(blockMode, "SpellBlockChance", "Spell block", "SpellBlockChanceMax")
	end
	local suppressionMode = TreeOptimizer.GetConstraintMode(self.constraints.suppression)
	if suppressionMode ~= "NONE" then
		add(suppressionMode, "SpellSuppressionChance", "Spell suppression", nil, nil, data.misc.SuppressionChanceCap)
	end
	local avoidanceMode = TreeOptimizer.GetConstraintMode(self.constraints.ailmentAvoidance)
	if avoidanceMode ~= "NONE" then
		for _, ailment in ipairs(data.elementalAilmentTypeList) do
			add(avoidanceMode, ailment.."AvoidChance", ailment.." avoidance", nil, nil, 100)
		end
	end
	local headroom = TreeOptimizer.GetConstraintMode(self.constraints.castingHeadroom)
	self.checkCastingHeadroom = headroom ~= 100 and headroom ~= "NONE"
	if self.checkCastingHeadroom then
		assert(type(headroom) == "number", "Casting headroom requires an allowable reduction between 0 and 100")
		for _, stat in ipairs({ "ManaCastingCapacityRatio", "ManaCastingSustainRatio" }) do
			local value = output[stat]
			assert(type(value) == "number" and value == value and math.abs(value) < math.huge,
				"Missing calculated casting headroom: "..stat)
			local minimum = math.max(1, value) * (1 - math.max(0.5, headroom) / 100)
			if headroom == 0 then
				minimum = math.max(1, minimum)
			end
			table.insert(self.targets, {
				stat = stat, minimum = minimum,
				label = stat == "ManaCastingCapacityRatio" and "Casting headroom (burst capacity)" or "Casting headroom (sustained recovery)",
			})
		end
	end
	if self.constraints.maxHit then
		for _, damageType in ipairs({ "Physical", "Fire", "Cold", "Lightning", "Chaos" }) do
			local stat = damageType.."MaximumHitTaken"
			add("KEEP", stat, damageType.." maximum hit taken")
		end
	end
end

function TreeOptimizer:ConstraintFailure(output)
	for id in pairs(self.spec.optimizerBlocks) do
		if self.spec.allocNodes[id] then
			return "Blocked passive is allocated: "..self.spec.nodes[id].dn.."."
		end
	end
	if not validMetric(output.ManaUnreserved) then
		return "Mana reservation exceeds available mana (or mana is not finite)."
	end
	if not validMetric(output.LifeUnreserved) or output.LifeUnreserved <= 0 then
		return "Life reservation must leave positive unreserved life."
	end
	if self.checkCastingHeadroom and output.ManaCastingUnsupported then
		return "Casting headroom: "..output.ManaCastingUnsupported.."\nSet to 100% to leave casting headroom unchecked."
	end
	if self.minimumExtraPoints and (not validMetric(output.ExtraPoints) or output.ExtraPoints < self.minimumExtraPoints) then
		return "Passive-point grants no longer cover the fixed normal-point budget."
	end
	for _, attr in ipairs({ "Str", "Dex", "Int", "Omni" }) do
		local required = output["Req"..attr]
		if required and (not validMetric(required) or not validMetric(output[attr]) or output[attr] < required) then
			return attr.." requirement is not met."
		end
	end
	for _, target in ipairs(self.targets) do
		local value = output[target.stat]
		local minimum = target.minimum
		if target.capStat then
			if not validMetric(output[target.capStat]) then
				return target.label.." cap is not finite."
			end
			minimum = math.max(minimum, output[target.capStat])
		end
		if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
			return target.label.." is not finite."
		end
		if value < minimum then
			if target.stat == "ManaCastingCapacityRatio" or target.stat == "ManaCastingSustainRatio" then
				return string.format("%s: %.3g < %.3g required.", target.label, value, minimum)
			end
			return target.label.." is below the required target."
		end
		if target.missingStat and (not validMetric(output[target.missingStat]) or output[target.missingStat] > 0) then
			return target.label.." is not capped."
		end
	end
end

function TreeOptimizer:Score(metrics)
	if metrics.survivalTime < self.base.survivalTime then
		return -math.huge
	end
	if self.goal == "DPS" then
		return metrics.dps / self.base.dps
	elseif self.goal == "EHP" then
		return metrics.dps >= self.base.dps * minimumMetricRatio and metrics.survivalTime / self.base.survivalTime or -math.huge
	end
	if metrics == self.base then
		return 0
	elseif metrics.dps <= self.base.dps
		or metrics.survivalTime == self.base.survivalTime and metrics.ehp <= self.base.ehp then
		return -math.huge
	end
	-- Buffer margin distinguishes equal survival times, including the simulation ceiling.
	return math.log(metrics.dps / self.base.dps) + math.log(metrics.survivalTime / self.base.survivalTime)
end

function TreeOptimizer:Evaluate(seen)
	local key = allocationKey(self.spec.allocNodes, self.spec.masterySelections)
	if seen[key] or not self:IsValid() then
		return
	end
	seen[key] = true
	local metrics, output = self:Metrics()
	self.tested = self.tested + 1
	local failure = not metrics and "DPS or configured survival is not finite." or self:ConstraintFailure(output)
	if metrics and not failure then
		local score = self:Score(metrics)
		local betterTie = score > -math.huge and score == self.bestScore
			and (metrics.survivalTime > self.bestMetrics.survivalTime
				or metrics.survivalTime == self.bestMetrics.survivalTime and metrics.ehp > self.bestMetrics.ehp)
		if score > self.bestScore + 1e-9 or betterTie then
			self.best = copyTable(self.spec.allocNodes, true)
			self.bestMasteries = copyTable(self.spec.masterySelections)
			self.bestMetrics = metrics
			self.bestScore = score
			self.bestFeasible = true
			self.improvements = self.improvements + 1
		end
	else
		self.rejected = self.rejected + 1
		self.lastRejection = failure
	end
end

function TreeOptimizer:Run()
	local metrics, output = self:Metrics()
	self.base = assert(metrics, "Optimizer requires finite DPS and configured survival. Check the build configuration.")
	assert(self.base.dps > 0 and self.base.ehp > 0 and self.base.survivalTime > 0,
		"Optimizer requires positive DPS and configured survival time/score. Select a damaging skill and check the enemy configuration.")
	self:SetTargets(output)
	self.initialFailure = self:ConstraintFailure(output) or (not self:IsValid() and "Passive allocation or mastery selection is invalid.")
	self.bestFeasible = not self.initialFailure
	self.bestMetrics = self.base
	self.bestScore = self.bestFeasible and self:Score(self.base) or -math.huge
	local seen = { [allocationKey(self.best, self.bestMasteries)] = true }
	while true do
		self.pass = self.pass + 1
		local current = self.best
		local currentMasteries = self.bestMasteries
		local masteryIds = { }
		for id in pairs(currentMasteries) do
			if TreeOptimizer.CanChange(self.spec.nodes[id], self.spec) then
				table.insert(masteryIds, id)
			end
		end
		table.sort(masteryIds)
		for _, id in ipairs(masteryIds) do
			self:Restore(current, currentMasteries)
			for _, effect in ipairs(self:MasteryEffects(self.spec.nodes[id])) do
				if effect ~= currentMasteries[id] then
					self:Restore(current, currentMasteries)
					self.spec.masterySelections[id] = effect
					self.spec:BuildAllDependsAndPaths()
					self:Evaluate(seen)
					coroutine.yield()
				end
			end
		end
		self:Restore(current, currentMasteries)
		local choices = { }
		for id, node in pairs(self.spec.nodes) do
			if node.isMultipleChoiceOption and not node.alloc and node.path and TreeOptimizer.CanChange(node, self.spec)
				and not self.spec.optimizerBlocks[id] then
				local used, ascendancyUsed = self.spec:CountAllocNodes(node.path)
				if used == 0 and ascendancyUsed == 0 then
					table.insert(choices, id)
				end
			end
		end
		table.sort(choices)
		for _, id in ipairs(choices) do
			self:Restore(current, currentMasteries)
			self.spec:AllocNode(self.spec.nodes[id])
			self:Evaluate(seen)
			coroutine.yield()
		end
		self:Restore(current, currentMasteries)
		local removals = { }
		for id in pairs(current) do
			local node = self.spec.nodes[id]
			local used, ascendancyUsed = self.spec:CountAllocNodes(node.depends)
			local cost = used + ascendancyUsed
			if TreeOptimizer.CanChange(node, self.spec) and cost > 0 and cost <= self.depth then
				local allowed = true
				for _, dependent in ipairs(node.depends) do
					if not TreeOptimizer.CanChange(dependent, self.spec) then
						allowed = false
						break
					end
				end
				if allowed then
					table.insert(removals, id)
				end
			end
		end
		table.sort(removals)
		for index, id in ipairs(removals) do
			self.branch = index
			self.branches = #removals
			self:Restore(current, currentMasteries)
			self.spec:DeallocNode(self.spec.nodes[id])
			local reduced = copyTable(self.spec.allocNodes, true)
			local reducedMasteries = copyTable(self.spec.masterySelections)
			local used, ascendancyUsed = self.spec:CountAllocNodes()
			local normalCost = self.budget - used
			local ascendancyCost = self.ascendancyBudget - ascendancyUsed
			local cost = normalCost + ascendancyCost
			local additions = { }
			if cost > 0 and cost <= self.depth then
				for targetId, node in pairs(self.spec.nodes) do
					if not node.alloc and node.path and TreeOptimizer.CanChange(node, self.spec) then
						local path = #node.intuitiveLeapLikesAffecting > 0 and { node } or node.path
						local normalPoints, ascendancyPoints = self.spec:CountAllocNodes(path)
						local allowed = normalPoints == normalCost and ascendancyPoints == ascendancyCost
						for _, pathNode in ipairs(path) do
							if not TreeOptimizer.CanChange(pathNode, self.spec) or self.spec.optimizerBlocks[pathNode.id] then
								allowed = false
								break
							end
						end
						if allowed then
							local ids = { }
							for _, pathNode in ipairs(path) do
								table.insert(ids, pathNode.id)
							end
							if node.type == "Mastery" then
								for _, effect in ipairs(self:MasteryEffects(node)) do
									table.insert(additions, { id = targetId, path = ids, effect = effect })
								end
							else
								table.insert(additions, { id = targetId, path = ids })
							end
						end
					end
				end
			end
			table.sort(additions, function(a, b)
				return a.id < b.id or a.id == b.id and (a.effect or 0) < (b.effect or 0)
			end)
			coroutine.yield()
			for _, addition in ipairs(additions) do
				self:Restore(reduced, reducedMasteries)
				local path = { }
				for _, pathId in ipairs(addition.path) do
					table.insert(path, self.spec.nodes[pathId])
				end
				if addition.effect then
					self.spec.masterySelections[addition.id] = addition.effect
				end
				self.spec:AllocNode(self.spec.nodes[addition.id], path)
				self:Evaluate(seen)
				coroutine.yield()
			end
		end
		self:Restore(self.best, self.bestMasteries)
		if current == self.best then
			self.done = true
			return
		end
	end
end

function TreeOptimizer:Stop()
	self:Restore(self.best, self.bestMasteries)
	self.done = true
	self.worker = nil
end

return TreeOptimizer
