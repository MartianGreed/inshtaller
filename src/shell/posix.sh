insh() {
    local __insh_code __insh_rc=0 __insh_trace=0
    case $- in *x*) __insh_trace=1; set +x;; esac
    if command @EXE@ _is-shell "$@"; then
        if __insh_code=$(command @EXE@ _shell @SHELL@ "$@"); then
            if (eval "$__insh_code"); then
                eval "$__insh_code" || __insh_rc=$?
            else
                __insh_rc=$?
            fi
        else
            __insh_rc=$?
        fi
    else
        command @EXE@ "$@" || __insh_rc=$?
    fi
    unset __insh_code
    if [ "$__insh_trace" = 1 ]; then set -x; fi
    return "$__insh_rc"
}
insh _startup
