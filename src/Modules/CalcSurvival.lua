-- Path of Building
--
-- Module: Calc Survival
-- Recovery-aware, configured-enemy benchmark for passive optimization.
--
local calcs = require("Modules.CalcBase")
local damageTypes = { "Physical", "Lightning", "Cold", "Fire", "Chaos" }
local resources = { "Life", "Mana", "EnergyShield" }
local elemental = { Lightning = true, Cold = true, Fire = true }
local window, maxStates = 30, 16

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function blend(a, b, weight)
	local result = { }
	for key in pairs(a) do
		result[key] = a[key]
	end
	for key in pairs(b) do
		local av, bv = a[key], b[key]
		if type(av) == "table" or type(bv) == "table" then
			result[key] = blend(av or { }, bv or { }, weight)
		elseif type(av) == "number" or type(bv) == "number" then
			result[key] = (av or 0) * weight + (bv or 0) * (1 - weight)
		else
			result[key] = av or bv
		end
	end
	for key, value in pairs(a) do
		if b[key] == nil then
			result[key] = type(value) == "table" and blend(value, { }, weight) or type(value) == "number" and value * weight or value
		end
	end
	return result
end

local function compress(states, buffer)
	for index, state in ipairs(states) do
		state.buffer = buffer(state.pools)
		state.order = index
	end
	table.sort(states, function(a, b)
		return a.buffer == b.buffer and a.order < b.order or a.buffer < b.buffer
	end)
	while #states > maxStates do
		local index, distance = 1, math.huge
		for i = 1, #states - 1 do
			local a, b = states[i], states[i + 1]
			local candidate = (b.buffer - a.buffer) * a.probability * b.probability / (a.probability + b.probability)
			if candidate < distance then
				index, distance = i, candidate
			end
		end
		local a, b = states[index], states[index + 1]
		local probability = a.probability + b.probability
		states[index] = blend(a, b, a.probability / probability)
		states[index].probability = probability
		table.remove(states, index + 1)
	end
end

local function schedule(state, time, resource, amount, duration)
	if amount == 0 then
		return
	end
	local rate = amount / duration
	state.timedRates[resource] = state.timedRates[resource] + rate
	local expiry = time + duration
	local rates = state.expiries[expiry] or { }
	rates[resource] = (rates[resource] or 0) + rate
	state.expiries[expiry] = rates
end

-- Branch on complete hits rather than shrinking lethal hits by their probability.
function calcs.simulateSurvival(actor, profile)
	local output, modDB = actor.output, actor.modDB
	local caps = profile.caps
	assert(finite(caps.Life) and caps.Life > 0, "Configured survival requires a positive recoverable life pool.")
	assert(profile.dot or finite(profile.interval) and profile.interval >= 1 / data.misc.ServerTickRate,
		"Configured survival requires an enemy attack/cast time of at least one server tick.")
	local initial = {
		Life = caps.Life, Mana = caps.Mana, EnergyShield = caps.EnergyShield,
		Ward = output.Ward or 0, WardActiveChance = 1,
		Guard = { shared = output.sharedGuardAbsorb or 0 },
		Aegis = { shared = output.sharedAegis or 0, sharedElemental = output.sharedElementalAegis or 0 },
		AlliesTakenBeforeYou = calcs.buildAllyLifePools(output),
		damageTakenThatCanBeRecouped = { },
		LifeLossLostOverTime = 0, LifeBelowHalfLossLostOverTime = 0,
	}
	for _, damageType in ipairs(damageTypes) do
		initial.Guard[damageType] = output[damageType.."GuardAbsorb"] or 0
		initial.Aegis[damageType] = output[damageType.."Aegis"] or 0
	end
	local poolSize = calcs.survivalPoolCalculator(actor, profile.damage, profile.dot)
	local initialBuffer = poolSize(initial)
	assert(finite(initialBuffer) and initialBuffer > 0, "Configured survival requires a finite usable defensive buffer.")
	local function buffer(pools)
		return math.min(1, math.max(0, poolSize(pools) / initialBuffer))
	end
	local states = { {
		probability = 1, pools = initial, expiries = { },
		timedRates = { Life = 0, Mana = 0, EnergyShield = 0 },
		leechAge = { Life = 0, Mana = 0, EnergyShield = 0 },
		rechargeAge = 0, wardAge = -1,
	} }
	local score, aliveTime, time = 0, 0, 0
	local nextHit = profile.dot and math.huge or profile.interval
	while time < window - 1e-9 and #states > 0 do
		local step = math.min(1 / data.misc.ServerTickRate, window - time, nextHit - time)
		for _, state in ipairs(states) do
			for expiry in pairs(state.expiries) do
				if expiry > time + 1e-9 then
					step = math.min(step, expiry - time)
				end
			end
		end
		local surviving = { }
		for _, state in ipairs(states) do
			local pools = state.pools
			local before = buffer(pools)
			local rechargePool = output.EnergyShieldRechargeAppliesToLife and "Life" or "EnergyShield"
			local beforeRecharge = pools[rechargePool]
			state.rechargeAge = state.rechargeAge + step
			for _, resource in ipairs(resources) do
				local normal, instant = 0, 0
				if pools[resource] >= caps[resource] - 1e-9 and not profile.overleech[resource] then
					state.leechAge[resource] = 0
				else
					state.leechAge[resource] = state.leechAge[resource] + step
				end
				for _, stream in ipairs(profile.leech) do
					local leech = stream[resource]
					normal = normal + leech.normal * (leech.duration > 0 and math.min(1, state.leechAge[resource] / leech.duration) or 0)
					instant = instant + leech.instant
				end
				local recovery = profile.regen[resource] + math.min(normal, profile.leechCap[resource]) + instant + state.timedRates[resource]
				local rate = (caps[resource] > 0 and recovery or 0) - profile.spending[resource]
				if caps[resource] > 0 and resource == rechargePool and state.rechargeAge >= (output.EnergyShieldRechargeDelay or math.huge) then
					rate = rate + (output[resource == "Life" and "LifeRecharge" or "EnergyShieldRecharge"] or 0)
				end
				pools[resource] = pools[resource] + rate * step
			end
			-- Integrate simultaneous recovery and DoT before clamping; a balanced DoT must not kill low-life builds between artificial ticks.
			if profile.hasDegen and pools.Life > 0 then
				local damage = { }
				for damageType, amount in pairs(profile.degen) do
					damage[damageType] = amount * step
				end
				pools = calcs.reducePoolsByDamage(pools, damage, actor, true)
				state.pools = pools
			end
			for _, resource in ipairs(resources) do
				pools[resource] = math.max(0, math.min(caps[resource], pools[resource]))
			end
			if pools[rechargePool] < beforeRecharge - 1e-9 or profile.spending[rechargePool] > 0 then
				state.rechargeAge = 0
			end
			if state.wardAge >= 0 then
				state.wardAge = state.wardAge + step
				if state.wardAge >= (output.WardRechargeDelay or math.huge) then
					pools.Ward, pools.WardActiveChance, state.wardAge = output.Ward, 1, -1
				end
			end
			aliveTime = aliveTime + state.probability * step
			score = score + state.probability * step * (before + (pools.Life > 0 and buffer(pools) or 0)) / 2
			for expiry, rates in pairs(state.expiries) do
				if expiry <= time + step + 1e-9 then
					for resource, rate in pairs(rates) do
						state.timedRates[resource] = state.timedRates[resource] - rate
					end
					state.expiries[expiry] = nil
				end
			end
			if pools.Life > 0 then
				table.insert(surviving, state)
			end
		end
		states = surviving
		time = time + step
		if time >= nextHit - 1e-9 then
			local branches = { }
			for _, state in ipairs(states) do
				for _, outcome in ipairs(profile.outcomes) do
					if outcome.probability > 0 then
						local child = copyTable(state)
						child.probability = state.probability * outcome.probability
						if outcome.damage then
							local pools = child.pools
							pools.Life = math.min(caps.Life, pools.Life + (output.Life - pools.Life) * profile.missingLife / 100)
							pools.Mana = math.min(caps.Mana, pools.Mana + (output.Mana - pools.Mana) * profile.missingMana / 100)
							local old = {
								damageTakenThatCanBeRecouped = copyTable(pools.damageTakenThatCanBeRecouped),
								LifeLossLostOverTime = pools.LifeLossLostOverTime,
								LifeBelowHalfLossLostOverTime = pools.LifeBelowHalfLossLostOverTime,
								Ward = pools.Ward, WardActiveChance = pools.WardActiveChance,
							}
							child.pools = calcs.reducePoolsByDamage(pools, copyTable(outcome.damage), outcome.actor or actor)
							pools = child.pools
							if pools.Life > 0 then
								for _, resource in ipairs(resources) do
									pools[resource] = math.min(caps[resource], pools[resource] + outcome.gain[resource])
									local amount = 0
									for _, damageType in ipairs(damageTypes) do
										local taken = (pools.damageTakenThatCanBeRecouped[damageType] or 0) - (old.damageTakenThatCanBeRecouped[damageType] or 0)
										amount = amount + taken * ((output[resource.."Recoup"] or 0) + (output[damageType..resource.."Recoup"] or 0) + (elemental[damageType] and output["Elemental"..resource.."Recoup"] or 0)) / 100
									end
									schedule(child, time, resource, amount, profile.recoupTime[resource])
									local pseudo = (outcome.physicalMitigated or 0) * (output["PhysicalDamageMitigated"..resource.."PseudoRecoup"] or 0) / 100
									if not modDB:Flag(nil, "UnaffectedBy"..resource.."Regen") then
										local duration = output["PhysicalDamageMitigated"..resource.."PseudoRecoupDuration"] or 4
										schedule(child, time, resource, pseudo, duration)
										for _, target in ipairs(resources) do
											if target ~= resource and pseudo > 0 and modDB:Flag(nil, resource.."RegenerationRecovers"..target)
												and not modDB:Flag(nil, "UnaffectedBy"..target.."Regen") and not modDB:Flag(nil, "No"..target.."Regen") and not modDB:Flag(nil, "CannotGain"..target) then
												schedule(child, time, target, pseudo * output[target.."RecoveryRateMod"] / output[resource.."RecoveryRateMod"], duration)
											end
										end
									end
								end
								local loss = pools.LifeLossLostOverTime - old.LifeLossLostOverTime + (pools.LifeBelowHalfLossLostOverTime - old.LifeBelowHalfLossLostOverTime) * profile.belowHalfLoss
								schedule(child, time, "Life", -loss, 4)
								local rechargePool = output.EnergyShieldRechargeAppliesToLife and "Life" or "EnergyShield"
								for _, loss in pairs(pools.resourcesLostToTypeDamage) do
									if (loss[rechargePool == "Life" and "life" or "energyShield"] or 0) > 0 then
										child.rechargeAge = 0
									end
								end
								if child.wardAge < 0 and (pools.Ward < old.Ward or pools.WardActiveChance < old.WardActiveChance) then
									child.wardAge = 0
								end
							end
						end
						if child.probability > 0 and child.pools.Life > 0 then
							table.insert(branches, child)
						end
					end
				end
			end
			states = branches
			compress(states, buffer)
			nextHit = nextHit + profile.interval
		end
	end
	local probability = 0
	for _, state in ipairs(states) do
		probability = probability + state.probability
	end
	return {
		ConfiguredSurvivalScore = math.min(window, score),
		ConfiguredSurvivalTime = math.min(window, aliveTime),
		ConfiguredSurvivalChance = math.min(100, probability * 100),
		ConfiguredSurvivalWindow = window,
	}
end

function calcs.calcSurvival(env, skills)
	local actor = env.player
	local output, modDB = actor.output, actor.modDB
	local dot = env.configInput.enemyDamageType == "DamageOverTime"
	local hit = not dot and assert(actor.survivalHitProfile, "Missing configured enemy hit profile.")
	local profile = {
		dot = dot, interval = output.enemySkillTime, damage = { }, degen = { }, outcomes = { },
		caps = {
			Life = output.LifeRecoverable,
			Mana = math.max(0, math.min(output.Mana, output.ManaUnreserved + (actor.mainSkill.skillData.ManaReservedSnapshot or 0)) - output.ManaCastingReservation),
			EnergyShield = output.EnergyShieldRecoveryCap,
		},
		regen = { }, spending = { Life = 0, Mana = 0, EnergyShield = 0 }, leech = { }, leechCap = { },
		overleech = { Life = modDB:Flag(nil, "CanLeechLifeOnFullLife"), EnergyShield = modDB:Flag(nil, "CanLeechEnergyShieldOnFullEnergyShield") },
		recoupTime = { }, belowHalfLoss = modDB:Sum("BASE", nil, "LifeLossBelowHalfLost") / 100,
		missingLife = hit and hit.recoverOnBlock and modDB:Sum("BASE", nil, "MissingLifeBeforeEnemyHit") or 0,
		missingMana = hit and hit.recoverOnBlock and modDB:Sum("BASE", nil, "MissingManaBeforeEnemyHit") or 0,
	}
	for _, resource in ipairs(resources) do
		profile.regen[resource] = output[resource.."RegenRecovery"] or 0
		profile.leechCap[resource] = (output["Max"..resource.."LeechRate"] or 0) * (output[resource.."RecoveryRateMod"] or 1)
		profile.recoupTime[resource] = (modDB:Flag(nil, "3SecondRecoup") or modDB:Flag(nil, "3Second"..resource.."Recoup")) and 3 or 4
	end
	for _, entry in ipairs(skills) do
		if entry.recurring then
			local stream = { }
			for _, resource in ipairs(resources) do
				local costResource = resource == "EnergyShield" and "ES" or resource
				local calculated = entry.output
				local cost = (calculated[costResource.."PerSecondCost"] or 0) + (calculated[costResource.."PercentPerSecondCost"] or 0) * output[resource] / 100
				local paidResource = resource == "Mana" and modDB:Flag(nil, "EnergyShieldProtectsMana") and "EnergyShield" or resource
				profile.spending[paidResource] = profile.spending[paidResource] + cost
				local instant = calculated[resource.."LeechInstantRate"] or 0
				local normal = math.max(0, (calculated[resource.."LeechRate"] or 0) - instant)
				local duration = calculated[resource.."LeechDuration"] or 0
				assert(normal == 0 or duration > 0, "Missing calculated "..resource.." leech duration.")
				stream[resource] = { normal = normal, duration = duration, instant = instant + (calculated[resource.."OnHitRate"] or 0) }
			end
			table.insert(profile.leech, stream)
		end
	end
	for _, damageType in ipairs(damageTypes) do
		profile.damage[damageType] = dot and (output[damageType.."EnemyDegen"] or 0) or hit.damage[damageType]
		profile.degen[damageType] = (output[damageType.."BuildDegen"] or 0) + (output[damageType.."EnemyDegen"] or 0)
		profile.hasDegen = profile.hasDegen or profile.degen[damageType] > 0
	end
	if not dot then
		local connected = 1 - output.ConfiguredNotHitChance / 100
		table.insert(profile.outcomes, { probability = 1 - connected })
		-- Average-category mitigation remains PoB's mixed attack/spell profile.
		local blockedActor
		if modDB:Flag(nil, "BlockedDamageDoesntBypassES") then
			blockedActor = { modDB = modDB, output = copyTable(output, true) }
			for _, damageType in ipairs(damageTypes) do
				if damageType ~= "Chaos" and output[damageType.."EnergyShieldBypass"] < 100 then
					blockedActor.output[damageType.."EnergyShieldBypass"] = 0
				end
			end
		end
		local function addOutcome(blocked, suppressed, probability)
			local outcome = { probability = connected * probability, damage = { }, gain = { }, actor = blocked and blockedActor or nil }
			for _, damageType in ipairs(damageTypes) do
				outcome.damage[damageType] = hit.damage[damageType] * (blocked and 1 - output.BlockEffect / 100 or 1) * (suppressed and 1 - output.SpellSuppressionEffect / 100 or 1)
			end
			outcome.physicalMitigated = math.max(0, output.PhysicalTakenDamage - outcome.damage.Physical)
			for _, resource in ipairs(resources) do
				outcome.gain[resource] = (blocked and hit.recoverOnBlock and output[resource.."OnBlock"] or 0) + (suppressed and hit.recoverOnBlock and (output[resource.."OnSuppress"] or 0) or 0)
			end
			if blocked and hit.recoverOnBlock then
				outcome.gain.EnergyShield = outcome.gain.EnergyShield + output.EnergyShieldOnSpellBlock * hit.spellFraction
			end
			local avoided = { outcome }
			for _, damageType in ipairs(damageTypes) do
				local chance = hit.avoidance[damageType]
				if chance > 0 and outcome.damage[damageType] > 0 then
					local split = { }
					for _, branch in ipairs(avoided) do
						local miss = {
							probability = branch.probability * chance,
							damage = copyTable(branch.damage), gain = branch.gain, actor = branch.actor,
							physicalMitigated = damageType == "Physical" and 0 or branch.physicalMitigated,
						}
						miss.damage[damageType] = 0
						branch.probability = branch.probability * (1 - chance)
						if branch.probability > 0 then
							table.insert(split, branch)
						end
						table.insert(split, miss)
					end
					avoided = split
				end
			end
			for _, branch in ipairs(avoided) do
				table.insert(profile.outcomes, branch)
			end
		end
		addOutcome(false, false, (1 - hit.blockChance) * (1 - hit.suppressChance))
		addOutcome(true, false, hit.blockChance * (1 - hit.suppressChance))
		addOutcome(false, true, (1 - hit.blockChance) * hit.suppressChance)
		addOutcome(true, true, hit.blockChance * hit.suppressChance)
	end
	for stat, value in pairs(calcs.simulateSurvival(actor, profile)) do
		output[stat] = value
	end
end
