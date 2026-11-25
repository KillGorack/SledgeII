extends Resource
class_name LootTable

# A list of items that can drop together. The LootManager rolls between its tables, then picks
# inside one by drop_weight. Dragging an item in here is the only step to make it drop.

@export var items: Array[LootItem] = []
