extends Node
## Numeric check: does any cloth survive past a pocket's drop line?
##
## Rendering the corner from above showed green where the hole should be, but a
## picture cannot say whether that green is cloth or the end of a cushion. This
## measures it.

func _ready() -> void:
	for mode: int in [PoolPhys.POOL, PoolPhys.SNOOKER]:
		PoolPhys.configure(mode)
		var table := PoolTable.new()
		print("\n=== ", "POOL" if mode == PoolPhys.POOL else "SNOOKER", " ===")
		var pieces := table.cloth_pieces()
		print("cloth pieces: ", pieces.size())
		for pk in table.pockets:
			var worst := -1.0
			var worst_pt := Vector2.ZERO
			for piece in pieces:
				for p in piece:
					if p.distance_to(pk.mouth) > 0.30:
						continue
					# Only cloth across the opening itself can be seen. Anything
					# further round than the jaw noses is under a cushion.
					var side := Vector2(-pk.normal.y, pk.normal.x)
					if absf((p - pk.mouth).dot(side)) > pk.half_width:
						continue
					# Depth past the drop line, along the pocket normal.
					var d := (p - pk.mouth).dot(pk.normal)
					if d > worst:
						worst = d
						worst_pt = p
			print("pocket %d %s mouth=%.4v  worst cloth depth past line = %+.4f m at %.4v"
				% [pk.id, "corner" if pk.is_corner else "side", pk.mouth, worst, worst_pt])
	get_tree().quit()
