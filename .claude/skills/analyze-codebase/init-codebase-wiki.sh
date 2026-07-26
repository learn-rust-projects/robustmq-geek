#!/usr/bin/env bash
# codebase-wiki scaffold — creates the full directory structure and skeleton files.
# Run from the repository root:  ./init-codebase-wiki.sh [target_dir]
# Defaults to ./codebase-wiki/

set -euo pipefail
WIKI="${1:-codebase-wiki}"

say() { echo "  +  $*"; }

# ----- directories --------------------------------------------------
say "Creating directory structure under $WIKI/ ..."
mkdir -p "$WIKI"/{atoms,analysis,inbox/processed,questions/{open,solving,answered,abandoned},plans}
mkdir -p "$WIKI"/items/{draft,next-actions,in-progress,review,done}
mkdir -p "$WIKI"/{tasks,reference,blog/{drafts,published}}
mkdir -p "$WIKI"/logs/reports/{daily,weekly,retro}

# ----- README.md ----------------------------------------------------
if [ ! -f "$WIKI/README.md" ]; then
  say "Writing $WIKI/README.md ..."
  cat > "$WIKI/README.md" <<'MKEOF'
# Codebase Wiki

This wiki reverse engineers the repository from code structure to runtime
mechanism, core abstractions, architecture boundaries, design tradeoffs, and
system cognition output.

## How to read this wiki

Start with the seven deliverables, then inspect phase analysis views, then
follow links into atomic notes.

## Seven deliverables

1. [架构图](analysis/architecture-diagram.md)
2. [启动流程](analysis/startup-flow.md)
3. [请求链路](analysis/request-flow.md)
4. [核心对象](analysis/03-core-design.md)
5. [关键算法](analysis/03-core-design.md)
6. [设计权衡](analysis/05-tradeoffs.md)
7. [经验总结](analysis/lessons-learned.md)

## Phase analysis views

- [01 Repository Mapping](analysis/01-repo-map.md)
- [02 Runtime Analysis](analysis/02-runtime.md)
- [03 Core Design](analysis/03-core-design.md)
- [04 Architecture](analysis/04-architecture.md)
- [05 Tradeoffs](analysis/05-tradeoffs.md)

## Atomic notes index

<!-- Keep this list sorted by slug. Add one bullet per atom. -->
<!-- When an atom subfolder exists, use the subfolder heading to group entries. -->

### By topic

<!--
  Every atom MUST appear under exactly one topic heading below.
  Topic headings serve as the quick-index — readers scan topics first,
  then drill into individual atoms.
  When a topic folder grows past 7 atoms, split it into a sub-folder.
  Keep topics as kebab-case English slugs matching the subfolder name.
-->

#### <topic-name>
- [atom title](atoms/<topic>/<slug>.md)

## Reference materials

Supplementary reference materials: raw code excerpts, design doc extracts,
external link summaries. Atoms keep only the most valuable insights;
reference/ serves as the raw material library.
- [Reference](reference/)

## Inbox

Drop raw notes into [inbox/](inbox/). On the next skill run, notes are
extracted into atoms and moved to [inbox/processed/](inbox/processed/).

## Learning loop

- [Open questions](questions/open/)
- [Answered questions](questions/answered/)
- [Learning plans](plans/)
- [Items — draft](items/draft/)
- [Items — next-actions](items/next-actions/)
- [Items — in-progress](items/in-progress/)
- [Items — review](items/review/)
- [Items — done](items/done/)
- [Tasks](tasks/)
- [Reference](reference/)
- [Blog drafts](blog/drafts/)
- [Published posts](blog/published/)

## Evidence and maintenance

- Analysis target: <!-- repository path or name -->
- Last full analysis: <!-- YYYY-MM-DD -->
- Last inbox processing: <!-- YYYY-MM-DD -->
- Stale areas: <!-- list code areas that changed or need re-check -->
MKEOF
fi

# ----- .annotation-progress.json ------------------------------------
if [ ! -f "$WIKI/.annotation-progress.json" ]; then
  say "Writing $WIKI/.annotation-progress.json ..."
  cat > "$WIKI/.annotation-progress.json" <<'EOF'
{
  "scope": "",
  "annotated": [],
  "skipped": [],
  "lastCompletedBatch": null,
  "timestamp": null
}
EOF
fi

# ----- .gitkeep (keep empty dirs in git) ----------------------------
for d in atoms analysis inbox inbox/processed questions/open questions/answered \
         questions/solving questions/abandoned plans items/draft items/next-actions items/in-progress \
         items/review items/done tasks reference blog/drafts blog/published; do
  touch "$WIKI/$d/.gitkeep"
done

say "Done.  Run: tree $WIKI/"
