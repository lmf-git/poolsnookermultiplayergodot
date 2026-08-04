class_name PoolRoots
extends RefCounted

## Polynomial root finding for event-driven collision scheduling.
##
## Every motion phase in PoolBall has constant acceleration, so a ball's
## position is exactly quadratic in time. That makes:
##   * ball vs. plane (linear cushion)  ->  quadratic in t
##   * ball vs. ball / circle / pocket  ->  quartic in t   (|dp(t)|^2 - r^2)
##
## We only ever need the *smallest* root inside a window, and we need to never
## miss one (a missed root is a ball tunnelling through a cushion). The quartic
## routine therefore brackets by critical points: the real roots of the
## derivative cut [lo, hi] into intervals on which the polynomial is monotonic,
## so a sign change at the interval ends is a necessary *and sufficient*
## condition for a root inside it. No sampling, nothing to tune.

const EPS := 1.0e-13
const NO_ROOT := INF


static func cbrt(x: float) -> float:
	return signf(x) * pow(absf(x), 1.0 / 3.0)


## Real roots of a*t^2 + b*t + c, using the numerically stable form that avoids
## catastrophic cancellation when b^2 >> 4ac.
static func quadratic_roots(a: float, b: float, c: float) -> PackedFloat64Array:
	if absf(a) < EPS:
		if absf(b) < EPS:
			return PackedFloat64Array()
		return PackedFloat64Array([-c / b])
	var disc := b * b - 4.0 * a * c
	if disc < 0.0:
		return PackedFloat64Array()
	if disc == 0.0:
		return PackedFloat64Array([-0.5 * b / a])
	var sd := sqrt(disc)
	var q := -0.5 * (b + (sd if b >= 0.0 else -sd))
	var r1 := q / a
	if absf(q) < EPS:
		return PackedFloat64Array([r1])
	var r2 := c / q
	return PackedFloat64Array([minf(r1, r2), maxf(r1, r2)])


## Real roots of a*t^3 + b*t^2 + c*t + d (Cardano, with the trigonometric
## branch for three real roots so we never take a cube root of a complex).
static func cubic_roots(a: float, b: float, c: float, d: float) -> PackedFloat64Array:
	if absf(a) < EPS:
		return quadratic_roots(b, c, d)
	var bn := b / a
	var cn := c / a
	var dn := d / a
	# Depressed cubic y^3 + p*y + q with t = y - bn/3.
	var p := cn - bn * bn / 3.0
	var q := 2.0 * bn * bn * bn / 27.0 - bn * cn / 3.0 + dn
	var shift := -bn / 3.0
	var disc := q * q * 0.25 + p * p * p / 27.0
	if disc > EPS:
		var sd := sqrt(disc)
		var u := cbrt(-0.5 * q + sd)
		var v := cbrt(-0.5 * q - sd)
		return PackedFloat64Array([u + v + shift])
	if disc > -EPS:
		var u2 := cbrt(-0.5 * q)
		if absf(u2) < EPS:
			return PackedFloat64Array([shift])
		return PackedFloat64Array([2.0 * u2 + shift, -u2 + shift])
	# Three distinct real roots.
	var r := sqrt(-p * p * p / 27.0)
	var phi := acos(clampf(-0.5 * q / r, -1.0, 1.0))
	var m := 2.0 * sqrt(-p / 3.0)
	return PackedFloat64Array([
		m * cos(phi / 3.0) + shift,
		m * cos((phi + TAU) / 3.0) + shift,
		m * cos((phi + 2.0 * TAU) / 3.0) + shift,
	])


static func eval4(c4: float, c3: float, c2: float, c1: float, c0: float, t: float) -> float:
	return (((c4 * t + c3) * t + c2) * t + c1) * t + c0


## Smallest root of a*t^2 + b*t + c strictly inside (lo, hi], or NO_ROOT.
static func quadratic_smallest(a: float, b: float, c: float, lo: float, hi: float) -> float:
	var roots := quadratic_roots(a, b, c)
	for t in roots:
		if t > lo and t <= hi:
			return t
	return NO_ROOT


## Smallest root of the quartic strictly inside (lo, hi], or NO_ROOT.
static func quartic_smallest(c4: float, c3: float, c2: float, c1: float, c0: float,
		lo: float, hi: float) -> float:
	if hi <= lo:
		return NO_ROOT

	# Degenerate to lower order when the leading terms vanish. This happens
	# constantly and legitimately: two balls with equal acceleration (e.g. both
	# stationary, or both rolling the same way) give c4 = c3 = 0.
	var scale := absf(c4) + absf(c3) + absf(c2) + absf(c1) + absf(c0)
	if scale < EPS:
		return NO_ROOT
	if absf(c4) / scale < 1.0e-14:
		if absf(c3) / scale < 1.0e-14:
			return quadratic_smallest(c2, c1, c0, lo, hi)
		var croots := cubic_roots(c3, c2, c1, c0)
		var best := NO_ROOT
		for t in croots:
			if t > lo and t <= hi and t < best:
				best = t
		return best

	# Critical points of the quartic partition [lo, hi] into monotonic spans.
	var crit := cubic_roots(4.0 * c4, 3.0 * c3, 2.0 * c2, c1)
	var cuts := PackedFloat64Array([lo])
	var sorted := Array(crit)
	sorted.sort()
	for t in sorted:
		if t > lo and t < hi:
			cuts.append(t)
	cuts.append(hi)

	for i in range(cuts.size() - 1):
		var a := cuts[i]
		var b := cuts[i + 1]
		var fa := eval4(c4, c3, c2, c1, c0, a)
		var fb := eval4(c4, c3, c2, c1, c0, b)
		if fa == 0.0 and a > lo:
			return a
		if (fa < 0.0) == (fb < 0.0):
			continue
		# Monotonic with a sign change: bisect. Doubles converge well inside
		# 80 halvings for any physically meaningful window.
		for _j in range(80):
			var mid := 0.5 * (a + b)
			if mid <= a or mid >= b:
				break
			var fm := eval4(c4, c3, c2, c1, c0, mid)
			if fm == 0.0:
				a = mid
				b = mid
				break
			if (fm < 0.0) == (fa < 0.0):
				a = mid
				fa = fm
			else:
				b = mid
		var root := 0.5 * (a + b)
		if root > lo and root <= hi:
			return root
	return NO_ROOT
