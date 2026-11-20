# Path of Building Community Fork Codebase Rundown

## Layout
* ### Assets
    * **game_ui_small.png**
        Overlay on top of range_guide.png.
    * **range_guide.png**
        Area of effect scale in Calcs view.
    * **ring.png**
        Ring overlay on hovering over jewel sockets in Tree view.
    * **ShadedInnerRing.png**
        Ring overlay for radius jewels.
    * **ShadedInnerRingFlipped.png**
        Ring overlay for Thread of Hope.
    * **ShadedOuterRing.png**
        Ring overlay for radius jewels.
    * **ShadedOuterRingFlipped.png**
        Ring overlay for Thread of Hope.
    * **small_ring.png**
        Highlighting of matching nodes in Tree view search results.
* ### Classes
    * **BuildControlList.lua**
    * **ButtonControl.lua**
    * **CalcBreakdownControl.lua**
    * **CalcSectionControl.lua**
    * **CalcsTab.lua**
    * **CheckBoxControl.lua**
    * **ConfigTab.lua**
    * **Control.lua**
    * **ControlHost.lua**
    * **DropDownControl.lua**
    * **EditControl.lua**
    * **FolderListControl.lua**
    * **GemSelectControl.lua**
    * **ImportTab.lua**
    * **Item.lua**
    * **ItemDBControl.lua**
    * **ItemListControl.lua**
    * **ItemSetListControl.lua**
    * **ItemSlotControl.lua**
    * **ItemsTab.lua**
    * **LabelControl.lua**
    * **ListControl.lua**
    * **MinionListControl.lua**
    * **ModDB.lua**
    * **ModList.lua**
    * **ModStore.lua**
    * **NotableDBControl.lua**
    * **NotesTab.lua**
    * **PassiveSpec.lua**
    * **PassiveSpecListControl.lua**
    * **PassiveTree.lua**
    * **PassiveTreeView.lua**
    * **PathControl.lua**
    * **PopupDialog.lua**
    * **PowerReportListControl.lua**
    * **ScrollBarControl.lua**
    * **SearchHost.lua**
    * **SectionControl.lua**
    * **SharedItemListControl.lua**
    * **SharedItemSetListControl.lua**
    * **SkillListControl.lua**
    * **SkillsTab.lua**
    * **SliderControl.lua**
    * **TextListControl.lua**
    * **Tooltip.lua**
    * **TooltipHost.lua**
    * **TreeTab.lua**
    * **UndoHandler.lua**
* ### Data
    * **Global.lua**
        Contains mappings of colour codes, mod flags and keywords. Also contains an enumeration of skill types used in the `ActiveSkills.dat` and `GrantedEffects.dat` game files to hardcode specific interactions. This has to be reverse engineered from the GGPK and not all flags are fully understood yet.
    * **New.lua**
        Newly announced uniques live here until their mod ranges are known.
* ### Export
    The export system warrants its own in-depth document.
* ### Modules
    * **Build.lua**
        Contains controls for everything on the build screen:
        top: "back", "save", "save as", skill points, level, class, ascendancy
        left: the buttons for the different tabs, bandits, pantheon, main skill, stat overview.
        Loads build, initialises all tab components, loads corresponding sections from the build file, builds calculation tab output.
        Contains functions to load/save build and input handling, popups for build version migration, saving, spectre library.
        Contains functions to add totem/minion stats to the sidebar, refreshing and building the statlist.
        Contains functions for attribute requirements in tooltips and comparison of tooltips.
        Contains additional file loading/saving logic.
    * **BuildList.lua**
        Contains the build selection screen that only has basic UI elements not exclusive to this screen. Filesystem manipulation, searching for XML build files in the build path and sorting the resulting list can be found here.
    * **CalcActiveSkill.lua**
    * **CalcBreakdown.lua**
    * **CalcDefence.lua**
    * **CalcOffence.lua**
        Pyroclast Mine and its Sabotage variant default to "Average Sequence (Automatic Overlap)"; "Single Hit" retains the previous per-hit, throwing-rate-based calculation without overlap.
        The sequence estimate adds one initial hit to the expected overlapping projectile hits per mine, using the existing explosion/spread radii and enemy size.
        Like Explosive Trap, it assumes uniform-area landings and integer collision coordinates. Pyroclast's exact landing distribution is not verified from raw game files.
        Projectile counts increase for every three prior mines, with projectile modifiers and rounding applied separately to each mine.
        Sequence length defaults to the active mine limit and can be reduced in Configuration. The model assumes repeated preloaded sequences with concurrent throwing and detonation;
        effective mine rate is the lower of mine supply and sequence detonation throughput. The first mine is instant, subsequent intervals accelerate by 10% per preceding interval,
        and sequence restarts respect the Detonate Mines action's base cooldown. It is an estimate, not a simulation of continued throws extending a sequence.
        Enabled Detonate Mines supported by Automation is detected from the calculated skill list, respecting support compatibility, disabled gems/groups and weapon swaps.
        Automation uses Detonate Mines' own cooldown (including support level/quality, local/global cooldown recovery, and existing server-tick rounding), matching the shared Automation trigger calculation.
        In this case the manual sequence count is ignored. A bounded simulation estimates the first 30 seconds of continuous throwing without a preload,
        averaged over four equally spaced Automation timer phases. Each trigger can start an independent accelerating sequence competing for the available mines;
        sequence-relative projectile counts are weighted by the sampled detonations, rather than assuming a maximum-length manual sequence.
        Throws use the calculated average mines per throw, carrying fractional extra mines into later batches. The active mine limit caps the available pool.
        This represents holding the mine-throwing button with linked Automation, not repeated maximum-size preloads. Neither the legacy "Active Mines" snapshot nor the manual sequence count determines simulated supply or occupancy.
        "Limit automated throwing by mana" defaults on. The timing estimate starts with full mana after other reservations, spends the calculated upfront cost per throw,
        and waits for calculated mana regeneration/flat recovery when unable to pay. It retains uninterrupted throw cadence while affordable, without banking missed throws during mana starvation.
        Calculated ongoing mana costs reduce recovery; the existing every-second-use mana refund is supported. Flasks, leech, recoup, on-kill recovery and other skills' spending are not scheduled.
        Mine reservation is separate from cost: each new mine temporarily reduces the available mana cap until its first detonation, expiry or replacement.
        GGG's [3.14 balance manifesto](https://www.pathofexile.com/forum/view-thread/3079632) explicitly distinguishes mine costs from reservation:
        reservation needs available capacity, not current mana, while the separate upfront cost must be payable.
        Re-arming does not create another mine, spend another throwing cost or re-reserve mana. Freeing reservation opens capacity but does not refund mana spent on throwing.
        Per-mine reservation is captured before applying the legacy Active Mines multiplier. The estimate restores the selected skill's static mine reservation before simulating its actual temporary reservation.
        Life/ES payment and life reservation are explicitly flagged as unsupported for resource limiting; those builds retain the theoretical, resource-unlimited timing estimate.
        Disable the checkbox for the previous resource-unlimited estimate. Manual preloaded-batch and Single Hit calculations are unchanged.
        Calcs reports the time-weighted average physical mine population after tick events and its peak after throws but before same-tick detonations, including mines waiting to re-arm.
        The population audit accounts for thrown mines as exhausted, expired, replaced at the mine limit, or remaining at the sample boundary.
        The legacy "Active Mines" value still supplies ordinary static reservation and mine-count-dependent bonuses outside the timing estimate; damage/defensive snapshots are not time-averaged.
        Detonation timers round up to server ticks, and existing sequences act before new triggers on ties; a sequence ends when its next attempt finds no available mine.
        These event-ordering assumptions are not verified against GGG's runtime. Sequences still active at 30 seconds are truncated, so this is a finite-window estimate, not an exact steady-state or preloaded burst calculation.
        The pool tracks individual mines, their original expiry, remaining uses and re-arm availability. New throws displace the oldest mines at the active mine limit, including re-arming mines.
        Guaranteed extra detonations (`mine_extra_uses`, including Tremor Rod and Reliquarian's Foulborn Tremor Rod) re-use the same mine after its exported cast time,
        modified by cast speed but not the player's action speed. Re-arming does not refresh the exported five-second Pyroclast lifetime; mine-duration modifiers apply.
        A chain selects the oldest eligible mine other than its immediately preceding mine. Re-arming merely makes the mine available: another sequence attempt or Detonate Mines action must detonate it.
        With extra uses and manual detonation, a server-tick simulation follows the preloaded batch, without continued throws, until its original expiry or 30 seconds.
        After a chain ends, it retries Detonate Mines at the action's base cooldown; this is a restart assumption, not a simulation of player input.
        Manual throughput is limited by both the sampled batch timing and the throw rate multiplied by observed detonations per physical mine, rather than blindly doubling damage or supply.
        Export data does not implement the engine's re-arm/chain rules. Community reports describe an additional refractory period, but no verified duration is available; none is invented here.
        Oldest-first selection, chain eligibility, simultaneous-event ordering and the cast-time-only re-arm gate are estimates, not verified reproductions of GGG's runtime.
        Chance-based extra detonations, Skitterbot-triggered detonations, mine arming/landing delays, enemy movement, and projectile travel time are not simulated.
        Calcs shows overlap, per-detonation projectiles, re-arm time, observed detonations per thrown/preloaded mine, reused-detonation rate, sequence timing, rate limits, and expected sequence hit damage.
        References: [GGG 3.27 patch notes](https://www.pathofexile.com/forum/view-thread/3869068), [mine detonation mechanics](https://www.poewiki.net/wiki/Mine#Detonating_mines), [Detonate Mines and Automation](https://www.poewiki.net/wiki/Detonate_Mines).
        Re-arming references: [Mark_GGG's explanation](https://www.pathofexile.com/forum/view-thread/1591919/filter-account-type/staff), [PoE Wiki Tremor Rod](https://www.poewiki.net/wiki/Tremor_Rod),
        [PoEDB's raw `mine_extra_uses` modifier](https://poedb.tw/us/Tremor_Rod), [Pyroclast's cast time and mine lifetime](https://poedb.tw/us/Pyroclast_Mine).
    * **CalcPerform.lua**
    * **Calcs.lua**
        Loads other calcs modules.
        Contains printer for console debugging output, calculators for changes to nodes, items, gems, etc and builds stats for sidebar _and_ calcs tab (one function).
    * **CalcSections.lua**
    * **CalcSetup.lua**
        Most of the code here revolves around the mod databases of player and enemy actors. Adds all mods that the two share with each other, as well as all modifiers that are specific to one actor type. Stuff like the base stats of characters, bandits and pantheons get applied here. Builds the list of nodes on the skill tree as well as the mod list for each node, including all mods added, removed or changed by radius jewels, and adds it to the calculation environment. Tracks attribute requirements, finds skills granted by items, checks jewel sockets, radius jewel and abyss jewels, adds flasks. Has special handling for Necromantic Aegis and Dancing Dervish. Counts number of corrupted/Shaper/Elder/etc. items. Processes extra skills granted by items and removes socket groups that no longer have matching items. Gets weapon data, adds granted passives and merges mods of allocated passives. Sets main skill group, builds list of active skills including support gems. Sets the main skill to the default attack if none is selected.
    * **CalcTools.lua**
        Calculates mod values and tally up increased/more modifiers, validates gems and skill types, checks if support gems can apply to active gems, determines gem type and attribute requirements, builds stat table for skill.
    * **CalcTriggers.lua**
        Automation triggers each supported spell independently when that spell's own cooldown ends, with the support's cooldown recovery modifiers and existing server-tick rounding.
        Its 0.60-second activation cooldown controls toggling Automation, not the supported spells. Automation uses the direct cooldown-rate path, not the general multi-spell rotation simulation.
        The separate Pyroclast timing estimate models mine supply and concurrent accelerating detonation sequences, not an alternative Automation trigger rule.
        References: [GGG 3.24 patch notes](https://www.pathofexile.com/forum/view-thread/3496784), [PoE Wiki](https://www.poewiki.net/wiki/Automation), [PoEDB gem data](https://poedb.tw/us/Automation).
    * **Common.lua**
        Contains various utilities such as a class library, character encoding converters, MurmurHash non-cryptographic hash function used in the GGPK file, type casts used for working with the GGPK file, JSON-to-Lua converter, utilities for manipulating and printing tables, functions for comparison, rounding, formatting and file manipulation
    * **ConfigOptions.lua**
        Contains specifications of the various configuration options for buffs, conditions, map mods and more.
    * **Data.lua**
        Contains skill types, item types. Duplicates some mod creation/processing logic.
        Holds common mappings such as jewel radius, monster exp multiplier, weapon and base info.
        Loads uniques and all bases, skills, stat descriptions, item mods, enchantments, essences, pantheons, skills, gems, minions and builds list of item bases, loads rare items template. There are extra checks to load either the 3.0 or the 2.6 versions, if applicable.
    * **ItemTools.lua**
        Calculate the range of mods on items, replace non-ascii characters in item text and colour mod lines.
    * **Main.lua**
        Loads game version, common, data, mod/item/calc/pantheon..tools.
        There are two modes of the program: the build list and the build itself.
        Sets build paths, loads mod caches, trees, rare and unique items.
        Rebuilds mod caches if in dev mode.
        Draws non-mode-dependent UI controls.
    * **ModParser.lua**
        Parses all mods on items, skills, pantheon to generate the `ModCache`.
        Warrants its own in-depth document.
    * **ModTools.lua**
        Functions to create mods, and format values, flags, tags.
        Also loads the `ModCache` generated by the `ModParser`s.
    * **PantheonTools.lua**
        Parser for pantheon mods used during `CalcSetup`.
    * **StatDescriber.lua**
* ### TreeData
* **.gitattributes**
    See <https://www.git-scm.com/docs/gitattributes>.
* **.gitignore**
    See <https://www.git-scm.com/docs/gitignore>.
* **CHANGELOG.md**
    Patch notes written in Markdown.
* **changelog.txt**
    Patch notes written in plain text.
* **CONTRIBUTING.md**
    Contribution guides.
* **GameVersions.lua**
    Contains global variables to identify and convert outdated builds. Also contains global table of passive skill tree versions used to upgrade to newer skill tree versions.
* **HeadlessWrapper.lua**
    Provides stubs for PoB's graphics host and its environment. Can be used to run PoB from the command line. You would still need to implement at least `Deflate()` and `Inflate()` to import/export builds. Useful for automated testing.
* **Launch.lua**
    Updates on first start, discerns whether PoB is running in dev mode, initialises renderer, loads `Main` module, has callbacks for exiting the program, advancing frames, registering key presses, launching non-blocking subscripts, updating, notification and error prompts.
* **LaunchInstall.lua**
    Downloads and installs the auto-updater on finishing program installation.
* **LICENSE.md**
    MIT licence
* **manifest.xml**
    Contains file name : SHA-1 hash pairings used to determine which files to update.
* **README.md**
    Project overview
* **runtime-win32.zip**
    Contains PoB executable, update executable, compiled libraries `libcurl` (HTTPS requests), `lcurl` (libcurl bindings for Lua), `lua51` (LuaJIT 5.1), `lzip` (DEFLATE), `SimpleGraphic` (custom 2D graphics host), Lua libraries for Base64, JSON, SHA-1, XML, and fonts.
* **tree-2_6.zip**
* **tree-3_6.zip**
* **tree-3_7.zip**
* **tree-3_8.zip**
* **tree-3_9.zip**
* **tree-3_10.zip**
* **tree-3_11.zip**
* **tree-3_12.zip**
* **update_manifest.py**
    Generates SHA-1 hashes for files in `manifest.xml`.
    New files have to be manually added to `manifest.xml` to be processed.
* **UpdateApply.lua**
    Consumes and applies table of update instructions. Updating the runtime itself is done from a separate host environment.
* **UpdateCheck.lua**
    Compares local and remote manifests to determine which files need to be updated, downloads these files and `changelog.txt`, rebuilds `manifest.xml` and builds table of update instructions.
