# Haskell lessons — learning parley's own compiler

Operator-paced course using the parley compiler as curriculum. Raw
progress log; to be shaped into a proper course (possibly via ivy) later.

## Session 1 — 2026-08-14

### Covered, and landed

1. **Algebraic data types as trees.** `data Protocol = End | Message ... | ...`
   defines a closed set of shapes; `|` reads "or". A shape that contains
   `Protocol` inside itself makes values into trees.
2. **Positional typed blanks.** `Message Role Role String Protocol` is a
   form with four typed blanks, filled by position. The two `Role` blanks
   are sender/receiver — position, not names, distinguishes them.
3. **`type` vs `data`.** `type Role = String` is a pure nickname (zero
   safety); `data` invents a genuinely new type with an explicit closed
   constructor set. The design ladder: bare String → type alias → named
   record fields → newtype wrappers, and why sender/receiver should NOT
   be newtypes here (same role plays both positions).
4. **Closed sets are the safety story.** The compiler checks pattern
   matches against the constructor list; adding a constructor turns every
   match site into a to-do list. "Illegal states unrepresentable."
5. **`[Role]` is a list of Role.** Brackets in types and in values.
6. **Pattern matching** (introduced, not yet confirmed landed): one
   equation per constructor; stencils bind names into blanks; `_`
   ignores; `:` conses an item; `++` appends lists; base cases live on
   the childless constructors (`End`, `Continue`), recursion on the rest.
   Walked `mentionedRoles` line by line.

### Open comprehension check (answer pending)

What does
`mentionedRoles (Message "a" "b" "x" (Message "b" "c" "y" End))`
return, stepped equation by equation? (Expected: `["a","b","b","c"]` —
the duplicate "b" is the point; compile dedupes elsewhere.)

### Observed stumbling points (course material!)

- "Why is Role twice? What is Role Role" — positional blanks of the same
  type are genuinely confusing; motivates named fields.
- "What does 'ever be one' mean" — closed vs open sets needed the
  String contrast to land.
- Pace: one concept per exchange, concrete values from the repo's own
  protocol, no jargon before its definition.

### Queued exercises (dojo style — operator writes, agent hints)

1. Convert `Protocol` and `Local` to named record fields; follow the
   compiler errors across the repo. (Teaches: records, change-the-type
   workflow.)
2. Add a `roles` CLI subcommand printing a protocol file's declared
   roles. (Teaches: IO, Either handling, reusing the parser.)
3. Write `messageCount :: Protocol -> Int`. (Teaches: writing a
   recursive walk from scratch against the test wall.)
