// revalidate.js — re-run decompose.js's OWN mechanical validation against the amended plan.
//
// The rules are not re-implemented here (that is how a checker drifts from the thing it checks).
// Instead the validation block is SLICED OUT of .claude/workflows/decompose.js between two stable
// anchors and evaluated with `plan`, `builtFeatures`, `currentSchemaVersion`, `gameDir` bound —
// so if the workflow's rules change, this check changes with them, and if the anchors ever stop
// matching exactly once, this fails loudly rather than silently checking nothing.
const fs = require('fs')

const src = fs.readFileSync('.claude/workflows/decompose.js', 'utf8')
const START = '// ---- VALIDATE (a): pure-JS mechanical checks on the returned object ----'
const END = '// ---- VALIDATE (b): independent skeptic agent re-reads the spec ----'
const occurrences = (s, sub) => s.split(sub).length - 1
if (occurrences(src, START) !== 1) throw new Error(`slice anchor START occurs ${occurrences(src, START)} times, expected exactly 1`)
if (occurrences(src, END) !== 1) throw new Error(`slice anchor END occurs ${occurrences(src, END)} times, expected exactly 1`)
let block = src.slice(src.indexOf(START) + START.length, src.indexOf(END))

// The workflow's block calls phase()/log(); stub them. It also declares `const features = plan.features`.
for (const marker of ['mechanicalErrors.push', 'buildBatches', 'migrations', 'sharedServices', 'retrofits']) {
  if (!block.includes(marker)) throw new Error(`sliced block is missing "${marker}" — the anchors no longer bracket the real rules`)
}
block = block.replace(/^\s*phase\(.*\)\s*$/m, '')

const plan = JSON.parse(fs.readFileSync('logs/deep-reach/amended-plan.json', 'utf8'))
const runner = new Function(
  'plan',
  'builtFeatures',
  'currentSchemaVersion',
  'gameDir',
  'log',
  // The sliced block declares mechanicalErrors / NAME_RE / SERVICE_RE / features itself — declaring
  // them here too would shadow-clash, and re-declaring them would be re-implementing the rules.
  `${block}
   return mechanicalErrors;`
)

const errors = runner(plan, [], 1, 'games/deep-reach', () => {})
console.log(`mechanical validation of the AMENDED plan (rules sliced live from decompose.js): ${errors.length} error(s)`)
errors.forEach((e) => console.log('  ! ' + e))

// Independent structural sanity on exactly what the amendments changed.
const idx = {}
plan.buildBatches.forEach((b, i) => b.forEach((n) => (idx[n] = i)))
const names = plan.features.map((f) => f.name)
const problems = []
if (plan.buildBatches.flat().length !== names.length) problems.push('buildBatches does not partition the feature set')
for (const f of plan.features) {
  for (const d of f.dependsOn || []) {
    if (idx[d] === undefined) problems.push(`${f.name} depends on unknown ${d}`)
    else if (idx[d] >= idx[f.name]) problems.push(`${f.name} (batch ${idx[f.name]}) depends on ${d} (batch ${idx[d]}) — dependency must be EARLIER`)
  }
}
console.log(`\namendment sanity: ${problems.length} problem(s)`)
problems.forEach((p) => console.log('  ! ' + p))
console.log('\nbatch order:')
plan.buildBatches.forEach((b, i) => console.log(`  ${i}: ${b.join(', ')}`))
process.exit(errors.length + problems.length === 0 ? 0 : 1)
