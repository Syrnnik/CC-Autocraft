# CC-Autocraft

A [CC: Tweaked](https://tweaked.cc/) Lua program for automated multi-level crafting in Minecraft.

## What it does

A touch-screen monitor UI lets you browse saved recipes, manage stock, and kick off crafting jobs with a count selector. The program figures out the full recipe chain, crafts all intermediate items it can (using what's already in storage), and delivers the result to the item vault.

**Example:** ask for 4 `oak_fence_gate` → the program automatically crafts the planks and sticks it needs, then crafts the fence gates.

Items with no recipe (raw materials like logs, ores, etc.) must already be present in the vault. If anything is missing, the program reports the full shortfall before starting.

## How it works

1. **Planning** — builds an ordered craft plan by walking the recipe tree bottom-up, using stock where available and scheduling crafts only for what's missing.
2. **Validation** — simulates the plan against current stock and reports all missing items at once if anything is short.
3. **Execution** — runs each craft step as a single batch: pushes all ingredients to the crafting turtle at once (or to the target machine), waits for the result, returns crafted items to the vault.

Two recipe types are supported:
- **Crafter** — standard shaped/shapeless recipes processed by a crafting turtle.
- **Machine** — items are pushed to one or more machine peripherals; the program waits for the result to appear and pulls it back.

## Components

| File | Runs on | Role |
|------|---------|------|
| `monitor.lua` | Computer | Main entry point: launches the touch-screen UI |
| `crafter.lua` | Turtle | Listens on rednet, calls `turtle.craft()` on demand |
| `craft.lua` | Computer | CLI alternative: enter item name and count in terminal |
| `new_craft.lua` | Computer | CLI alternative: record a new crafter recipe via terminal |
| `all_recipes.lua` | Computer | CLI: list all saved recipes |
| `get_recipe.lua` | Computer | CLI: show details of a single recipe |
| `delete_recipe.lua` | Computer | CLI: delete a recipe by name |

## Config

All settings are in `src/lib/config.lua`.

| Setting | Default | Description |
|---------|---------|-------------|
| `IS_DEBUG_MODE` | `false` | Enable verbose debug logging |
| `STOCK_NAME` | `"create:item_vault_1"` | Peripheral name of the item vault |
| `NEW_RECIPE_INTERFACE_NAME` | `"minecraft:barrel_0"` | Peripheral used to record new recipes |
| `CRAFTER_NAME` | `"turtle_2"` | Peripheral name of the crafting turtle |
| `CRAFTER_NETWORK_ID` | `5` | Rednet ID of the crafting turtle |
| `MONITOR_NAME` | `"monitor_1"` | Peripheral name of the touch-screen monitor |
| `MONITOR_TEXT_SCALE` | `1.0` | Text scale for the monitor |
| `CRAFT_TIMEOUT` | `30` | Seconds to wait for the turtle before giving up |
| `MACHINE_CRAFT_TIMEOUT` | `30` | Seconds to wait for a machine recipe to complete |
| `CLEAR_CRAFTER_BEFORE_CRAFT` | `true` | Pull leftover items from the turtle before each craft |
| `PATTERN_SIZE` | `3` | Recipe grid size (3 for a standard 3×3 grid) |
| `NEW_RECIPE_INTERFACE_ROW_SIZE` | `9` | Row size of the recipe recording interface |
| `PATTERN_START` | `4` | First slot of the recipe pattern in the interface |
| `RECIPES_PATH` | `"data/recipes.json"` | Path where recipes are stored on disk |

## Deploy

Copy `.env.example` to `.env` and fill in your Minecraft save paths, then:

```sh
just deploy
```

Requires [just](https://github.com/casey/just) and [rsync](https://rsync.samba.org/).
