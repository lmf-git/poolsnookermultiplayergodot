# Realistic Pool and Snooker

UK eight-ball pool on an 8-foot table, snooker on a 12-foot table, and killer for
up to eight players, in Godot 4.8, built around a purpose-written cue-sports
physics engine. Play hot-seat, against the computer, or against someone on
another machine over a network.

The game opens on a menu: pick the game, who is playing, and how good the
computer is -- or host a table for others to join, or join theirs. `M` brings it
back mid-frame.

Run it by opening the folder in Godot and pressing play, or:

```
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

## Controls

| | |
|---|---|
| mouse | aim (turns the cue) |
| `Q` / `E` | fine aim |
| left-drag | draw the cue back, release to play the stroke |
| `SPACE` | replay the last power |
| arrow keys | tip offset — draw, follow, english |
| `W` / `S` | raise / lower the butt of the cue |
| `J` | jump stance (butt up, tip on centre) |
| `K` | scoop stance (cue level, tip under the ball) |
| `X` | reset tip to centre |
| left click | place the cue ball when in hand |
| right-drag | orbit camera &nbsp;&nbsp; wheel: zoom |
| `C` | cycle camera (behind cue / orbit / overhead) |
| `SHIFT` | hold for precision aim (about 0.02°/pixel) |
| `ESC` | release / recapture the mouse |
| `M` | menu: game, opponent, CPU skill, hosting and joining |
| `G` | aim guide &nbsp;&nbsp; `T`: slow motion &nbsp;&nbsp; `R`: re-rack &nbsp;&nbsp; `H`: help |

While the computer is at the table the cue keys are locked out, but the camera,
the guide, slow motion and the menu all stay live — watching from wherever you
like is not playing for it.

Power is set by drawing the cue back with the mouse, the way it is drawn back on
the table: hold the left button and pull. The horizontal component of that
movement still steers the aim, so the line can be adjusted mid-draw instead of
starting the stroke again. Let go with the cue barely drawn and it is not a
stroke at all.

There are two ways to get the cue ball airborne, and they are different strokes.

**The jump.** Press `J` for the whole stance at once — butt raised to 45 degrees,
tip on centre — or set it by hand with `W`. Measured on the table: about 10 cm of
air at 30 degrees and 16 cm at 50, against a 5.7 cm ball. Striking the *bottom*
with a raised cue is a draw/masse stroke and manages roughly half that, which is
the right answer: the downward drive that launches a jump goes through the ball's
centre. A cue that is not deliberately raised cannot jump at all — the couple of
degrees it tilts by itself to clear a rail behind the shot is a geometric
accommodation, not a stab into the slate, and is excluded (`JUMP_MIN_ELEV`).

**The scoop.** The other way needs no elevation: put the tip right *under* the
ball. A tip that is genuinely underneath does not simply drive the ball along the
shaft — part of the blow acts along the contact normal, which points up and
forward, and the ball chips. That is the scoop jump: a real stroke, and illegal in
tournament play precisely because it works. It begins only once the tip is past
`SCOOP_START` (0.40 of the radius below centre), so ordinary draw is untouched — a
level cue at 0.35 below centre keeps the ball dead on the cloth, and at the legal
limit it chips 6.3 cm, over a ball.

The scoop is driven by how far *under* the ball the tip is, not by its distance
from centre. Keying it off the offset magnitude made side english scoop as well,
which quietly tripled the squirt angle.

`J` and `K` set up each of these in one press. The HUD draws the cue side-on
against the table and reports how high the current stroke will actually go, so
neither has to be found by feel.

The scoop is position-dependent, and correctly so: a rail close behind the shot
forces the butt up to keep the shaft clear, which tilts the tip down and works
directly against getting under the ball. Out in open table it chips 6.8 cm; a third
of a metre from a cushion, less than one. `K` says so when the rail is costing you,
rather than letting the stroke quietly do nothing.

**A ball behind the shot does the same thing, harder.** There is no stroke at all
*through* a ball, so the butt comes up until the shaft clears the top of it —
each ball in the way asks for one angle, over its highest point at the offset the
shaft passes it by plus the wood's own thickness there, and the stroke is played
at the steepest of them. The cue used to be drawn straight through the ball,
which looks like a bug in the renderer and plays like a shot nobody could make.
The CPU evaluates its candidates at the same elevation, so a shot it can only
reach over an intervening ball is scored as the weakened stroke it really is.

`EXPLAINER.md` is a full walk through the physics: why a ball's path is a
polynomial, how the event solver uses that, and where every model and constant
comes from.

## Why not Godot's built-in physics

Neither Godot Physics nor Jolt can produce believable pool. A generic rigid-body
solver has no notion of a ball sliding versus rolling, no spin transfer across a
ball-ball contact, no cushion whose nose sits above the ball's equator, and no
cue-tip impulse model. What you get is balls that jitter at rest, ignore english
entirely, and rebound off rails at the mirror angle.

So the built-in physics server is idle (`3d/default_gravity=0`), and all motion
comes from `scripts/physics/`. Godot handles rendering, audio and input.

## The room

There are no art assets in this project, and the room the table stands in is no
exception: `RoomView` builds it from the table outward — floor, walls, ceiling,
skirting, a dado rail with panelling below it, a rack of spare cues and a
scoreboard — and the surfaces are two procedural shaders rather than textures.

`shaders/wood.gdshader` is boarded timber: floorboards, the wall panelling and
the trim all come out of it at different scales, with staggered butt joints,
per-board tone, cathedral figure, and grooves that are genuinely bumped rather
than painted on (the normal comes from resampling the same height field the
colour does). `shaders/plaster.gdshader` is the walls: a wide float mottle, a
fine tooth, and a fall-off with height, because a billiard room is lit from over
the cloth and the walls go dark upward.

UVs on every room surface are in **metres**, so a floorboard is 168 mm wide
whatever size the room is — which matters, because the room is sized from the
table and the snooker room is half as big again as the pool one in each
direction. The pendant lamps belong to the room for the same reason: two over a
pub table, three over a snooker table, spaced and scaled from `PLAY_L` and
`PLAY_W`. They are the only light on the cloth, so that spacing is not
decoration.

## How the simulation works

It is **event driven**, not time stepped. On the cloth a ball is always in one of
four regimes — sliding, rolling, spinning in place, or stationary — and in every
one of them linear and angular acceleration are *constant*. So inside a regime a
ball's position is exactly quadratic in time, and instead of stepping and looking
for overlaps we solve analytically for the earliest moment anything happens:

* ball vs. cushion plane → quadratic in *t*
* ball vs. ball, pocket jaw, or pocket → quartic in *t* (`|Δp(t)|² − r² = 0`)

`PoolRoots.quartic_smallest` finds the first root in a window by cutting it at the
derivative's real roots: the polynomial is monotonic between consecutive critical
points, so a sign change at the ends is a necessary *and sufficient* condition for
a root inside. Nothing is sampled, so nothing can be missed.

Consequences that matter:

* **No tunnelling.** A test fires balls at the rails at 60 m/s — four times a real
  break — from 40 directions. None escapes.
* **Frame-rate independent.** Contacts land at the same instant however the caller
  slices time; a 1 ms caller and a 50 ms caller agree to 1 µm on a three-cushion
  shot.
* **Balls at rest are actually at rest** (`phase_left = INF`, zero cost), so there
  is none of the residual jitter a constraint solver leaves behind.
* A full break takes ~50 ms of CPU for ~6 s of table time (~120× real time).

### The physics itself

Derived rather than tuned. The tunable numbers are all in `PoolPhys.gd` and are
measured quantities from the billiards literature (Marlow, *The Physics of Pocket
Billiards*; Han 2005; Mathavan et al. 2010) or WPA equipment specs.

**Sliding.** With friction `F = −μmg û` at the contact point, `du/dt = −(7/2)μg û`,
so the slip *direction* is invariant while sliding — which is what makes the phase
closed-form. A ball struck dead centre has lost exactly 2/7 of its speed when
slipping stops (verified to 1e-6).

**Ball-ball.** Nearly elastic along the line of centres, Coulomb-limited across
it. The tangential impulse needed to kill slip between two equal spheres is
`m|uₜ|/7`. This is what produces throw: max english on a dead-full hit throws the
object ball 3.25°, which matches published measurements (~5° maximum for a stun
shot).

**Cushions.** The nose sits at 63.5% of a ball diameter, i.e. *above* the ball's
equator, so the contact normal is tilted down by ~15.7°. Everything real about
rail play falls out of that tilt plus friction:

* apparent normal restitution at the centre drops from 0.85 to ~0.72
* a plain ball comes off **long** — 45° in, 46.3° out, measured from the normal
* running english lengthens the rebound (41.1° vs 40.2°), reverse english
  shortens it much more sharply (29.2°), exactly the asymmetry players rely on
* balls hop a millimetre or two off a hard rail

**Cue strike.** Impulse from a 1-D collision against the ball's *effective* mass
for an off-centre hit, `1/m_eff = 1/m + d²/I`. A centre hit reaches the elastic
limit `2M/(M+m)·V`; maximum english costs a third of the speed. Side english also
squirts the cue ball ~3.5° away from the spin, and an elevated cue can jump the
ball.

**Pockets** are a straight *drop line* — the mouth between two cushion noses,
pushed outward by the shelf depth — not a circle. A ball loses support when its
centre crosses that line. This is what a pocket really is, and it gets several
things right for free: you can cheat a corner pocket along the rail (its mouth
runs diagonally across the ball's path) but not a side pocket (whose mouth is
parallel to the rail); balls hang in the jaws instead of always dropping; and the
opening cut in the table is a corner cut away rather than a round hole punched in
the cloth. Rounded jaws let balls rattle and be rejected — 20 of 24
deliberately off-line shots at a corner spat back out.

A ball that drops is not deleted: it keeps its velocity and spin, tips over the
lip of the opening, and falls under gravity onto the pocket shelf. The bed and the
wooden rails are both cut by those same drop lines, so the hole goes all the way
through the table. A ball that bounces back out was never potted — it returns to
play as a foul.

**The aim guide is a traced simulation**, not a line drawn along the cue. It runs a
throwaway copy of the shot and draws the cue ball's real path. That matters
because a straight line is a lie as soon as there is side spin on the ball: squirt
launches the cue ball a few degrees off the cue's line and swerve bends it
afterwards. Measured, the straight line was off by 2.5 degrees on a test shot with
english — enough to promise contacts that never happened. Tracing costs ~5 ms and
is only recomputed when the shot inputs change.

## Games

Three rule sets share one engine, chosen from the menu. Which *table* a game
wants and which *rules* it runs under are separate questions --
`PoolPhys.table_for()` maps one to the other -- because killer is UK pool's
table, balls and physics with entirely different rules.

`PoolPhys.configure()` reshapes ball size and mass, table dimensions, cushion
height and the pocket cut; the table geometry, its view, the room around it and
the ball assets are all rebuilt from those.

**Snooker** — 12 ft x 6 ft, 52.5 mm balls, 15 reds and six colours on their spots,
baulk line and D. Red then colour while reds remain, colours re-spotted, one
colour of the striker's choice after the last red — theirs only until the table
passes — then the colours in ascending order; fouls score at least four to the
opponent, and in-hand means in the D.

**UK eight-ball pool** — an 8-foot pub table: 7 ft x 3 ft 6 in of slate, 2 inch
balls, seven reds and seven yellows plus the black, and pockets cut about 1.8
balls wide where an American corner is 2. Smaller than a 9-foot table, with
lighter balls and tighter pockets, and it plays nothing like one.

The rules are WEPF world rules, which differ from American eight-ball in ways
that change how the game is played, not just what it is called:

* a foul hands the opponent **two visits** — and nothing else. The cue ball is
  played from where it stopped; it only comes in hand when there is none on the
  table to play, and then it goes **in the D**, as at the break. Ball in hand
  anywhere is the American game, and awarding it here would price every foul as a
  lost frame and make safety play pointless;
* **potting an opponent's ball is a foul** in itself, and the ball stays down;
* the break is played **from the D**, and the black is racked on its spot;
* the **black on the break is a re-rack**, not a spot-up, and the player who did
  not foul breaks again;
* a ball knocked off the table goes back **on the black spot**; the black leaving
  the table loses the frame;
* and there is **no cushion requirement** after the contact. American eight-ball
  asks for a ball down or any ball to a rail; the UK game does not, which is what
  makes the roll-up — creep up behind your own ball and leave the table exactly
  as it was — legal, and a staple. It used to be called a foul here, handing over
  two shots for playing the right shot.

No "free table" and no nomination: both need a decision the game has no way to
ask the player for.

**Killer** — the pub knockout, on the pool table. Two to eight players, one shot
each visit, and every ball on the table is a legal target for everybody all the
time. Pot a ball and you survive to your next visit; fail to pot and you are out.
Fouling is elimination too, which is the consistent reading of "pot a ball or you
are out" -- going in-off has not potted anything worth having, and it saves
inventing a second punishment for a game whose only currency is lives. The last
player standing wins, and clearing the table with players still in re-racks it.

`RulesKiller.LIVES` is one, which is the game as usually described. The pub
version is as often played with three, and the engine already handles it; only
that constant changes.

The rules engine never watches the simulation live. It reads `PoolSim.shot_log` —
an ordered record of every contact, cushion and pocket — after the shot settles.

## Playing over a network

Host or join from the menu: pick **host** and a port, or **join** and type an
address. There is no lobby server, so somebody has to say where they are. The
host picks the game and the seats, presses **start frame** when everyone has
arrived, and any seat nobody joined is played by the computer -- run by the host,
because the computer player is not reproducible across machines and has to be
decided in one place.

Nothing sends ball positions. The simulator was already a pure function of the
table and the stroke, so a peer sends the *stroke* -- aim, speed, spin,
elevation, the cue-ball position it was struck from, and the seed for its miscue
-- and every machine plays it out and arrives at the same table. That is a few
dozen bytes a turn, with no interpolation, no rollback and no authoritative
physics; a mid-shot packet loss cannot desynchronise anything because there are
no mid-shot packets.

One thing is streamed, and it is deliberately not part of that: while a player is
lining a shot up, the direction of their cue and how far it is drawn back go out
twenty times a second, unreliably. Without it a watching machine draws the cue
from its *own* last aim -- the striker appears to be aiming at nothing at all,
and the computer's turn in particular looks broken. It is cosmetic by
construction: it is sent only before a stroke, never during a shot, and nothing
in the simulation or the rules ever reads it, so a dropped one costs a few
milliseconds of a cue not having moved yet.

**Both addresses are offered when you host.** Anyone in the same building has to
use the local one: a packet aimed at your external address has to leave the
network and come back in through the router, and plenty of routers refuse to do
that, so a host advertising only its forwarded address is joinable from the
internet and not from the next room. `NetGame.local_address()` picks the
private-range address (skipping loopback, IPv6, link-local, and preferring a real
adapter to a VPN or virtual machine one) and the lobby leads with it.

**Whose turn it is is said in the middle of the screen.** With the cue locked out
and the table doing nothing, a player who missed the hand-over reads it as the
game having frozen; the notice announces itself full size, then shrinks up out of
the way and stays there for as long as this machine has nothing to do about it.
Across a hot seat, where the person it has passed to is sitting right there, it
says it once and goes.

What it costs is strictness, and three things had to change to earn it:

* **Every source of randomness a shot touches is seeded and sent.** The miscue
  scatter and the direction a stacked ball topples used to be drawn from the
  global generator, which cannot be synchronised; they now come from
  `PoolSim.rng`, seeded per stroke from a number the striker sends.
* **Drops are stepped in table time, not frame time.** `advance_drops` used to be
  integrated with the wall-clock frame delta, so a ball falling into a pocket
  landed differently at different frame rates -- and drops finish *before* the
  rules judge the shot, so that was rules-relevant, not cosmetic.
* **Inputs are queued, never dropped.** A stroke that arrives while the receiver
  is still simulating the previous one is held and retried, ordered by a stroke
  number. Discarding one input desynchronises the frame permanently, because the
  sender will never send it again.

The cue ball while it is *in hand* is deliberately not shared state: the player
holding it is moving it about on their own screen, and nobody else has a position
for it until the stroke that uses it arrives carrying it.

`tests/NetMatch.gd` runs two real peers over the loopback in one process -- each
under its own `MultiplayerAPI` root, which is what Godot needs for two peers in
one tree -- drives them through the menu, and after every shot checks that both
tables hold every ball in the same place to the last bit, that both logged the
same events at the same times, and that both rules engines agree.

## The computer player

`AIPlayer` plays the same game you do. It sees only where the balls are, strokes
the cue through `PoolSim.cue_strike` like everything else, and misses. Nothing is
nudged in its favour: the levels differ in how well it aims and how much of the
table it bothers to look at, never in the physics.

A turn is planned in four steps:

1. **Geometry.** Every legal ball into every pocket, ghost-balled; blocked lines
   and impossible cuts thrown away; what is left priced by a prior built from the
   three things that actually make a pot hard — how fine the cut is, how squarely
   the ball can enter the pocket, and how much angular room the pocket leaves at
   that range.
2. **Simulation.** The best few of those, plus safeties when nothing is on, are
   each *played out* on a throwaway copy of the table until every ball stops.
   This is the expensive part, so it is spread across frames at 7 ms a frame:
   a turn costs it about 18 ms of thinking at Easy and 230 ms at Pro on a pool
   table, rather more on a snooker one, none of which drops a frame.
3. **Judgement.** The finished table is scored the way the game would score it.
4. **Execution.** Aim and power are then perturbed by the level's error, scaled
   by how long and how hard the shot is. The shot it *chooses* is the shot it
   wanted; the shot it *plays* is the one its hands were up to.

| | aim error | stroke error | looks at | position | safeties | aims off for throw |
|---|---|---|---|---|---|---|
| Easy | 1.3° | 22% | 6 shots | no | no | no |
| Medium | 0.5° | 10% | 14 shots | yes | yes | no |
| Hard | 0.18° | 7.5% | 26 shots | yes | yes | yes |
| Pro | 0.07° | 3% | 40 shots | fully | yes | yes |

Position play is not a weighting, it is a *stroke*: a level without it can only
roll the ball in at the least speed that reaches the pocket, because follow,
draw and a firmer stroke are candidates it never generates. That is why Easy
looks like it is not trying — it is not choosing a weak stroke, it has no other
one. Every level is held to the same range of cue speeds the player's power
meter spans.

**Every candidate is on a budget.** A shot played out with the simulator's full
allowance can resolve millions of events before giving up — a hard stroke into a
tight cluster generates them by the thousand, multiplied by the six hundred
slices a long playout takes — and the shot log grows with every one of them. Left
unbounded that is not a slow turn, it is minutes of frozen process and hundreds
of megabytes, which ends with the application being killed. A candidate gets
9,000 events, 12 ms and 18 seconds of table time, and is scored on whatever
happened by then; one that cannot settle inside that was never a shot worth
playing.

The two games get genuinely different opponents, because they are different
games. **Pool** is territorial: clear your seven, and above all do not give up a
foul, which here is two visits. **Snooker** is economic: a ball
is worth its value times the chance of getting it, and a shot is worth the ball
plus what it leaves — so the CPU plays the red/colour alternation as a position
problem, and will trade safeties from baulk when there is nothing on. It also
prefers, between two otherwise equal safeties, the one that disturbs the pack;
without that, two cautious computers trade untouched safeties off the same solid
triangle forever, which is not snooker.

Snookered, it mirrors the target through each cushion in turn and plays the bank
that the simulation says actually makes the contact.

**It plays for the value of the ball, and it lays snookers.** Both of those were
missing and both were one number out of place:

* A pot scored its points at a flat 26 each against a position term worth up to
  169, so the five points between a yellow and a black were outbid by a good
  angle and the CPU took the yellow every time. Points are now weighted by the
  level's ambition — a professional values the black at 406 against the yellow's
  116 and goes to it, a club player still takes the safe two.
* Worse, the black was often never *considered*: the queue is ordered by a prior
  that only knows how easy a shot looks, and the spin and aiming variants of the
  best-looking one sit right behind it, so the whole simulation budget could go
  on one easy yellow. The best candidate for each distinct ball is now promoted
  to the front, so every colour gets played out at least once and the scoring
  decides between them.
* A snooker cannot be stumbled into — the cue ball has to finish in one small
  place behind one particular ball — so it is now aimed for directly. Pick
  something to hide behind that the opponent is *not* on, work out where the cue
  ball has to stop, and build the stroke backwards from the 90° rule: a cue ball
  stunning off an object ball leaves along the tangent, so asking for a departure
  direction fixes the contact and therefore the aim. Thin contacts carry a finite
  aiming allowance, so the certainty weighting prices them out for the levels
  whose cue action is not up to them.

The last of those needed a scoring bug fixed first: once the reds were gone the
CPU asked "can they hit *any* colour", so a snooker laid behind the pink while
the opponent was on the blue scored as no snooker at all. The generator and the
scoring now both go through `_their_targets()`.

## Tests

```
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . res://tests/TestRunner.tscn
```

112 assertions. Not smoke tests — each checks against something analytically
derivable or a known fact about real pool: the 5/7 rule, the 90° rule, the
draw/stun/follow ordering, throw direction and magnitude, cushions coming off
long, no-tunnelling, pockets rejecting near-misses, break sanity across seeds,
energy never increasing (ball-ball *and* cushion), and step-size independence.

The rules have their own suite, which describes shots rather than playing them —
the engine reads nothing but `PoolSim.shot_log`, so a hand-written log is a
complete shot as far as it is concerned:

```
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . res://tests/RulesTest.tscn
```

32 assertions over the things that make this the UK game: the two-visit foul and
what spends a visit, what does and does not put the cue ball in hand, potting an
opponent's ball, the black on the break, and every way the black ends a frame.

Other harnesses in `tests/`:

* `PlayTest.tscn` — plays 24 shots through the real game scene, headless
* `InputTest.tscn` — drives the game with synthetic mouse/keyboard events
* `Capture.tscn` — boots the game, plays a scripted break, writes screenshots:
  `Godot --path . res://tests/Capture.tscn -- /output/dir`
* `Diagnose.tscn` — event-mix and stall diagnostics for a break
* `CpuMatch.tscn` — plays whole frames computer against computer and logs every
  shot, which is what the difficulty levels were tuned against:
  `Godot --headless --path . res://tests/CpuMatch.tscn -- pool 3 1 40`
  (game, level 0-3, frames, shot cap)
* `AIProfile.tscn` — how long a turn takes the CPU to plan, per level and game
* `MenuTest.tscn` — 19 assertions that the menu starts the game it is showing
* `PocketFit.tscn` — the four pieces of geometry a pocket is made of (mouth, cut
  cloth, cut wood, shaft) checked against each other on both tables: that the
  rails are cut to the opening and not past it, that nothing but the shaft can be
  seen through the gap between cloth and wood, and that a ball entering anywhere
  along the mouth is inside the shaft before the liner can touch it
* `PocketLook.tscn` — close-up stills of a corner and a middle pocket on both
  tables, and `ZLook.tscn` for straight-down orthographic plans of one jaw: the
  shapes a number cannot settle
* `NetUpnp.tscn` — hosts for real and talks to the actual router: that hosting is
  never blocked or delayed by the attempt, that an answer always arrives, that
  the mapping is handed back on close, and that this machine has a local address
  to give people in the same building. A refusal from the router is a legitimate
  result, not a failure
* `PocketEdge.tscn` — 360 tables with a ball parked at every offset around every
  pocket lip, each put through the rules, the aim guide's trace and a whole CPU
  turn; 34,069 checks, most of them that a number is still a number. A ball on a
  drop line is where the pocket test, the jaw circles, the rail plateau and the
  surface query all meet, and it is where the planner used to run away

Godot buffers stdout when it is piped, so a long headless run looks like it has
hung until it exits. Redirect to a file and tail it, or run it in a terminal.

## Things worth knowing if you change it

* **Godot's `Vector3` is single precision.** That sets the accuracy floor, not the
  solver. On a break, float32 round-off amplified by a 16-ball cluster means
  positions cannot agree to the micron across different step schedules; the
  *outcome* still does. Tests assert accordingly.
* **Triangle winding on generated meshes is not cosmetic.** Godot flips authored
  normals on back-facing triangles, so a reversed quad renders pure *black* — not
  merely culled, and two-sided rendering does not save you. `TableView._quad`
  derives winding from the intended normal so no call site can get it wrong.
* **A mesh with UVs and a normal-mapped material needs tangents.**
* Roll-out length is set by `MU_ROLL` alone. An earlier build sped the clock up as
  balls slowed, to shorten the dull tail of a shot; it was immediately visible as
  the ball *accelerating* and has been removed. If shots feel long, change the
  friction coefficient, not the clock.
* Ball textures, table geometry, and impact sounds are all generated at startup —
  there are no art assets.

## The rail top

A ball is not confined to the cloth. `PoolBall.ground_y` is the height of whatever
is under it, and `PoolTable.surface_height()` answers that: cloth inside the
cushions, the rail plateau outside them, and *nothing at all* over a pocket
opening or past the outer edge of the woodwork.

That last case is the point. The rail is a surface, not a catcher — a ball whose
flight is still past the outer edge when it falls back to rail height has nothing
under it and keeps going over the side, exactly as it should. A ball that comes
down over the wood lands on it, runs along it, and falls off when it runs out of
rail (all three are tested).

Two things had to change for this to work. Cushions became one-sided: a ball out on
the rail is behind every cushion it has passed, and was being counted as deeply
penetrating them and slapped back onto the table. And pocket openings gained a
lateral bound: a side pocket's drop line is an unbounded half-plane, which is
harmless for a ball on the cloth but otherwise swallows the entire length of that
rail.

## The cushions

Each cushion is one continuous mesh, ends included. The cross-section -- nose at
63.5% of a ball diameter, face sweeping down to the cloth, back rising to the rail
-- is swept straight down the cushion and then carried on **round each end, a full
half turn**, so the cushion finishes in a rounded cap. Snooker and English pool
jaws are rounded: the rubber and the cloth over it wrap around the end of the
cushion, and nothing about the end is cut away from the pocket at an angle. That
is an American facing, on tables that have none. The cap *is* the cushion rather
than something parked on the end of it.

The round **opens into the pocket**: the nose stops dead on the end of its own
collision segment and the body behind it swings out past it, so the jaw is widest
where it meets the rail. A cushion that narrows to a point as it reaches the
pocket is the wrong way round, and it is what the first version of this drew.

Each point of the cross-section rides its own arc, curling *forward* about a
centre its own radius in front of it, and that radius is half the point's depth --
nothing at the nose, half the cushion's depth at the back. Three things fall out
of it. Every arc is tangent at the same place, so the cap closes on a single line
at the end of the nose rather than on a face. The whole round stays inside the
cushion's own depth, which matters because past that is wood that has been cut
away for the pocket. And the *back* of the cushion sweeps a circle of exactly half
the cushion's depth about the end of the segment -- which is the collision jaw
circle, so `PoolPhys.JAW_R` is derived as `CUSHION_DEPTH / 2` rather than quoted,
and the rubber a ball rattles off is the curve the solver bounces it off.
`tests/PocketFit.gd` reads the vertices back out of the built mesh and checks both
directions of that: no drawn rubber outside the collision geometry, and no jaw
circle left undrawn. Both are 0.00 mm out on both tables.

It was previously a straight prism with a plain vertical cylinder at each end: a
different height and a different cross-section, which is why it read as bolted on.
The attempt after that revolved the cross-section bodily around the jaw circle,
which cannot work -- the profile is deeper than the jaw radius, so its far side
passes through the axis and turns inside out, and the only way to keep it out of
trouble was to shrink it to a third of its depth as it went round. The result was
a small green hook curling into the mouth of every pocket. Rolling a separate
circle for each point of the profile is what fixes that: nothing rotates, so
nothing can invert.

The cushions are drawn back-face culled. They were two-sided, which on a swept
tube means the far inner wall shows straight through the near one: it reads as two
cushions overlapping with the lighting fighting itself. Culling is safe because the
winding is derived from the intended normal rather than assumed. The underside of
the profile is skipped entirely -- it lies flat on the bed and z-fights with it.

The collision geometry did not change through any of this: the jaws are the same
circles in the same places. The end of the cushion is simply drawn on the circle
it always represented.

## The shape of the openings

Nothing about a pocket opening should read as ruled. The cut in the cloth is built
from two curved pieces: the mouth edge bows back toward the table across its
middle, and the throat behind it widens on an arc rather than two straight sides.

Two things had been giving it away. The bow was 6 mm across a 115 mm mouth --
under half a degree of curvature, invisible. And the cut was padded 45 mm wider
than the mouth actually is, which put its straight sides *outside* the jaws where
nothing rounded them off. The width now matches the real jaw-to-jaw distance, so
the cushion facings bound the visible opening.

The cut does not stop at the jaw noses, though: past each nose it runs on
sideways along the drop line before turning outward. The cloth does not stop at
the nose line either -- it runs under the cushions to the outer edge of the bed --
so a cut that ended at the noses stranded a wedge of cloth past the drop line at
every pocket, standing in the open where the cushions had already ended: green
where the hole should be, up to 35 mm deep at a corner and 43 mm at a side pocket.
The shoulders that fix it sit under the cushion bodies, so they cost nothing that
can be seen. `tests/FeltCheck.gd` measures the deepest surviving scrap of cloth
across every mouth in both games; it is now on the wrong side of the line
everywhere.

The rounded jaw discs used to be subtracted back out of the cut to round its
sides. That is no longer wanted: each disc reaches about a jaw radius past the end
of the cushion, and subtracting it puts a tab of cloth back exactly where nothing
is covering it.

The wood is a separate cut, and it is the one that had gone wrong. A pocket's
**opening** is not its mouth: past the mouth the cloth is cut away and the
cushions have already ended, so the hole runs on until the woodwork starts. That
is a circle about the mouth, reaching to the inner corner of the two rails at a
corner pocket and to the ends of its own mouth at a middle one, and it is what the
rails are now cut to. They used to be cut from the *shaft* below instead -- shaft
radius plus a lip -- and the shaft is deliberately the widest thing at a pocket,
because it has to be hidden by the wood from every angle. So every rail was opened
50 mm wider than the pocket it was serving and scooped out for 30 mm either side
of where the opening actually reached it. `tests/PocketFit.gd` measures that
overrun along the rail on both tables; it is now the 6 mm lip and nothing more.

Everything else at a pocket follows from that opening: the shaft is the opening
plus enough margin to stay under the wood, and the mitre across each corner stands
clear of the shaft by enough wood to carry the skirt hanging below it.

That width also bounds pocket capture sideways, so narrowing it was a physics
change as well as a cosmetic one -- the pocket tests cover it: rail-rolls still
drop in the corner, side pockets still refuse a ball hugging the rail and accept
one played into the mouth, and near-misses still rattle out at the same rate.

One deliberate mismatch: the cloth edge bows up to 14 mm inside the straight drop
line the solver uses, so a ball can sit just within the visible cut and still be
supported. Real cloth is cut in exactly that curve, and 14 mm is a quarter of a
ball.

## Resting contacts

The event solver assumes things *happen*: it advances to the next contact and
resolves it. A pair of balls that are merely touching breaks that assumption --
the closing speed is near zero, so the impulse is near zero, so they are still
touching afterwards and the same contact is found again on the next event. Left
alone this consumes the whole event budget on a quiet table.

Two cases are therefore settled rather than bounced. A near-vertical contact (a
ball that has come down on top of another) has its closing speed removed and the
upper ball topples off the way it is already leaning. A horizontal contact closing
slower than 2 cm/s has its closing speed removed and the pair is pushed apart by
10 micrometres -- a nanometre, which is what it used to be, rounds straight back
into contact in single precision and the pair starts ringing again.

## Known gaps

* No trim line between cloth and wood along the cushion top.
* A ball that lands on another settles onto it and topples off rather than being
  genuinely supported by it: the support model knows the cloth and the rail, not
  other balls. It looks right and can no longer stall, but it is not a real
  resting contact.
* A shot that has not settled after 60 seconds of table time is abandoned as a
  foul, so a wedged ball can never hang the game.
* Draw shots lose speed by design, and the numbers are in the right place:
  maximum *legal* draw (tip 0.52 below centre) delivers 66% of a centre-ball
  stroke, falling off smoothly from 100%. Past the miscue limit it collapses --
  19% at the far edge -- which is why the tip controls now hold at the legal
  limit for a moment before the miscue band opens up. Reaching for maximum draw
  should land on maximum legal draw, not on the worst spot on the ball.
* Network play is direct-address only: no lobby, no matchmaking, no NAT
  traversal, so playing over the internet means the host forwards a port.
* A player who disconnects mid-frame has their seat taken over by the computer.
  The frame is finished rather than abandoned, which is the better of two bad
  outcomes, but there is no reconnecting.
* Snooker scoring covers the main loop (reds/colours, re-spotting, fouls, the
  final clearance) but not free balls after a snooker, or a re-spotted black.
* UK pool has no free table and no nomination: both need a decision the game
  cannot ask the player for.
* The CPU aims at the ghost ball, which is where the object ball would go if the
  contact were frictionless. Throw is not modelled in its aiming — Hard and Pro
  only find it by trying the shot a fraction either side and keeping what the
  simulation pots, and Easy and Medium do not look for it at all. They under-cut
  slightly on thick shots, as most players do.
* A candidate shot that blows its event budget is judged on a half-finished
  table, so the CPU slightly under-rates shots that end in a scramble.
* The CPU never plays a jump or a scoop, and never deliberately doubles a ball
  off a cushion into a pocket. It banks only to escape a snooker.
* The room has no windows, no door and nobody in it.
