/* Dumps libxml2's (native nokogiri.so) Unicode category / block / chvalid membership as ranges.
 * Built as a shared object and called through Fiddle from a Ruby process that has loaded the
 * native nokogiri gem (nokogiri.so needs libruby symbols); see oracle_unicode.rb.
 * Output lines: "<kind> <name> lo-hi lo-hi ..." (hex). */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

typedef int (*catfn)(int, const char *);
typedef int (*chfn)(unsigned int);

static void dump(const char *kind, const char *name, int (*f)(void *, int, const char *), void *fn, const char *arg) {
    int in = 0, lo = 0, c;
    printf("%s %s", kind, name);
    for (c = 0; c <= 0x110000; c++) {
        int v = (c < 0x110000) ? f(fn, c, arg) : 0;
        if (v < 0) { printf(" ERR"); break; }
        if (v && !in) { in = 1; lo = c; }
        else if (!v && in) { in = 0; printf(" %x-%x", lo, c - 1); }
    }
    printf("\n");
}
static int callcat(void *fn, int c, const char *a) { return ((catfn) fn)(c, a); }
static int callch(void *fn, int c, const char *a) { (void) a; return ((chfn) fn)((unsigned int) c); }

int unicode_dump(const char *so, const char *blocks_in, const char *out) {
    void *h = dlopen(so, RTLD_NOW | RTLD_NOLOAD);
    if (!h) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    FILE *in = fopen(blocks_in, "r");
    if (!freopen(out, "w", stdout)) return 1;
    void *cat = dlsym(h, "xmlUCSIsCat"), *blk = dlsym(h, "xmlUCSIsBlock");
    static const char *cats[] = {"C","Cc","Cf","Co","Cs","L","Ll","Lm","Lo","Lt","Lu","M","Mc","Me","Mn","N","Nd","Nl","No","P","Pc","Pd","Pe","Pf","Pi","Po","Ps","S","Sc","Sk","Sm","So","Z","Zl","Zp","Zs", NULL};
    for (int i = 0; cats[i]; i++) dump("cat", cats[i], callcat, cat, cats[i]);
    char line[256];
    while (fgets(line, sizeof line, in)) {
        for (char *p = line; *p; p++) if (*p == '\n') *p = 0;
        if (*line) dump("block", line, callcat, blk, line);
    }
    static const char *chs[] = {"xmlIsBaseChar","xmlIsChar","xmlIsCombining","xmlIsDigit","xmlIsExtender","xmlIsIdeographic", NULL};
    for (int i = 0; chs[i]; i++) dump("ch", chs[i], callch, dlsym(h, chs[i]), NULL);
    fflush(stdout);
    fclose(in);
    return 0;
}
