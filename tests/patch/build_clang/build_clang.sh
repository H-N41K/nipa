#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Copyright (C) 2019 Netronome Systems, Inc.

# FIXED: Removed ccache to prevent it from remembering the old, broken paths
cc="clang-15"
output_dir=build_clang/
ncpu=$(grep -c processor /proc/cpuinfo)

# FIXED: Prepend /usr/bin to the execution path so sub-shells find the compiler links
export PATH="/usr/bin:/bin:$PATH"

# FIXED: Explicitly pass versioned tools so nested makefiles (like objtool) don't fallback to unversioned names
build_flags="-Oline -j $ncpu W=1 LLVM=-15 AR=llvm-ar-15 HOSTAR=llvm-ar-15 NM=llvm-nm-15 HOSTNM=llvm-nm-15 OBJCOPY=llvm-objcopy-15 HOSTOBJCOPY=llvm-objcopy-15"

tmpfile_o=$(mktemp)
tmpfile_n=$(mktemp)
rc=0

status_echo() {
    echo -e "\n\033[1;34m[NIPA STATUS]\033[0m $1"
}

prep_config() {
  status_echo "Generating Kconfig via allmodconfig..."
  make -q LLVM=-15 AR=llvm-ar-15 HOSTAR=llvm-ar-15 O=$output_dir allmodconfig 
  ./scripts/config --file $output_dir/.config -d werror
  ./scripts/config --file $output_dir/.config -d drm_werror
  ./scripts/config --file $output_dir/.config -d kvm_werror
}

echo "Using $build_flags redirect to $tmpfile_o and $tmpfile_n"
echo "LLVM=-15 cc=\"$cc\""
$cc --version | head -n1

HEAD=$(git rev-parse HEAD)

echo "Tree base:"
git log -1 --pretty='%h ("%s")' HEAD~

if [ x$FIRST_IN_SERIES == x0 ] && \
   ! git diff --name-only HEAD~ | grep -q -E "Kconfig$"
then
    status_echo "Skipping baseline build (not first patch, no Kconfig updates)."
else
    status_echo "Starting baseline compilation of the tree..."
    prep_config
    make CC="$cc" $build_flags O=$output_dir
fi

touch_relink=/dev/null
if ! git log --diff-filter=A HEAD~.. --exit-code >>/dev/null || \
   git diff --name-only HEAD~ | grep -q -E "Makefile$" || \
   git diff --name-only HEAD~ | grep -q -E "Kconfig$"
then
    status_echo "New files or structural updates detected. Forcing object re-linking..."
    touch_relink=${output_dir}/include/generated/utsrelease.h
fi

touch $touch_relink

status_echo "Checking out baseline commit (HEAD~)..."
git checkout -q HEAD~

status_echo "Building the base kernel framework (WITHOUT your patch)..."
prep_config
make CC="$cc" $build_flags O=$output_dir 2> >(tee $tmpfile_o >&2)
incumbent=$(grep -i -c "\(warn\|error\)" $tmpfile_o)
status_echo "Baseline build completed. Found $incumbent existing warnings/errors."

status_echo "Returning to patch commit (HEAD)..."
git checkout -q $HEAD

touch $touch_relink

status_echo "Building the modified kernel framework (WITH your patch applied)..."
prep_config
make CC="$cc" $build_flags O=$output_dir 2> >(tee $tmpfile_n >&2) || rc=1
current=$(grep -i -c "\(warn\|error\)" $tmpfile_n)
status_echo "Patch build completed. Found $current total warnings/errors."

echo "Errors and warnings before: $incumbent this patch: $current" >&$DESC_FD

if [ $current -gt $incumbent ]; then
  status_echo "Regression found! Analyzing new compiler errors..." 1>&2
  diff -U 0 $tmpfile_o $tmpfile_n 1>&2

  status_echo "Generating per-file warning delta breakdown..." 1>&2
  tmpfile_fo=$(mktemp)
  tmpfile_fn=$(mktemp)

  grep -i "\(warn\|error\)" $tmpfile_o | sed -n 's@\(^\.\./[/a-zA-Z0-9_.-]*.[ch]\):.*@\1@p' | sort | uniq -c \
    > $tmpfile_fo
  grep -i "\(warn\|error\)" $tmpfile_n | sed -n 's@\(^\.\./[/a-zA-Z0-9_.-]*.[ch]\):.*@\1@p' | sort | uniq -c \
    > $tmpfile_fn

  diff -U 0 $tmpfile_fo $tmpfile_fn 1>&2
  rm $tmpfile_fo $tmpfile_fn

  rc=1
else
  status_echo "Success! No new errors or warnings introduced by this patch."
fi

rm $tmpfile_o $tmpfile_n

exit $rc
