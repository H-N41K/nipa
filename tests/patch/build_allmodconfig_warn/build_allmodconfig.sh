#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Copyright (C) 2019 Netronome Systems, Inc.

# OPTIMIZATION 1: Force ccache to recognize sparse and match content signatures
export CCACHE_COMPILERCHECK=content
export CCACHE_SLOPPINESS=time_macros,include_file_mtime

cc="ccache gcc"
output_dir=build_allmodconfig_warn/
ncpu=$(grep -c processor /proc/cpuinfo)

# OPTIMIZATION 2: Restrict heavy C=1 static checking ONLY to the networking tree (drivers/net and net)
# We also use -s for silence and -j for core exhaustion
build_flags="-s -Oline -j $ncpu W=1 C=1 CHECK=\"sparse\" M=\"net drivers/net\""

tmpfile_o=$(mktemp)
tmpfile_n=$(mktemp)
rc=0

prep_config() {
  make -s CC="$cc" O=$output_dir allmodconfig
  ./scripts/config --file $output_dir/.config -d werror
  ./scripts/config --file $output_dir/.config -d drm_werror
  ./scripts/config --file $output_dir/.config -d kvm_werror
  ./scripts/config --file $output_dir/.config -d rust
}

echo "Using speed-optimized flags: $build_flags"
$cc --version | head -n1

HEAD=$(git rev-parse HEAD)

echo "Tree base:"
git log -1 --pretty='%h ("%s")' HEAD~

# OPTIMIZATION 3: Tighten guardrails to skip time-wasting baseline passes if not absolutely forced
if [ x${FIRST_IN_SERIES:-0} == x0 ] && \
   ! git diff --name-only HEAD~ | grep -q -E "(Kconfig|Makefile)$"
then
    echo "[NIPA] Skipping heavy baseline tree compilation."
else
    echo "[NIPA] Compiling minimal cached network baseline..."
    prep_config
    make -s CC="$cc" O=$output_dir $build_flags
fi

touch_relink=/dev/null
if ! git log --diff-filter=A HEAD~.. --exit-code >>/dev/null || \
   git diff --name-only HEAD~ | grep -q -E "Makefile$" || \
   git diff --name-only HEAD~ | grep -q -E "Kconfig$"
then
    echo "[NIPA] Forcing module re-link layers..."
    touch_relink=${output_dir}/include/generated/utsrelease.h
fi

touch $touch_relink
git checkout -q HEAD~

echo "[NIPA] Compiling network sub-tree BEFORE patch..."
prep_config
make -s CC="$cc" O=$output_dir $build_flags 2>&1 >/dev/null | \
  grep -v -E "arch/x86/boot.*warning: symbol.*was not declared|error: bad constant expression" \
  >$tmpfile_o || true

incumbent=$(grep -i -c "\(warn\|error\)" $tmpfile_o)

echo "[NIPA] Compiling network sub-tree WITH patch..."
git checkout -q $HEAD
touch $touch_relink
prep_config

make -s CC="$cc" O=$output_dir $build_flags 2>&1 >/dev/null | \
  grep -v -E "arch/x86/boot.*warning: symbol.*was not declared|error: bad constant expression" \
  >$tmpfile_n || rc=1

current=$(grep -i -c "\(warn\|error\)" $tmpfile_n)

echo "Errors and warnings before: $incumbent this patch: $current" >&$DESC_FD

if [ $current -gt $incumbent ]; then
  echo "New errors added" 1>&2
  diff -U 0 $tmpfile_o $tmpfile_n 1>&2

  echo "Per-file breakdown" 1>&2
  tmpfile_fo=$(mktemp)
  tmpfile_fn=$(mktemp)

  grep -i "\(warn\|error\)" $tmpfile_o | sed -n 's@\(^\.\./[/a-zA-Z0-9_.-]*.[ch]\):.*@\1@p' | sort | uniq -c \
    > $tmpfile_fo
  grep -i "\(warn\|error\)" $tmpfile_n | sed -n 's@\(^\.\./[/a-zA-Z0-9_.-]*.[ch]\):.*@\1@p' | sort | uniq -c \
    > $tmpfile_fn

  diff -U 0 $tmpfile_fo $tmpfile_fn 1>&2
  rm $tmpfile_fo $tmpfile_fn
  rc=1
fi

rm $tmpfile_o $tmpfile_n
exit $rc
