# CC-Autocraft

A [CC: Tweaked](https://tweaked.cc/) Lua program for automated multi-level crafting in Minecraft.

## What it does

A touch-screen monitor UI lets you browse saved recipes, manage stock, label peripherals, and kick off crafting jobs with a count selector. The program figures out the full recipe chain, crafts all intermediate items it can (using what's already in storage), and delivers the result back to storage.

**Example:** ask for 10 `andesite_casing` → the program automatically crafts the stripped logs it needs first, then crafts the casings.

Items with no recipe (raw materials like logs, ores, etc.) must already be in storage. If anything is missing, the program reports the full shortfall before starting.

## How it works

1. **Planning** — builds an ordered craft plan by walking the recipe tree bottom-up, using stock where available and scheduling crafts only for what's missing.
2. **Validation** — simulates the plan against current stock and reports all missing items at once before starting.
3. **Execution** — runs each craft step in order; progress bar updates after each individual craft. Finished items go to storage, ready for the next step.

Two recipe types are supported:

- **Crafter** — standard shaped/shapeless recipes processed by a crafting turtle.
- **Machine** — items are pushed to one or more machine peripherals; the program waits for the result to appear and pulls it back.

## Installation (in-game)

On the **computer** (the one with the monitor):

```
wget run https://raw.githubusercontent.com/Syrnnik/CC-Autocraft/dev/install.lua computer
```

On the **crafting turtle**:

```
wget run https://raw.githubusercontent.com/Syrnnik/CC-Autocraft/dev/install.lua crafter
```

Both commands download all required files into an `autocraft/` folder. You can specify a different folder as the second argument:

```
wget run https://raw.githubusercontent.com/Syrnnik/CC-Autocraft/dev/install.lua computer myfolder
```

After installing, run `autocraft/monitor` on the computer and `autocraft/crafter` on the turtle.

### Auto-start on boot

To have the programs launch automatically when the computer or turtle turns on, rename the entry point to `startup.lua`:

On the **computer**:
```
mv monitor.lua startup.lua
```

On the **crafting turtle**:
```
mv crafter.lua startup.lua
```

## UI tabs

| Tab | Description |
|-----|-------------|
| **RECIPES** | Browse saved recipes, craft, edit, or delete them |
| **STOCK** | View current inventory counts, filterable by mod |
| **+RECIPE** | Record a new recipe from the crafting interface |
| **CHECKLIST** | Material checklist from a Create schematic clipboard — shows status per item, craft missing items, move available items to the output chest |
| **LABELS** | Assign friendly names to peripherals (e.g. `depot_3` → `lava_input`) |
| **SETUP** | Assign system roles to peripherals (stock, crafter, monitor, etc.) |

## Components

| File | Runs on | Role |
|------|---------|------|
| `monitor.lua` | Computer | Main entry point: launches the touch-screen UI |
| `crafter.lua` | Turtle | Listens on rednet, calls `turtle.craft()` on demand |
| `craft.lua` | Computer | CLI: craft an item by name and count |
| `new_craft.lua` | Computer | CLI: record a new crafter recipe |
| `checklist.lua` | Computer | CLI: print checklist status and transfer in-stock items to output |
| `migrate_recipes.lua` | Computer | Interactive tool: replace port names with labels across all recipes |
| `all_recipes.lua` | Computer | CLI: list all saved recipes |
| `get_recipe.lua` | Computer | CLI: show details of a single recipe |
| `delete_recipe.lua` | Computer | CLI: delete a recipe by name |

## Configuration

### config.lua — edit once after install

Only one value usually needs changing:

| Setting | Default | Description |
|---------|---------|-------------|
| `CRAFTER_NETWORK_ID` | `5` | Rednet ID of the crafting turtle (run `id` on the turtle) |

Everything else is optional:

| Setting | Default | Description |
|---------|---------|-------------|
| `IS_DEBUG_MODE` | `true` | Verbose logging — turn off for normal use |
| `MONITOR_TEXT_SCALE` | `1.0` | Text scale for the monitor |
| `CRAFT_TIMEOUT` | `30` | Seconds to wait for the turtle before giving up |
| `MACHINE_CRAFT_TIMEOUT` | `30` | Seconds to wait for a machine recipe to complete |
| `CLEAR_CRAFTER_BEFORE_CRAFT` | `false` | Pull leftover items from the turtle before each craft |
| `PATTERN_SIZE` | `3` | Recipe grid size (3 for a standard 3×3 grid) |

### SETUP tab — configure peripherals in-game

Peripheral assignments are configured from the monitor UI under the **SETUP** tab — no file editing required. Assign each system role to a peripheral by choosing from your labeled peripherals or entering a name manually.

| Role | Description |
|------|-------------|
| **Stock View** | Peripheral scanned to read available item counts |
| **Stock In** | Peripheral items are pulled from for crafting |
| **Stock Out** | Peripheral crafted items are delivered to |
| **Crafter** | The crafting turtle peripheral |
| **New Recipes** | Interface used to record new recipes (e.g. a barrel) |
| **Monitor** | The touch-screen monitor |
| **Materials Out** | Output chest for the CHECKLIST tab — items are moved here from stock |

`Stock View`, `Stock In`, and `Stock Out` can all point to the same peripheral for a simple single-vault setup.

## Local development

Copy `.env.example` to `.env` and fill in your Minecraft save paths, then:

```sh
just deploy
```

Requires [just](https://github.com/casey/just) and [rsync](https://rsync.samba.org/).
