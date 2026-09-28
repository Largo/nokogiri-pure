/*
 * Direct oracle for the xmlschemastypes.c port: links against a libxml2 2.13.9 build and
 * answers requests on stdin (one per line, tab-separated, string fields hex-encoded, "-" = NULL).
 * Build: see build_oracle.sh. Used by gen_fixtures.rb to produce the JSON fixtures.
 *
 *   P type mode value              parse (mode N = xmlSchemaValPredefTypeNode, R = ...NoNorm)
 *   C t1 m1 v1 t2 m2 v2            compare two values (all whitespace combinations)
 *   F ftype fvaltype fvalue base valtype mode value actuallen
 *                                  facet checks (fws/ws all combos)
 *   N value                        name validators + collapse/replace
 *   D doc attrname type value ...  node-dependent validation on attribute attrname of the
 *                                  root element of the parsed doc (several type/value pairs)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libxml/parser.h>
#include <libxml/tree.h>
#include <libxml/valid.h>
#include <libxml/xmlschemas.h>
#include <libxml/xmlschemastypes.h>
#include <libxml/schemasInternals.h>

static char *unhex(const char *s) {
    if (strcmp(s, "-") == 0) return NULL;
    size_t n = strlen(s) / 2;
    char *r = malloc(n + 1);
    for (size_t i = 0; i < n; i++) { unsigned v; sscanf(s + 2 * i, "%2x", &v); r[i] = (char) v; }
    r[n] = 0;
    return r;
}
static void phex(const char *s) {
    if (s == NULL) { printf("-"); return; }
    if (*s == 0) { printf("="); return; }
    for (; *s; s++) printf("%02x", (unsigned char) *s);
}
static xmlSchemaTypePtr ty(const char *name) {
    return xmlSchemaGetPredefinedType(BAD_CAST name, BAD_CAST "http://www.w3.org/2001/XMLSchema");
}
static int parse(xmlSchemaTypePtr t, const char *mode, const char *v, xmlSchemaValPtr *val, xmlNodePtr node) {
    if (mode[0] == 'N') return xmlSchemaValPredefTypeNode(t, BAD_CAST v, val, node);
    return xmlSchemaValPredefTypeNodeNoNorm(t, BAD_CAST v, val, node);
}
static void canon(xmlSchemaValPtr val) {
    const xmlChar *c = NULL;
    int r = xmlSchemaGetCanonValue(val, &c);
    printf("\t%d\t", r); phex((const char *) c);
    xmlFree((void *) c);
    for (int ws = 0; ws <= 3; ws++) {
        c = NULL;
        r = xmlSchemaGetCanonValueWhtsp(val, &c, ws);
        printf("\t%d\t", r); phex((const char *) c);
        xmlFree((void *) c);
    }
}

int main(void) {
    char line[1 << 20];
    xmlInitParser();
    xmlSchemaInitTypes();
    while (fgets(line, sizeof(line), stdin)) {
        char *f[64]; int nf = 0;
        line[strcspn(line, "\n")] = 0;
        for (char *p = strtok(line, "\t"); p && nf < 64; p = strtok(NULL, "\t")) f[nf++] = p;
        if (nf == 0) continue;
        if (strcmp(f[0], "P") == 0) {
            xmlSchemaTypePtr t = ty(f[1]);
            char *v = unhex(f[3]);
            xmlSchemaValPtr val = NULL;
            int r0 = parse(t, f[2], v, NULL, NULL);
            int r1 = parse(t, f[2], v, &val, NULL);
            printf("%d\t%d\t%d", r0, r1, val ? (int) xmlSchemaGetValType(val) : -1);
            if (val) {
                canon(val);
                xmlSchemaValPtr cp = xmlSchemaCopyValue(val);
                printf("\t%d", cp ? xmlSchemaCompareValues(val, cp) : -99);
                xmlSchemaFreeValue(cp);
                printf("\t"); phex((const char *) xmlSchemaValueGetAsString(val));
                printf("\t%d", xmlSchemaValueGetAsBoolean(val));
            }
            printf("\n");
            xmlSchemaFreeValue(val);
            free(v);
        } else if (strcmp(f[0], "C") == 0) {
            char *v1 = unhex(f[3]), *v2 = unhex(f[6]);
            xmlSchemaValPtr a = NULL, b = NULL;
            int r1 = parse(ty(f[1]), f[2], v1, &a, NULL);
            int r2 = parse(ty(f[4]), f[5], v2, &b, NULL);
            printf("%d\t%d\t%d", r1, r2, xmlSchemaCompareValues(a, b));
            for (int x = 0; x <= 3; x++)
                for (int y = 0; y <= 3; y++)
                    printf("\t%d", xmlSchemaCompareValuesWhtsp(a, x, b, y));
            printf("\n");
            xmlSchemaFreeValue(a); xmlSchemaFreeValue(b); free(v1); free(v2);
        } else if (strcmp(f[0], "F") == 0) {
            xmlSchemaFacetPtr facet = xmlSchemaNewFacet();
            char *fv = unhex(f[3]), *v = unhex(f[7]);
            xmlSchemaTypePtr base = ty(f[4]);
            xmlSchemaValPtr val = NULL;
            facet->type = atoi(f[1]);
            facet->value = BAD_CAST fv;
            int rf = strncmp(f[2], "R:", 2) == 0 ?
                xmlSchemaValPredefTypeNodeNoNorm(ty(f[2] + 2), BAD_CAST fv, &facet->val, NULL) :
                xmlSchemaValPredefTypeNode(ty(f[2]), BAD_CAST fv, &facet->val, NULL);
            int rv = parse(ty(f[5]), f[6], v, &val, NULL);
            unsigned long actual = strtoul(f[8], NULL, 10);
            int fvt = facet->val ? (int) xmlSchemaGetValType(facet->val) : -1;
            int isdec = fvt == XML_SCHEMAS_DECIMAL || (fvt >= XML_SCHEMAS_INTEGER && fvt <= XML_SCHEMAS_UBYTE);
            printf("%d\t%d\t%lu", rf, rv, isdec ? xmlSchemaGetFacetValueAsULong(facet) : 0);
            printf("\t%d", xmlSchemaValidateFacet(base, facet, BAD_CAST v, val));
            printf("\t%d", xmlSchemaValidateFacet(NULL, facet, BAD_CAST v, NULL));
            printf("\t%d", xmlSchemaValidateFacet(base, facet, BAD_CAST v, NULL));
            int vt = val ? (int) xmlSchemaGetValType(val) : base->builtInType;
            for (int x = 0; x <= 3; x++)
                for (int y = 0; y <= 3; y++) {
                    if (facet->val == NULL && facet->type == XML_SCHEMA_FACET_ENUMERATION && y != 0)
                        printf("\tX"); /* would crash */
                    else
                        printf("\t%d", xmlSchemaValidateFacetWhtsp(facet, x, vt, BAD_CAST v, val, y));
                }
            if (facet->type == XML_SCHEMA_FACET_LENGTH || facet->type == XML_SCHEMA_FACET_MINLENGTH ||
                facet->type == XML_SCHEMA_FACET_MAXLENGTH) {
                unsigned long len = 12345;
                int r = xmlSchemaValidateLengthFacet(base, facet, BAD_CAST v, val, &len);
                printf("\t%d\t%lu", r, len);
                for (int y = 0; y <= 3; y++) {
                    len = 12345;
                    r = xmlSchemaValidateLengthFacetWhtsp(facet, vt, BAD_CAST v, val, &len, y);
                    printf("\t%d\t%lu", r, len);
                }
                unsigned long exp = 12345;
                r = xmlSchemaValidateListSimpleTypeFacet(facet, BAD_CAST v, actual, &exp);
                printf("\t%d\t%lu", r, exp);
            }
            printf("\n");
            xmlSchemaFreeValue(val);
            facet->value = NULL;
            xmlSchemaFreeFacet(facet);
            free(fv); free(v);
        } else if (strcmp(f[0], "N") == 0) {
            char *v = unhex(f[1]);
            printf("%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t",
                   xmlValidateNCName(BAD_CAST v, 0), xmlValidateNCName(BAD_CAST v, 1),
                   xmlValidateQName(BAD_CAST v, 0), xmlValidateQName(BAD_CAST v, 1),
                   xmlValidateName(BAD_CAST v, 0), xmlValidateName(BAD_CAST v, 1),
                   xmlValidateNMToken(BAD_CAST v, 0), xmlValidateNMToken(BAD_CAST v, 1));
            xmlChar *c = xmlSchemaCollapseString(BAD_CAST v);
            phex((const char *) c); xmlFree(c);
            printf("\t");
            c = xmlSchemaWhiteSpaceReplace(BAD_CAST v);
            phex((const char *) c); xmlFree(c);
            printf("\n");
            free(v);
        } else if (strcmp(f[0], "D") == 0) {
            char *xml = unhex(f[1]);
            char *aname = unhex(f[2]);
            xmlDocPtr doc = xmlReadMemory(xml, strlen(xml), "d.xml", NULL, XML_PARSE_NONET);
            xmlNodePtr root = xmlDocGetRootElement(doc);
            xmlNodePtr node = aname ? (xmlNodePtr) xmlHasProp(root, BAD_CAST aname) : root;
            for (int i = 3; i + 1 < nf; i += 2) {
                char *v = unhex(f[i + 1]);
                xmlSchemaValPtr val = NULL;
                int r = xmlSchemaValPredefTypeNode(ty(f[i]), BAD_CAST v, &val, node);
                printf("%s%d", i == 3 ? "" : "\t", r);
                const xmlChar *c = NULL;
                if (val) { xmlSchemaGetCanonValue(val, &c); }
                printf("\t"); phex((const char *) c); xmlFree((void *) c);
                printf("\t%d", node && node->type == XML_ATTRIBUTE_NODE ? (int) ((xmlAttrPtr) node)->atype : -1);
                xmlSchemaFreeValue(val);
                free(v);
            }
            /* IDs registered */
            printf("\t%d", doc->ids ? xmlHashSize(doc->ids) : 0);
            printf("\t%d\n", doc->refs ? xmlHashSize(doc->refs) : 0);
            xmlFreeDoc(doc);
            free(xml); free(aname);
        }
        fflush(stdout);
    }
    return 0;
}
