#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 FOSSology Contributors
# SPDX-License-Identifier: GPL-2.0-only
#
# generate-test-data.sh — create a tarball containing source files with
# well-known license headers.  Used by the smoke test to verify that
# FOSSology correctly identifies GPL-2.0, MIT, Apache-2.0, and BSD-3-Clause.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$REPO_ROOT/test-data"
TARBALL="$OUT_DIR/sample.tar.gz"

if [[ -f "$TARBALL" ]]; then
  echo "[test-data] Already exists at $TARBALL"
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/sample-project/src"

# ── GPL-2.0-only ─────────────────────────────────────────────────────────────
cat > "$WORK/sample-project/src/gpl_scanner.c" << 'SRCEOF'
/*
 * SPDX-FileCopyrightText: Copyright (C) 2024 Test Contributors
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2
 * as published by the Free Software Foundation.
 */
#include <stdio.h>
int main(void) { printf("scanner\n"); return 0; }
SRCEOF

# ── MIT ───────────────────────────────────────────────────────────────────────
cat > "$WORK/sample-project/src/mit_parser.py" << 'SRCEOF'
# SPDX-FileCopyrightText: Copyright (c) 2024 Test Author
# SPDX-License-Identifier: MIT
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

def parse():
    pass
SRCEOF

# ── Apache-2.0 ───────────────────────────────────────────────────────────────
cat > "$WORK/sample-project/src/ApacheUtil.java" << 'SRCEOF'
// SPDX-FileCopyrightText: Copyright 2024 Test Organization
// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0

package com.example;
public class ApacheUtil {
    public static void main(String[] args) {}
}
SRCEOF

# ── BSD-3-Clause ──────────────────────────────────────────────────────────────
cat > "$WORK/sample-project/src/bsd_helper.h" << 'SRCEOF'
/*
 * SPDX-FileCopyrightText: Copyright (c) 2024 Test Contributors
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 * 1. Redistributions of source code must retain the above copyright notice.
 * 2. Redistributions in binary form must reproduce the above copyright notice.
 * 3. Neither the name of the copyright holder nor the names of its
 *    contributors may be used to endorse or promote products.
 */
#ifndef BSD_HELPER_H
#define BSD_HELPER_H
void help(void);
#endif
SRCEOF

mkdir -p "$OUT_DIR"
tar -czf "$TARBALL" -C "$WORK" sample-project/

echo "[test-data] Created $TARBALL ($(du -h "$TARBALL" | cut -f1))"
