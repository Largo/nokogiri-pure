/* Oracle tool: libxml2 2.13.9 HTML parser SAX event / error dump.
 * usage: htmlsax MODE CHUNK OPTIONS ENCODING FILE
 *   MODE: pull | push | pushdom | pulldom      CHUNK: push chunk size
 *   ENCODING: "-" for none
 * Build: gcc -I<libxml2>/include -I<build>/include htmlsax.c <build>/.libs/libxml2.a -lm -o htmlsax
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libxml/HTMLparser.h>
#include <libxml/parserInternals.h>
#include <libxml/xmlerror.h>
#include <libxml/tree.h>

static void pstr(const xmlChar *s, int len) {
  putchar('"');
  for (int i = 0; len < 0 ? s[i] : i < len; i++) {
    unsigned char c = s[i];
    if (c == '"' || c == '\\') printf("\\%c", c);
    else if (c < 0x20 || c >= 0x7f) printf("\\x%02X", c);
    else putchar(c);
  }
  putchar('"');
}
static void pstrn(const xmlChar *s) { if (s) pstr(s, -1); else printf("nil"); }

static htmlParserCtxtPtr gctxt;
static void loc(void) { if (gctxt && gctxt->input) printf(" @%d:%d", gctxt->input->line, gctxt->input->col); }

static void sdoc(void *c) { printf("startDocument"); loc(); puts(""); }
static void edoc(void *c) { printf("endDocument"); loc(); puts(""); }
static void sel(void *c, const xmlChar *n, const xmlChar **a) {
  printf("startElement "); pstrn(n);
  if (a) for (int i = 0; a[i]; i += 2) { printf(" "); pstrn(a[i]); printf("="); pstrn(a[i+1]); }
  loc(); puts("");
}
static void eel(void *c, const xmlChar *n) { printf("endElement "); pstrn(n); loc(); puts(""); }
static void chars(void *c, const xmlChar *s, int len) { printf("characters "); pstr(s, len); loc(); puts(""); }
static void cdata(void *c, const xmlChar *s, int len) { printf("cdata "); pstr(s, len); loc(); puts(""); }
static void ign(void *c, const xmlChar *s, int len) { printf("ignorable "); pstr(s, len); loc(); puts(""); }
static void comm(void *c, const xmlChar *s) { printf("comment "); pstrn(s); loc(); puts(""); }
static void pi(void *c, const xmlChar *t, const xmlChar *d) { printf("pi "); pstrn(t); printf(" "); pstrn(d); loc(); puts(""); }
static void isub(void *c, const xmlChar *n, const xmlChar *e, const xmlChar *s) {
  printf("internalSubset "); pstrn(n); printf(" "); pstrn(e); printf(" "); pstrn(s); loc(); puts("");
}
static void serr(void *u, const xmlError *e) {
  printf("error d=%d c=%d l=%d %d:%d ", e->domain, e->code, e->level, e->line, e->int2);
  pstrn((const xmlChar *)e->message); printf(" s1="); pstrn((const xmlChar *)e->str1);
  printf(" s2="); pstrn((const xmlChar *)e->str2); printf(" i1=%d\n", e->int1);
}

static void dump(xmlNodePtr n, int depth) {
  for (; n; n = n->next) {
    printf("%*s%d ", depth * 2, "", n->type); pstrn(n->name); if (n->type != XML_DTD_NODE) printf(" L%d", n->line);
    if (n->type == XML_TEXT_NODE || n->type == XML_CDATA_SECTION_NODE || n->type == XML_COMMENT_NODE || n->type == XML_PI_NODE) {
      printf(" "); pstrn(n->content);
    }
    if (n->type == XML_DTD_NODE) { xmlDtdPtr d = (xmlDtdPtr)n; printf(" "); pstrn(d->ExternalID); printf(" "); pstrn(d->SystemID); }
    if (n->type == XML_ELEMENT_NODE) {
      for (xmlAttrPtr a = n->properties; a; a = a->next) {
        printf(" @"); pstrn(a->name); printf("=");
        if (a->children) pstrn(a->children->content); else printf("nil");
      }
    }
    puts("");
    if (n->type != XML_DTD_NODE && n->type != XML_ATTRIBUTE_NODE) dump(n->children, depth + 1);
  }
}

int main(int argc, char **argv) {
  if (argc < 6) return 2;
  const char *mode = argv[1];
  int chunk = atoi(argv[2]);
  int opts = atoi(argv[3]);
  const char *enc = strcmp(argv[4], "-") ? argv[4] : NULL;
  FILE *f = fopen(argv[5], "rb");
  static char data[1 << 24];
  size_t len = fread(data, 1, sizeof(data), f);
  fclose(f);
  xmlSetStructuredErrorFunc(NULL, serr);

  htmlSAXHandler sax;
  memset(&sax, 0, sizeof(sax));
  sax.startDocument = sdoc; sax.endDocument = edoc; sax.startElement = sel; sax.endElement = eel;
  sax.characters = chars; sax.cdataBlock = cdata; sax.ignorableWhitespace = ign; sax.comment = comm;
  sax.processingInstruction = pi; sax.internalSubset = isub;
  int dom = strstr(mode, "dom") != NULL;

  if (!strncmp(mode, "push", 4)) {
    xmlCharEncoding e = enc ? xmlParseCharEncoding(enc) : XML_CHAR_ENCODING_NONE;
    htmlParserCtxtPtr ctxt = htmlCreatePushParserCtxt(dom ? NULL : &sax, NULL, NULL, 0, NULL, e);
    gctxt = ctxt;
    htmlCtxtUseOptions(ctxt, opts);
    size_t pos = 0;
    if (chunk <= 0) chunk = 1 << 24;
    while (pos < len) {
      size_t n = len - pos < (size_t)chunk ? len - pos : (size_t)chunk;
      int r = htmlParseChunk(ctxt, data + pos, n, 0);
      printf("chunk %zu r=%d\n", n, r);
      pos += n;
    }
    int r = htmlParseChunk(ctxt, NULL, 0, 1);
    printf("final r=%d wf=%d\n", r, ctxt->wellFormed);
    if (dom && ctxt->myDoc) { printf("encoding "); pstrn(ctxt->myDoc->encoding); puts(""); dump(ctxt->myDoc->children, 0); }
  } else {
    htmlParserCtxtPtr ctxt = htmlNewSAXParserCtxt(dom ? NULL : &sax, NULL);
    gctxt = ctxt;
    htmlDocPtr doc = htmlCtxtReadMemory(ctxt, data, len, NULL, enc, opts);
    if (dom && doc) { printf("encoding "); pstrn(doc->encoding); puts(""); dump(doc->children, 0); }
  }
  return 0;
}
