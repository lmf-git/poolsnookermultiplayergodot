# How the physics works

This is a from-scratch billiards engine. Godot's own physics server is switched
off (`3d/default_gravity=0`) and never used — the engine only draws what this code
decides. Everything below lives in `scripts/physics/`.

The whole thing rests on one observation, so it is worth stating first.

---

## 1. The idea: a ball's path is a polynomial

A ball on cloth is always in exactly one of four regimes:

| regime | what it means |
|---|---|
| **sliding** | the contact patch is skidding across the nap |
| **rolling** | rolling without slipping, losing speed to rolling resistance |
| **spinning** | centre stationary, still turning about the vertical axis |
| **stationary** | asleep |

(plus **airborne** — free flight — and two out-of-play states.)

In every one of them, linear and angular acceleration are **constant**. Section 2
shows why that is true even for sliding, which is the surprising case. And if
acceleration is constant, then within a regime

```
p(t) = p₀ + v₀t + ½at²        v(t) = v₀ + at        ω(t) = ω₀ + αt
```

*exactly*. No integration error, ever. A ball's position is a quadratic in time.

That changes what a simulation step can be. The usual approach — advance every
body by a fixed Δt, then hunt for overlaps — is unnecessary. If positions are
polynomials, you can **solve for the moment the next thing happens**:

* ball vs. a cushion plane → linear distance in a quadratic position → **quadratic in t**
* ball vs. ball, or vs. a round pocket jaw → `|Δp(t)|² − r² = 0` → **quartic in t**
* ball vs. a pocket's drop line → **quadratic in t**

So the loop in `PoolSim.advance()` is:

1. find the earliest root over every pair and every piece of table geometry;
2. advance **every** ball to exactly that instant, analytically;
3. resolve whatever happened there;
4. repeat.

Nothing is sampled. Nothing is approximated in between.

### What that buys

**Tunnelling is impossible.** Not unlikely — impossible. A contact time is a root
of a polynomial, not something you might step over. There is a test that fires
balls at the rails at 60 m/s (four times a real break) from 40 directions; none
escapes.

**Frame rate cannot change the outcome.** Contacts land at the same instant
however the caller slices time. A caller stepping 1 ms and one stepping 50 ms
agree to 3 µm across a three-cushion shot.

**Resting balls cost nothing.** A stationary ball has `phase_left = INF` and is
skipped entirely. There is no jitter to damp, because nothing is being
continuously re-solved.

### Finding the roots

`PoolRoots.quartic_smallest` needs the *first* root in a window and must never
miss one. It works by bracketing on critical points: the real roots of the
derivative cut the window into spans on which the polynomial is monotonic, so a
sign change at a span's ends is a necessary **and sufficient** condition for a
root inside it. Then bisect. No sampling, no tolerance to tune, no missed
grazing contacts.

---

## 2. Sliding, and why it is closed-form

This is the part that makes everything else possible.

A ball has centre velocity `v` and spin `ω`. The material point touching the cloth
is moving at

```
u = v + ω × (−R ŷ)          (horizontal part)
```

While `u ≠ 0` the ball is skidding, and kinetic friction acts at the contact,
opposing `u`:

```
F = −μₛ m g û
```

That force also exerts a torque about the centre, `τ = (−R ŷ) × F`. Working
through both:

```
dv/dt = −μₛ g û
dω/dt = (5 μₛ g / 2R) (ŷ × û)
```

Now differentiate the slip itself:

```
du/dt = dv/dt − R (dω/dt × ŷ) = −(7/2) μₛ g û
```

**The slip decays along a fixed direction.** `û` never rotates while sliding. So
the accelerations above are constant, the phase is a polynomial, and it ends at a
time you can write down: `|u₀| / (7/2 μₛ g)`.

Two consequences worth knowing:

* A ball struck dead centre has lost exactly **2/7 of its speed** when slipping
  stops. The test checks this to 1e-6.
* Excess topspin or backspin is converted into translation. A following ball
  genuinely accelerates; a drawing ball slows, stops and comes back. Both settle
  at the rolling speed `(5v + 2Rω)/7`, and the test checks the measured peak
  against that formula.

### Rolling, spinning, stationary

Rolling obeys `ω = (ŷ × v)/R` and decays at `μᵣ g`. The constraint is re-imposed
exactly at the start of each phase so slip cannot re-accumulate from round-off.

Vertical-axis spin (english on a ball that is otherwise rolling or still) decays
on its own independent timeline — it is not coupled to the contact slip, because
at an idealised point contact a vertical spin produces no slip at all. It needs
the contact *patch*, which is where `MU_SPIN` comes from.

---

## 3. The cue strike

The tip strikes at an offset `(a, b)` from centre, measured in the plane
perpendicular to the shaft, in units of the ball radius. The impulse follows from
a one-dimensional collision against the ball's **effective mass** for an
off-centre blow:

```
1/m_eff = 1/m + d²/I           d = perpendicular distance from centre to the cue axis

J = (1+e) m V / (1 + m/M + (5/2)(d²/R²))
```

A centre-ball hit reaches the elastic limit `2M/(M+m)·V` exactly. Maximum english
costs about a third of the speed, which is why extreme spin is expensive.

Three further effects are modelled:

**Squirt.** Side spin deflects the cue ball *away* from the english, because the
shaft has end mass that must be pushed aside. About 3.5° at half-tip offset on a
pool cue, 4.5°/unit on the thinner snooker cue — less wood at the end, less
deflection.

**Miscue.** The tip can be placed out past `MAX_TIP_OFFSET` (0.52 R), but past
that it is slipping off the ball: progressively less of the stroke is delivered
and the contact wanders off line. This is the **only randomness in the engine** —
see §8.

**Scoop.** A tip that gets genuinely *under* the ball does not simply drive it
along the shaft. Part of the blow acts along the contact normal, which for a low
hit points up and forward, and the ball chips into the air. That is the scoop
jump — a real stroke, illegal in tournament play precisely because it works. It
begins only past `SCOOP_START` (0.40 R below centre), so ordinary draw is
untouched: a level cue at 0.35 below centre keeps the ball dead on the cloth, and
at the legal limit it chips 6.3 cm — over a ball.

The scoop is driven by how far *under* the ball the tip is, not by its distance
from centre. Keying it off the offset magnitude made side english scoop as well,
which tripled the squirt angle.

---

## 4. Ball against ball

Nearly elastic along the line of centres (`e = 0.95`), Coulomb-limited across it.

The tangential part is what produces **throw**. The impulse needed to kill
tangential slip between two equal spheres is `m|uₜ|/7`, from
`Δuₜ = 2J(1/m + R²/I) = 7J/m`. Take the smaller of that and `μ J_n`:

```
J_t = min(μ_bb · J_n , m|uₜ|/7)
```

Maximum english on a dead-full hit throws the object ball **3.25°**, which matches
published measurements (~5° maximum for a stun shot). Left and right english throw
opposite ways.

Two contacts are treated as *resting* rather than colliding, because an
event-driven solver has no other way to handle them — see §7.

---

## 5. Cushions

The single most important detail: the cushion nose sits at 63.5% of a ball
diameter, which is **above the ball's equator**. So the contact normal is tilted
downward by ~15.7°, and nearly everything real about rail play falls out of that
tilt plus friction:

* apparent normal restitution at the centre drops from 0.85 to about **0.72**;
* a plain ball comes off **long** — 45° in, 46.3° out, measured from the normal;
* **running english lengthens** the rebound (41.1° vs 40.2° plain) while **reverse
  english shortens it far more sharply** (29.2°) — exactly the asymmetry players
  rely on, and it emerges rather than being scripted;
* balls hop a millimetre or two off a hard rail.

The vertical kick is bounded, symmetrically, at 10% of the arrival speed (and
0.35 m/s absolute). Both directions matter. Unbounded upward, the friction impulse
can lever a fast spinning ball into the air. Unbounded *downward* is worse: a ball
a couple of millimetres airborne gets driven down at 5 m/s, the cloth bounce
returns half of it, and an ordinary rail contact becomes a 31 cm launch. That was
a real bug, found by tracing a suspicious jump-height reading.

Cushions are also one-sided — only struck from the playing side. Without that, a
ball sitting out on the rail counts as deeply penetrating every cushion it is
behind, and gets slapped back onto the table.

---

## 6. Pockets, the rail top, and the air

### Pockets are lines, not circles

A pocket is a straight **drop line** — the mouth between two cushion noses, pushed
outward by the shelf depth. A ball loses support when its centre crosses it.

Modelling it as a circle (the first attempt) is wrong in a way that shows: a circle
centred outside the corner bulges back into the playing surface, so balls vanish
while they still look to be out on the cloth. The mouth-line model gets several
things right for free:

* you can cheat a **corner** pocket along the rail — its mouth runs diagonally
  across the ball's path — but **not a side** pocket, whose mouth is parallel to
  the rail. Both are true of real tables, and both are tested.
* balls hang in the jaws instead of always dropping.
* the opening cut in the table is a corner cut away, not a hole punched in the
  cloth.

A ball that drops is not deleted. It keeps its velocity and spin, tips over the
lip, and falls under gravity onto the pocket shelf, bouncing off the liner. The
liner wall is active **from the moment of entry** — a ball entering at 3 m/s takes
about 100 ms to fall its own diameter and covers 30 cm horizontally in that time,
which was quite enough to sail out the back of the pocket and off the table. A
ball that bounces back out was never potted: it returns to play as a foul.

### The rail top is a surface, not a catcher

`PoolBall.ground_y` is the height of whatever is underneath: cloth inside the
cushions, the rail plateau outside them, and **nothing at all** over a pocket
opening or past the outer edge of the woodwork.

That last case is the point. A ball whose flight is still past the outer edge when
it falls back to rail height has nothing under it and keeps going over the side. A
ball that comes down over the wood lands on it, runs along it, and falls off when
it runs out of rail — the plateau edges and pocket openings are all straight
lines, so the moment it leaves is another quadratic root.

### Jumps

Two different strokes get a ball airborne:

* **The jump** — raise the butt, strike at or just above centre. The tip drives
  the ball down into the slate and the rebound launches it. About 10 cm of air at
  30° and 16 cm at 50°, against a 5.7 cm ball.
* **The scoop** — level cue, tip under the ball (§3). About 6 cm.

Only *deliberate* elevation counts. The couple of degrees the cue tilts by itself
to keep the shaft clear of a rail behind the shot is a geometric accommodation,
not a stab into the slate, and is excluded — otherwise standing near a cushion
gave you a free chip.

---

## 7. Resting contacts, and why they need care

An event solver assumes things *happen*: advance to the next contact, resolve it,
move on. A pair of balls merely **touching** breaks that assumption. The closing
speed is near zero, so the impulse is near zero, so they are still touching
afterwards — and the same contact is found again on the very next event. Forever.

That is not hypothetical; it consumed the entire event budget on a quiet table.
Three cases are therefore settled rather than bounced:

| case | treatment |
|---|---|
| horizontal contact closing < 2 cm/s | remove the closing speed, push apart by 10 µm |
| near-vertical contact (ball landed on a ball) | remove closing speed; the upper ball topples the way it is already leaning |
| ball on the cloth with < 8 cm/s of upward speed | absorbed, not launched |

The 10 µm separation matters. It was one nanometre, and a nanometre rounds
straight back into contact in single-precision table coordinates, so the pair
starts ringing again.

**Known limitation:** a ball that lands on another settles onto it and topples off
rather than being genuinely supported by it. `ground_y` knows about the cloth and
the rail, not other balls, so a ball cannot balance on one or nestle between two.
It looks right and cannot stall, but it is not a real resting contact.

---

## 8. Determinism

**Yes — including jumps, scoops and swerve.** There is exactly one deliberate
exception, and it is tested from both sides.

Every stroke inside the legal tip area replays bit-for-bit: same inputs, same
outcome, every time. The tests assert `max difference == 0.0` on the final
position and state of all sixteen balls for a jump (45° elevation), a scoop (level
cue, tip at the limit) and a swerving side-spin shot.

Why it holds: the strike model is a pure function of its arguments; the event
solver has no sampling, no clock, and no hidden state; the airborne path is the
same closed-form quadratic as everything else. Nothing about leaving the cloth
introduces a new mechanism.

**The exception is the miscue.** Past `MAX_TIP_OFFSET` the tip skids off the ball
unpredictably, and that is modelled with an actual random deflection (up to 5°
scaled by how far past the limit you are). Two identical miscue attempts finish
0.21 m apart. This is deliberate, it is confined to `cue_strike`, and it can be
switched off: `cue_strike(..., deterministic := true)` suppresses it, which is how
the aim guide traces a shot without the prediction jittering.

That randomness is now *seeded* rather than global. `PoolSim.rng` supplies both it
and the one other draw the physics makes -- which way a ball balanced exactly on
top of another topples -- so a stroke is reproducible from its arguments alone
rather than merely from its arguments plus whatever state the global generator
happened to be in. Network play depends on it: both machines simulate the same
stroke, and "the same" has to include the coin flips.

**Drops are stepped in table time.** `advance_drops` was for a long time
integrated with the wall-clock frame delta while the shot itself advanced in fixed
slices, which made where a ball came to rest inside a pocket depend on frame rate.
That is not cosmetic: the rules wait for a drop to finish before judging the shot,
and a ball can bounce back out of a pocket, so the outcome was frame-rate
dependent. It is now stepped with the shot.

Three qualifications, stated precisely:

1. **Same inputs, same step schedule → bit-identical.** Verified.
2. **Different step schedules → identical contact *times*, but not bit-identical
   positions on a break.** Godot's `Vector3` is single precision; that is the
   accuracy floor, not the solver. Round-off amplified by a chaotic sixteen-ball
   cluster means a 1 ms caller and a 50 ms caller diverge by millimetres. On a
   non-chaotic shot — one ball, three cushions — they agree to **3 µm**. The
   outcome the rules care about (which balls dropped, whether anything left the
   table) is asserted to match either way.
3. **Racking is randomised** — ball order and a fraction of a millimetre of
   jitter, so no two breaks are identical. That is setup, not physics, and it is
   seeded from a `RandomNumberGenerator` you can pin. A networked frame pins it
   from a seed the host sends, so both machines shuffle the triangle alike.

Qualification 2 is why network play sends strokes rather than positions and lets
both machines simulate: they run the *same* step schedule (fixed slices, driven
by the same inputs), which is case 1, not case 2. `tests/NetMatch.gd` asserts it
directly — two peers over a real socket, every ball in the same place to the last
bit after every shot, and identical shot logs with identical event times.

---

## 9. The numbers, and where they come from

All in `PoolPhys.gd`. They are measured quantities from the billiards literature
(Marlow, *The Physics of Pocket Billiards*; Han 2005; Mathavan et al. 2010) or WPA
equipment specs — not values dialled in until the game felt right. The models
above are derived; these are the only inputs.

| | pool | snooker |
|---|---|---|
| ball radius / mass | 28.575 mm / 170 g | 26.25 mm / 142 g |
| table (between noses) | 1.270 × 2.540 m | 1.778 × 3.569 m |
| cue mass / tip radius | 539 g / 6.5 mm | 525 g / 4.7 mm |
| squirt | 7.0°/R | 4.5°/R |
| rolling resistance μᵣ | 0.015 | 0.011 |

Shared: sliding friction 0.20, spin friction 0.0132, ball–ball restitution 0.95
and friction 0.06, cushion restitution 0.85 and friction 0.20, cloth restitution
0.50.

`PoolPhys.configure()` reshapes all of it in one call; everything derived is
recomputed there.

---

## 10. The model, run backwards

The computer player needs an answer the simulation is not set up to give: not
"where does this ball end up", but "how hard do I have to hit it so that it
arrives *there* still moving". That is the same physics read in the other
direction, and it is worth spelling out because getting it wrong is what makes a
computer opponent hit everything either too softly or far too hard.

Distance travelled is not `v²/2μg` for a single μ. A ball struck through its
centre leaves the tip with no spin at all, so it *slides*, and sliding costs
about fifteen times what rolling does on this cloth. It slides for

$$d_{\text{slide}} = \frac{12\,v_0^{2}}{49\,\mu_s g}$$

arriving at 5/7 of its launch speed (§2), and only then does rolling resistance
take over:

$$v(d) = \sqrt{\left(\tfrac{5}{7}v_0\right)^{2} - 2\mu_r g\,(d - d_{\text{slide}})}$$

`AIPlayer.speed_after` is exactly that pair of cases. To get the launch speed for
a required arrival speed it is inverted by bisection rather than solved: the
function has a kink in it where the ball stops sliding, and twenty-eight halvings
of a monotonic function is both shorter and harder to get wrong than the two-case
algebra. The CPU applies it twice per pot — once for the object ball from the
pocket back to the contact, once for the cue ball from the contact back to where
it is standing — and then converts to a tip speed through the cue-strike impulse
of §3.

Estimating this badly is visible immediately: too soft and every pot dies in the
jaws, too hard and the cue ball is never where the next shot needs it.

## 11. What is checked

`tests/TestRunner.tscn` — 112 assertions. They are not smoke tests. Each one
checks against something analytically derivable or a known fact about real play:

the 5/7 rule · slide duration `2u₀/7μg` · the 90° rule · draw/stun/follow ordering ·
throw direction and magnitude · cushions coming off long · running vs. reverse
english · energy never increasing (ball–ball *and* cushion) · cushions never
launching a ball · scoop working while ordinary draw does not · no tunnelling at
60 m/s · pockets rejecting near-misses · potted balls staying potted at 8 m/s ·
the rail catching what lands on it and *not* catching what flies over · break
sanity across seeds · the aim guide agreeing with the shot it predicts · the event
budget surviving 40 varied shots · and the determinism results above.

Other harnesses: `PlayTest` (24 shots through the real scene), `InputTest`
(synthetic mouse and keyboard), `StressTest` (randomised everything),
`CpuMatch` (whole frames, computer against computer), `AIProfile` (planning cost
per level), `Capture`/`SnookerShot` (screenshots), `JumpDiag`/`ScoopDiag` (height
tables), `GuideCost` (aim-guide profiling), `Diagnose` (event mix and stalls).
