# HANDOFF

更新日: 2026-08-03 06:34 JST

## Current goal (Class M)

- `fix/guard-normalization-reparse` で destructive normalization 例を fail-closed 化する。
- 対象は `README.md`、`SKILL.md`、`docs/SKILL.ja.md`、
  `examples/guarded-normalization.md`、`scripts/validate-oss-readiness.ps1`、
  `CHANGELOG.md`。isolated worktree上で作業する。

## Decisions and guarantees

- 自動 `git status` 取得を廃止し、利用者が明示した相対pathだけを処理する。
- repo内の通常file/reparseなし、同じ明示pathがHEADとstage-0 indexの双方で
  independently regular blob、write直前の各identityとraw-byte digest一致を必須にする。
- Git routing/config/pathspec/trace/replace/lazy-fetchの迂回を拒否し、Gitは
  Applicationとして解決する。3つのTrace2 overrideを同期Git query中だけ
  process環境へ設定して`finally`で除去する。専用single-threaded PowerShell
  processを使い、同じprocessのrunspace/thread/child起動を重ねない。PATH自体は
  trusted-host前提。
- strict UTF-8、重複BOM除去、CRLF/lone CR→LF、Unicode-safe diagnosticを固定する。
- `WriteAllText`はatomicでない。例外時はpath-free fatalで即時停止し、
  trusted backup / HEAD / indexから適切な復旧元を選ぶ。
- hard link、Unix mount差替え、最終check/write間raceは残リスクとして明記済み。
- validatorはexact oracle、root AST envelope、critical helper/function/statement
  digest、command argument、source mutation、実reparse fixture、nonrecursive
  owner-marker cleanupを検査する。英日short guideはstep 4のsource位置、root AST、
  全PowerShell fence aggregate digestでも固定する。

## Measured evidence

- freeze版validator: 289,767 bytes、SHA-256
  `759C8CF1AE7B516D8C3FA7AA1142B37C45479F24FE0651B259ECDE4A6A330FB3`。
- freeze版でPowerShell 7 readiness exit 0、Windows PowerShell 5.1 readiness exit 0。
- private-marker repository scan exit 0。先行snapshotのfull self-testもexit 0
  (195.1秒)で、scanner/self-test sourceは以後未変更。
- Gitleaks 8.30.1 working-tree scan exit 0 / finding 0。Semgrep 1.165.0
  `p/security-audit`は24 files / 2 rules / finding 0。
- 変更7ファイルはstrict UTF-8。validatorだけ意図的BOMあり、CR/NUL/TABは全て0。
  `git diff --check`と`git diff --cached --check`はいずれもexit 0。
- PowerShell、adversarial、docsの独立read-only reviewはfreeze版で全てCLEAR。
- system/global `trace2.*Target`を実設定したpositive semantic fixtureは同一failure
  classを3回試して改善せず撤去したため未確認。構造gateとGit公式仕様の確認は実施済み。

## Protected state / next steps

- main checkoutのuntracked `.debug-intent-fixture/` は既存WIP。内容未読・変更禁止。
- cleanup policyで拒否されたlocal temp residue
  `codex-032-gitmode-probe-27bae94d52ed4265889551116be4c807` は保持し、
  再試行しない。絶対pathは公開文書へ記録しない。
- commit/push/PR/CI/merge/post-main/cleanupを行う。
- release / deploy / secret / OAuth / 実データ / paid operation は未実行・対象外。
