#!/usr/bin/env bash

# 
# Hopefully safe re-implementation of ldd.
# If not safer, it was at least a good exercise.
# It sure is a lot slower than ldd -- by a few orders of magnitude...

# NOTE:
#  
# `arch=get-arch $app` doesn't do what you think it'll do:
# 1. bash evaluates the assignement `arch=get-arch`
# 2. bash evaluates $app -> which will be resolved to a named binary in $PATH
# 3. bash attempts to execute $app
#
# `arch=(get-arch $app)` gets evaluated to an array containing two string:
#  ( 'get-arch' "$app" ) -> "$app" variable will be expanded to its value.
#
# what you want is to get the *command substitution* by its value

get-arch() {
    [[ $(file -b $1 | grep -o "64-bit") ]] && echo "64" || echo "32"
}

app=$1
arch="$(get-arch $app)"

declare -a -r bdirs=(
    '/lib64'
    '/lib'
    '/bin'
    '/usr/lib64'
    '/usr/lib'
    '/usr/bin'
)

xpand-bdirs() {
    local -a paths
    for p in ${bdirs[*]}; do
        paths+=( $p/$1 )
    done
    echo ${paths[*]}
}

declare fp

found-fullpath() {
    p=$(readlink -f $1)     # follow simlinks
    # match the first module that has the same bitness as app
    return $([[ $(get-arch $p) = $arch ]]; echo $?)
}

get-fullpath() {
    fp=$1
    # 1. if we are dealing with a path, we found it!
    [[ -f $fp ]] && {
        return 0
    }
    local paths=$(xpand-bdirs $1)
    # 2. check if direct expansion yields paths
    for p in ${paths[*]}; do
        [[ -f $p ]] && $(found-fullpath $p) && {
            fp=$p
            return 0 
        }
    done        
    # 3. if all else fails, resort to slow `find` calls
    [[ ! -f $fp ]] && {
        local paths=$(find ${bdirs[@]} -name $1)
        for p in ${paths[*]}; do
            $(found-fullpath $p) && { 
                fp=$p
                return 0 
            }
        done
    }
    return 2 # file not found
}

declare -a deps

# NOTE:                                                                                        
# 
# Changing the IFS to a more convinient character can simplify variable expansions & matching.
# Also use '*' instead of '@' in the 'deps' expansion at the subshell,
# to use the first character of the IFS (now set to '\n'),
# when the subshell (word)splits the value of 'deps'.

in-dependencies() {
    return $(IFS=$'\n'; [[ ${deps[*]} =~ $1 ]]; echo $?)
}

list-dependencies() {
    local od=$(objdump -p $1 | grep -oP '(?<=NEEDED).*' | sed -e 's/\s*//g')
    for dep in ${od[*]}; do
        if ! $(in-dependencies $dep); then  # avoid circular dependencies
            get-fullpath $dep && {
                deps+=( $fp )
                list-dependencies $fp  
            }
        fi
    done  
}

list-dependencies $app

# Keep just non-repeated dependency paths.
deps=( $(IFS=$'\n'; echo "${deps[*]}" | sort -u) )

for dep in ${deps[*]}; do
    printf "$dep\n"
done
