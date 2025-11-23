#!/usr/bin/env bash
set -euo pipefail

############################################
# Usage 表示
############################################
usage() {
  cat <<EOF
Usage: $(basename "$0") [-n NUM_VARIANTS] [-b BASE_REF] instruction_name "AI prompt" [-- extra-ai-args...]

  instruction_name : ブランチ/ワークツリーのベース名 (例: instruction)
  "AI prompt"      : すべてのエージェントに与える指示文（必ずダブルクォートで囲む）

Options:
  -n NUM_VARIANTS  作成するバリエーション数 (1〜10, デフォルト: 4)
  -b BASE_REF      派生元にするブランチ/コミット (デフォルト: 現在のブランチ)

Examples:
  $(basename "$0") instruction "UI を改善して"
  $(basename "$0") -n 2 instruction "バリデーション周りを整理して"
  $(basename "$0") -b main instruction "エラーハンドリングを改善して" -- --model gpt-5.1-pro
EOF
}

############################################
# バリエーション数バリデーション
############################################
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
ensure_git_repo() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Error: このスクリプトは Git リポジトリ内で実行してください" >&2
    exit 1
  fi
}

############################################
# 引数パース処理
############################################
parse_args() {
  NUM_VARIANTS=4
  BASE_REF=""

  while getopts ":n:b:h" opt; do
    case "$opt" in
      n)
        NUM_VARIANTS="$OPTARG"
        ;;
      b)
        BASE_REF="$OPTARG"
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

  if [ "$#" -lt 2 ]; then
    echo "Error: instruction_name と \"AI prompt\" が必要です" >&2
    usage
    exit 1
  fi

  INSTRUCTION_NAME="$1"
  shift
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
resolve_base_ref() {
  if [ -z "${BASE_REF:-}" ]; then
    BASE_REF="$(git rev-parse --abbrev-ref HEAD)"
  fi
}

############################################
# 実行内容の概要ログ
############################################
print_summary() {
  echo "=== gtr multi AI runner ==="
  echo "Base ref     : $BASE_REF"
  echo "Instruction  : $INSTRUCTION_NAME"
  echo "Variants     : $NUM_VARIANTS"
  echo
}

############################################
# ブランチ重複チェック
############################################
branch_exists() {
  local branch_name="$1"
  git show-ref --verify --quiet "refs/heads/${branch_name}"
}

############################################
# メイン処理: worktree 作成 & AI 起動
############################################
run_multi_ai() {
  for ((i=1; i<=NUM_VARIANTS; i++)); do
    BRANCH="${INSTRUCTION_NAME}-v${i}"

    if branch_exists "$BRANCH"; then
      echo "[$i/$NUM_VARIANTS] Branch already exists: ${BRANCH}. Skipping."
      continue
    fi

    echo "[$i/$NUM_VARIANTS] Creating worktree for branch: ${BRANCH} (from ${BASE_REF})"
    git gtr new "${BRANCH}" --from "${BASE_REF}"

    echo "[$i/$NUM_VARIANTS] Starting AI for branch: ${BRANCH}"
    if [ "${#AI_ARGS[@]}" -eq 0 ]; then
      git gtr ai "${BRANCH}" -- --plan "${PROMPT}"
    else
      git gtr ai "${BRANCH}" -- --plan "${PROMPT}" "${AI_ARGS[@]}"
    fi

    echo
  done

  echo "=== Done. Use 'git gtr list' to see all worktrees. ==="
}

############################################
# メインエントリポイント
############################################
main() {
  parse_args "$@"
  ensure_git_repo
  validate_num_variants "$NUM_VARIANTS"
  resolve_base_ref
  print_summary
  run_multi_ai
}

main "$@"
