function insh
    set -l fish_trace
    if command @EXE@ _is-shell $argv
        set -l __insh_code (command @EXE@ _shell fish $argv | string collect)
        or return $status
        set -l __insh_fish (status fish-path)
        printf '%s\n' "$__insh_code" | command $__insh_fish --no-config
        or return $status
        eval $__insh_code
    else
        command @EXE@ $argv
    end
end
insh _startup
