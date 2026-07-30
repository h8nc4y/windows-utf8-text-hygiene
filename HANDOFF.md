# HANDOFF

更新日: 2026-07-30 (JST)

## Current delivery (Class M)

- 目的: CI checkout が後続 step の Git config に認証情報を残さないよう、
  全workflow YAMLのcanonical checkoutでcredential persistenceを無効化する
  （現在のWindows / Ubuntu / macOSの3 checkoutを含む）。
- 影響: workflow YAML全canonical checkoutと、同じworkflow contractを検証する
  readinessのsynthetic mutationに限定する。active `uses` はunquotedかつ
  single-line canonical YAMLのみを許可し、escape / alias / explicit / folded /
  flow collection（mapping / sequence）、explicit YAML tag、document marker、
  YAML directiveをfail closedにする。credential入力の対象は完全一致する
  `actions/checkout@<40-lowercase-sha>`だけで、末尾名`checkout`のlocal/third-party
  actionは対象外とする。mapping valueとbare sequence itemのmultiline
  quoted/plain/block scalar continuationはmapping検査から除外する。構造位置の
  anchor / alias / tag / flowだけを拒否し、expanded/compact `uses`の両形式へ
  同じcredential契約を適用する。
- ローカル検証: PowerShell 7 / Windows PowerShell 5.1 のreadiness、
  scanner full self-test、repository scanはすべて成功。Gitleaksはworking treeと
  全9 commitsで0件、Semgrepは24 tracked filesで0 findings。変更6 filesの
  strict UTF-8、意図的BOM例外、LF、行末空白、NUL、EOF改行、diff checkも成功。
- review: 最終validatorとpublic-safe fixture差分は独立reviewでP0 / P1 / P2 /
  P3各0。repository scanが初回に検出したsynthetic drive-absolute pathは、
  backslashの字句fixtureを保つ相対表現へ置換して両runtimeで再検証した。
- GitHub evidence: [PR #9](https://github.com/h8nc4y/windows-utf8-text-hygiene/pull/9)の
  [head run 30497420072](https://github.com/h8nc4y/windows-utf8-text-hygiene/actions/runs/30497420072)と
  [post-main run 30497764598](https://github.com/h8nc4y/windows-utf8-text-hygiene/actions/runs/30497764598)は、
  Windows / Ubuntu 24.04 / macOS 15の全jobが成功。`actionlint`は未確認。
- 非対象: action pin、trigger、permissions、job、runner、timeout、command、
  利用者の実ファイル変換、release、deploy、secret、外部 API は変更しない。

## Previous delivered work (PR #7, Class M)

- 目的: `git status --porcelain=v1 -z` が0件・1件・複数件のどの場合も、
  guarded-normalization例がrecord列を同じ配列型として扱えるようにする。
- 影響: copy-adaptable exampleとreadinessのsynthetic contractだけを変更する。
  scanner runtime、利用者の実ファイル、repository全体の改行には触れない。
- RED: 1 recordだけを現行parserへ渡すと、pipeline出力が`System.String`へ
  scalar化され、`$entries[0]`が`System.Char`となって`Substring()`に失敗する。

## Delivered success metrics

- NUL区切りsynthetic inputで0 / 1 / multiple cardinalityをPS7 / PS5.1で通す。
- 日本語名・空白名を保持し、rename pairとdeleteを従来どおりskipする。
- exampleの明示array contractと意味fixtureをmutationで崩すとreadinessが落ちる。
- 実ファイル変換なしでfull validation、scan、UTF-8 hygiene、3 OS CIを通す。

## Previous verification (PR #7)

- RED: 1件のsynthetic porcelain recordはPS7 / PS5.1の双方で
  `System.String`へscalar化し、index後の`System.Char.Substring()`で失敗。
- validator追加後、旧exampleは両runtimeでexact array-safe block欠落の
  1件だけを報告してexit 1。
- `[string[]]$entries = @(...)`適用後、0 / 1 / multiple、日本語 / 空白path、
  rename pair / delete skip、source / semantic mutationを両runtimeでpass。
- readiness / repo scanはPS7・PS5.1・Ubuntu 24.04でpass。Ubuntu scanは
  Windows worktreeのgitdirがcontainer内で無効なため、read-only sourceを
  container内の一時git indexへ登録して実測した。
- PS7 / PS5.1 full scanner suiteはexit 0
  （`Private marker scan self-test passed.`）、stderr 0 bytes。
- Gitleaks dir / 直近4 commitsは0件、Semgrep `p/security-audit`は
  24 files / 0 findings。tracked 24 filesのUTF-8 / BOM / LF hygieneも全項目0。
- exact freezeの独立reviewはP0 / P1 / P2 / P3各0、CLEARANCE YES。
- [PR #7](https://github.com/h8nc4y/windows-utf8-text-hygiene/pull/7)と
  merge後のmainで、Windows / Ubuntu 24.04 / macOS 15の全jobが成功。

## Current state

- 最新の機能変更は[PR #9](https://github.com/h8nc4y/windows-utf8-text-hygiene/pull/9)で
  `main`へmerge済み。head commitは`b0a4b067b28a020587f42b9e005e5b411dd0a593`、
  merge commitは`94ad4c763edc744427f7bde7d6dbc31da91ba62e`。
- PR head run `30497420072`とpost-main run `30497764598`は、
  Windows / Ubuntu 24.04 / macOS 15の全jobが成功。
- `main` / `origin/main` / GitHub `main`は
  `94ad4c763edc744427f7bde7d6dbc31da91ba62e`、treeは
  `86b65176718a776b2e9da1f18e4f56f67a010c4c`で一致。
- open PR / issue / 必須の既知修正は0件。implementation task branchと
  隔離worktreeはcleanup済み。

## Previous delivered work (Class M)

- 目的: private-marker scanner が所有する Git isolation root の再帰削除を、
  OS temp 直下の exact-prefix + GUID 名を持つ通常directoryだけに限定する。
- 影響: cleanup前にrootが別path、leaf、reparse point、別のregular
  directoryへ置換された場合は、再帰削除せず固定診断でfail closedする。
- 非対象: 実文書のencoding変換、repository全体の改行正規化、release、deploy。

## Previous success metrics

- run固有owner markerと削除直前のroot / marker再取得で、check/use間の
  regular directory差替えとreparse差替えを拒否する。
- scanner内3箇所のcleanupを共通guardへ集約し、raw recursive deleteを
  scanner本体へ残さない。
- synthetic fixtureでvalid / wrong-name / nested / regular replacement /
  reparse replacementをPowerShell 7とWindows PowerShell 5.1で検証する。
- readiness、repository scan、Gitleaks、Semgrep、whitespace、3 OS CIを通す。

## Key files

- `scripts/private-marker-process.ps1`: owned cleanup boundary。
- `scripts/scan-private-markers.ps1`: scannerの3 cleanup経路。
- `scripts/test-scan-private-markers.ps1`: hostile synthetic regression。
- `scripts/validate-oss-readiness.ps1`: source / test / cleanup callsite契約。
- `README.md` / `SECURITY.md` / `CHANGELOG.md`: 公開契約。

## Recent decisions

- 利用者の実ファイルは変更せず、synthetic fixtureと明示UTF-8だけを使う。
- path名だけではownership証明にしない。別の32桁IDをroot内へ保存し、
  初回検査後にも同じIDと通常directory属性を再照合する。
- Windows PowerShell 5.1で実行する日本語commented `.ps1` のUTF-8 BOMは維持する。

## Starting baseline

- `main` は `origin/main` の `bcd1e57` と一致。
- PowerShell 7 / 5.1 readiness、repository private-marker scan、
  unstaged / staged whitespace checkは成功。
- tracked 23 filesはstrict UTF-8。CRLF、bare CR、行末空白、NUL、
  TAB、form feedは0。PS5.1対象の4 scriptsだけ意図的BOMあり。

## Verification

- RED: readinessがmissing boundary / owner / double state validation /
  3 guarded callsites / hostile fixturesを12件で検出。
- GREEN: PowerShell 7 / Windows PowerShell 5.1のreadiness、scanner
  full self-test、repository scanは成功。変更8 filesのstrict UTF-8、
  BOM例外、LF、行末空白、NUL、TAB、form feed契約も成功。
- PowerShell parser、Gitleaks worktree / 5-commit history、Semgrep
  82 rules / 24 files、unstaged / staged whitespace checkは成功。
- dependency manifestはなく、dependency auditは対象外。
- 初回独立reviewのP2 2件（missing-root fixture、AST allowlistの
  `Remove-Item`）とP3 1件（ownership表現）を修正。再reviewは
  P0 / P1 / P2 / P3各0でclearance。
- review修正後のPowerShell 7 full self-testは、既存process-tree
  post-check deadlineで1回失敗後、同条件retryで成功。5.1は初回成功。
- [PR run 30240086396](https://github.com/h8nc4y/windows-utf8-text-hygiene/actions/runs/30240086396)
  とmerge後main run `30240311896` は3 OSすべて成功。

## Next steps

新しいissue、PR feedback、CI failureがなければ、利用者の実ファイルを変更せず、
synthetic fixtureで証明できる次のlocal-safe Class S/M改善を選ぶ。
