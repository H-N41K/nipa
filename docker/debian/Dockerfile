FROM debian:bookworm

ARG nipauid
RUN useradd -o -m -u $nipauid nipa

RUN apt-get update && apt-get install -y \
	procps python3 git patatt build-essential ccache flex bison gawk \
	libssl-dev libelf-dev sparse bc cpio gdb strace vim python3-requests python3-jsonschema \
	clang-15 lld-15 llvm-15 llvm-15-tools \
	python3-ply python3-git \
 && rm -rf /var/lib/apt/lists/*

# FIXED: Replicated explicit symlinks into /bin/ as well, to catch hardcoded sub-shell paths
RUN ln -sf /usr/bin/clang-15 /usr/bin/clang && \
    ln -sf /usr/bin/lld-15 /usr/bin/lld && \
    ln -sf /usr/bin/ld.lld-15 /usr/bin/ld.lld && \
    ln -sf /usr/bin/llvm-config-15 /usr/bin/llvm-config && \
    ln -sf /usr/bin/llvm-ar-15 /usr/bin/llvm-ar && \
    ln -sf /usr/bin/llvm-nm-15 /usr/bin/llvm-nm && \
    ln -sf /usr/bin/llvm-objcopy-15 /usr/bin/llvm-objcopy && \
    ln -sf /usr/bin/llvm-ar-15 /bin/llvm-ar && \
    ln -sf /usr/bin/llvm-nm-15 /bin/llvm-nm

RUN mkdir -p /home/nipa/.local/share/patatt && chown -R nipa: /home/nipa
RUN git config --global --add safe.directory /nipa-run/tree
