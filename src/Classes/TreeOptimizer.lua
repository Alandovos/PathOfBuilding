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

function TreeOptimizer.new(spec, calculate, goal, depth, dpsStat)
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
	return { dps = dps, ehp = ehp }
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
	self.base = assert(self:Metrics(), "Optimizer requires finite DPS and EHP. Check the build configuration.")
	assert(self.base.dps > 0 and self.base.ehp > 0, "Optimizer requires positive DPS and EHP. Select a damaging skill and check the enemy configuration.")
	self.bestMetrics = self.base
	self.bestScore = self:Score(self.base)
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
					local metrics = self:Metrics()
					self.tested = self.tested + 1
					if metrics then
						local score = self:Score(metrics)
						if score > self.bestScore + 1e-9 then
							self.best = copyTable(self.spec.allocNodes, true)
							self.bestMetrics = metrics
							self.bestScore = score
							self.improvements = self.improvements + 1
						end
					else
						self.rejected = self.rejected + 1
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
