extends SceneTree

## Mean absolute RGB difference of two PNGs inside a pixel rect.
##   godot --headless --script tools/test/png_diff.gd -- A.png B.png X Y W H
## Prints `diff <value>`; exits 2 when an image cannot be read.

func _init() -> void:
	var a := OS.get_cmdline_user_args()
	var ia := Image.load_from_file(a[0])
	var ib := Image.load_from_file(a[1])
	if ia == null or ib == null or ia.get_size() != ib.get_size():
		printerr("cannot compare ", a[0], " and ", a[1])
		quit(2)
		return
	var r := Rect2i(int(a[2]), int(a[3]), int(a[4]), int(a[5])).intersection(Rect2i(Vector2i.ZERO, ia.get_size()))
	var total := 0.0
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			var ca := ia.get_pixel(x, y)
			var cb := ib.get_pixel(x, y)
			total += (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
	print("diff %.6f" % (total / maxf(1.0, r.get_area())))
	quit(0)
