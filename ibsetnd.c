/* SPDX-License-Identifier: GPL-3.0-or-later
 * Read or set NodeDescription using a LID-routed SMP.
 * Usage: ibsetnd DEVICE [DESCRIPTION]
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <infiniband/mad.h>

/* Decimal by default, even with leading zeroes; hexadecimal needs 0x. */
static int number(const char *s, unsigned long max, unsigned long *value)
{
    char *end;
    /* Reject signs/whitespace; strtoul validates the remaining digits. */
    if (*s < '0' || *s > '9')
        return -1;
    errno = 0;
    *value = strtoul(s, &end, s[0] == '0' && (s[1] == 'x' || s[1] == 'X') ? 16 : 10);
    return errno || *end || !*value || *value > max ? -1 : 0;
}

/* Match the documented MST switch names, preserving the ,CA,port route.
 * Reject multiple _lid- delimiters rather than guessing from a node name.
 */
static int destination(char *s, int *lid, char **ca, int *port)
{
    char *name = strsep(&s, ","), *marker;
    unsigned long n;
    *ca = strsep(&s, ",");
    *port = 0;
    if (*ca && (!**ca || (*ca)[strspn(*ca, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")]))
        return -1;
    if (s) {
        if (number(s, 255, &n))
            return -1;
        *port = (int)n;
    }
    if (!strncmp(name, "/dev/mst/", 9))
        name += 9;
    marker = name;
    if (strncmp(name, "lid-", 4)) {
        if (strncmp(name, "SW_", 3) || strchr(name, '/') ||
            !(marker = strstr(name, "_lid-")))
            return -1;
        ++marker;
    }
    if (number(marker + 4, 0xbfff, &n))
        return -1;
    *lid = (int)n;
    return 0;
}

int main(int argc, char **argv)
{
    int classes[] = { IB_SMI_CLASS };
    int lid, port, status = 0, rc = 1;
    char *ca;
    struct ibmad_port *src;
    ib_portid_t dest = {0};
    unsigned char requested[IB_SMP_DATA_SIZE] = {0};
    unsigned char result[IB_SMP_DATA_SIZE + 1] = {0};

    if (argc != 2 && argc != 3) {
        fprintf(stderr, "Usage: ibsetnd DEVICE [DESCRIPTION]\n");
        return 2;
    }
    if (argc == 3) {
        size_t len = strlen(argv[2]);
        if (len > sizeof(requested)) {
            fprintf(stderr, "description exceeds 64 bytes\n");
            return 2;
        }
        memcpy(requested, argv[2], len);
    }
    /* argv strings are writable; split the device argument in place. */
    if (destination(argv[1], &lid, &ca, &port)) {
        fprintf(stderr, "invalid device: expected lid-N or SW_..._lid-N, optionally with ,CA,port\n");
        return 2;
    }
    src = mad_rpc_open_port(ca, port, classes, 1);
    if (!src) {
        fprintf(stderr, "cannot open local MAD port\n");
        return 1;
    }
    ib_portid_set(&dest, lid, 0, 0);
    mad_rpc_set_retries(src, 0);
    smp_mkey_set(src, 0);
    if (argc == 3) {
        memcpy(result, requested, sizeof(requested));
        if (!smp_set_status_via(result, &dest, IB_ATTR_NODE_DESC, 0, 1000,
                                &status, src) || status) {
            fprintf(stderr, "NodeDescription Set failed (MAD status 0x%x); write outcome may be unknown\n", status);
            goto done;
        }
    }
    status = 0;
    if (!smp_query_status_via(result, &dest, IB_ATTR_NODE_DESC, 0, 1000,
                              &status, src) || status) {
        fprintf(stderr, "NodeDescription read failed (MAD status 0x%x)%s\n",
                status, argc == 3 ? "; Set succeeded but readback is unverified" : "");
        goto done;
    }
    if (argc == 3 && memcmp(requested, result, sizeof(requested))) {
        fprintf(stderr, "NodeDescription readback differs from requested value\n");
        goto done;
    }
    puts((char *)result);
    rc = 0;
done:
    mad_rpc_close_port(src);
    return rc;
}
