#!/usr/bin/env bash
set -euo pipefail

############################################
# Usage 表示
############################################
# スクリプトの使い方を表示する
usage() {
  cat <<EOF
Usage: $(basename "$0") [-n NUM_VARIANTS] [-b BASE_REF] [-N NAME_BASE] "AI prompt" [-- extra-ai-args...]

  "AI prompt"      : すべてのエージェントに与える指示文（必ずダブルクォートで囲む）

Options:
  -n NUM_VARIANTS    作成するバリエーション数 (1〜10, デフォルト: 4)
  -b BASE_REF        派生元にするブランチ/コミット (デフォルト: 現在のブランチ)
  -N NAME_BASE       ブランチ名のベース（デフォルト: ai-parallel-{model}）
  -h, --help         このヘルプを表示して終了

Examples:
  $(basename "$0") "UI を改善して"
  $(basename "$0") -n 2 "バリデーション周りを整理して"
  $(basename "$0") -b main "エラーハンドリングを改善して" -- --model gpt-5.1-pro
  $(basename "$0") -N my-parallel "非対話で進めて" -- --model gpt-5.1-pro --full-auto
  $(basename "$0") "非対話で進めて" -- --model gpt-5.1-pro --full-auto
EOF
}

############################################
# バリエーション数バリデーション
############################################
# -n で指定された数が有効範囲か確認する
validate_num_variants() {
  local n="$1"

  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    echo "Error: -n NUM_VARIANTS は数値で指定してください（指定値: $n）" >&2
    exit 1
  fi
  if (( n < 1 || n > 10 )); then
    echo "Error: NUM_VARIANTS は 1〜10 の範囲で指定してください（指定値: $n）" >&2
    exit 1
  fi
}

############################################
# Git リポジトリの存在確認
############################################
# Git 配下で実行されていることを検証する
ensure_git_repo() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Error: このスクリプトは Git リポジトリ内で実行してください" >&2
    exit 1
  fi
}

############################################
# 引数パース処理
############################################
# CLI 引数を解析し、各種変数をセットする
parse_args() {
  NUM_VARIANTS=4
  BASE_REF=""
  NAME_BASE=""
  MODEL_NAME="default"
  BRANCH_PREFIX=""

  # 長いオプション（--help）を先にチェック
  for arg in "$@"; do
    if [ "$arg" = "--help" ]; then
      usage
      exit 0
    fi
  done

  while getopts ":n:b:N:h" opt; do
    case "$opt" in
      n)
        NUM_VARIANTS="$OPTARG"
        ;;
      b)
        BASE_REF="$OPTARG"
        ;;
      N)
        NAME_BASE="$OPTARG"
        ;;
      h)
        usage
        exit 0
        ;;
      \?)
        echo "Error: invalid option -$OPTARG" >&2
        usage
        exit 1
        ;;
      :)
        echo "Error: option -$OPTARG requires an argument" >&2
        usage
        exit 1
        ;;
    esac
  done

  shift $((OPTIND - 1))

  if [ "$#" -lt 1 ]; then
    echo "Error: \"AI prompt\" が必要です" >&2
    usage
    exit 1
  fi

  PROMPT="$1"
  shift || true

  AI_ARGS=()
  if [ "${1:-}" = "--" ]; then
    shift
    AI_ARGS=("$@")
  fi
}

############################################
# BASE_REF 解決処理
############################################
# ベース参照が未指定なら現在のブランチ名を採用する
resolve_base_ref() {
  if [ -z "${BASE_REF:-}" ]; then
    BASE_REF="$(git rev-parse --abbrev-ref HEAD)"
  fi
}

############################################
# モデル名/ブランチベース解決処理
############################################
# --model 引数からモデル名を抽出しブランチ名に使える形へ整形する
resolve_model_name() {
  MODEL_NAME="default"

  local i=0
  while [ $i -lt ${#AI_ARGS[@]} ]; do
    local arg="${AI_ARGS[$i]}"

    if [[ "$arg" == --model=* ]]; then
      MODEL_NAME="${arg#--model=}"
      break
    elif [[ "$arg" == "--model" ]]; then
      local next="${AI_ARGS[$((i + 1))]:-}"
      if [ -n "$next" ] && [[ "$next" != --* ]]; then
        MODEL_NAME="$next"
      fi
      break
    fi

    i=$((i + 1))
  done

  MODEL_NAME="${MODEL_NAME:-default}"
  MODEL_NAME="${MODEL_NAME// /-}"
  MODEL_NAME="${MODEL_NAME//\//-}"
  MODEL_NAME="${MODEL_NAME//[!A-Za-z0-9._-]/-}"
}

# ブランチ名のベース部分を決定する
branch_base_name() {
  local base="${NAME_BASE:-ai-parallel-${MODEL_NAME}}"
  # 連続したハイフンは読みやすさのため 1 本にまとめる
  # shellcheck disable=SC2001
  base="$(echo "$base" | sed -E 's/-{2,}/-/g')"
  printf '%s\n' "$base"
}

# スクリプトが生成したブランチのタイムスタンプ付き一覧を返す
collect_script_branches() {
  local base="$1"

  git for-each-ref --format='%(refname:short) %(committerdate:unix)' refs/heads \
    | while read -r name ts; do
        case "$name" in
          "${base}-"[a-z0-9][a-z0-9][a-z0-9][a-z0-9]"-v"[0-9]*)
            printf '%s %s\n' "$ts" "$name"
            ;;
        esac
      done
}

# ブランチに紐づく worktree のパスを取得する
find_worktree_path_for_branch() {
  local branch="$1"
  local target="refs/heads/${branch}"
  local line worktree_path=""

  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        worktree_path="${line#worktree }"
        ;;
      "branch "*)
        if [ "${line#branch }" = "$target" ]; then
          printf '%s\n' "$worktree_path"
          return 0
        fi
        ;;
    esac
  done < <(git worktree list --porcelain)

  return 1
}

# 対象ブランチとその worktree を削除する
delete_branch_and_worktree() {
  local branch="$1"
  local worktree_path

  worktree_path="$(find_worktree_path_for_branch "$branch" || true)"

  if [ -n "$worktree_path" ]; then
    echo "Removing worktree for ${branch}: ${worktree_path}"
    if ! git worktree remove --force "$worktree_path"; then
      echo "Warning: failed to remove worktree ${worktree_path} for ${branch}" >&2
    fi
  fi

  echo "Deleting branch ${branch}"
  if ! git branch -D "$branch"; then
    echo "Warning: failed to delete branch ${branch}" >&2
  fi
}

# 指定ベースのブランチが増えすぎた場合に古いものを間引く
cleanup_old_branches() {
  local base max_keep total to_delete
  local -a script_branches=()
  local -a sorted_branches=()
  base="$1"
  max_keep=19

  while IFS= read -r line; do
    script_branches+=("$line")
  done < <(collect_script_branches "$base")

  total="${#script_branches[@]}"
  if (( total < 20 )); then
    return
  fi

  while IFS= read -r line; do
    sorted_branches+=("$line")
  done < <(printf '%s\n' "${script_branches[@]}" | sort -n)

  to_delete=$((total - max_keep))
  echo "Found ${total} existing script branches (base: ${base}). Deleting ${to_delete} oldest to keep ${max_keep}."

  for ((i=0; i<to_delete; i++)); do
    local entry branch_name
    entry="${sorted_branches[$i]}"
    branch_name="${entry#* }"
    delete_branch_and_worktree "$branch_name"
  done
}

# ブランチ名用にランダム 4 文字のサフィックスを生成する
generate_branch_suffix() {
  local suffix

  suffix="$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c 4 || true)"
  if [ -z "$suffix" ]; then
    suffix="$(printf '%04x' "$RANDOM")"
  fi

  printf '%s\n' "${suffix:0:4}"
}

# バリエーションごとに付与するブランチ接頭辞を準備する
prepare_branch_prefix() {
  local base
  base="$(branch_base_name)"
  BRANCH_PREFIX="${base}-$(generate_branch_suffix)"
}

############################################
# 実行内容の概要ログ
############################################
# これからの実行内容を標準出力にまとめて表示する
print_summary() {
  echo "=== gtr multi AI runner ==="
  echo "Base ref     : $BASE_REF"
  echo "Model        : $MODEL_NAME"
  echo "Branch base  : $BRANCH_PREFIX"
  echo "Variants     : $NUM_VARIANTS"
  echo "Prompt       : $PROMPT"
  echo
}

############################################
# ブランチ重複チェック
############################################
# 指定ブランチがすでに存在するか確認する
branch_exists() {
  local branch_name="$1"
  git show-ref --verify --quiet "refs/heads/${branch_name}"
}

############################################
# メイン処理: worktree 作成 & AI 起動
############################################
# バリエーション数ぶん worktree を作り codex exec を走らせる
run_multi_ai() {
  local branch_prefix
  branch_prefix="$BRANCH_PREFIX"

  for ((i=1; i<=NUM_VARIANTS; i++)); do
    BRANCH="${branch_prefix}-v${i}"

    if branch_exists "$BRANCH"; then
      echo "[$i/$NUM_VARIANTS] Branch already exists: ${BRANCH}. Skipping."
      continue
    fi

    echo "[$i/$NUM_VARIANTS] Creating worktree for branch: ${BRANCH} (from ${BASE_REF})"
    git gtr new "${BRANCH}" --from "${BASE_REF}"

    echo "[$i/$NUM_VARIANTS] Starting AI for branch: ${BRANCH} (codex exec --json)"

    WORKTREE_DIR="$(git gtr go "${BRANCH}")"
    if [ -z "$WORKTREE_DIR" ]; then
      echo "[$i/$NUM_VARIANTS] Failed to resolve worktree path for ${BRANCH}" >&2
      continue
    fi

    if [ "${#AI_ARGS[@]}" -eq 0 ]; then
      (cd "$WORKTREE_DIR" && codex exec --json "${PROMPT}") || echo "[$i/$NUM_VARIANTS] codex exec exited with non-zero status" >&2
    else
      (cd "$WORKTREE_DIR" && codex exec --json "${AI_ARGS[@]}" "${PROMPT}") || echo "[$i/$NUM_VARIANTS] codex exec exited with non-zero status" >&2
    fi

    echo
  done

  echo "=== Done. Use 'git gtr list' to see all worktrees. ==="
}

############################################
# メインエントリポイント
############################################
# 一連の処理を順序通りに実行する
main() {
  parse_args "$@"
  ensure_git_repo
  validate_num_variants "$NUM_VARIANTS"
  resolve_base_ref
  resolve_model_name
  cleanup_old_branches "$(branch_base_name)"
  prepare_branch_prefix
  print_summary
  run_multi_ai
}

main "$@"
