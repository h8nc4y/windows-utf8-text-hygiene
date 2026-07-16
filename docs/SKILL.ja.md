# Windows UTF-8 テキスト衛生（encoding 正規化と検証）

これはリポジトリルートの [SKILL.md](../SKILL.md)（英語・正典）の日本語版です。内容が
食い違う場合は英語版を正とします。

Windows 上で、日本語（および任意の非 ASCII）テキストを含むリポジトリの
encoding を正規化・検証するための手順です。守る規約は
**「repo のテキストファイルは UTF-8 BOM なし + LF + 行末空白なし + NUL
バイトなし」**。ただし Windows PowerShell 5.1 で実行する `.ps1` にだけ、
後述の理由で意図的な例外を置きます。

この skill の核心は順序です: まず非破壊で検査し、strict UTF-8 デコードに
合格したものだけを正規化し、生成時に事故を予防し、追記のたびに再検証する。

## いつ使うか

- repo の Markdown / docs / スクリプトに日本語を書いた・追記した後の検証。
- `git diff --check` が行末空白を警告した、または diff に CRLF が現れたとき。
- 日本語が「縺」「?」等に化けた（mojibake）、rg/grep が `binary file
  matches` と言い出した（NUL 混入の疑い）とき。
- PowerShell で生成した Markdown の code span が壊れた（`` `t `` が TAB、
  `` `f `` が form feed に展開された）とき。
- Windows PowerShell 5.1 で動かす `.ps1` に日本語コメントを足したら構文
  エラーになった — あるいはもっと悪く、文が黙って実行されなくなったとき。
- hook（エージェントハーネスの settings に登録した hook 等）の stdout に
  出す日本語が読み手側で化けるとき。

## 前提ルール

- repo のテキストファイルは **UTF-8 BOM なし + LF + 行末空白なし** に揃える。
- 例外: **Windows PowerShell 5.1 で実行する日本語（非 ASCII）入り `.ps1`
  は UTF-8 BOM 必須**。BOM がないと 5.1 はファイルを UTF-8 ではなく
  システムの ANSI コードページ（日本語環境では CP932）として読む。
  pwsh 7 のみで動かすスクリプトは BOM なしでよい（7 は UTF-8 が既定）。
- 一般的な git ハイジーン（リポジトリごとの改行方針・コミット作法）は各自の
  運用規約に従う。この skill が持つのは encoding 固有の規則だけ。

### なぜ PS 5.1 例外が必要か（実測した故障モード）

5.1 が BOM なし UTF-8 を CP932 として誤読するとき、多バイト文字の末尾
バイトが CP932 の lead byte 域（0x81–0x9F, 0xE0–0xFC）に入っていると、
デコーダは**次のバイトを trail byte として一緒に消費**します。日本語
コメントと文字列リテラルを含む `.ps1` で、Windows 11 上で 3 つの故障
モードを実測しました（3 つともカタカナ「ト」= UTF-8 `E3 83 88`、末尾
`88` が CP932 lead byte、で再現）:

1. **文が黙ってスキップされる（最悪ケース）。** 該当バイトで終わる
   コメント行が直後の改行（`0x0A`）を飲み込み、コメント行と次の行が
   1 行に融合する。次の行の `$msg = '...'` 代入は実行されないまま、
   スクリプトはエラーなし exit 0 で終わり、変数は空になる。
2. **`TerminatorExpectedAtEndOfString`。** 該当バイトで終わる文字列
   リテラルが自分の閉じ `'`（`0x27`）を飲み込み、「文字列に終端記号
   がありません」になる。
3. **`UnexpectedToken`。** 同じ機序が `param(...)` 内で構造トークンを
   食い、function 定義ごと壊れる。

同じ BOM なしファイルは pwsh 7 では正常に動き、同じ内容に BOM を付ければ
5.1 でも正常に動く — これが例外の根拠です。

## 手順

### 検査（非破壊）

1. 対象を変更ファイルに絞り、行末空白と CRLF を検査する（Git Bash・POSIX
   パス）。`git diff --check` は **unstaged 分しか見ない**ので、`git add`
   済みの変更は `--cached` で別途検査する。実測: CRLF + 行末空白を追記
   すると unstaged では警告（exit 2）、`git add` 後は素の形が出力なし
   exit 0 で素通りし、`--cached --check` だけが検出した（exit 2）:

   ```bash
   git -C <repo> status --short
   git -C <repo> diff --check            # unstaged の行末空白・conflict marker
   git -C <repo> diff --cached --check   # staged 分。add 済みはこちらでないと検出できない
   ```

2. BOM をバイトで検査する（PowerShell）:

   ```powershell
   $b = [System.IO.File]::ReadAllBytes($path)
   $hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
   ```

   Git Bash なら `head -c 3 <file> | od -An -tx1` で `ef bb bf` を目視する。

3. NUL バイトを検査する（Git Bash・実測済み）:

   ```bash
   rg -al '\x00' <dir-or-files>   # 出力されたファイル＝NUL 混入
   ```

   `-a` なしの rg は `pattern contains "\0" but it is impossible to match`
   エラーで exit 2 になる（実測）— このフラグは省略できない。grep も同じ
   理由で `-a` が必要: `grep -laP '\x00'` は検出できるが、`grep -lP
   '\x00'` はバイナリ扱いで出力なし exit 1 になる（実測）。ファイル列挙
   には `rg -al` が速く出力も簡潔。PowerShell 代替:
   `[System.IO.File]::ReadAllBytes($path) -contains 0`。

### 正規化（破壊的。実行前に必ず下の「安全条件」を満たすこと）

4. まず strict UTF-8 デコード検査を通し、**通ったものだけ** BOM 除去 +
   LF 化 + 行末空白除去して書き直す。引数なしの `ReadAllText($path)` は
   不正な UTF-8 バイトを U+FFFD に**黙って置換**するため、ANSI /
   Shift_JIS（CP932）ファイルにこの手順を適用すると元テキストを不可逆
   破壊する。CP932 の「日本語テスト」で実測: strict 読みは
   `DecoderFallbackException`、lenient 読みは U+FFFD 混入テキストを返し、
   それを書き戻すと日本語部分は復元不能な `�` 系のガラクタになった
   （ASCII 域のバイトだけが生き残る。壊れた結果の見た目はビューアの
   encoding 次第で変わるが、元のバイトはどう見ても失われている）:

   ```powershell
   try {
       # throwOnInvalidBytes=true: 不正 UTF-8（ANSI/Shift_JIS 等）なら黙って
       # 壊す代わりに例外を投げる。先頭 BOM は読み込み時に自動で外れる
       $t = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false, $true))
   } catch [System.Text.DecoderFallbackException] {
       # このファイルは UTF-8 ではない。正規化を中止し、encoding 変換は別判断として
       # 報告の未確認事項に残す（勝手に Shift_JIS→UTF-8 変換しない）。他ファイルの作業は継続
       return
   }
   $t = $t.Replace("`r`n", "`n")
   $t = ($t -split "`n" | ForEach-Object { $_.TrimEnd() }) -join "`n"
   [System.IO.File]::WriteAllText($path, $t, [System.Text.UTF8Encoding]::new($false))  # BOM なし
   ```

5. Windows PowerShell 5.1 で実行する `.ps1` だけは BOM 付きで書く:

   ```powershell
   [System.IO.File]::WriteAllText($path, $t, [System.Text.UTF8Encoding]::new($true))
   ```

### 生成・追記時の予防

6. バッククォートを含む Markdown を PowerShell で組み立てるときは
   **single-quoted here-string + placeholder 置換**を使う。double-quoted
   文字列 / here-string では `` `t `` → TAB、`` `f `` → form feed に展開
   されて（実測）、code span が壊れて届く:

```powershell
$tpl = @'
本文。`auth.json` のような code span はここに直接書く。可変値は __NAME__。
'@
$out = $tpl.Replace('__NAME__', $value)
```

   注意: here-string の閉じ `'@` は**必ず行頭（列 0）**に置く。この
   パターンをインデント付きの場所へ貼ると閉じ `'@` が行頭でなくなり
   parse error になるため、貼り付け時はインデントを外す（上の例を
   インデントなしで置いてあるのはそのため）。

7. hook の stdout は raw UTF-8 バイトで書く。既定ではコンソールの
   コードページで出力され、ストリームを UTF-8 として読むハーネス側では
   日本語が化ける:

   ```powershell
   function Write-Utf8Stdout([string]$s) {
       $bytes = [System.Text.Encoding]::UTF8.GetBytes($s)
       $stream = [Console]::OpenStandardOutput()
       $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
   }
   ```

### 追記後の検証

8. 日本語 doc へ追記したら、追記行を読み戻して化けと制御文字混入を確認
   する（PowerShell）:

   ```powershell
   Select-String -Path $path -Pattern '追記した見出しの一部' -Encoding utf8
   Select-String -Path $path -Pattern "[`t`f]"   # ヒット＝backtick 展開事故の疑い
   ```

   2 つ目のパターンが double-quoted なのは意図的で、`` `t `` と `` `f ``
   を実際の TAB / form feed 文字に展開させて、その文字自体を検索している。

9. 最後に `git diff --check` と `git diff --cached --check` の両方
   （両方が要る理由は手順 1）、および `git diff <file>` で、意図した
   変更だけかを確認する。

## 安全条件

正規化（手順 4–5）の前提チェック — 全項目を先に満たす:

- [ ] 対象ファイルが git 管理下で、`git diff` / `git checkout -- <file>`
  で直前状態に戻れる。未追跡ファイルは先にバックアップコピーを取る。
- [ ] strict UTF-8 デコード（`[System.Text.UTF8Encoding]::new($false,
  $true)`）が例外なく通ること。通らないファイルは ANSI / Shift_JIS 混入の
  疑いがあり、手順 4–5 を適用しない。encoding 変換を副作用として実施せず、
  報告の未確認事項に残す。
- [ ] 対象は自分が変更・追加したテキストファイルのみ。バイナリ（画像・
  exe 等）、vendored、`node_modules` 等の生成物には適用しない。
- [ ] `.ps1` から BOM を外す前に、そのスクリプトが Windows PowerShell 5.1
  経由で実行されないことを確認する（対話シェルが pwsh 7 でも、hook・
  タスクスケジューラは 5.1 経由の可能性がある）。
- [ ] repo 全体の一括 CRLF→LF 変換はこの skill のスコープ外
  （`.gitattributes` / `core.autocrlf` の方針と衝突して巨大 diff を作る）。
  判断がつかない場合も一括変換は実行せず、変更ファイル単位に限定して
  作業を継続し、見送った判断を報告の未確認事項に残す（停止しない）。
- [ ] タブが構文上必須のファイル（Makefile 等）には手順 8 の制御文字検査を
  機械適用しない。誤検出したら対象から外して継続する。

停止条件:

- 同種の失敗が 3 回改善しなければ停止し、失敗内容と残る証跡を報告する。

## 完了チェック

- [ ] `git diff --check` と `git diff --cached --check` の出力がともに空。
- [ ] `rg -al '\x00'` が対象ファイルにヒットしない。
- [ ] repo テキストの BOM 検査が False（Windows PowerShell 5.1 実行の
  `.ps1` のみ True）。
- [ ] 追記した日本語行が Select-String で意図どおり読め、backtick 展開
  由来の TAB / form feed がない。
- [ ] `git diff` に encoding 正規化以外の意図しない変更が混じっていない。

## 報告

- 検査対象ファイル数と、検出した問題の内訳（BOM / CRLF / 行末空白 /
  NUL / mojibake）。
- 正規化したファイル一覧と、実行した検証コマンド＋結果の要約（未実行の
  検証は書かない）。
- BOM を残した `.ps1` があればその理由（Windows PowerShell 5.1 実行のため）。
- 一括処理や正規化を見送った判断・未確認事項（strict デコード不合格で
  正規化を見送ったファイル、スコープ外とした一括 CRLF→LF 変換など）。

## 出自

この skill は、日本語リポジトリを扱う Windows 開発機での実運用
（エージェント運用を含む）から蒸留したものです。上の各規則は観測された
失敗か検証済みのリカバリに遡れます。文書化した具体挙動 — CP932 の
lenient 読み往復による破壊、NUL パターンに対する rg / grep の `-a`
必須、`git diff --check` の staged / unstaged 分割、`` `t `` / `` `f ``
の backtick 展開、Windows PowerShell 5.1 の BOM なし 3 故障モード — は、
いずれも記載のコマンドを Windows 11 + PowerShell 7.x + Windows
PowerShell 5.1 + ripgrep + Git Bash で実行して再現確認しています。
「実測」の語はその直接観測を指します。直接測っていない事柄（壊れた
バイトが別ビューアでどう見えるか等）は本文中で都度限定しています。
