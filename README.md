# CC-Autocraft

A [CC: Tweaked](https://tweaked.cc/) Lua program for automated multi-level crafting in Minecraft.

## What it does

You run `craft` on a computer, enter an item name and how many you need — the program figures out the full recipe chain, crafts all the intermediate items it can (using what's already in storage), and delivers the result to the item vault.

**Example:** ask for 4 `oak_fence_gate` → the program automatically crafts the planks and sticks it needs, then crafts the fence gates.

Items with no recipe (raw materials like logs, ores, etc.) must already be present in the vault. If anything is missing, the program reports the full shortfall before starting.

## How it works

1. **Planning** — builds an ordered craft plan by walking the recipe tree bottom-up, using stock where available and scheduling crafts only for what's missing.
2. **Validation** — simulates the plan against current stock and reports all missing items at once if anything is short.
3. **Execution** — runs each craft step in order: pulls ingredients from the vault, sends them to the crafting turtle over rednet, waits for the result, returns crafted items to the vault.

### Components

| File | Runs on | Role |
|------|---------|------|
| `craft.lua` | Computer | Entry point: input item + count, start crafting |
| `crafter.lua` | Turtle | Listens on rednet, calls `turtle.craft()` on demand |
| `new_craft.lua` | Computer | Record a new recipe by placing items in the interface |
| `all_recipes.lua` | Computer | List all saved recipes |
| `get_recipe.lua` | Computer | Show details of a single recipe |

## Config

All settings are in `src/lib/config.lua`.

| Setting | Default | Description |
|---------|---------|-------------|
| `IS_DEBUG_MODE` | `false` | Enable verbose debug logging |
| `STOCK_NAME` | `"create:item_vault_1"` | Peripheral name of the item vault |
| `NEW_RECIPE_INTERFACE_NAME` | `"minecraft:barrel_0"` | Peripheral name of the interface used to record new recipes |
| `CRAFTER_NAME` | `"turtle_2"` | Peripheral name of the crafting turtle |
| `CRAFTER_NETWORK_ID` | `5` | Rednet ID of the crafting turtle |
| `PATTERN_SIZE` | `3` | Recipe grid size (3 for a standard 3×3 grid) |
| `CRAFTER_ROW_SIZE` | `4` | Row size of the turtle inventory (always 4) |
| `NEW_RECIPE_INTERFACE_ROW_SIZE` | `9` | Row size of the recipe recording interface |
| `PATTERN_START` | `4` | First slot of the recipe pattern in the interface |
| `RECIPES_PATH` | `"data/recipes.json"` | Path where recipes are saved on disk |
| `CRAFT_TIMEOUT` | `30` | Seconds to wait for the turtle to respond before giving up |
| `CLEAR_CRAFTER_BEFORE_CRAFT` | `true` | Pull any leftover items from the turtle before each craft (safe but slower; disable if crafting speed matters and the turtle is always clean) |

## Deploy

Copy `.env.example` to `.env` and fill in your Minecraft save paths, then:

```sh
just deploy
```

Requires [just](https://github.com/casey/just), [rsync](https://rsync.samba.org/).
