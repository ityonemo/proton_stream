// SPDX-FileCopyrightText: 2025 Isaac Yonemoto
// SPDX-License-Identifier: Apache-2.0

// Test helper: reads numbers from stdin, outputs n+1
// Used for testing bidirectional communication

#include <stdio.h>
#include <stdlib.h>

int main() {
    char buf[256];
    while (fgets(buf, sizeof(buf), stdin) != NULL) {
        int n = atoi(buf);
        printf("%d\n", n + 1);
        fflush(stdout);
    }
    return 0;
}
