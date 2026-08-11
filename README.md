# HostMemoryResidencyKit

**Your shared domain core is linked into five processes. Four of them will be killed before they can tell you why.**

The same `Sources/` directory ships inside the app, the widget extension, the intent extension, the notification service and the share extension. The app has gigabytes. The notification service has tens of megabytes. Nothing in the type system, the build graph, or code review tells you which one you are compiling for — and when you get it wrong, the failure mode is not an exception. It is `jetsam`, which cannot be caught, does not unwind, and leaves a crash report with no memory warning attached.

This package is the layer that decides, **before any work starts**, which parts of a shared core may be resident in the current process, at what fidelity, and what happens when the honest answer is "none of them".

---

## Why this matters

Almost every memory-budget layer written in the wild is wrong in the same four ways, and each one is invisible in review:

| The obvious implementation | Why it fails |
|---|---|
| Compare current footprint against the **limit** | The limit is not the number you have. What you have is `limit − baseline − margin`, and the transient peak of *loading* the thing is what actually crosses it. |
| Catch the failure and recover | There is no `catch OutOfMemory`. Refusing to start is the only control that exists. |
| Evict least-recently-used until under budget | Teardown is not free. Flushing a journal can need a bigger buffer than the journal occupies, so the eviction **raises** the peak — at the exact moment you were closest to the ceiling. |
| Infer what to drop | Only the component's owner knows whether a smaller entitlement evaluator gives a smaller answer or a **wrong** one. |

`HostMemoryResidencyKit` encodes all four as executable rules with tests that fail when the rule is removed.

---

## The design, in seven decisions

**1. Headroom, not ceiling.** `HostBudget` carries `limit`, `baseline` and `safetyMargin` separately. Everything is decided against `headroom`, and the plan reserves the **peak** — steady state plus the transient cost of activation — never the steady state alone.

**2. Fail-closed budget resolution.** `HostBudgetTable` falls back to the **smallest** budget it holds, never the largest and never a permissive default. A table shipped incomplete, or a host kind a future OS introduces, resolves conservatively. Guessing high here is unrecoverable; guessing low merely degrades.

**3. Degradation is declared, never inferred.** Each component declares a `ComponentRequirement` (`required` / `degradable` / `optional`) and a `meaningFloor` — the lowest fidelity at which it still answers the same question the same way. `.required` is refused rather than stepped below its floor. `.degradable` may go below it, and every such step produces a `DegradationRecord`. A component that changes meaning is never allowed to do so silently.

**4. Net-negative evictions are refused, and they cost you.** `ResidentComponent.evictionIsNetPositive` is `teardownPeakBytes < residentBytes`. A component that fails that test is *retained*: it stays in memory, it is not in the plan, and its bytes keep consuming headroom. That tax is real and can be what pushes a required component out — which the planner reports precisely, instead of quietly running an LRU loop that makes things worse.

**5. `cannotAffordTeardown` is a real refusal.** A process can be too tight to shrink. If everything currently resident plus the largest teardown buffer already exceeds headroom, there is no plan — including the plan to free memory.

**6. The activation model is explicit, and it is the dangerous knob.** `.sequential` carries one activation peak; `.concurrent` adds them all. The default is `.sequential` because that is what a `for` loop does. A caller who activates in a `TaskGroup` and leaves the default has told the planner a specific lie — which is why (7) exists.

**7. The model is held to account.** `BudgetAudit` compares every modelled peak against the measured one and gates on the difference, **asymmetrically**: over-prediction wastes headroom and passes; under-prediction manufactures confidence in a plan that gets the process killed, and fails. Counters survive ring-buffer eviction, so a burst of bad samples cannot be erased by pushing good ones through afterwards.

### The reentrancy decision worth reading the code for

`ReservationLedger` is a **`struct`**, not an actor, and that is a correctness decision.

The obvious shape is an actor. An actor would be wrong, because callers must `await` it — and that `await` lands squarely between *"does this fit?"* and *"record that it does"*. Actors are reentrant: a suspension inside a critical section is not a critical section.

`ResidencyCoordinator.admit` therefore awaits its footprint probe **first, before reading any state**, and everything after the suspension is straight-line. A concurrent admission that was parked on the probe resumes onto post-mutation state and reserves only the delta.

`ReentrancyTests` proves this rather than asserting it. A `BarrierProbe` parks all six callers inside the probe simultaneously — so the interleaving is deterministic, not lucky — and the suite runs the same six callers against two actors that differ **only in the position of one `await`**:

- `CheckThenActActor` admits all six and commits 180 MB against a 90 MB ceiling.
- `SafeAdmissionActor` admits exactly three.

---

## What's in it

| Type | Role |
|---|---|
| `ByteCount` | Saturating byte arithmetic with **no trapping path**: `+`, `-`, `*`, `Double` conversion, percentages and ratios all clamp into `0 ... Int.max`. |
| `HostClass`, `HostBudget`, `HostBudgetTable` | Process kind × device class → budget, resolved fail-closed. |
| `ComponentCatalog`, `ComponentDescriptor`, `FidelityProfile` | Validated declarations: requirement, meaning floor, resident/activation/teardown costs, rebuild cost. |
| `ResidencyPlanner` | The pure function. Feasibility floor, three-phase reduction ladder, deterministic tie-breaking, typed `PlanRefusal`. |
| `ReservationLedger` | Check-and-reserve with no suspension point in between. |
| `ResidencyCoordinator` | The actor that composes measure → plan → reserve → apply → audit. |
| `BudgetAudit` | Bounded, asymmetric model-vs-reality gate. |
| `FootprintProbe` / `MachFootprintProbe` | Injectable measurement; the real one reads `phys_footprint` (not `resident_size`, which under-reports compressed pages). |
| `ExampleCatalog` | A worked seven-component core sized so every interesting case is reachable. |

---

## Try it in ten lines

```swift
import HostMemoryResidency

let planner = ResidencyPlanner(budgets: .illustrative)
let plan = try planner.plan(
    host: HostClass(kind: .widgetExtension, tier: .constrained),
    purpose: .timelineRefresh,
    catalog: ExampleCatalog.make()
)

print(plan.reservedPeakBytes)          // fits inside 17 MB of headroom
print(plan.degradations)               // the content index, below its meaning floor — declared
print(plan.retained)                   // anything too expensive to let go of
```

Swap `.constrained` for `.generous`, or `.widgetExtension` for `.application`, and watch the same catalog resolve differently. That is the whole point: the code did not change, the process did.

### Installation

```swift
.package(url: "https://github.com/rajatslakhina/host-memory-residency-kit.git", from: "1.0.0")
```

---

## Trade-offs, stated rather than buried

- **Coarse device tiers.** Apple does not publish per-process jetsam ceilings and they move between releases, so keying off an exact number encodes a number that will be wrong. Three classes is enough for the decisions that matter and few enough to test. The cost: a device near a tier boundary is budgeted as the tier below.
- **Reduction order.** Meaning-preserving reductions everywhere → drop optional components → step below meaning floors. The rejected alternative — drop optional components first, since they are explicitly expendable — reaches a fitting plan in fewer steps but throws away a whole feature while something else sits at `full` because nobody looked at it. Losing a feature should cost more than losing resolution.
- **Greedy, not optimal.** The ladder reduces the largest component first. It is not a knapsack solver and does not claim to find the minimum-loss plan; it claims to find a fitting plan deterministically and cheaply, in a code path that runs inside a memory-pressure handler.
- **`retained` bytes are pessimistic.** A retained component might be evictable later under different conditions. Modelling that would require a time dimension the planner does not have, so it charges for them now.
- **`.illustrative` numbers are invented.** They are shaped like real iOS limits; they are not Apple's, because Apple does not publish Apple's.

---

## Verification

- `swift build -Xswiftc -warnings-as-errors` and `swift build --build-tests -Xswiftc -warnings-as-errors` — clean, from a wiped `.build`.
- `swift test` — **72 tests, 0 failures.**
- CI runs both on Linux (Swift 6 container) and on `macos-15`, where the Darwin `phys_footprint` probe and the SwiftUI module are compiled too. See the [Actions tab](https://github.com/rajatslakhina/host-memory-residency-kit/actions).
- Every test that guards a claim in this README has a control that fails without the rule — the net-negative eviction test has a twin that changes only the teardown cost and succeeds; the audit gate is fed a deliberately under-predicting model and asserted to **fail**; the reentrancy suite ships the buggy implementation alongside the correct one and asserts the buggy one over-commits.

**Demo app:** [host-memory-residency-kit-demo-app](https://github.com/rajatslakhina/host-memory-residency-kit-demo-app) — a SwiftUI app that consumes this package as a version-pinned remote dependency. See that repo for exactly what was and was not run on a Simulator.

---

## Licence

MIT. See [LICENSE](LICENSE).
