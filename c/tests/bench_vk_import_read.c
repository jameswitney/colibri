/* bench_vk_import_read: the PCIe/import-read wall of a decode expert group over
 * imported host slabs (specs/CS-expert-compute-site.md §6 falsifier 1, the CS-0 leg).
 *
 * The compute-site lever submits every non-resident routed expert of a decode
 * layer-token as a zero-copy view of its host-RAM slab: k experts' weights, read by
 * the GEMV over VK_EXT_external_memory_host pages inside one submit. The falsifier's
 * bar is device time <= 2.5 ms a layer-token at k=6, real geometry (~2.5 ms x 43
 * layers = ~108 ms/tok ceiling; the fork's 0.381 ms is the VRAM-resident bound).
 *
 * What runs: DeepSeek V4 Flash's decode geometry (hidden 4096, moe_inter 2048,
 * top-6), six experts' gate/up/down as fmt 7 MXFP4 matrices whose CODES stay in host
 * memory (posix_memalign'ed, imported through coli_vk_tensor_import -- the alias's
 * byte volume: fmt 7's codes are the fp4 nibbles the store's fmt 15 holds, its f32
 * scales land in the device pool at import like fmt 15's packed bytes would stay on
 * the slab), driven as ONE coli_vk_xb_issue_w group -- the tier's own expert batch,
 * the submit CS-1b rides. A VRAM control leg runs the same group from uploaded
 * copies (coli_vk_tensor_ensure): the 0.381 ms class. Reports both legs' device and
 * wall ms a layer-token and the effective host-read GB/s beside the bar.
 *
 *   make tests/bench_vk_import_read VK=1 && ./tests/bench_vk_import_read [reps]
 * Needs a Vulkan device that imports host memory (RADV: yes); refuses cleanly when
 * it cannot (exit 1 with the reason), the house rig gates' rule. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "../backend_vulkan.h"

enum { D = 4096, I = 2048, K = 6, GS = 32, FMT = 7 };   /* the model's decode geometry */

static double now_s(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (double)t.tv_sec + t.tv_nsec * 1e-9; }

/* one matrix of O rows x Ip inputs: fmt 7's codes (a nibble a weight) in host memory */
typedef struct { ColiVkTensor *t; uint8_t *codes; float *scales; size_t alloc; } Mat;
static int mat_make(Mat *m, int O, int Ip) {
    size_t al = coli_vk_import_alignment();
    if (!al) { fprintf(stderr, "bench_vk_import_read: the device imports no host memory\n"); return 0; }
    size_t wb = (size_t)(Ip + 1) / 2 * (size_t)O, sz = (wb + al - 1) / al * al;
    if (posix_memalign((void **)&m->codes, al, sz)) { fprintf(stderr, "bench_vk_import_read: out of host memory\n"); return 0; }
    for (size_t i = 0; i < wb; i++) m->codes[i] = (uint8_t)(i * 2654435761u >> 13);
    m->scales = malloc((size_t)O * ((Ip + GS - 1) / GS) * sizeof(float));
    if (!m->scales) return 0;
    for (size_t i = 0; i < (size_t)O * ((Ip + GS - 1) / GS); i++) m->scales[i] = 0.25f;
    m->alloc = sz;
    m->t = NULL;
    return 1;
}

int main(int argc, char **argv) {
    int reps = argc > 1 ? atoi(argv[1]) : 30;
    if (reps < 5) reps = 5;
    char spv[1024];
    if (!coli_vk_init(coli_vk_shader_path(spv, sizeof spv))) {
        fprintf(stderr, "bench_vk_import_read: no Vulkan device\n");
        return 1;
    }
    if (!coli_vk_xb_init(D, I, COLI_VK_ACT_SWIGLU_V4, 7.0f, 0, 0)) {
        fprintf(stderr, "bench_vk_import_read: the expert batch did not start\n");
        return 1;
    }
    printf("bench_vk_import_read: import alignment %zu, K=%d experts of gate/up [%d x %d] + down [%d x %d], fmt %d gs %d\n",
           coli_vk_import_alignment(), K, I, D, D, I, FMT, GS);

    /* the input row: values E4M3-exact (eighths), as the contract's rounding leaves them */
    float x[D], w[K];
    const float *xrows[K];
    int rows[K];
    for (int i = 0; i < D; i++) x[i] = (float)((i % 7) - 3) * 0.125f;
    for (int k = 0; k < K; k++) { w[k] = 1.0f / (float)K; rows[k] = 1; xrows[k] = x; }

    /* both legs over the same bytes: imported host codes vs uploaded VRAM copies */
    for (int leg = 0; leg < 2; leg++) {
        Mat gate[K], up[K], down[K];
        ColiVkExpert *ex[K];
        for (int k = 0; k < K; k++) {
            int ok = mat_make(&gate[k], I, D) && mat_make(&up[k], I, D) && mat_make(&down[k], D, I);
            for (int m = 0; ok && m < 3; m++) {   /* 0 gate, 1 up (D inputs, I rows), 2 down (I inputs, D rows) */
                Mat *a = m == 0 ? &gate[k] : m == 1 ? &up[k] : &down[k];
                int in = m == 2 ? I : D, rows_ = m == 2 ? D : I;
                ok = leg == 0
                    ? coli_vk_tensor_import(&a->t, a->codes, a->alloc, a->scales, FMT, in, rows_, GS)
                    : coli_vk_tensor_ensure(&a->t, a->codes, a->scales, FMT, in, rows_, GS);
            }
            ex[k] = ok ? coli_vk_xb_expert(gate[k].t, up[k].t, down[k].t) : NULL;
        }
        if (!ex[K - 1]) {
            printf("bench_vk_import_read: %s leg refused (fmt %d unsupported here)\n",
                   leg == 0 ? "import" : "vram", FMT);
            return 1;
        }
        /* warm the pipelines, then time whole submits: issue the group, join it */
        for (int r = 0; r < 3; r++) {
            const float *y[K];
            double dms;
            if (!coli_vk_xb_issue_w(ex, rows, K, xrows, w) || !coli_vk_xb_join(y, &dms)) return 1;
        }
        double best = 1e9, wall_sum = 0, dev_sum = 0;
        for (int r = 0; r < reps; r++) {
            double t0 = now_s();
            const float *y[K];
            double dms;
            if (!coli_vk_xb_issue_w(ex, rows, K, xrows, w) || !coli_vk_xb_join(y, &dms)) return 1;
            double ms = (now_s() - t0) * 1e3;
            if (ms < best) best = ms;
            wall_sum += ms;
            dev_sum += dms;
        }
        size_t host_bytes = 0;
        for (int k = 0; k < K; k++)
            host_bytes += coli_vk_tensor_bytes(gate[k].t) + coli_vk_tensor_bytes(up[k].t) + coli_vk_tensor_bytes(down[k].t);
        double mean = wall_sum / reps;
        printf("bench_vk_import_read: %s leg: %d reps, wall %.3f ms (best %.3f) a layer-token, "
               "device %.3f ms, %.1f MiB a group -> %.1f GB/s effective%s\n",
               leg == 0 ? "imported-host" : "vram-resident", reps, mean, best, dev_sum / reps,
               host_bytes / 1048576.0, (host_bytes / 1048576.0 / 1024.0) * 1e3 / mean,
               leg == 0 ? "  [bar: <= 2.5 ms]" : "  (the 0.381 ms class)");
        for (int k = 0; k < K; k++) {   /* xb_expert_free frees the three tensors with it */
            coli_vk_xb_expert_free(ex[k]);
            free(gate[k].codes); free(up[k].codes); free(down[k].codes);
            free(gate[k].scales); free(up[k].scales); free(down[k].scales);
        }
    }
    return 0;
}
