describe("ItemDBControl", function()
	local originalGetCursorPos

	before_each(function()
		originalGetCursorPos = GetCursorPos
	end)

	after_each(function()
		GetCursorPos = originalGetCursorPos
	end)

	it("sorts lower-is-better stats below zero", function()
		local function makeItem(name)
			return {
				name = name,
				base = {},
				enchantModLines = {},
				implicitModLines = {},
				explicitModLines = {},
				baseModList = {},
			}
		end
		local betterItem = makeItem("Better Item")
		local worseItem = makeItem("Worse Item")
		local invalidItem = makeItem("Invalid Item")
		local takenDamage = {
			[betterItem] = 80,
			[worseItem] = 120,
		}
		local itemsTab = {
			activeItemSet = { useSecondWeaponSet = false },
			slots = { ["Body Armour"] = { shown = function() return true end } },
			build = {
				calcsTab = {
					GetMiscCalculator = function()
						return function(args)
							return { PhysicalTakenHit = takenDamage[args.repItem] }
						end
					end,
				},
			},
			IsItemValidForSlot = function(_, item)
				return item ~= invalidItem
			end,
		}
		local control = new("ItemDBControl"):ItemDBControl(nil, { 0, 0, 100, 100 }, itemsTab, {
			list = { invalidItem, betterItem, worseItem },
		}, "RARE")
		control.sortDetail = {
			stat = "PhysicalTakenHit",
			transform = function(value) return -value end,
		}
		control.sortOrder = { control.sortControl.STAT, control.sortControl.NAME }

		control:ListBuilder()

		assert.are.equal(betterItem, control.list[1])
		assert.are.equal(worseItem, control.list[2])
		assert.are.equal(invalidItem, control.list[3])
		assert.are.equal(-80, betterItem.measuredPower)
		assert.are.equal(-120, worseItem.measuredPower)
		assert.are.equal(-math.huge, invalidItem.measuredPower)
	end)

	it("ranks Viscera at midpoint rolls without changing database items or equipped slots", function()
		newBuild()
		local source = new("Item"):Item([[
Rarity: Rare
Severed Rhoa Head
Severed Rhoa Head
Implicits: 1
{range:1}(20-30)% increased Chaos Damage
]])
		local originalRaw = source.raw
		local slot = build.itemsTab.slots.Head
		local equipped = slot.selItemId
		local calls = 0
		local itemsTab = {
			activeItemSet = build.itemsTab.activeItemSet,
			slots = { Head = slot },
			IsItemValidForSlot = function(_, item, slotName)
				return build.itemsTab:IsItemValidForSlot(item, slotName)
			end,
			build = { calcsTab = { GetMiscCalculator = function()
				return function(override)
					calls = calls + 1
					assert.are.equal("Head", override.repSlotName)
					assert.are.equal(0.5, override.repItem.implicitModLines[1].range)
					assert.are.equal(25, override.repItem.baseModList[1].value)
					return { CombinedDPS = 125 }
				end
			end } },
		}
		local control = new("ItemDBControl"):ItemDBControl(nil, { 0, 0, 360, 200 }, itemsTab, { list = { source } }, "VISCERA")
		assert.are.equal("CombinedDPS", control.sortMode)
		assert.is_not_nil(control.controls.sort)
		control:ListBuilder()
		assert.are.equal(1, calls)
		assert.are.equal(125, control.list[1].measuredPower)
		assert.are.equal(0.5, control.list[1].implicitModLines[1].range)
		assert.is_truthy(control:GetRowValue(1, 1, control.list[1]):find("125", 1, true))
		assert.are.equal(originalRaw, source.raw)
		assert.are.equal(1, source.implicitModLines[1].range)
		assert.are.equal(equipped, slot.selItemId)
		control:SetSortMode("Name")
		control:ListBuilder()
		assert.are.equal(1, calls)
		assert.are.equal(colorCodes[source.rarity]..source.name, control:GetRowValue(1, 1, control.list[1]))
	end)

	it("sorts native Viscera replacements by DPS and refreshes the ranking metric", function()
		newBuild()
		build.skillsTab:PasteSocketGroup("Essence Drain 20/0  1")
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		runCallback("OnFrame")
		local lesser = main.visceraDB.list["Lesser Severed Rhoa Head, Severed Rhoa Head"]
		local greater = main.visceraDB.list["Severed Rhoa Head, Severed Rhoa Head"]
		assert(lesser and greater)
		local control = new("ItemDBControl"):ItemDBControl(nil, { 0, 0, 360, 200 }, build.itemsTab, {
			list = { lesser, greater },
		}, "VISCERA")
		control.controls.slot:SelByValue("Head")
		control:ListBuilder()
		assert.are.equal(greater.name, control.list[1].name)
		assert(control.list[1].measuredPower > control.list[2].measuredPower)
		local calculate = build.calcsTab:GetMiscCalculator()
		local output = calculate({ repSlotName = "Head", repItem = control.list[1] }, false)
		assert.near(output.CombinedDPS, control.list[1].measuredPower, 1e-8)
		control:SetSortMode("FullDPS")
		control:ListBuilder()
		output = calculate({ repSlotName = "Head", repItem = control.list[1] }, true)
		assert.near(output.FullDPS, control.list[1].measuredPower, 1e-8)
		assert(build.itemsTab.controls.visceraDB.controls.sort)
		local _, sortY = build.itemsTab.controls.visceraDB.controls.sort:GetPos()
		local _, slotY = build.itemsTab.controls.visceraDB.controls.slot:GetPos()
		local _, searchY = build.itemsTab.controls.visceraDB.controls.search:GetPos()
		assert(slotY + 18 <= sortY and sortY + 18 <= searchY)
	end)

	it("marks Viscera unavailable without a compatible active slot", function()
		newBuild()
		local control = new("ItemDBControl"):ItemDBControl(nil, { 0, 0, 360, 200 }, {
			slots = {},
			build = build,
			activeItemSet = build.itemsTab.activeItemSet,
		}, { list = { main.visceraDB.list["Severed Rhoa Head, Severed Rhoa Head"] } }, "VISCERA")
		control:ListBuilder()
		assert.are.equal(-math.huge, control.list[1].measuredPower)
		assert.is_truthy(control:GetRowValue(1, 1, control.list[1]):find("unavailable", 1, true))
	end)

	it("searches Foulborn modifier text without case sensitivity", function()
		local item = new("Item"):Item([[
			Rarity: Unique
			Kitava's Thirst
			Zealot Helmet
			Variant: Pre 3.11.0
			Variant: Current
			Selected Variant: 2
			50% chance to Trigger Socketed Spells when you Spend at least 100 Mana on an
			Upfront Cost to Use or Trigger a Skill, with a 0.1 second Cooldown
		]])
		local control = new("ItemDBControl"):ItemDBControl(nil, { 0, 0, 100, 100 }, {
			build = {
				characterLevel = 100,
			},
		}, {
			list = { item },
		}, "UNIQUE")
		control.controls.search.buf = "life on an upfront cost"
		control.controls.searchMode.selIndex = 3

		assert.is_true(control:DoesItemMatchFilters(item))
	end)

	it("releases focus after opening an item with a double click", function()
		local item = {
			raw = "Rarity: Unique\nTest Item\nLeather Belt",
		}
		local itemsTab
		itemsTab = {
			CreateDisplayItemFromRaw = function(_, raw, isUnique)
				itemsTab.displayRaw = raw
				itemsTab.displayIsUnique = isUnique
			end,
		}
		local control = new("ItemDBControl"):ItemDBControl(nil, { 0, 0, 100, 100 }, itemsTab, {
			list = { item },
		}, "UNIQUE")
		control.list = { item }
		GetCursorPos = function()
			return 3, 3
		end
		control.GetRowRegion = function()
			return { x = 0, y = 0, width = 100, height = 100 }
		end

		local selectedControl = control:OnKeyDown("LEFTBUTTON", true)

		assert.is_nil(selectedControl)
		assert.are.equal(item.raw, itemsTab.displayRaw)
		assert.is_true(itemsTab.displayIsUnique)
	end)

	it("offers only compatible slot categories in the Viscera dropdown", function()
		newBuild()
		local control = build.itemsTab.controls.visceraDB
		assert.are.same({ "Any slot", "Head", "Body", "Arm", "Leg" }, control.controls.slot.list)
		for _, raw in ipairs(data.viscera) do
			local item = new("Item"):Item(raw, "RARE", true)
			for _, slotName in ipairs({ "Head", "Body", "Arm", "Leg" }) do
				control.controls.slot:SelByValue(slotName)
				assert.are.equal(build.itemsTab:IsItemValidForSlot(item, slotName) == true, control:DoesItemMatchFilters(item))
			end
		end
	end)

	it("appends typed Wickerman filters after Grafts", function()
		local item = new("Item"):Item("")
		item.base = { }
		for _, dbType in ipairs({ "RARE", "UNIQUE" }) do
			local control = new("ItemDBControl"):ItemDBControl(nil, { 0, 0, 100, 100 }, { }, { list = { } }, dbType)
			item.type = "Graft"
			control.controls.slot:SelByValue("Graft 1")
			assert.are.equal("Graft 1", control.slotList[control.controls.slot.selIndex])
			assert.is_true(control:DoesItemMatchFilters(item))
			control.controls.slot:SelByValue("Graft 2")
			assert.are.equal("Graft 2", control.slotList[control.controls.slot.selIndex])
			local lastIndex = control.controls.slot.selIndex
			for _, slotName in ipairs({ "Head", "Body", "Arm", "Leg" }) do
				control.controls.slot:SelByValue(slotName)
				assert.are.equal(lastIndex + 1, control.controls.slot.selIndex)
				assert.is_false(control:DoesItemMatchFilters(item))
				item.type = slotName
				assert.is_true(control:DoesItemMatchFilters(item))
				lastIndex = control.controls.slot.selIndex
			end
		end
	end)
end)
