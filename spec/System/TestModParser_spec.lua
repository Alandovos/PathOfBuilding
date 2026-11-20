describe("TestModParser", function()
	it("parses guaranteed extra mine uses from cached item text and exported numeric wording", function()
		local freshParser = LoadModule("Modules/ModParser")
		for _, parse in ipairs({ modLib.parseMod, freshParser.parseMod }) do
			for _, case in ipairs({
				{ text = "Mines can be Detonated an additional time", uses = 1 },
				{ text = "Mines can be Detonated 1 additional times", uses = 1 },
				{ text = "Mines can be Detonated 2 additional times", uses = 2 },
			}) do
				local mods, extra = parse(case.text)
				assert.is_nil(extra)
				local modDB = new("ModDB"):ModDB()
				modDB:AddList(mods)
				assert.are.equals(case.uses, modDB:Sum("BASE", nil, "MineExtraUses"))
			end
		end
	end)

	local function getMasterDistillerCritMultiplier(value, skillTypes, hasDiamondFlask)
		local mods, extra = modLib.parseMod("If Diamond Flask Charges are consumed, +" .. value .. "% to Critical Strike Multiplier")
		assert.is_nil(extra)
		local modDB = new("ModDB"):ModDB()
		modDB:AddList(mods)
		modDB.conditions.HaveDiamondFlask = hasDiamondFlask
		return modDB:Sum("BASE", { skillTypes = skillTypes }, "CritMultiplier")
	end

	it("applies the Master Distiller diamond flask bonus only to eligible skills while the flask is present", function()
		assert.are.equal(100, getMasterDistillerCritMultiplier(100, {}, true))
		assert.are.equal(60, getMasterDistillerCritMultiplier(60, {}, true))
		assert.are.equal(0, getMasterDistillerCritMultiplier(100, {}, false))
		assert.are.equal(0, getMasterDistillerCritMultiplier(100, { [SkillType.Triggered] = true }, true))
		assert.are.equal(0, getMasterDistillerCritMultiplier(100, { [SkillType.Channel] = true }, true))
	end)
end)
