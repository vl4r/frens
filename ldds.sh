#!/usr/bin/env bash
# 
# Hopefully safe re-implementation of ldd.
# If not safer, it was at least a good exercise.
# It sure is a lot slower than ldd -- by a few orders of magnitude...

get-arch() {
    [[ $(file -b $1 | grep -o "64-bit") ]] && echo "64" || echo "32"
}

declare -r APP=$1
declare -r ARCH=$(get-arch $APP)
declare -r BDIRS=(
    '/lib64'
    '/lib'
    '/bin'
    '/usr/lib64'
    '/usr/lib'
    '/usr/bin'
)

declare -r PPIPE=$(mktemp -u)
declare -r XTCMD='exit 2' 

declare -a deps
declare -i unresolved_deps=0

xpand-bdirs() {
    local -a paths
    for p in ${BDIRS[*]}; do
        paths+=( "$p/$1" )
    done
    echo "${paths[*]}"
}

found-fullpath() {
    [[ -f $1 ]] && {
        # follow simlinks
        p=$(readlink -f $1)             
        # match the first module that has the same bitness as APP
        [[ $(get-arch $p) = $ARCH ]] && true 
    } || false
}

get-fullpath() {
    local fp=$1
    # 1. if we are dealing with a path, we found it!
    [[ ! -f $fp ]] && {
        local paths=$(xpand-bdirs $fp)
        # 2. check if direct expansion yields paths
        for p in ${paths[*]}; do
            found-fullpath $p && {
                fp=$p
                break
            }
        done        
        # 3. if all else fails, resort to slow `find` calls
        [[ ! -f $fp ]] && {
            local paths=$(find ${BDIRS[@]} -name $1)
            for p in ${paths[*]}; do
                found-fullpath $p && { 
                    fp=$p
                    break
                }
            done
        }
        [[ ! -f $fp ]] && {
            echo $XTCMD > $PPIPE
        }
    }
    echo $fp > $PPIPE
}

# NOTE:                                                                                        
# 
# Changing the IFS to a more convinient character can simplify variable expansions & matching.
# Also use '*' instead of '@' in the 'deps' expansion at the subshell,
# to use the first character of the IFS (now set to '\n'),
# when the subshell (word)splits the value of 'deps'.

in-dependencies() {
    $(IFS=$'\n'; [[ "${deps[*]}" =~ $1 ]]) && true || false
}

list-dependencies() {
    local ndeps=()
    local od=( $(objdump -p $1 | grep -oP '(?<=NEEDED).*' | sed -e 's/\s*//g') )
    for dep in ${od[*]}; do
        get-fullpath "$dep" & 
        ((unresolved_deps++))
    done
}

mkfifo $PPIPE || exit 1

# Housekeeping... 
trap 'rm -f $PPIPE; exit' EXIT SIGKILL 

list-dependencies "$APP"
while true ; do
    if readarray -t ldeps; then
        for dep in ${ldeps[*]}; do
            [[ "$dep" =~ "$XTCMD" ]] && {
                echo "exiting..."
                $dep
            } || ! in-dependencies "$dep" && { # avoid circular dependencies
                deps+=( "$dep" )
                list-dependencies "$dep "
            } 
            ((unresolved_deps--))
        done
#printf "#unresolved deps: ${#unresolved_deps[*]}\n"
        [[ $unresolved_deps -eq 0 ]] && break
    fi
done < $PPIPE   # this keeps the pipe open for writing
                # https://stackoverflow.com/a/4291558
                # whereas the following opens and closes the pipe on every iteration:
                #   `read -r ldeps < $PPIPE`
                # which causes certain writers to catch an error when writing.
                # Some data is lost.

deps=( $(IFS=$'\n'; echo "${deps[*]}" | sort -u) )

for dep in ${deps[*]}; do
    printf "$dep\n"
done
