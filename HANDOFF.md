# HANDOFF

更新日: 2026-08-01 (JST)

## Latest maintenance verification (2026-08-01, Class S)

- 目的: workflow構文の未確認事項を解消し、実装を変えずに現在の
  `.github/workflows/validate.yml`を公式actionlintで検証する。
- provenance: 公式actionlint v1.7.12 releaseのWindows amd64 artifactを使用した。
  download後のSHA-256はGitHub release API掲載値
  `6e7241b51e6817ea6a047693d8e6fed13b31819c9a0dd6c5a726e1592d22f6e9`と一致した。
- verification: `actionlint.exe -no-color .github/workflows/validate.yml`は
  exit 0、finding 0。初回の`-color never`は現行CLIに存在しない引数形式のため
  lint前にexit 3となり、`-help`で確認した`-no-color`へ修正して再実行した。
- local gates: PowerShell 7 / Windows PowerShell 5.1のreadiness、scanner
  self-test、repository scanは成功。self-testの実行時間はPS7が189.9秒、
  PS5.1が117.3秒。PS7 repository scanの初回は外部GitHub Release URLを
  `non-allowlisted-github-repo-url`として1件検出し、URL削除後は両runtimeで
  finding 0となった。
- security: Gitleaks 8.30.1はworking treeと全13 commitsで0件。
  Semgrep 1.165.0 `p/security-audit`は24 tracked files / 2 rules /
  0 findings。
- review: 独立read-only reviewはP0 / P1 / P2 / P3各0、CLEAR。
- GitHub evidence: [PR #13](https://github.com/h8nc4y/windows-utf8-text-hygiene/pull/13)の
  [head run 30650773662](https://github.com/h8nc4y/windows-utf8-text-hygiene/actions/runs/30650773662)と
  [post-main run 30651184545](https://github.com/h8nc4y/windows-utf8-text-hygiene/actions/runs/30651184545)は、
  Windows / Ubuntu 24.04 / macOS 15の全jobが成功。
- 非対象: workflow、validator、scanner、利用者file、release、deploy、secret、
  外部API、費用操作は変更しない。

## Latest delivery (PR #11, Class M)

- 目的: Windows PowerShell 5.1で実行する日本語commented `.ps1` 4本の
  UTF-8 BOM例外を、byte-level検査だけでなく`.editorconfig`でも予防する。
- 影響: `.editorconfig`は対象4pathへだけ`charset = utf-8-bom`を各1回指定し、
  `[*.ps1]` / `[scripts/*.ps1]`のwildcardで将来のpwsh-only scriptへ
  BOMを波及させない。readinessは同じexact allowlistをsynthetic textで検証する。
- TDD: 対象関数なし、既存`.editorconfig`の契約不適合を順にRED確認。
  exact 4 section追加後、canonical / 欠落 / section重複 / assignment重複 /
  repository-wide wildcard / scripts-directory wildcard / 後置non-BOM /
  後置global `unset` fixtureは、PowerShell 7とWindows PowerShell 5.1の
  対象抽出testで成功。
- ローカル検証: PowerShell 7 / Windows PowerShell 5.1のreadiness、
  scanner self-test、repository scanは成功。tracked 24 filesのUTF-8 hygieneは
  findings 0で、BOMはPS5.1対象4本だけ。unstaged / staged diff checkも成功。
- security: Gitleaks 8.30.1はworking treeと全11 commitsで0件。
  Semgrep 1.165.0 `p/security-audit`は24 files / 2 rules / 0 findings。
- 実行メモ: PS7 self-testの初回foreground実行は180秒でtimeoutしたが、
  残存process 0を確認後のbounded background再実行はexit 0、stderr 0 bytes。
- review: 初回独立reviewのP2 1件（後置non-BOM charsetのfalse-green）を修正。
  再reviewはP0 / P1 / P2 / P3各0、CLEARANCE YES。
- commit `204823c6afc500591aaf34de97677f569c9f15d6`ではglobal
  pre-commit hookを省略せず、staged Gitleaksは成功。Semgrepは
  対象staged sourceなしとしてskip。
- GitHub evidence: [PR #11](https://github.com/h8nc4y/windows-utf8-text-hygiene/pull/11)の
  [head run 30525194142](https://github.com/h8nc4y/windows-utf8-text-hygiene/actions/runs/30525194142)は
  Windows / Ubuntu 24.04 / macOS 15の全jobが成功。
  [post-main run 30525679640](https://github.com/h8nc4y/windows-utf8-text-hygiene/actions/runs/30525679640)は、
  初回Windows jobだけ合成Gitコンパイルの一時失敗で落ちたが、failed-job
  rerunのattempt 2でWindows jobが成功し、run全体が3 OS成功状態となった。
  `actionlint`は未確認。
- 非対象: 利用者fileのencoding変換、repository全体の改行正規化、release、
  deploy、secret、外部 API は変更しない。

## Previous delivered work (PR #9, Class M)

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

- workflow / source behavior baselineはPR #11の実装merge commit
  `d6a617f3804491e7a4514b9df7ab7ac17d3a18a6`。
- delivery closeout docs baselineはPR #12のmerge commit
  `75c8d6d7dcfd3087da10bfd5b83a3741a5459e24`。workflowとsourceは変更していない。
- actionlint evidence baselineはdocs-only PR #13のmerge commit
  `9107342b799187014122f062004b1ba441f88b5b`。workflowとsourceは変更していない。
- 隔離worktreeだけで変更し、main checkoutのtracked stateと無関係な
  未追跡内容には触れていない。
- PS5.1対象4本のbyte-level BOM契約と`.editorconfig`契約は一致。
  actionlint v1.7.12による現行workflowの検証もfinding 0。
  利用者fileの変換、release、deploy、外部API実行、費用発生はない。

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

- `.editorconfig`: PS5.1対象4pathのexact `utf-8-bom` allowlist。
- `scripts/validate-oss-readiness.ps1`: allowlist parserとsynthetic mutations。
- `README.md` / `examples/gitattributes-editorconfig-sample.md`: 利用者向け契約。
- `CHANGELOG.md` / `HANDOFF.md`: current deliveryと検証状態。
- `scripts/*.ps1` 4本: 実byte-level BOM契約。内容自体は変更しない。

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

PR #13のactionlint検証とintegrationは完了。Windows CIの合成Gitコンパイル失敗が
再発する場合は、
別のClass M taskでcompile結果のexit / stream診断をfailureへ含め、precondition
失敗後にtimeout fixtureを続行しない契約を追加する。attempt 2成功だけを
flakiness解消の証明にはしない。workflow変更時はactionlintを再実行する。
