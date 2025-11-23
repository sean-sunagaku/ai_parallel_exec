# ai_parallel_exec.sh

`ai_parallel_exec.sh` は、1 つのプロンプトから複数の Git ブランチ／ワークツリーを自動生成し、各ワークツリー内で Codex エージェントを起動するための補助スクリプトです。ブランチ名はデフォルトで `ai-parallel-{model}-v{番号}` 形式になります。

## 前提条件

- Git リポジトリ上で実行すること
- `git gtr` サブコマンドが利用できる環境 (Git Town など)
- `codex` CLI がインストール済みであり、`codex exec --json` が実行可能であること

## 使い方

```bash
./ai_parallel_exec.sh [-n NUM_VARIANTS] [-b BASE_REF] [-N NAME_BASE] "AI prompt" [-- extra-ai-args...]
```

- `"AI prompt"` : すべてのエージェントに与える指示文 (ダブルクォートで囲む)
- `-- extra-ai-args...` : `codex exec` に渡したい追加引数があれば `--` 以降に列挙

## オプション

| オプション | 説明 |
| --- | --- |
| `-n NUM_VARIANTS` | 生成するバリエーション数。1〜10 の範囲で指定。デフォルトは 4。 |
| `-b BASE_REF` | ブランチ作成の派生元となるブランチ／コミット。未指定なら現在のブランチ。 |
| `-N NAME_BASE` | ブランチ名のベースを上書き。未指定の場合は `ai-parallel-{model}` が使われる。 |
| `-h`, `--help` | ヘルプを表示して終了。 |

## ブランチ命名規則

`NAME_BASE` を指定しない場合、Codex に渡すモデル名から自動的に `ai-parallel-{model}` が作られ、そこに `-v{番号}` を付与したブランチ名が順番に生成されます。例: `ai-parallel-gpt-5.1-pro-v1`, `ai-parallel-gpt-5.1-pro-v2`, …

```147:159:ai_parallel_exec.sh
  local branch_base
  branch_base="$(branch_base_name)"

  for ((i=1; i<=NUM_VARIANTS; i++)); do
    BRANCH="${branch_base}-v${i}"

    if branch_exists "$BRANCH"; then
      echo "[$i/$NUM_VARIANTS] Branch already exists: ${BRANCH}. Skipping."
      continue
    fi

    echo "[$i/$NUM_VARIANTS] Creating worktree for branch: ${BRANCH} (from ${BASE_REF})"
    git gtr new "${BRANCH}" --from "${BASE_REF}"
```

## 実行例

```bash
# ベースブランチを main に固定し、モデルごとに 2 バリエーション生成
./ai_parallel_exec.sh -b main -n 2 "エラーハンドリングを改善して" -- --model gpt-5.1-pro --full-auto

# ブランチ名ベースを任意に指定する例
./ai_parallel_exec.sh -N my-parallel "非対話で進めて" -- --model gpt-5.1-pro --full-auto

# モデル指定を省略した最小実行例（ベースは ai-parallel-default）
./ai_parallel_exec.sh "UI を改善して"
```

## 出力

各バリエーションごとに `git gtr new` でワークツリーを作成し、その直後に `codex exec --json` を実行します。完了すると、最後に `git gtr list` で作成したワークツリーを確認するよう案内が表示されます。

## 生成結果の確認手順

- ワークツリー一覧を確認: `git gtr list`
- 対象バリエーションへ移動: `cd "$(git gtr go ai-parallel-<model>-v1)"`（実際のブランチ名で置き換え）
- ワークツリー内で成果物を確認: `git status`, `git diff`, `ls` など
- `codex exec` のログは標準出力のみ。必要なら実行時に `tee` で保存: `./ai_parallel_exec.sh ... | tee logs/run-$(date +%Y%m%d-%H%M%S).log`

## 使い始める際のヒント

- 事前に `git status` で作業ツリーがクリーンなことを確認してください。
- バリエーション数を増やすほど Codex の実行時間が長くなる可能性があります。まずは `-n 2` などから試すのがおすすめです。
