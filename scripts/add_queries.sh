# Query insertion script.
#!/bin/bash
#
# Takes one argument, a json project file.
# That json file must contain all of the following
#
# name         name for project, usually the name of the software (binutils-2.25, openssh-2.1, etc)
# directory    directory in which src-2-src query injection will occur -- should be somewhere on the nas
# tarfile      path to software tar file
# configure    how to configure the software (./configure plus arguments)
# make         how to make the software (make might have args or might have FOO=bar required precursors)
# install      how to install the software (note that configure will be run with --prefix ...lava-install)
#
# script proceeds to untar the software, run btrace on it to extract a compile_commands.json file,
# which contains all information needed to compile every file in the project.
# then, the script runs lavaTool using that compile_commands.json file, on every source file,
# adding extra source code to perform taint queries.  At the time of this writing, the taint
# queries were for every argument of every fn call, injected both before and after the call.
# Also, the return value of the fn is queried.  Oh, and lavaTool also injects "queries" that
# indicate when a potential attack point has been encountered.  At the time of this writing,
# that includes calls to memcpy and malloc.
#
# After lavaTool has transformed this source, it exits.  You should now try to make the project
# and deal with any complaints (often src-to-src breaks the code a little). Once you have a working
# version of the compiled exec with queries you will need to log on to a 64-bit machine
# and run the bug_mining.py script (which uses PANDA to trace taint).
#


progress() {
  echo
  echo -e "\e[32m[queries]\e[0m \e[1m$1\e[0m"
}

set -e # Exit on error

if [ $# -lt 1 ]; then
  echo "Usage: $0 JSONfile"
  exit 1
fi

json="$(realpath $1)"
lava="$(dirname $(dirname $(realpath $0)))"

directory="$(jq -r .directory $json)"
name="$(jq -r .name $json)"

progress "Entering $directory/$name."
mkdir -p "$directory/$name"
cd "$directory/$name"

tarfile="$(jq -r .tarfile $json)"

progress "Untarring $tarfile..."
source=$(tar tf "$tarfile" | head -n 1 | cut -d / -f 1)
if [ -e "$source" ]; then
  rm -rf "$source"
fi
tar xf "$tarfile"

progress "Entering $source."
cd "$source"

progress "Creating git repo."
git init
git add -A .
git commit -m 'Unmodified source.'

progress "Configuring..."
mkdir -p lava-install
$(jq -r .configure $json) --prefix=$(pwd)/lava-install

progress "Making..."
$lava/btrace/sw-btrace $(jq -r .make $json)

progress "Installing..."
$(jq -r .install $json)

progress "Creating compile_commands.json..."
$lava/btrace/sw-btrace-to-compiledb /home/moyix/git/llvm/Debug+Asserts/lib/clang/3.6.1/include
git add compile_commands.json
git commit -m 'Add compile_commands.json.'

cd ..

tar czf "btraced.tar.gz" "$source"

c_files=$(python $lava/src_clang/get_c_files.py $source)
c_dirs=$(for i in $c_files; do dirname $i; done | sort | uniq)

progress "Copying include files..."
for i in $c_dirs; do
  echo "   $i"
  cp $lava/include/*.h $i/
done

progress "Inserting queries..."
for i in $c_files; do
  $lava/src_clang/build/lavaTool -action=query \
    -lava-db="$directory/$name/lavadb" \
    -p="$source/compile_commands.json" \
    -project-file="$json" "$i"
done

progress "Done inserting queries. Time to make and run actuate.py on a 64-BIT machine!"