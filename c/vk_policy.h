/* vk_policy.h -- the default-on levers' env resolution (gap-wave4, the hw-risk
 * audit's Rule 1/2), one spelling for every reader: the backend
 * (backend_vulkan.c's registry and s1gemv), the tier (vk_tier.c's compute site
 * and decode growth), the chain (vk_chain.c's attention tile) and the engine
 * (deepseek_v4.c's rows16 valve). The policy: the measured levers arm by DEFAULT
 * behind each one's own capability probe -- an unset env takes the lever's
 * default, an explicitly set env always wins (COLI_VK_...=0 is the per-lever
 * escape hatch), and COLI_VK_LEGACY=1 turns every unset lever back off so the
 * stack stands exactly as the upstream base (one stderr line a lever says which
 * of engaged / refused:<reason> / legacy it took; docs/ENVIRONMENT.md).
 *
 * A header inline, not a backend symbol: the tier and the chain read the policy
 * at their own env sites, and cu_tier.c recompiles the tier over the CUDA table
 * unchanged (its backend calls are shimmed; these are pure env reads). */
#ifndef COLI_VK_POLICY_H
#define COLI_VK_POLICY_H
#include <stdlib.h>   /* getenv/atoi */

static inline int coli_vk_legacy(void) {   /* COLI_VK_LEGACY=1: the upstream-base hatch */
    const char *e = getenv("COLI_VK_LEGACY");
    return e && *e && atoi(e) != 0;
}
static inline int coli_vk_env_int(const char *name, int def) {   /* one lever's resolution */
    const char *e = getenv(name);
    if (e && *e) return atoi(e);
    return coli_vk_legacy() ? 0 : def;
}
#endif
