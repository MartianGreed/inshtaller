def --env --wrapped insh [...args: string] {
    let probe = (do { ^@EXE@ _is-shell ...$args } | complete)
    if $probe.exit_code == 0 {
        let result = (do { ^@EXE@ _shell nu ...$args } | complete)
        if $result.exit_code != 0 {
            error make {msg: $result.stderr}
        }
        let changes = ($result.stdout | from json)
        mut values = $changes.set
        if ('PATH' in $values) {
            $values = ($values | update PATH { split row (char esep) })
        }
        load-env $values
        for key in $changes.unset { hide-env --ignore-errors $key }
    } else {
        ^@EXE@ ...$args
    }
}
insh _startup
