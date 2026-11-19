/* midi_dump: bk_analyze_midi on each file named, one JSON line per file (tools/parity/midi_parity.py
 * holds the lines against midi_analyze.py).  Usage: midi_dump <file.mid>... */
#include <stdio.h>
#include <stdlib.h>

#include "beatkey.h"

int main(int argc, char **argv) {
    bk_log_set_dir(getenv("BEATKEY_LOG_DIR"));
    for (int i = 1; i < argc; i++) {
        FILE *f = fopen(argv[i], "rb");
        if (!f) {
            printf("{\"file\": \"%s\", \"error\": \"open\"}\n", argv[i]);
            continue;
        }
        fseek(f, 0, SEEK_END);
        long n = ftell(f);
        fseek(f, 0, SEEK_SET);
        unsigned char *buf = malloc(n > 0 ? (size_t)n : 1);
        size_t got = fread(buf, 1, n > 0 ? (size_t)n : 0, f);
        fclose(f);
        bk_reading r;
        char err[256];
        int rc = bk_analyze_midi(buf, got, &r, err, sizeof err);
        free(buf);
        if (rc != BK_OK) {
            printf("{\"file\": \"%s\", \"error\": %d}\n", argv[i], rc);
            continue;
        }
        printf("{\"file\": \"%s\", \"bpm\": %.17g, \"bpm_exact\": %.17g, \"keys\": [", argv[i], r.bpm, r.bpm_exact);
        for (int k = 0; k < 3; k++) printf("%s[\"%s\", %.17g]", k ? ", " : "", r.keys[k].name, r.keys[k].percent);
        printf("]}\n");
    }
    return 0;
}
