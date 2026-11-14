class_name Easing
extends RefCounted

## CSS timing functions. css() is cubic-bezier(0.25, 0.1, 0.25, 1), the curve
## every touchscreen transition in the web dashboard uses.

const CSS := [0.25, 0.1, 0.25, 1.0]


static func css(t: float) -> float:
	return cubic_bezier(CSS[0], CSS[1], CSS[2], CSS[3], t)


static func out_cubic(t: float) -> float:
	var u := 1.0 - clampf(t, 0.0, 1.0)
	return 1.0 - u * u * u


static func linear(t: float) -> float:
	return clampf(t, 0.0, 1.0)


## y at the x = t of the curve (0,0) (x1,y1) (x2,y2) (1,1), as browsers solve it:
## Newton iterations on x(s), bisection when the slope is too flat.
static func cubic_bezier(x1: float, y1: float, x2: float, y2: float, t: float) -> float:
	if t <= 0.0:
		return 0.0
	if t >= 1.0:
		return 1.0
	var cx := 3.0 * x1
	var bx := 3.0 * (x2 - x1) - cx
	var ax := 1.0 - cx - bx
	var cy := 3.0 * y1
	var by := 3.0 * (y2 - y1) - cy
	var ay := 1.0 - cy - by
	var s := t
	var solved := false
	for i in 8:
		var x := ((ax * s + bx) * s + cx) * s - t
		if absf(x) < 1e-7:
			solved = true
			break
		var dx := (3.0 * ax * s + 2.0 * bx) * s + cx
		if absf(dx) < 1e-6:
			break
		s -= x / dx
	if not solved:
		var lo := 0.0
		var hi := 1.0
		s = t
		while lo < hi:
			var x := ((ax * s + bx) * s + cx) * s
			if absf(x - t) < 1e-7:
				break
			if t > x:
				lo = s
			else:
				hi = s
			s = (hi - lo) * 0.5 + lo
			if hi - lo < 1e-7:
				break
	return ((ay * s + by) * s + cy) * s
