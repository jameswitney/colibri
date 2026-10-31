/* K1 — the L2 spec's one-off kernel microbench (specs/L2-chain-moe-vkdmoe.md §7):
 * vkc_moe_rows(7,...) (L2 Stage B's grouped mx GEMMs) vs vkc_moe(7,...) (the generic
 * per-pair chain_moe.comp path) at DeepSeek-V4-Flash's routed-expert shape:
 * K=6, E=256, D=4096, I=2048, fmt 7 (MXFP4) gs 32, S in {1, 8, 512, 2048}.
 * Decides route (b)'s trigger (the per-pair generic path >1.5x slower than the grouped
 * path at S=1) and gives Stage B its throughput number. One-off: built against the
 * worktree's VK objects with the test harness's own helpers and timing methodology
 * (48 layers of experts a frame, one untimed warmup, best of 4 timed frames), not
 * landed in the tree.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include "backend_vulkan.h"
#include "vk_chain.h"

static unsigned rng = 12345;
static unsigned rnd(void) { rng = rng * 1103515245u + 12345u; return rng >> 8; }
static float frnd(void) { return (float)((int)(rnd() % 2001) - 1000) / 1000.0f; }
static float *fvec(size_t n, float scale) { float *v = malloc(n * sizeof *v); for (size_t i = 0; i < n; i++) v[i] = frnd() * scale; return v; }
static VkcBuf *up(const float *v, size_t n) {
    VkcBuf *b = vkc_buf(n * 4, VKC_DEV);
    if (!b) return NULL;
    vkc_begin(); vkc_write(b, 0, v, n * 4); vkc_submit(1);
    return b;
}
static double bnow(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }

int main(int argc, char **argv) {
    const char *spv = argc > 1 ? argv[1] : "shaders/qmatmul.spv";
    const char *mode = argc > 2 ? argv[2] : "both";   /* moe | rows | both: phase isolation */
    const int want_moe = !strcmp(mode, "moe") || !strcmp(mode, "both"), want_rows = !strcmp(mode, "rows") || !strcmp(mode, "both");
    int Ss[8], ns = 0;
    for (int i = 3; i < argc && ns < 8; i++) Ss[ns++] = atoi(argv[i]);
    if (!ns) { Ss[ns++] = 1; Ss[ns++] = 8; Ss[ns++] = 512; Ss[ns++] = 2048; }
    if (!coli_vk_init(spv)) { printf("K1: no Vulkan device\n"); return 1; }
    if (!vkc_init()) { printf("K1: the chain's pipelines did not come up\n"); return 1; }
    const int fmt = 7, gs = 32, E = 256, K = 6, D = 4096, I = 2048;
    int nl = 48;
    if (getenv("K1_NL") && atoi(getenv("K1_NL")) > 0) nl = atoi(getenv("K1_NL"));
    if (!vkc_moe_rows_ready(fmt, fmt)) { printf("K1: fmt 7 rows not ready on this device\n"); return 1; }
    if (!coli_vk_xb_init(D, I, COLI_VK_ACT_SWIGLU, 0, 0, 0)) { printf("K1: no expert batch here\n"); return 1; }
    /* the experts exactly as test_moe_rows_q builds them: random e2m1 codes, ue8m0-class
     * scales as floats, one table of E experts (a full DSV4 layer, 3.75 GiB — far past L2,
     * so every pass reads weights from VRAM even reused across the frame's layers) */
    size_t rg = (size_t)D / 2, rd = (size_t)I / 2, ng = (size_t)D / gs, nd = (size_t)I / gs;
    uint8_t *wg = malloc(rg * I), *wu = malloc(rg * I), *wd = malloc(rd * D);
    float *sg = malloc((size_t)I * ng * 4), *su = malloc((size_t)I * ng * 4), *sd = malloc((size_t)D * nd * 4);
    ColiVkTensor **t = calloc((size_t)3 * E, sizeof *t);
    ColiVkExpert **ex = calloc((size_t)E, sizeof *ex);
    uint32_t *tab = calloc((size_t)E * COLI_VK_XB_ENTRY, 4);
    int ok = wg && wu && wd && sg && su && sd && t && ex && tab;
    for (int e = 0; e < E && ok; e++) {
        for (size_t i = 0; i < rg * I; i++) { wg[i] = (uint8_t)rnd(); wu[i] = (uint8_t)rnd(); }
        for (size_t i = 0; i < rd * D; i++) wd[i] = (uint8_t)rnd();
        for (size_t i = 0; i < (size_t)I * ng; i++) { sg[i] = 0.002f + 0.002f * (rnd() & 255) / 255.f; su[i] = 0.002f + 0.002f * (rnd() & 255) / 255.f; }
        for (size_t i = 0; i < (size_t)D * nd; i++) sd[i] = 0.002f + 0.002f * (rnd() & 255) / 255.f;
        ok = coli_vk_tensor_ensure(&t[3 * e], wg, sg, fmt, D, I, gs) && coli_vk_tensor_ensure(&t[3 * e + 1], wu, su, fmt, D, I, gs) &&
             coli_vk_tensor_ensure(&t[3 * e + 2], wd, sd, fmt, I, D, gs) && (ex[e] = coli_vk_xb_expert(t[3 * e], t[3 * e + 1], t[3 * e + 2])) &&
             coli_vk_xb_expert_entry(ex[e], tab + (size_t)e * COLI_VK_XB_ENTRY);
    }
    if (!ok) { printf("K1: the experts did not go up\n"); return 1; }
    VkcBuf *tb = vkc_buf((size_t)E * COLI_VK_XB_ENTRY * 4, VKC_DEV);
    vkc_begin(); ok = vkc_write(tb, 0, tab, (size_t)E * COLI_VK_XB_ENTRY * 4) && vkc_submit(1);
    printf("K1: fmt %d gs %d, E %d K %d D %d I %d, a layer's experts %.2f GiB, %d layers a frame\n",
           fmt, gs, E, K, D, I, (double)E * (2.0 * (rg * I + (size_t)I * ng * 4) + rd * D + (size_t)D * nd * 4) / (1 << 30), nl);
    fflush(stdout);
    for (size_t si = 0; si < (size_t)ns && ok; si++) {
        const int S = Ss[si];
        float *lg = fvec((size_t)S * E * nl, 2.f), *x = fvec((size_t)S * D, 1.f);
        VkcBuf *lb = up(lg, (size_t)S * E * nl), *xb = up(x, (size_t)S * D);
        VkcBuf *ib = vkc_buf((size_t)S * K * 4 * nl, VKC_DEV), *wb = vkc_buf((size_t)S * K * 4 * nl, VKC_DEV);
        VkcBuf *hb = vkc_buf((size_t)S * K * (I + D) * 4, VKC_DEV), *y0 = vkc_buf((size_t)S * D * 4, VKC_DEV), *y1 = vkc_buf((size_t)S * D * 4, VKC_DEV);
        VkcRoute rp = {S * nl, E, K, 0, 0, E, 0, 0, 0, K, 1, K, 1, 1, 1, 1.f, 1.f, 0.f};
        vkc_begin(); ok = vkc_route(lb, NULL, ib, wb, &rp) && vkc_submit(1);   /* every layer's ids, once */
        printf("K1 S %5d: routed ok=%d\n", S, ok); fflush(stdout);
        double bm = 1e9, br = 1e9;
        VkcMoeRows rr = {0};
        for (int r = -1; r < 4 && ok && want_moe; r++) {   /* the per-pair generic path (chain_moe.comp) */
            VkcMoe mp = {S, K, D, I, 0, 0.f, 0.f, 0.f, 0, 0, D, 0, K, 0, K, 0, D, 0, 0, fmt, fmt, E, 0, 0};
            vkc_begin();
            for (int l = 0; l < nl && ok; l++) { mp.i_off = mp.w_off = l * S * K; ok = vkc_moe(xb, ib, wb, tb, hb, y0, &mp); }
            double t0 = bnow(); ok = vkc_submit(1) && ok; double dt = bnow() - t0;
            if (r >= 0 && dt < bm) bm = dt;
        }
        if (want_moe && ok) printf("K1 S %5d: vkc_moe phase done (%.1f us/layer best)\n", S, bm < 1e9 ? bm * 1e6 / nl : -1.0);
        fflush(stdout);
        for (int r = -1; r < 4 && ok && want_rows; r++) {   /* the grouped path (Stage B: qmatmul_grp_mx.comp) */
            VkcMoe mp = {S, K, D, I, 0, 0.f, 0.f, 0.f, 0, 0, D, 0, K, 0, K, 0, D, 0, 0, fmt, fmt, E, 0, 0};
            vkc_begin();
            for (int l = 0; l < nl && ok; l++) { mp.i_off = mp.w_off = l * S * K; ok = vkc_moe_rows(xb, ib, wb, tb, &rr, y1, &mp); }
            double t0 = bnow(); ok = vkc_submit(1) && ok; double dt = bnow() - t0;
            if (r >= 0 && dt < br) br = dt;
        }
        if (want_rows && ok) printf("K1 S %5d: vkc_moe_rows phase done (%.1f us/layer best)\n", S, br < 1e9 ? br * 1e6 / nl : -1.0);
        fflush(stdout);
        if (bm < 1e9 && br < 1e9 && ok)
            printf("K1 S %5d: vkc_moe %8.1f us/layer, vkc_moe_rows %8.1f us/layer, pair/rows %5.2fx%s\n",
                   S, bm * 1e6 / nl, br * 1e6 / nl, bm / br,
                   S == 1 && bm / br > 1.5 ? "  <-- route (b) trigger fires (>1.5x at S=1)" : "");
        else if (!ok) printf("K1 S %d: a frame failed (moe %s, rows %s)\n", S, bm < 1e9 ? "done" : "not reached", br < 1e9 ? "done" : "not reached");
        fflush(stdout);
        vkc_moe_rows_free(&rr);
        VkcBuf *fr[] = {lb, xb, ib, wb, hb, y0, y1};
        for (size_t k = 0; k < sizeof fr / sizeof *fr; k++) if (fr[k]) vkc_free(fr[k]);
        free(lg); free(x);
    }
    vkc_free(tb);
    for (int e = 0; e < E; e++) if (ex[e]) coli_vk_xb_expert_free(ex[e]);
    free(t); free(ex); free(tab); free(wg); free(wu); free(wd); free(sg); free(su); free(sd);
    vkc_shutdown(); coli_vk_shutdown();
    return ok ? 0 : 1;
}
