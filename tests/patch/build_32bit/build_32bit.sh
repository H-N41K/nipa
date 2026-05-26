#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Copyright (C) 2019 Netronome Systems, Inc.

cc="ccache gcc"
output_dir=build_32bit/
ncpu=$(grep -c processor /proc/cpuinfo)
build_flags="-Oline -j $ncpu W=1"
tmpfile_o=$(mktemp)
tmpfile_n=$(mktemp)
rc=0

# Visual helper for scannable terminal tracking
status_echo() {
    echo -e "\n\033[1;35m[NIPA 32-BIT STATUS]\033[0m $1"
}

prep_config() {
  status_echo "Generating 32-bit i386 Kconfig via allmodconfig..."
  # Added -q flag so configuration entries don't flood your console log
  make -q CC="$cc" O=$output_dir ARCH=i386 allmodconfig
  ./scripts/config --file $output_dir/.config -d werror
  ./scripts/config --file $output_dir/.config -d drm_werror
  ./scripts/config --file $output_dir/.config -d kvm_werror
}

clean_up_output() {
    local file=$1
    # modpost triggers this randomly on use of existing symbols
    sed -i '/arch\/x86\/boot.* warning: symbol .* was not declared. Should it be static?/d' $file
}

echo "Using $build_flags redirect to $tmpfile_o and $tmpfile_n"
echo "CC=$cc"
$cc --version | head -n1

HEAD=$(git rev-parse HEAD)

echo "Tree base:"
git log -1 --pretty='%h ("%s")' HEAD~

if [ x$FIRST_IN_SERIES == x0 ] && \
   ! git diff --name-only HEAD~ | grep -q -E "Kconfig$"
then
    status_echo "Skipping baseline build (not the first patch, no Kconfig updates)."
else
    status_echo "Compiling the initial baseline tree (this will take a while)..."
    prep_config
    make CC="$cc" O=$output_dir ARCH=i386 $build_flags
fi

# Check if new files were added, new files will cause mod re-linking
# so all module and linker related warnings will pop up in the "after"
# but not "before". To avoid this we need to force re-linking on
# the "before", too.
touch_relink=/dev/null
if ! git log --diff-filter=A HEAD~.. --exit-code >>/dev/null || \
   git diff --name-only HEAD~ | grep -q -E "Makefile$" || \
   git diff --name-only HEAD~ | grep -q -E "Kconfig$"
then
    status_echo "Structural configuration changes detected. Forcing cross-module re-linking..."
    touch_relink=${output_dir}/include/generated/utsrelease.h
fi

touch $touch_relink

status_echo "Checking out baseline commit (HEAD~)..."
git checkout -q HEAD~

status_echo "Compiling base kernel framework (WITHOUT your patch applied)..."
prep_config
make CC="$cc" O=$output_dir ARCH=i386 $build_flags 2> >(tee $tmpfile_o >&2)
# NEW ONE make CC="$cc" O=$output_dir ARCH=i386 $build_flags 2> >(stdbuf -oL -eL tee $tmpfile_o >&2)

clean_up_output $tmpfile_o
incumbent=$(grep -i -c "\(warn\|error\)" $tmpfile_o)
status_echo "Baseline 32-bit build complete. Found $incumbent existing warnings/errors."

status_echo "Returning to patch target commit (HEAD)..."
git checkout -q $HEAD

# Also force rebuild "after" in case the file added isn't important.
touch $touch_relink

status_echo "Compiling modified kernel framework (WITH your patch applied)..."
prep_config
make CC="$cc" O=$output_dir ARCH=i386 $build_flags 2> >(tee $tmpfile_n >&2) || rc=1
# new one make CC="$cc" O=$output_dir ARCH=i386 $build_flags 2> >(stdbuf -oL -eL tee $tmpfile_n >&2) || rc=1


clean_up_output $tmpfile_n
current=$(grep -i -c "\(warn\|error\)" $tmpfile_n)
status_echo "Patch 32-bit build complete. Found $current total warnings/errors."

echo "Errors and warnings before: $incumbent this patch: $current" >&$DESC_FD

if [ $current -gt $incumbent ]; then
  status_echo "Regression detected! Printing compiler warning comparisons..." 1>&2
  diff -U 0 $tmpfile_o $tmpfile_n 1>&2

  status_echo "Isolating per-file delta regression points..." 1>&2
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
  status_echo "Success! No 32-bit regression warnings introduced by this patch."
fi

rm $tmpfile_o $tmpfile_n

exit $rc
