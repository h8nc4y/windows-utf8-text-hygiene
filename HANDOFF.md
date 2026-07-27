# HANDOFF

更新日: 2026-07-27 (JST)

## Current state

- 最新の機能変更は [PR #5](https://github.com/h8nc4y/windows-utf8-text-hygiene/pull/5)
  で `main` へ squash merge済み。
- merge commit `d850136e0df4a9200ae8f85216da36f4d7508b7c` の
  [post-main run 30240311896](https://github.com/h8nc4y/windows-utf8-text-hygiene/actions/runs/30240311896)
  はWindows、Ubuntu 24.04、macOS 15の全job・全stepが成功。
- open PR / issue / 必須の既知修正: このhandoff作成時点ではなし。

## Latest delivered work (Class M)

- 目的: private-marker scanner が所有する Git isolation root の再帰削除を、
  OS temp 直下の exact-prefix + GUID 名を持つ通常directoryだけに限定する。
- 影響: cleanup前にrootが別path、leaf、reparse point、別のregular
  directoryへ置換された場合は、再帰削除せず固定診断でfail closedする。
- 非対象: 実文書のencoding変換、repository全体の改行正規化、release、deploy。

## Success metrics

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

- 実ユーザー文書は変更せず、synthetic fixtureと明示UTF-8だけを使う。
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

新しいissue、PR feedback、CI failureがなければ、実ユーザー文書を変更せず、
synthetic fixtureで証明できる次のlocal-safe Class S/M改善を選ぶ。
