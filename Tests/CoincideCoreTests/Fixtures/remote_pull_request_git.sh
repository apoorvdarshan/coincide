#!/bin/sh
# Private acceptance router. Swift substitutes shell-quoted task-owned paths.
fixture_root=__FIXTURE_ROOT__
fixture_peer=__PYTHON_PEER__
phase=other
find_phase() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -C|-c|--git-dir|--work-tree|--namespace|--config-env)
                [ "$#" -ge 2 ] || return
                shift 2 ;;
            --git-dir=*|--work-tree=*|--namespace=*|--config-env=*|--no-pager|--no-optional-locks|--literal-pathspecs|--no-lazy-fetch|--no-replace-objects)
                shift ;;
            -*) return ;;
            *)
                case "$1" in
                    rev-parse|config|status|for-each-ref|show-ref|cat-file|symbolic-ref|show|diff|ls-files|fetch|commit|worktree|checkout|update-ref|push|clone|ls-remote)
                        phase=$1 ;;
                esac
                return ;;
        esac
    done
}
find_phase "$@"
printf '{"phase":"%s","pid":%s}\n' "$phase" "$$" >> "$fixture_root/git-phases.jsonl"
case "$phase" in
    rev-parse|config|status|for-each-ref|show-ref|cat-file|symbolic-ref|show|diff|ls-files)
        # Match the original Python metadata route's transport refusal. The
        # original argv and native Git remain authoritative; no fixture state
        # or interpreter is needed for these metadata commands.
        GIT_ALLOW_PROTOCOL=''
        export GIT_ALLOW_PROTOCOL
        exec /usr/bin/git "$@" ;;
esac
# Preserve all controlled mutations, local fetch mapping, held jobs and denials.
exec /usr/bin/python3 "$fixture_peer" "$fixture_root" "$@"
