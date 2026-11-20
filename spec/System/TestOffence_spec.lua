describe("TestOffence", function()
	before_each(function()
		newBuild()
	end)

	teardown(function()
		-- newBuild() takes care of resetting everything in setup()
	end)

	-- Asserts actual is within a relative tolerance of expected, e.g. 0.005 = 0.5%
	local function assertNearRelative(expected, actual, tolerance, msg)
		assert.is_true(math.abs(expected - actual) / expected <= tolerance,
			string.format("%s: expected ~%.2f (within %.1f%%), got %.2f", msg, expected, tolerance * 100, actual))
	end

	describe("Pyroclast Mine automatic modeling", function()
		before_each(function()
			-- Keep geometry/sequence checks resource-independent; mana-limit checks opt in separately.
			build.configTab.input.pyroclastMineManaLimited = false
		end)

		local function update(config)
			for key, value in pairs(config or { }) do
				build.configTab.input[key] = value
			end
			build.configTab:BuildModList()
			runCallback("OnFrame")
			return build.calcsTab.mainOutput
		end

		for _, name in ipairs({ "Pyroclast Mine", "Pyroclast Mine of Sabotage" }) do
			it("calculates " .. name .. " overlap, sequence projectiles and Full DPS automatically", function()
				build.skillsTab:PasteSocketGroup(name .. " 20/0  1")
				build.skillsTab.socketGroupList[1].includeInFullDPS = true
				local output = update({ enemySizePreset = "Medium" })

				assert.are.equals(15, output.MineSequenceCount)
				assert.are.equals(5, output.MineSequenceAverageProjectiles)
				assert.near(100 * 14 ^ 2 / 26 ^ 2, output.OverlapChance, 0.000001)
				assert.near(1 + 5 * 14 ^ 2 / 26 ^ 2, output.SkillDPSMultiplier, 0.000001)
				assert.near(output.AverageDamage * output.SkillDPSMultiplier * output.Speed, output.TotalDPS, 0.000001)
				assert.near(output.CombinedDPS, output.FullDPS, 0.000001)
				assert.near(output.AverageDamage * output.SkillDPSMultiplier * 15, output.MineSequenceDamage, 0.000001)
				assert.is_falsy(build.calcsTab.mainEnv.player.mainSkill.skillFlags.showAverage)
			end)
		end

		it("uses prior mines rather than the current mine for Pyroclast sequence breakpoints", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			for _, case in ipairs({
				{ mines = 1, projectiles = 3 },
				{ mines = 3, projectiles = 3 },
				{ mines = 4, projectiles = 3.25 },
				{ mines = 6, projectiles = 3.5 },
				{ mines = 7, projectiles = 26 / 7 },
			}) do
				local output = update({ pyroclastMineSequenceCount = case.mines })
				assert.near(case.projectiles, output.MineSequenceAverageProjectiles, 0.000001)
			end
			assert.are.equals(15, update({ pyroclastMineSequenceCount = 100 }).MineSequenceCount)
			assert.are.equals(1, update({ pyroclastMineSequenceCount = -1 }).MineSequenceCount)
		end)

		it("accounts for Pyroclast quality and additional projectiles without assuming every projectile hits", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/20  1")
			local output = update({ customMods = "Skills fire 2 additional Projectiles" })
			assert.are.equals(8, output.MineSequenceAverageProjectiles)
			assert.near(1 + 8 * 14 ^ 2 / 26 ^ 2, output.SkillDPSMultiplier, 0.000001)
		end)

		it("rounds Pyroclast projectile multipliers separately for each mine", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			local output = update({ pyroclastMineSequenceCount = 4, customMods = "50% more Projectiles" })
			assert.near(4.5, output.MineSequenceAverageProjectiles, 0.000001)
		end)

		it("recalculates Pyroclast overlap for area modifiers and caps it for large enemies", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			local output = update({ customMods = "100% increased Area of Effect", enemySizePreset = "Medium" })
			assert.near(25, output.OverlapChance, 0.000001)
			assert.near(2.25, output.SkillDPSMultiplier, 0.000001)
			output = update({ enemyRadius = 100 })
			assert.are.equals(100, output.OverlapChance)
			assert.are.equals(6, output.SkillDPSMultiplier)
		end)

		it("limits Pyroclast DPS by throwing and detonation instead of multiplying the two rates", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			local output = update({ pyroclastMineSequenceCount = 4 })
			local baseDamage = output.AverageDamage
			local baseRate = output.MineEffectiveRate
			local expectedSequenceTime = 0.35 + 0.35 / 1.1 + 0.35 / 1.2
			assert.near(expectedSequenceTime, output.MineSequenceTime, 0.000001)
			assert.near(output.MineLayingSpeed * output.MineThrowCount, baseRate, 0.000001)
			output = update({ customMods = "Mines have 100% increased Detonation Speed" })
			assert.near(baseRate, output.MineEffectiveRate, 0.000001)
			assert.near(expectedSequenceTime / 2, output.MineSequenceTime, 0.000001)
			output = update({ customMods = "Mines have 20% increased Detonation Speed" })
			assert.near(expectedSequenceTime / 1.2, output.MineSequenceTime, 0.000001)
			output = update({ customMods = "1000% increased Mine Throwing Speed" })
			local detonationLimitedDPS = output.TotalDPS
			assert.near(4 / expectedSequenceTime, output.MineEffectiveRate, 0.000001)
			output = update({ customMods = "1000% increased Mine Throwing Speed\nMines have 100% increased Detonation Speed" })
			assert.near(2 * detonationLimitedDPS, output.TotalDPS, 0.000001)
			assert.near(baseDamage, output.AverageDamage, 0.000001)
		end)

		it("includes additional mines per throw in the Pyroclast supply limit", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1\nMinefield 20/0  1")
			local output = update({ customMods = "Mines have 1000% increased Detonation Speed" })
			assert.is_true(output.MineThrowCount > 1)
			assert.near(output.MineLayingSpeed * output.MineThrowCount, output.MineEffectiveRate, 0.000001)
		end)

		it("applies Detonate Mines quality to Pyroclast detonation speed", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			build.skillsTab:PasteSocketGroup("Detonate Mines 1/20  1")
			local output = update({ pyroclastMineSequenceCount = 4, customMods = "1000% increased Mine Throwing Speed" })
			assert.near(0.35 / 1.2, output.MineDetonationTime, 0.000001)
			output = update({ customMods = "1000% increased Mine Throwing Speed\n100% increased Effect of Buffs on you" })
			assert.near(0.35 / 1.2, output.MineDetonationTime, 0.000001)
		end)

		it("respects the Detonate Mines cooldown for a single-mine Pyroclast sequence", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			local output = update({ pyroclastMineSequenceCount = 1, customMods = "1000% increased Mine Throwing Speed" })
			assert.are.equals(0, output.MineSequenceTime)
			assert.near(5, output.MineEffectiveRate, 0.000001)
		end)

		it("does not produce invalid Pyroclast DPS when detonation speed is reduced to zero", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			local output = update({ pyroclastMineSequenceCount = 4, customMods = "Mines have 100% reduced Detonation Speed" })
			assert.are.equals(0, output.MineEffectiveRate)
			assert.are.equals(0, output.TotalDPS)
		end)

		it("preserves Pyroclast single-hit mode and does not leak sequence multipliers when switching modes", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			update()
			local gem = build.skillsTab.socketGroupList[1].gemList[1]
			gem.skillPart = 2
			build.buildFlag = true
			local output = update()
			assert.is_nil(output.MineSequenceCount)
			assert.near(output.AverageDamage * output.MineLayingSpeed * output.MineThrowCount, output.TotalDPS, 0.000001)
			gem.skillPart = 1
			build.buildFlag = true
			output = update()
			assert.near(1 + 5 * 14 ^ 2 / 26 ^ 2, output.SkillDPSMultiplier, 0.000001)
		end)

		it("shows Pyroclast configuration and Calcs details and preserves the estimate after saving", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/20  1")
			local output = update({ pyroclastMineSequenceCount = 4, enemySizePreset = "Large" })
			local expectedDPS = output.TotalDPS
			build.viewMode = "CONFIG"
			runCallback("OnFrame")
			assert.is_true(build.configTab.varControls.pyroclastMineSequenceCount.shown())
			assert.is_true(build.configTab.varControls.enemySizePreset.shown())
			build.viewMode = "CALCS"
			runCallback("OnFrame")
			assert.are.equals(4, #build.calcsTab.calcsEnv.player.breakdown.MineSequenceAverageProjectiles.rowList)
			local xml = build:SaveDB("Pyroclast sequence")
			loadBuildFromXML(xml, "Pyroclast sequence")
			assert.are.equals(4, build.configTab.input.pyroclastMineSequenceCount)
			assert.near(expectedDPS, build.calcsTab.mainOutput.TotalDPS, 0.000001)
		end)

		for _, name in ipairs({ "Pyroclast Mine", "Pyroclast Mine of Sabotage" }) do
			it("detects linked Automation for " .. name .. " and uses the estimate in Full DPS", function()
				build.skillsTab:PasteSocketGroup(name .. " 20/0  1")
				build.skillsTab.socketGroupList[1].includeInFullDPS = true
				build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
				local output = update({ pyroclastMineSequenceCount = 15 })
				assert.near(1 / 0.231, output.MineAutomationTriggerRate, 0.000001)
				assert.is_true(output.MineSequenceCount < 15)
				assert.is_true(output.MineSequenceAverageProjectiles < 5)
				assert.is_true(output.MineEffectiveRate > 0)
				assert.is_true(output.MineEffectiveRate <= output.MineLayingSpeed * output.MineThrowCount)
				assert.near(output.AverageDamage * output.SkillDPSMultiplier * output.Speed, output.TotalDPS, 0.000001)
				assert.near(output.CombinedDPS, output.FullDPS, 0.000001)
				local automatedDPS = output.TotalDPS
				assert.near(automatedDPS, update({ pyroclastMineSequenceCount = 1 }).TotalDPS, 0.000001)
			end)
		end

		for _, name in ipairs({ "Pyroclast Mine", "Pyroclast Mine of Sabotage" }) do
			for _, rearming in ipairs({ false, true }) do
				it("derives continuously thrown " .. name .. " population independently of manual mine counts" .. (rearming and " with re-arming" or ""), function()
					build.skillsTab:PasteSocketGroup(name .. " 20/0  1")
					build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
					local gem = build.skillsTab.socketGroupList[1].gemList[1]
					gem.skillMineCount = 1
					gem.skillMineCountCalcs = 1
					build.buildFlag = true
					local output = update({
						pyroclastMineSequenceCount = 1,
						customMods = rearming and "Mines can be Detonated an additional time" or "",
					})
					local average, peak = output.MineAverageActive, output.MinePeakActive
					local rate, projectiles, dps, reservation = output.MineEffectiveRate, output.MineSequenceAverageProjectiles, output.TotalDPS, output.ManaReserved
					assert.is_true(average > 0 and average < output.ActiveMineLimit)
					assert.is_true(average <= peak and peak <= output.ActiveMineLimit)
					gem.skillMineCount = output.ActiveMineLimit
					gem.skillMineCountCalcs = output.ActiveMineLimit
					build.buildFlag = true
					output = update({ pyroclastMineSequenceCount = output.ActiveMineLimit })
					assert.are.equals(average, output.MineAverageActive)
					assert.are.equals(peak, output.MinePeakActive)
					assert.are.equals(rate, output.MineEffectiveRate)
					assert.are.equals(projectiles, output.MineSequenceAverageProjectiles)
					assert.near(dps, output.TotalDPS, 0.000001)
					assert.is_true(output.ManaReserved > reservation)
					build.viewMode = "CALCS"
					runCallback("OnFrame")
					assert.is_not_nil(build.calcsTab.calcsEnv.player.breakdown.MineAverageActive)
					assert.is_not_nil(build.calcsTab.calcsEnv.player.breakdown.MinePeakActive)
				end)
			end
		end

		for _, name in ipairs({ "Pyroclast Mine", "Pyroclast Mine of Sabotage" }) do
			it("spends mana and resumes held " .. name .. " throws as recovery becomes available", function()
				newBuild()
				assert.is_true(build.configTab.input.pyroclastMineManaLimited)
				build.skillsTab:PasteSocketGroup(name .. " 20/0  1")
				build.skillsTab.socketGroupList[1].includeInFullDPS = true
				build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
				local output = update({ customMods = "Cannot Leech or Regenerate Mana" })
				assert.are.equals(0, output.ManaRegenRecovery)
				assert.is_not_nil(output.MineActualThrowRate)
				assert.is_true(output.MineActualThrowRate > 0 and output.MineActualThrowRate < output.MineLayingSpeed)
				assert.is_true(output.MineManaWait > 0)
				assert.is_true(output.MineManaSpentRate * 29.997 <= output.Mana + 0.000001)
				assert.near(output.CombinedDPS, output.FullDPS, 0.000001)
				assert.near(output.MineActualThrowRate, build.calcsTab.calcsOutput.MineActualThrowRate, 0.000001)
				local depletedDPS = output.TotalDPS
				output = update({ customMods = "Cannot Leech or Regenerate Mana\n+1000 to maximum Mana" })
				assert.are.equals(0, output.ManaRegenRecovery)
				assert.is_true(output.TotalDPS > depletedDPS)
				output = update({ customMods = "Regenerate 1000 Mana per second" })
				local recoveredDPS, recoveredRate = output.TotalDPS, output.MineActualThrowRate
				assert.are.equals(0, output.MineManaWait)
				assert.is_true(recoveredDPS > depletedDPS)
				assert.near(output.ManaCost * recoveredRate, output.ManaPerSecondCost, 0.000001)
				output = update({ pyroclastMineManaLimited = false })
				assert.near(recoveredDPS, output.TotalDPS, 0.000001)
			end)
		end

		it("does not double-count the Active Mines reservation in mana-limited throwing", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
			local gem = build.skillsTab.socketGroupList[1].gemList[1]
			local expectedDPS, expectedRate
			for _, count in ipairs({ 0, 1, 15 }) do
				gem.skillMineCount = count
				gem.skillMineCountCalcs = count
				build.buildFlag = true
				local output = update({ pyroclastMineManaLimited = true })
				if expectedDPS then
					assert.near(expectedDPS, output.TotalDPS, 0.000001)
					assert.near(expectedRate, output.MineActualThrowRate, 0.000001)
				end
				expectedDPS, expectedRate = output.TotalDPS, output.MineActualThrowRate
			end
		end)

		it("treats temporary mine reservation separately from spending, releasing it on the first detonation", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
			local mods = "Cannot Leech or Regenerate Mana\n100% reduced Mana Cost of Skills\n1000% increased Mine Throwing Speed\nMines have 100% reduced Detonation Speed"
			local output = update({ pyroclastMineManaLimited = true, customMods = mods })
			assert.are.equals(0, output.ManaCost)
			assert.are.equals(0, output.ManaRegenRecovery)
			assert.are.equals(0, output.MineManaSpentRate)
			assert.is_true(output.MineActualThrowRate > 0)
			assert.is_true(output.MineManaWait > 0)
			assert.is_true(output.MinePeakActive < output.ActiveMineLimit)
			output = update({ customMods = mods .. "\nMines can be Detonated an additional time\n99% reduced Cast Speed" })
			assert.are.equals(0, output.MineManaSpentRate)
			assert.are.equals(0, output.MineReusedRate)
			assert.are.equals(output.ActiveMineLimit, output.MinePeakActive)
		end)

		it("does not throw when there is no mana or the upfront cost exceeds the entire pool", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
			for _, mods in ipairs({ "100% reduced maximum Mana", "+1000 to Total Mana Cost of Skills" }) do
				local output = update({ pyroclastMineManaLimited = true, customMods = mods })
				assert.are.equals(0, output.MineActualThrowRate)
				assert.are.equals(0, output.MineManaSpentRate)
				assert.are.equals(0, output.TotalDPS)
			end
		end)

		it("explicitly flags unsupported life or Energy Shield payment instead of applying mana limits", function()
			for _, support in ipairs({ "", "\nLifetap 20/0  1" }) do
				newBuild()
				build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1" .. support)
				build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
				local output = update({ pyroclastMineManaLimited = true, customMods = support == "" and "Eldritch Battery" or "" })
				assert.is_nil(output.MineActualThrowRate)
				assert.is_true(output.TotalDPS > 0)
				assert.is_not_nil(build.calcsTab.mainEnv.player.mainSkill.infoMessage:find("unavailable with Life/ES payment", 1, true))
			end
		end)

		it("lets continuous throwing fill the mine pool when detonation cannot keep up", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
			local average = update().MineAverageActive
			local output = update({ customMods = "1000% increased Mine Throwing Speed\nMines have 100% reduced Detonation Speed" })
			assert.are.equals(output.ActiveMineLimit, output.MinePeakActive)
			assert.is_true(output.MineAverageActive > average)
			assert.is_true(output.MineAverageActive <= output.MinePeakActive)
			assert.is_true(output.MineEffectiveRate < output.MineLayingSpeed * output.MineThrowCount)
			output = update({ customMods = "100% reduced Mine Throwing Speed" })
			assert.are.equals(0, output.MineAverageActive)
			assert.are.equals(0, output.MinePeakActive)
			assert.are.equals(0, output.TotalDPS)
		end)

		it("does not report continuous mine occupancy for preloaded manual or single-hit estimates", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			local output = update()
			assert.is_nil(output.MineAverageActive)
			assert.is_nil(output.MinePeakActive)
			build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
			assert.is_not_nil(update().MineAverageActive)
			build.skillsTab.socketGroupList[1].gemList[1].skillPart = 2
			build.buildFlag = true
			output = update()
			assert.is_nil(output.MineAverageActive)
			assert.is_nil(output.MinePeakActive)
		end)

		it("does not mistake unlinked Automation on another spell for automated mine detonation", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1")
			build.skillsTab:PasteSocketGroup("Steelskin 20/0  1\nAutomation 20/0  1")
			local output = update({ pyroclastMineSequenceCount = 4 })
			assert.is_nil(output.MineAutomationTriggerRate)
			assert.are.equals(4, output.MineSequenceCount)
		end)

		it("returns to the manual estimate when Detonate Mines, Automation or their group is disabled", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
			local group = build.skillsTab.socketGroupList[2]
			assert.is_not_nil(update().MineAutomationTriggerRate)
			for _, target in ipairs({ group.gemList[1], group.gemList[2], group }) do
				target.enabled = false
				build.buildFlag = true
				local output = update({ pyroclastMineSequenceCount = 4 })
				assert.is_nil(output.MineAutomationTriggerRate)
				assert.are.equals(4, output.MineSequenceCount)
				target.enabled = true
				build.buildFlag = true
				assert.is_not_nil(update().MineAutomationTriggerRate)
			end
		end)

		it("uses Automation level, quality and global cooldown recovery with server-tick breakpoints", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 1/0  1")
			assert.near(1 / 0.264, update().MineAutomationTriggerRate, 0.000001)
			local automation = build.skillsTab.socketGroupList[2].gemList[2]
			automation.level = 20
			build.buildFlag = true
			assert.near(1 / 0.231, update().MineAutomationTriggerRate, 0.000001)
			assert.near(1 / 0.231, update({ customMods = "5% increased Cooldown Recovery Rate" }).MineAutomationTriggerRate, 0.000001)
			automation.quality = 20
			build.buildFlag = true
			assert.near(1 / 0.198, update().MineAutomationTriggerRate, 0.000001)
			assert.near(1 / 0.132, update({ customMods = "100% increased Cooldown Recovery Rate" }).MineAutomationTriggerRate, 0.000001)
		end)

		it("uses the same Automation cadence in the mine estimate and shared trigger calculation", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
			local attemptRate = update().MineAutomationTriggerRate
			build.mainSocketGroup = 2
			build.buildFlag = true
			local output = update()
			assert.near(attemptRate, output.SkillTriggerRate, 0.000001)
			build.mainSocketGroup = 1
			build.buildFlag = true
			assert.near(attemptRate, update().MineAutomationTriggerRate, 0.000001)
		end)

		it("models competing automated sequences and recalculates their projectile mix for throwing and detonation speeds", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1\nMinefield 20/0  1")
			build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
			local output = update()
			local baseProjectiles = output.MineSequenceAverageProjectiles
			local baseDPS = output.TotalDPS
			assert.is_true(output.MineThrowCount > 1)
			assert.is_true(baseProjectiles > 3)
			assert.is_true(baseProjectiles < 5)
			assert.is_true(math.abs(update({ customMods = "Mines have 100% increased Detonation Speed" }).MineSequenceAverageProjectiles - baseProjectiles) > 0.000001)
			output = update({ customMods = "100% increased Mine Throwing Speed" })
			assert.is_true(output.TotalDPS > baseDPS)
			assert.is_true(output.MineSequenceAverageProjectiles > baseProjectiles)
			assert.is_true(output.MineEffectiveRate <= output.MineLayingSpeed * output.MineThrowCount)
		end)

		it("still detonates the first mine instantly through Automation when subsequent detonation speed is zero", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
			local output = update({ customMods = "1000% increased Mine Throwing Speed\nMines have 100% reduced Detonation Speed" })
			assert.are.equals(1, output.MineSequenceCount)
			assert.are.equals(3, output.MineSequenceAverageProjectiles)
			assertNearRelative(1 / 0.231, output.MineEffectiveRate, 0.01, "Instant first mine per automated trigger")
			assert.is_true(output.TotalDPS > 0)
			output = update({ customMods = "100% reduced Cooldown Recovery Rate" })
			assert.are.equals(0, output.MineAutomationTriggerRate)
			assert.are.equals(0, output.TotalDPS)
			output = update({ customMods = "100% reduced Mine Throwing Speed" })
			assert.are.equals(0, output.MineEffectiveRate)
			assert.are.equals(0, output.TotalDPS)
		end)

		it("carries fractional extra-mine supply without exceeding the automated throwing rate", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1\nSwift Assembly 20/0  1")
			build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
			local output = update()
			assert.is_not_nil(output.MineAutomationTriggerRate)
			assert.is_true(output.MineThrowCount > 1)
			assert.is_true(output.MineThrowCount % 1 ~= 0)
			assertNearRelative(output.MineLayingSpeed * output.MineThrowCount, output.MineEffectiveRate, 0.03, "Fractional automated mine supply")
			assert.is_true(output.MineEffectiveRate <= output.MineLayingSpeed * output.MineThrowCount)
		end)

		for _, name in ipairs({ "Pyroclast Mine", "Pyroclast Mine of Sabotage" }) do
			for _, automated in ipairs({ false, true }) do
				it("models Tremor Rod re-arming for " .. name .. (automated and " with Automation" or " with manual detonation"), function()
					build.skillsTab:PasteSocketGroup(name .. " 20/0  1")
					build.skillsTab.socketGroupList[1].includeInFullDPS = true
					if automated then
						build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
					end
					local baselineDPS = update().TotalDPS
					build.itemsTab:CreateDisplayItemFromRaw("Rarity: UNIQUE\nTremor Rod\nMilitary Staff\nImplicits: 0\nMines can be Detonated an additional time")
					build.itemsTab:AddDisplayItem()
					local output = update()
					assert.are.equals(1, output.MineExtraUses)
					assert.near(0.18, output.MineRearmTime, 0.000001)
					assert.is_true(output.MineReusedRate > 0)
					assert.is_true(output.MineDetonationsPerMine > 1)
					assert.is_true(output.MineDetonationsPerMine <= 2)
					assert.is_true(output.MineEffectiveRate <= 2 * output.MineLayingSpeed * output.MineThrowCount)
					assert.is_true(output.TotalDPS > baselineDPS)
					assert.is_true(math.abs(output.TotalDPS - 2 * baselineDPS) > 0.01)
					assert.near(output.CombinedDPS, output.FullDPS, 0.000001)
					assert.near(output.TotalDPS, build.calcsTab.calcsOutput.TotalDPS, 0.000001)
					local expectedDPS = output.TotalDPS
					local xml = build:SaveDB("Re-arming Pyroclast")
					loadBuildFromXML(xml, "Re-arming Pyroclast")
					assert.near(expectedDPS, build.calcsTab.mainOutput.TotalDPS, 0.000001)
				end)
			end
		end

		for _, automated in ipairs({ false, true }) do
			it("recognizes the actual Foulborn Tremor Rod passive" .. (automated and " with Automation" or " with manual detonation"), function()
				build.spec:SelectClass(build.spec.tree.classNameMap.Scion)
				build.spec:SelectAscendClass(build.spec.tree.ascendNameMap.Reliquarian.ascendClassId)
				build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
				if automated then
					build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
				end
				update()
				local node = build.spec.nodes[43857]
				local skill = build.calcsTab.mainEnv.player.mainSkill
				local auraEffect = skill.skillModList:Sum("INC", skill.skillCfg, "AuraEffect")
				build.spec:AllocNode(node)
				build.buildFlag = true
				local output = update()
				assert.is_true(node.alloc)
				assert.are.equals(1, output.MineExtraUses)
				assert.is_true(output.MineReusedRate > 0)
				assert.is_true(output.MineDetonationsPerMine <= 2)
				skill = build.calcsTab.mainEnv.player.mainSkill
				assert.are.equals(auraEffect + 50, skill.skillModList:Sum("INC", skill.skillCfg, "AuraEffect"))
			end)
		end

		it("scales Pyroclast re-arming with cast speed but not the owner's action speed", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
			local rod = "Mines can be Detonated an additional time"
			local output = update({ customMods = rod .. "\n100% increased Cast Speed" })
			assert.near(0.09, output.MineRearmTime, 0.000001)
			output = update({ customMods = rod .. "\n20% increased Action Speed" })
			assert.near(1.2, output.ActionSpeedMod, 0.000001)
			assert.near(0.18, output.MineRearmTime, 0.000001)
			output = update({ customMods = rod .. "\n99% reduced Cast Speed" })
			assert.near(18, output.MineRearmTime, 0.000001)
			assert.are.equals(0, output.MineReusedRate)
		end)

		it("does not re-arm expired Pyroclast mines in either detonation mode", function()
			for _, automated in ipairs({ false, true }) do
				newBuild()
				build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
				if automated then
					build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
				end
				local output = update({ customMods = "Mines can be Detonated an additional time\n99% reduced Mine Duration" })
				assert.are.equals(0, output.MineReusedRate)
				assert.is_true(output.MineDetonationsPerMine <= 1)
			end
		end)

		it("preserves the original Pyroclast expiry through multiple guaranteed extra uses", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
			local mods = "Mines can be Detonated 2 additional times\n1000% increased Cast Speed\n1000% increased Cooldown Recovery Rate\n1000% increased Mine Throwing Speed\nMines have 10000% increased Detonation Speed"
			local output = update({ customMods = mods })
			assert.are.equals(2, output.MineExtraUses)
			assert.is_true(output.MineDetonationsPerMine > 2)
			assert.is_true(output.MineDetonationsPerMine <= 3)
			output = update({ customMods = mods .. "\n99% reduced Mine Duration" })
			assert.is_true(output.MineReusedRate > 0)
			assert.is_true(output.MineDetonationsPerMine <= 2)
		end)

		it("counts re-arming Pyroclast mines against the active limit so new throws can displace them", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
			local output = update({ customMods = "Mines can be Detonated an additional time\n10000% increased Mine Throwing Speed\n90% reduced Cast Speed" })
			assert.near(1.8, output.MineRearmTime, 0.000001)
			assert.is_true(output.MineLayingSpeed * output.MineRearmTime > output.ActiveMineLimit)
			assert.are.equals(0, output.MineReusedRate)
			assert.is_true(output.MineDetonationsPerMine <= 1)
		end)

		it("handles zero throwing, trigger recovery and cast speed with extra Pyroclast uses", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
			local rod = "Mines can be Detonated an additional time\n"
			for _, mod in ipairs({ "100% reduced Mine Throwing Speed", "100% reduced Cooldown Recovery Rate", "100% reduced Mine Duration" }) do
				local output = update({ customMods = rod .. mod })
				assert.are.equals(0, output.TotalDPS)
				assert.are.equals(0, output.MineReusedRate)
			end
			local output = update({ customMods = rod .. "100% reduced Cast Speed" })
			assert.is_true(output.TotalDPS > 0)
			assert.are.equals(0, output.MineReusedRate)
		end)

		it("does not treat a manual restart as a continuation of the previous Pyroclast sequence", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			local output = update({ customMods = "Mines can be Detonated an additional time", pyroclastMineSequenceCount = 1 })
			assert.are.equals(2, output.MineDetonationsPerMine)
			assert.are.equals(1, output.MineSequenceCount)
			assert.are.equals(3, output.MineSequenceAverageProjectiles)
			build.skillsTab.socketGroupList[1].gemList[1].skillPart = 2
			build.buildFlag = true
			output = update()
			assert.is_nil(output.MineRearmTime)
			assert.is_nil(output.MineSequenceCount)
			assert.near(output.AverageDamage * output.MineLayingSpeed * output.MineThrowCount, output.TotalDPS, 0.000001)
		end)

		for _, name in ipairs({ "Pyroclast Mine", "Pyroclast Mine of Sabotage" }) do
			it("uses simulated nearby mines for " .. name .. " mastery damage and Full DPS", function()
				build.skillsTab:PasteSocketGroup(name .. " 20/0  1")
				build.skillsTab.socketGroupList[1].includeInFullDPS = true
				build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
				local mastery = "Each Mine applies 2% increased Damage taken to Enemies within 6 metres, up to 10%"
				local base = update({ customMods = "Nearby Enemies take 40% increased Damage" }).TotalDPS
				local output = update({ customMods = "Nearby Enemies take 40% increased Damage\n" .. mastery })
				assert.is_true(output.MineDamageTakenAtHit > 0 and output.MineDamageTakenAtHit <= 10)
				assert.near(base * (1 + output.MineDamageTakenAtHit / 140), output.TotalDPS, 0.000001)
				assert.near(output.CombinedDPS, output.FullDPS, 0.000001)
				local dps = output.TotalDPS
				local gem = build.skillsTab.socketGroupList[1].gemList[1]
				gem.skillMineCount, gem.skillMineCountCalcs = 15, 15
				build.buildFlag = true
				output = update()
				assert.near(dps, output.TotalDPS, 0.000001)
				assert.near(dps, build.calcsTab.calcsOutput.TotalDPS, 0.000001)
				assert.are.equals(15, build.calcsTab.mainEnv.enemy.modDB:GetMultiplier("ActiveMineCount"))
				build.viewMode = "CALCS"
				runCallback("OnFrame")
				assert.is_not_nil(build.calcsTab.calcsEnv.player.breakdown.MineDamageTakenAtHit)
				assert.is_not_nil(build.calcsTab.calcsEnv.player.breakdown.MineDamageTakenOverTime)
				gem.skillMineCount, gem.skillMineCountCalcs = nil, nil
				build.buildFlag = true
				output = update({ customMods = "Nearby Enemies take 40% increased Damage" })
				assert.near(base, output.TotalDPS, 0.000001)
				assert.near(0, output.MineDamageTakenAtHit, 0.000001)
			end)
		end

		it("uses time-weighted mine debuff uptime for ignite, not hit-weighted or snapshot damage taken", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
			local mods = "-14 to maximum number of Remote Mines\n100% chance to Ignite"
			local output = update({ customMods = mods })
			local hit, ignite = output.TotalDPS, output.IgniteDPS
			assert.is_true(ignite > 0)
			output = update({ customMods = mods .. "\nEach Mine applies 2% increased Damage taken to Enemies within 6 metres, up to 10%" })
			assert.near(2, output.MineDamageTakenAtHit, 0.000001)
			assert.near(2 * output.MineAverageActive, output.MineDamageTakenOverTime, 0.000001)
			assert.is_true(output.MineDamageTakenOverTime < output.MineDamageTakenAtHit)
			assert.near(hit * 1.02, output.TotalDPS, 0.000001)
			assert.near(ignite * (1 + output.MineDamageTakenOverTime / 100), output.IgniteDPS, 0.000001)
		end)

		it("caps each sampled mine debuff before averaging and weights hits by sequence projectiles", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1\nMinefield 20/0  1")
			build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
			local mods = "100% increased Mine Throwing Speed\nMines can be Detonated an additional time"
			local uncapped = update({ customMods = mods .. "\nEach Mine applies 2% increased Damage taken to Enemies within 6 metres, up to 100%" })
			local hit, dot = uncapped.MineDamageTakenAtHit, uncapped.MineDamageTakenOverTime
			assert.near(2 * uncapped.MineAverageActive, dot, 0.000001)
			local output = update({ customMods = mods .. "\nEach Mine applies 2% increased Damage taken to Enemies within 6 metres, up to 10%" })
			assert.is_true(output.MinePeakActive > 5)
			assert.is_true(output.MineDamageTakenAtHit < math.min(hit, 10))
			assert.is_true(output.MineDamageTakenOverTime < math.min(dot, 10))
			local weighted = output.MineDamageTakenAtHit
			output = update({ enemySizePreset = "Custom", enemyRadius = 100 })
			assert.is_true(math.abs(output.MineDamageTakenAtHit - weighted) > 0.000001)
		end)

		it("accounts for mana-starved debuff downtime and handles no mine supply", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
			local mods = "Each Mine applies 2% increased Damage taken to Enemies within 6 metres, up to 10%"
			local uptime = update({ customMods = mods }).MineDamageTakenOverTime
			local output = update({ pyroclastMineManaLimited = true, customMods = mods .. "\nNo Mana Regeneration" })
			assert.is_true(output.MineManaWait > 0)
			assert.is_true(output.MineDamageTakenOverTime < uptime)
			output = update({ customMods = mods .. "\n100% reduced Mine Throwing Speed" })
			assert.are.equals(0, output.TotalDPS)
			assert.are.equals(0, output.MineDamageTakenAtHit)
			assert.are.equals(0, output.MineDamageTakenOverTime)
		end)

		it("preserves static mine mastery behavior outside automated Average Sequence", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1")
			local gem = build.skillsTab.socketGroupList[1].gemList[1]
			gem.skillMineCount, gem.skillMineCountCalcs = 5, 5
			build.buildFlag = true
			local base = update().TotalDPS
			local mods = "Each Mine applies 2% increased Damage taken to Enemies within 6 metres, up to 10%"
			local output = update({ customMods = mods })
			assert.near(base * 1.1, output.TotalDPS, 0.000001)
			assert.is_nil(output.MineDamageTakenAtHit)
			build.skillsTab:PasteSocketGroup("Detonate Mines 1/0  1\nAutomation 20/0  1")
			assert.is_not_nil(update().MineDamageTakenAtHit)
			gem.skillPart = 2
			build.buildFlag = true
			output = update()
			assert.is_nil(output.MineDamageTakenAtHit)
			local singleHit = output.TotalDPS
			assert.near(singleHit / 1.1, update({ customMods = "" }).TotalDPS, 0.000001)
		end)

		it("shows automated sequence breakdowns, survives saving and preserves single-hit mode", function()
			build.skillsTab:PasteSocketGroup("Pyroclast Mine 20/0  1\nMinefield 20/0  1")
			build.skillsTab:PasteSocketGroup("Detonate Mines 1/20  1\nAutomation 20/20  1")
			local output = update()
			local expectedDPS = output.TotalDPS
			assert.near(output.TotalDPS, build.calcsTab.calcsOutput.TotalDPS, 0.000001)
			build.viewMode = "CALCS"
			runCallback("OnFrame")
			local breakdown = build.calcsTab.calcsEnv.player.breakdown
			assert.is_not_nil(breakdown.MineAutomationTriggerRate)
			assert.is_true(#breakdown.MineSequenceAverageProjectiles.rowList > 1)
			local xml = build:SaveDB("Automated Pyroclast")
			loadBuildFromXML(xml, "Automated Pyroclast")
			assert.near(expectedDPS, build.calcsTab.mainOutput.TotalDPS, 0.000001)
			build.skillsTab.socketGroupList[1].gemList[1].skillPart = 2
			build.buildFlag = true
			output = update()
			assert.is_nil(output.MineAutomationTriggerRate)
			assert.is_nil(output.MineSequenceCount)
			assert.near(output.AverageDamage * output.MineLayingSpeed * output.MineThrowCount, output.TotalDPS, 0.000001)
		end)
	end)

	for _, support in ipairs({
		{ name = "Trap", cooldown = "TrapCooldown", speed = "TrapThrowingSpeed", rate = 119 / 60 },
		{ name = "Blastchain Mine", cooldown = "Cooldown", speed = "MineLayingSpeed", rate = 10 / 3 },
		{ name = "High-Impact Mine", cooldown = "Cooldown", speed = "MineLayingSpeed", rate = 10 / 3 },
	}) do
		it("limits " .. support.name .. " hit DPS and Full DPS by cooldown without exceeding throwing speed", function()
			build.skillsTab:PasteSocketGroup("Frost Bomb 20/0  1\n" .. support.name .. " 20/0  1")
			build.skillsTab.socketGroupList[1].includeInFullDPS = true
			for _, case in ipairs({
				{ recovery = 0, cooldown = 2.508 },
				{ recovery = 100, cooldown = 1.254 },
				{ recovery = 1000, cooldown = 0.231 },
			}) do
				build.configTab.input.customMods = case.recovery .. "% increased Cooldown Recovery Rate"
				build.configTab:BuildModList()
				runCallback("OnFrame")

				local output = build.calcsTab.mainOutput
				local expectedRate = case.recovery == 1000 and support.rate or 1 / case.cooldown
				assert.near(case.cooldown, output[support.cooldown], 0.000001)
				assert.near(support.rate, output[support.speed], 0.000001)
				assert.near(expectedRate, output.Speed, 0.000001)
				assert.near(output.AverageDamage * expectedRate, output.TotalDPS, 0.000001)
				assert.near(output.TotalDPS, output.FullDPS, 0.000001)
			end
		end)

		it("keeps cooldown-free " .. support.name .. " skills limited by throwing speed", function()
			build.skillsTab:PasteSocketGroup("Fireball 20/0  1\n" .. support.name .. " 20/0  1")
			runCallback("OnFrame")

			local output = build.calcsTab.mainOutput
			assert.is_nil(output[support.cooldown])
			assert.near(support.rate, output.Speed, 0.000001)
			assert.near(output.AverageDamage * support.rate, output.TotalDPS, 0.000001)
		end)
	end

	it("preserves Lightning Spire Trap's independent hit rate", function()
		build.skillsTab:PasteSocketGroup("Lightning Spire Trap 20/0  1")
		runCallback("OnFrame")

		local output = build.calcsTab.mainOutput
		assert.near(8.019, output.TrapCooldown, 0.000001)
		assert.near(1 / 0.36, output.HitSpeed, 0.000001)
		assert.near(output.AverageDamage / 0.36, output.TotalDPS, 0.000001)
	end)

	it("preserves the cooldown cap for spells used by totems", function()
		build.skillsTab:PasteSocketGroup("Frost Bomb 20/0  1\nSpell Totem 20/0  1")
		runCallback("OnFrame")

		local output = build.calcsTab.mainOutput
		assert.near(2.508, output.Cooldown, 0.000001)
		assert.near(1 / 2.508, output.Speed, 0.000001)
		assert.near(output.AverageDamage / 2.508, output.TotalDPS, 0.000001)
	end)

	it("counts only permanent minions for Communion", function()
		build.skillsTab:PasteSocketGroup("Fireball 20/0  1\nCommunion 3/0  1")
		build.skillsTab:PasteSocketGroup("Summon Reaper 20/0  1")
		build.skillsTab:PasteSocketGroup("Summon Raging Spirit 20/0  1")
		runCallback("OnFrame")

		local modDB = build.calcsTab.calcsEnv.player.modDB
		assert.is_true(modDB:Sum("BASE", nil, "Multiplier:SummonedMinion") > 1)
		assert.are.equals(1, modDB:Sum("BASE", nil, "Multiplier:PermanentMinion"))
		assert.is_true(build.calcsTab.calcsOutput.PhysicalMin > 0)

		newBuild()
		build.skillsTab:PasteSocketGroup("Fireball 20/0  1\nCommunion 3/0  1")
		build.skillsTab:PasteSocketGroup("Summon Raging Spirit 20/0  1")
		runCallback("OnFrame")

		assert.are.equals(0, build.calcsTab.calcsEnv.player.modDB:Sum("BASE", nil, "Multiplier:PermanentMinion"))
		assert.are.equals(0, build.calcsTab.calcsOutput.PhysicalMin or 0)
	end)

	it("does not apply arrow damage modifiers to Fireball", function()
		build.skillsTab:PasteSocketGroup("Fireball 20/0  1")
		build.configTab.input.customMods = "Projectiles Pierce an additional Target"
		build.configTab:BuildModList()
		runCallback("OnFrame")
		local damageWithoutArrowMod = build.calcsTab.mainOutput.AverageDamage

		build.configTab.input.customMods = [[
		Projectiles Pierce an additional Target
		Arrows deal 50% increased Damage with Hits and Ailments to Targets they Pierce
		]]
		build.configTab:BuildModList()
		runCallback("OnFrame")

		assert.are.equals(damageWithoutArrowMod, build.calcsTab.mainOutput.AverageDamage)
	end)

	it("rounds area modifiers before calculating radius", function()
		build.skillsTab:PasteSocketGroup("Fireball 20/0  1")
		build.configTab.input.customMods = [[
		1% increased Area of Effect
		50% more Area of Effect
		]]
		build.configTab:BuildModList()
		runCallback("OnFrame")

		-- The client truncates 101% * 150% to 151% before taking the square root.
		assert.are.equals(1.51, build.calcsTab.mainOutput.AreaOfEffectMod)
	end)

	it("applies final skill radius modifiers after area scaling", function()
		build.skillsTab:PasteSocketGroup("Summon Carrion Golem 20/0  1")
		runCallback("OnFrame")

		local mainSocketGroup = build.skillsTab.socketGroupList[build.mainSocketGroup]
		local activeSkill = mainSocketGroup.displaySkillList[mainSocketGroup.mainActiveSkill]
		local foundLeapSlam
		for index, minionSkill in ipairs(activeSkill.minion.activeSkillList) do
			if minionSkill.activeEffect.grantedEffect.id == "BoneGolemLeapSlam" then
				activeSkill.activeEffect.srcInstance.skillMinionSkill = index
				activeSkill.activeEffect.srcInstance.skillMinionSkillCalcs = index
				foundLeapSlam = true
				break
			end
		end
		assert.is_true(foundLeapSlam)
		build.modFlag = true
		build.buildFlag = true
		runCallback("OnFrame")

		-- Leap Slam has 15 base radius and 30% final radius: floor(15 * 1.30) = 19.
		assert.are.equals(19, build.calcsTab.mainEnv.minion.output.AreaOfEffectRadius)
	end)

	it("rounds each scaled damage conversion to a whole percent", function()
		build.skillsTab:PasteSocketGroup("Fireball 20/0  1")
		build.configTab.input.customMods = [[
		40% of Physical Damage Converted to Lightning Damage
		40% of Physical Damage Converted to Cold Damage
		40% of Physical Damage Converted to Fire Damage
		]]
		build.configTab:BuildModList()
		runCallback("OnFrame")

		local conversion = build.calcsTab.mainEnv.player.mainSkill.conversionTable.Physical
		assert.are.equals(0.33, conversion.conversion.Lightning)
		assert.are.equals(0.33, conversion.conversion.Cold)
		assert.are.equals(0.33, conversion.conversion.Fire)
		assert.is_true(math.abs(conversion.mult - 0.01) < 0.000001)
	end)

	it("rounds damage after the final step of a conversion path", function()
		build.itemsTab:CreateDisplayItemFromRaw([[
		New Item
		Imbued Wand
		Adds 2 to 2 Physical Damage to Spells
		]])
		build.itemsTab:AddDisplayItem()
		build.skillsTab:PasteSocketGroup("Fireball 20/0  1")
		build.configTab.input.customMods = [[
		50% of Physical Damage Converted to Lightning Damage
		50% of Lightning Damage Converted to Cold Damage
		]]
		build.configTab:BuildModList()
		runCallback("OnFrame")

		assert.are.equals(9.6, build.calcsTab.calcsOutput.PhysicalMinBase)
		assert.are.equals(1, build.calcsTab.calcsOutput.ColdMin)
	end)

	it("parses more/less/increased/reduced minimum and maximum damage of every type", function()
		build.itemsTab:CreateDisplayItemFromRaw([[
		New Item
		Coral Amulet
		25% more Maximum Lightning Damage
		50% less Minimum Lightning Damage
		10% increased Maximum Cold Damage
		12% reduced Minimum Physical Damage
		20% more Maximum Chaos Damage
		30% more Maximum Fire Damage
		]])
		build.itemsTab:AddDisplayItem()
		runCallback("OnFrame")

		local modDB = build.calcsTab.mainEnv.player.modDB

		-- "more"/"less" -> MORE modifier (More() returns the aggregate multiplier)
		assert.are.equals(1.25, modDB:More(nil, "MaxLightningDamage"))
		assert.are.equals(0.5, modDB:More(nil, "MinLightningDamage"))
		assert.are.equals(1.2, modDB:More(nil, "MaxChaosDamage"))
		assert.are.equals(1.3, modDB:More(nil, "MaxFireDamage"))

		-- "increased"/"reduced" -> INC modifier
		assert.are.equals(10, modDB:Sum("INC", nil, "MaxColdDamage"))
		assert.are.equals(-12, modDB:Sum("INC", nil, "MinPhysicalDamage"))

		-- sanity: these must not have leaked into the wrong stat/type
		assert.are.equals(1, modDB:More(nil, "MinChaosDamage"))
		assert.are.equals(0, modDB:Sum("INC", nil, "MaxLightningDamage"))
	end)

	-- calcDamage rounds each min/max to an integer before our multipliers' effects can be
	-- observed, so scaling the rounded baseline can differ from the real value by ~1
	local function assertNear(expected, actual, msg)
		assert.is_true(math.abs(expected - actual) <= 2, string.format("%s: expected ~%.2f, got %.2f", msg, expected, actual))
	end

	it("applies min/max damage mods to an actual skill in CalcOffence", function()
		build.skillsTab:PasteSocketGroup("Slot: Body Armour\nArc 20/0  1\n")
		runCallback("OnFrame")

		local baseMin = build.calcsTab.calcsOutput.LightningMin
		local baseMax = build.calcsTab.calcsOutput.LightningMax
		assert.is_true(baseMax > 0)
		assert.is_true(baseMin > 0)

		-- MORE path: "more"/"less" scale only the targeted end of the roll
		build.itemsTab:CreateDisplayItemFromRaw([[
		New Item
		Coral Amulet
		25% more Maximum Lightning Damage
		50% less Minimum Lightning Damage
		]])
		build.itemsTab:AddDisplayItem()
		runCallback("OnFrame")

		assertNear(baseMax * 1.25, build.calcsTab.calcsOutput.LightningMax, "25%% more max")
		assertNear(baseMin * 0.5, build.calcsTab.calcsOutput.LightningMin, "50%% less min")

		-- INC path: "increased" stacks multiplicatively with the MORE factors above
		build.itemsTab:CreateDisplayItemFromRaw([[
		New Item
		Coral Ring
		40% increased Maximum Lightning Damage
		100% increased Minimum Lightning Damage
		]])
		build.itemsTab:AddDisplayItem()
		runCallback("OnFrame")

		assertNear(baseMax * 1.25 * 1.4, build.calcsTab.calcsOutput.LightningMax, "more + increased max")
		assertNear(baseMin * 0.5 * 2, build.calcsTab.calcsOutput.LightningMin, "less + increased min")
	end)

	it("applies minimum and maximum attack damage mods", function()
		build.itemsTab:CreateDisplayItemFromRaw([[
		New Item
		Rusted Sword
		]])
		build.itemsTab:AddDisplayItem()
		build.skillsTab:PasteSocketGroup("Double Strike 20/0  1")
		runCallback("OnFrame")

		local baseMin = build.calcsTab.mainOutput.MainHand.TotalMin
		local baseMax = build.calcsTab.mainOutput.MainHand.TotalMax

		build.itemsTab:CreateDisplayItemFromRaw([[
		New Item
		Coral Amulet
		50% less Minimum Attack Damage
		100% more Maximum Attack Damage
		]])
		build.itemsTab:AddDisplayItem()
		runCallback("OnFrame")

		assertNear(baseMin * 0.5, build.calcsTab.mainOutput.MainHand.TotalMin, "50%% less attack min")
		assertNear(baseMax * 2, build.calcsTab.mainOutput.MainHand.TotalMax, "100%% more attack max")
	end)

	it("parses universal cannot deal/deal no non-<type> damage for player and minions", function()
		build.skillsTab:PasteSocketGroup("Slot: Body Armour\nArc 20/0  1\n")
		runCallback("OnFrame")
		assert.is_true(build.calcsTab.calcsOutput.LightningMax > 0)

		build.itemsTab:CreateDisplayItemFromRaw([[
		New Item
		Coral Amulet
		Cannot deal non-Fire Damage
		Minions deal no non-Fire Damage
		]])
		build.itemsTab:AddDisplayItem()
		runCallback("OnFrame")

		local modDB = build.calcsTab.mainEnv.player.modDB
		assert.truthy(modDB:Flag(nil, "DealNoPhysical"))
		assert.truthy(modDB:Flag(nil, "DealNoLightning"))
		assert.truthy(modDB:Flag(nil, "DealNoCold"))
		assert.truthy(modDB:Flag(nil, "DealNoChaos"))
		assert.is_true(not (modDB:Flag(nil, "DealNoFire")))

		-- minion wording wraps the same flags in MinionModifier
		local minionDealNo = { }
		for _, value in ipairs(modDB:List(nil, "MinionModifier")) do
			if value.mod and value.mod.name:match("^DealNo") then
				minionDealNo[value.mod.name] = true
			end
		end
		assert.truthy(minionDealNo["DealNoPhysical"])
		assert.truthy(minionDealNo["DealNoLightning"])
		assert.truthy(minionDealNo["DealNoCold"])
		assert.truthy(minionDealNo["DealNoChaos"])
		assert.is_true(not (minionDealNo["DealNoFire"]))

		-- Arc is pure lightning, so the player can no longer deal damage with it
		assert.are.equals(0, build.calcsTab.calcsOutput.LightningMax)
		local lightningBreakdown = build.calcsTab.calcsEnv.player.breakdown.Lightning
		assert.are.equals("You can't deal Lightning damage", lightningBreakdown[1])
		assert.are.equals(1, #lightningBreakdown.modList)
		assert.are.equals("DealNoLightning", lightningBreakdown.modList[1].mod.name)
		assert.matches("^Item:%d+:New Item", lightningBreakdown.modList[1].mod.source)
	end)

	it("keeps deal no non-elemental damage as its own literal", function()
		build.itemsTab:CreateDisplayItemFromRaw([[
		New Item
		Coral Amulet
		Deal no non-Elemental Damage
		]])
		build.itemsTab:AddDisplayItem()
		runCallback("OnFrame")

		local modDB = build.calcsTab.mainEnv.player.modDB
		assert.truthy(modDB:Flag(nil, "DealNoPhysical"))
		assert.truthy(modDB:Flag(nil, "DealNoChaos"))
		assert.is_true(not (modDB:Flag(nil, "DealNoLightning")))
		assert.is_true(not (modDB:Flag(nil, "DealNoCold")))
		assert.is_true(not (modDB:Flag(nil, "DealNoFire")))
	end)

	it("enemies in your chilling areas take damage increased by the area's chill effect", function()
		build.skillsTab:PasteSocketGroup("Slot: Body Armour\nVortex 20/0  1\n")
		runCallback("OnFrame")

		local baseAvg = build.calcsTab.mainOutput.AverageDamage
		assert.is_true(baseAvg > 0)
		-- the chill effect currently applied to the enemy (here, from Vortex's chilling area)
		local currentChill = build.calcsTab.mainOutput.CurrentChill
		assert.is_true(currentChill ~= nil and currentChill > 0)

		build.itemsTab:CreateDisplayItemFromRaw([[
		New Item
		Coral Amulet
		Enemies in your Chilling Areas have Cold Damage taken increased by Chill Effect
		]])
		build.itemsTab:AddDisplayItem()
		runCallback("OnFrame")

		-- config checkbox not ticked -> enemy is not in the area -> no change
		assert.are.equals(baseAvg, build.calcsTab.mainOutput.AverageDamage)

		build.configTab.input.conditionEnemyInChillingArea = true
		build.configTab:BuildModList()
		runCallback("OnFrame")

		-- Vortex deals pure cold damage, so the ColdDamageTaken increase scales all of it
		local scaledAvg = baseAvg * (1 + currentChill / 100)
		assertNearRelative(scaledAvg, build.calcsTab.mainOutput.AverageDamage, 0.005,
			string.format("base %.2f scaled by %d%% current chill", baseAvg, currentChill))

		-- the paired "Chilled by your Hits" wording must not stack with the chilling area one
		build.itemsTab:CreateDisplayItemFromRaw([[
		New Item
		Coral Ring
		Enemies Chilled by your Hits have Cold Damage taken increased by Chill Effect
		]])
		build.itemsTab:AddDisplayItem()
		runCallback("OnFrame")

		assertNearRelative(scaledAvg, build.calcsTab.mainOutput.AverageDamage, 0.005,
			string.format("both wordings must apply only once (base %.2f, %d%% chill)", baseAvg, currentChill))
	end)

	-- "Base <ailment> Duration is X seconds" overrides the fixed base duration of the damaging ailments
	for _, case in ipairs({
		{ ailment = "Ignite", skill = "Fireball", chanceMod = "25% chance to Ignite", gameBase = 4 },
		{ ailment = "Bleeding", skill = "Double Strike", chanceMod = "25% chance to cause Bleeding on Hit", gameBase = 5, output = "BleedDuration" },
		{ ailment = "Poison", skill = "Double Strike", chanceMod = "25% chance to Poison on Hit", gameBase = 2 },
	}) do
		it("supports base " .. case.ailment .. " duration override", function()
			local outputName = case.output or (case.ailment .. "Duration")
			build.itemsTab:CreateDisplayItemFromRaw([[
			New Item
			Rusted Sword
			]])
			build.itemsTab:AddDisplayItem()
			build.skillsTab:PasteSocketGroup("Slot: Body Armour\n" .. case.skill .. " 20/0  1\n")
			build.itemsTab:CreateDisplayItemFromRaw([[
			New Item
			Coral Amulet
			]] .. case.chanceMod)
			build.itemsTab:AddDisplayItem()
			runCallback("OnFrame")

			assert.are.equals(case.gameBase, build.calcsTab.mainOutput[outputName])

			build.itemsTab:CreateDisplayItemFromRaw([[
			New Item
			Coral Ring
			Base ]] .. case.ailment .. [[ Duration is 1 second]])
			build.itemsTab:AddDisplayItem()
			runCallback("OnFrame")

			assert.are.equals(1, build.calcsTab.mainOutput[outputName])
		end)
	end
	it("uses the final totem limit when scaling area of effect", function()
		build.skillsTab:PasteSocketGroup("Searing Bond of Detonation 20/0  1")
		build.configTab.input.customMods = [[
		+3 to Maximum Power Charges
		Skills used by Totems have 10% more Area of Effect per maximum number of Summoned Totems
		]]
		build.configTab:BuildModList()
		runCallback("OnFrame")

		-- 1 base totem + 6 maximum power charges, so 70% more area of effect.
		assert.are.equals(7, build.calcsTab.mainOutput.ActiveTotemLimit)
		assert.are.equals(1.7, build.calcsTab.mainOutput.AreaOfEffectMod)
	end)
	it("applies Energy Blade's quality attack speed as increased, not more", function()
		local function attackSpeed(quality)
			newBuild()
			build.itemsTab:CreateDisplayItemFromRaw("Rarity: NORMAL\nCorsair Sword")
			build.itemsTab:AddDisplayItem()
			build.skillsTab:PasteSocketGroup("Energy Blade 20/" .. quality .. "  1")
			build.skillsTab:PasteSocketGroup("Slot: Weapon 1\nCleave 20/0  1")
			build.mainSocketGroup = 2
			build.configTab.input.customMods = "100% increased Attack Speed"
			build.configTab:BuildModList()
			runCallback("OnFrame")
			return build.calcsTab.mainOutput.Speed
		end

		-- "Buff grants 10% increased Attack Speed" at 20% quality: (1 + 1 + 0.1) / (1 + 1)
		assertNearRelative(1.05, attackSpeed(20) / attackSpeed(0), 0.0001)
	end)
end)
