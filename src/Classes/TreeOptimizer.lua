-- Path of Building
--
-- Fixed-budget local search over connected passive branch exchanges.
local TreeOptimizer = { }
TreeOptimizer.__index = TreeOptimizer

function TreeOptimizer.CanChange(node, spec)
	local original = spec.tree.nodes[node.id]
	return node.type ~= "ClassStart" and node.type ~= "AscendClassStart"
		and node.type ~= "Mastery" and not (original and original.type == "Mastery")
		and not node.ascendancyName and node.type ~= "Socket" and not node.isJewelSocket
		and not node.expansionSkill and node.id < 65536 and not node.isMultipleChoiceOption
		and not spec.optimizerLocks[node.id]
end

local function allocationKey(allocation)
	local ids = { }
	for id in pairs(allocation) do
		table.insert(ids, id)
	end
	table.sort(ids)
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
	local self = setmetatable({
		spec = spec,
		calculate = calculate,
		goal = goal,
		depth = depth,
		dpsStat = dpsStat,
		constraints = copyTable(constraints or { }),
		targets = { },
		budget = spec:CountAllocNodes(),
		required = { },
		masteries = copyTable(spec.masterySelections),
		best = copyTable(spec.allocNodes, true),
		tested = 0,
		rejected = 0,
		improvements = 0,
		pass = 0,
	}, TreeOptimizer)
	for id, node in pairs(spec.allocNodes) do
		if not TreeOptimizer.CanChange(node, spec) then
			self.required[id] = true
		end
	end
	self.worker = coroutine.create(function() self:Run() end)
	return self
end

function TreeOptimizer:Restore(allocation)
	for _, node in pairs(self.spec.nodes) do
		node.alloc = allocation[node.id] ~= nil
	end
	self.spec.allocNodes = copyTable(allocation, true)
	self.spec.masterySelections = copyTable(self.masteries)
	self.spec:BuildAllDependsAndPaths()
end

function TreeOptimizer:IsValid()
	if self.spec:CountAllocNodes() ~= self.budget then
		return false
	end
	for id in pairs(self.required) do
		if not self.spec.allocNodes[id] then
			return false
		end
	end
	for id, effect in pairs(self.masteries) do
		if self.spec.masterySelections[id] ~= effect then
			return false
		end
	end
	return true
end

function TreeOptimizer:Metrics()
	local output = self.calculate({ spec = self.spec })
	local dps = output[self.dpsStat]
	if self.dpsStat == "CombinedDPS" and output.Minion then
		dps = output.Minion.CombinedDPS
	end
	local ehp = output.TotalEHP
	if not validMetric(dps) or not validMetric(ehp) then
		return nil
	end
	return { dps = dps, ehp = ehp }, output
end

function TreeOptimizer.GetConstraintMode(value)
	if value == nil or value == false then
		return "NONE"
	elseif value == true then
		return "CAP"
	end
	assert(value == "NONE" or value == "KEEP" or value == "CAP", "Unknown defensive constraint mode")
	return value
end

function TreeOptimizer:SetTargets(output)
	local function add(stat, minimum, label, capStat, missingStat)
		assert(type(minimum) == "number" and minimum == minimum,
			"Cannot determine optimizer target: "..label)
		table.insert(self.targets, { stat = stat, minimum = minimum, label = label, capStat = capStat, missingStat = missingStat })
	end
	for _, damageType in ipairs({ "Fire", "Cold", "Lightning", "Chaos" }) do
		local mode = TreeOptimizer.GetConstraintMode(self.constraints[damageType == "Chaos" and "chaosRes" or "elementalRes"])
		if mode ~= "NONE" then
			local stat = damageType.."Resist"
			if mode == "KEEP" then
				add(stat, output[stat], damageType.." resistance")
			else
				local missingStat = "Missing"..stat
				assert(type(output[stat]) == "number" and type(output[missingStat]) == "number",
					"Missing calculated resistance cap: "..damageType)
				add(stat, output[stat] + output[missingStat], damageType.." resistance", nil, missingStat)
			end
		end
	end
	local blockMode = TreeOptimizer.GetConstraintMode(self.constraints.block)
	if blockMode ~= "NONE" then
		add("BlockChance", blockMode == "CAP" and output.BlockChanceMax or output.BlockChance, "Attack block", blockMode == "CAP" and "BlockChanceMax" or nil)
		add("SpellBlockChance", blockMode == "CAP" and output.SpellBlockChanceMax or output.SpellBlockChance, "Spell block", blockMode == "CAP" and "SpellBlockChanceMax" or nil)
	end
	local suppressionMode = TreeOptimizer.GetConstraintMode(self.constraints.suppression)
	if suppressionMode ~= "NONE" then
		add("SpellSuppressionChance", suppressionMode == "CAP" and data.misc.SuppressionChanceCap or output.SpellSuppressionChance, "Spell suppression")
	end
	local avoidanceMode = TreeOptimizer.GetConstraintMode(self.constraints.ailmentAvoidance)
	if avoidanceMode ~= "NONE" then
		for _, ailment in ipairs(data.elementalAilmentTypeList) do
			add(ailment.."AvoidChance", avoidanceMode == "CAP" and 100 or output[ailment.."AvoidChance"], ailment.." avoidance")
		end
	end
	if self.constraints.maxHit then
		for _, damageType in ipairs({ "Physical", "Fire", "Cold", "Lightning", "Chaos" }) do
			local stat = damageType.."MaximumHitTaken"
			add(stat, output[stat], damageType.." maximum hit taken")
		end
	end
end

function TreeOptimizer:ConstraintFailure(output)
	if not validMetric(output.ManaUnreserved) then
		return "Mana reservation exceeds available mana (or mana is not finite)."
	end
	if not validMetric(output.LifeUnreserved) or output.LifeUnreserved <= 0 then
		return "Life reservation must leave positive unreserved life."
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
		if type(value) ~= "number" or value ~= value or value < minimum then
			return target.label.." is below the required target."
		end
		if target.missingStat and (not validMetric(output[target.missingStat]) or output[target.missingStat] > 0) then
			return target.label.." is not capped."
		end
	end
end

function TreeOptimizer:Score(metrics)
	if self.goal == "DPS" then
		return metrics.ehp >= self.base.ehp and metrics.dps / self.base.dps or -math.huge
	elseif self.goal == "EHP" then
		return metrics.dps >= self.base.dps and metrics.ehp / self.base.ehp or -math.huge
	end
	-- Log ratios give DPS and EHP equal relative weight without multiplying huge outputs.
	return math.log(metrics.dps / self.base.dps) + math.log(metrics.ehp / self.base.ehp)
end

function TreeOptimizer:Run()
	local metrics, output = self:Metrics()
	self.base = assert(metrics, "Optimizer requires finite DPS and EHP. Check the build configuration.")
	assert(self.base.dps > 0 and self.base.ehp > 0, "Optimizer requires positive DPS and EHP. Select a damaging skill and check the enemy configuration.")
	self:SetTargets(output)
	self.initialFailure = self:ConstraintFailure(output)
	self.bestFeasible = not self.initialFailure
	self.bestMetrics = self.base
	self.bestScore = self.bestFeasible and self:Score(self.base) or -math.huge
	local seen = { [allocationKey(self.best)] = true }
	while true do
		self.pass = self.pass + 1
		local current = self.best
		local removals = { }
		for id, node in pairs(current) do
			if TreeOptimizer.CanChange(node, self.spec) and #node.depends <= self.depth then
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
			self:Restore(current)
			self.spec:DeallocNode(self.spec.nodes[id])
			local reduced = copyTable(self.spec.allocNodes, true)
			local cost = self.budget - self.spec:CountAllocNodes()
			local additions = { }
			if cost > 0 and cost <= self.depth then
				for targetId, node in pairs(self.spec.nodes) do
					if not node.alloc and node.path and TreeOptimizer.CanChange(node, self.spec) then
						local path = #node.intuitiveLeapLikesAffecting > 0 and { node } or node.path
						local allowed = #path == cost
						for _, pathNode in ipairs(path) do
							if not TreeOptimizer.CanChange(pathNode, self.spec) then
								allowed = false
								break
							end
						end
						if allowed then
							local ids = { }
							for _, pathNode in ipairs(path) do
								table.insert(ids, pathNode.id)
							end
							table.insert(additions, { id = targetId, path = ids })
						end
					end
				end
			end
			table.sort(additions, function(a, b) return a.id < b.id end)
			coroutine.yield()
			for _, addition in ipairs(additions) do
				self:Restore(reduced)
				local path = { }
				for _, pathId in ipairs(addition.path) do
					table.insert(path, self.spec.nodes[pathId])
				end
				self.spec:AllocNode(self.spec.nodes[addition.id], path)
				local key = allocationKey(self.spec.allocNodes)
				if not seen[key] and self:IsValid() then
					seen[key] = true
					local metrics, output = self:Metrics()
					self.tested = self.tested + 1
					local failure = not metrics and "DPS or EHP is not finite." or self:ConstraintFailure(output)
					if metrics and not failure then
						local score = self:Score(metrics)
						if score > self.bestScore + 1e-9 then
							self.best = copyTable(self.spec.allocNodes, true)
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
				coroutine.yield()
			end
		end
		self:Restore(self.best)
		if current == self.best then
			self.done = true
			return
		end
	end
end

function TreeOptimizer:Stop()
	self:Restore(self.best)
	self.done = true
	self.worker = nil
end

return TreeOptimizer
