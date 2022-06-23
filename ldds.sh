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

declare -r DPIPE=$(mktemp -u)
declare -r PPIPE=$(mktemp -u)
declare -r XTCMD='exit 2' 

declare -a deps

xpand-bdirs() {
    local -a paths
    for p in ${BDIRS[*]}; do
        paths+=( $p/$1 )
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
    local n=0
    local ndeps=()
    local od=( $(objdump -p $1 | grep -oP '(?<=NEEDED).*' | sed -e 's/\s*//g') )
    for dep in ${od[*]}; do
        if ! in-dependencies $dep; then  # avoid circular dependencies
            # NOTE: this doesn't work because a child/subshell can't write to the parent's memory.
            #       We, therefore, need some FIFO to allow communication between child and parent.
            #deps[$i]=$(get-fullpath $dep) & 
            get-fullpath $dep &
            ((n++))
        fi 
    done
    if [[ $n -eq 0 ]]; then
        return
    fi
    while [[ $n -gt 0 ]]; do
        # https://stackoverflow.com/a/4291558
        # NOTE: This opens and closes the pipe on every iteration:
        #       `read -r ldeps < $PPIPE`
        #       which causes certain writers to catch an error when writing.
        #       Some data is lost.
        if read -r ldeps; then
            [[ "$ldeps" =~ "$XTCMD" ]] && {
                echo "exiting..."
                $ldeps
            }
            ndeps+=( ${ldeps[*]} )
            n=$(($n-${#ldeps[*]}))
        fi
    done < $PPIPE # this keeps the pipe open for writing
    for dep in ${ndeps[*]}; do
        deps+=( $dep )
        list-dependencies $dep
    done
}

mkfifo $DPIPE || exit 1
mkfifo $PPIPE || exit 1

# Housekeeping... 
trap 'rm -f $PPIPE; exit' EXIT SIGKILL 

list-dependencies $APP
# Keep just non-repeated dependency paths.
deps=( $(IFS=$'\n'; echo "${deps[*]}" | sort -u) )

for dep in ${deps[*]}; do
    printf "$dep\n"
done
