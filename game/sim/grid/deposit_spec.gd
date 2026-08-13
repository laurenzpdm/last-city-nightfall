class_name DepositSpec
extends Resource
## One resource type's placement rule for a biome.
##
## The gradient lives here: a deposit's yield is multiplied by
## `1 + richness_gain * (distance/map_radius)^richness_exponent` from the biome,
## so the ore that is worth hauling is always further out than the ore you have.
## That single number is the pressure that pushes a city off its safe island.

## Grid.Res value: 1 scrap, 2 coal, 3 iron, 4 copper, 5 sulfur, 6 vent.
@export var kind: int = 2
## How many separate deposits to scatter.
@export var clusters: int = 10
## Ring the deposits may fall in, in tiles from the geothermal core.
@export var min_distance: int = 24
@export var max_distance: int = 120
## Tiles per deposit.
@export var size_min: int = 12
@export var size_max: int = 34
## Yield per tile before the distance multiplier.
@export var base_amount: int = 320
## Minimum gap between two deposits of this kind.
@export var spacing: int = 14
## Deposits may sit on these terrains only (empty = any walkable, non-road tile).
@export var allow_ruins: bool = false
