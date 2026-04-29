/*
 * This file is part of mpv-apple.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

/*
 * libmpv headless Vulkan ra_ctx — for embedding mpv into a media app
 * where the display surface (e.g. AVSampleBufferDisplayLayer + IOSurface
 * on Apple) is owned by the host app, not by mpv. The host app
 * pre-allocates a small pool of VkImages, registers it via the public
 * `mpv_libmpv_apple_set_pool` entry point, and selects this ra_ctx by
 * setting `gpu-context=libmpvvk`.
 *
 * This file owns:
 *   1. The single-pool registry behind the `mpv_libmpv_apple_*` API.
 *   2. The `ra_ctx_vulkan_libmpv` ra_ctx itself, which initialises
 *      MoltenVK headlessly and creates a `pl_vulkan_create_headless_swapchain`
 *      seeded from the registered pool.
 *
 * The registry is a single static slot. Multi-instance mpv embedding
 * (more than one player at a time in the same process) is rare for a
 * media app and isn't required for v1; if needed later the registry
 * can grow to a hash keyed on `mpv_global` without changing the public
 * ABI.
 */

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include <vulkan/vulkan.h>
#include <libplacebo/colorspace.h>
#include <libplacebo/vulkan.h>

#include "common.h"
#include "context.h"
#include "utils.h"
#include "video/out/placebo/utils.h"
#include "video/out/vo.h"

#include "mpv/render_libmpv_apple.h"

// ─── single-slot registry behind mpv_libmpv_apple_set_pool ────────────────

static pthread_mutex_t pool_lock = PTHREAD_MUTEX_INITIALIZER;
static mpv_libmpv_apple_pool_params pool_params; // copied in by set_pool
static bool pool_set;

int mpv_libmpv_apple_set_pool(mpv_handle *ctx,
                              const mpv_libmpv_apple_pool_params *params)
{
    (void) ctx; // single-slot registry — handle is informational

    if (!params || params->num_images <= 0 || !params->images ||
        !params->acquire || !params->present ||
        params->width <= 0 || params->height <= 0 ||
        params->format == VK_FORMAT_UNDEFINED)
    {
        return MPV_ERROR_INVALID_PARAMETER;
    }

    pthread_mutex_lock(&pool_lock);
    pool_params = *params;
    pool_set = true;
    pthread_mutex_unlock(&pool_lock);
    return 0;
}

void mpv_libmpv_apple_clear_pool(mpv_handle *ctx)
{
    (void) ctx;
    pthread_mutex_lock(&pool_lock);
    memset(&pool_params, 0, sizeof(pool_params));
    pool_set = false;
    pthread_mutex_unlock(&pool_lock);
}

static bool pool_snapshot(mpv_libmpv_apple_pool_params *out)
{
    pthread_mutex_lock(&pool_lock);
    bool ok = pool_set;
    if (ok)
        *out = pool_params;
    pthread_mutex_unlock(&pool_lock);
    return ok;
}

// ─── ra_ctx ───────────────────────────────────────────────────────────────

struct priv {
    struct mpvk_ctx vk;
    mpv_libmpv_apple_pool_params pool;
};

// Thunks bridging libplacebo's `pl_vulkan_sem` (a {VkSemaphore, uint64_t}
// pair for timeline-semaphore compatibility) to the public ABI's plain
// `VkSemaphore`. Our headless swapchain only ever uses binary semaphores,
// so the timeline value is unused — unpack `.sem` and forward.

static bool acquire_thunk(void *priv, int *out_index)
{
    struct priv *p = priv;
    return p->pool.acquire(p->pool.priv, out_index);
}

static void present_thunk(void *priv, int index, pl_vulkan_sem sem_wait)
{
    struct priv *p = priv;
    p->pool.present(p->pool.priv, index, sem_wait.sem);
}

static void libmpv_uninit(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    if (!p)
        return;

    // Release Vulkan + ra_swapchain first — that completes any
    // in-flight pl_swapchain work and stops further acquire/present
    // callbacks. AFTER that quiesces, signal the host so it can drop
    // its retain on the pool's `priv` pointer.
    ra_vk_ctx_uninit(ctx);
    mpvk_uninit(&p->vk);

    if (p->pool.destroy)
        p->pool.destroy(p->pool.priv);
}

static bool libmpv_init(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv = talloc_zero(ctx, struct priv);
    int msgl = ctx->opts.probing ? MSGL_V : MSGL_ERR;

    if (!pool_snapshot(&p->pool)) {
        MP_MSG(ctx, msgl, "libmpvvk: no headless image pool registered "
                          "(call mpv_libmpv_apple_set_pool before vo_create)\n");
        goto fail;
    }

    // The host app brings up MoltenVK itself — that's how it gets to
    // allocate IOSurface-backed VkImages with VK_EXT_metal_objects.
    // We import its VkInstance/VkDevice into libplacebo here. mpvk_init
    // would create a *new* VkInstance, so we skip it; we still need a
    // pl_log so libplacebo's diagnostics route through mpv's logger.
    p->vk.pllog = mppl_log_create(p, ctx->vo->log);
    if (!p->vk.pllog) {
        MP_MSG(ctx, msgl, "libmpvvk: pl_log creation failed\n");
        goto fail;
    }
    mppl_log_set_probing(p->vk.pllog, false);

    p->vk.vulkan = pl_vulkan_import(p->vk.pllog, pl_vulkan_import_params(
        .instance              = p->pool.instance,
        .get_proc_addr         = p->pool.get_proc_addr,
        .phys_device           = p->pool.phys_device,
        .device                = p->pool.device,
        .queue_graphics        = {
            .index = p->pool.queue_family_index,
            .count = 1,
        },
        .extensions            = p->pool.device_extensions,
        .num_extensions        = p->pool.num_device_extensions,
        // libplacebo's required-features check inspects this struct
        // and rejects the device if any aren't present. The host app's
        // VkDevice MUST have been created with these enabled (see
        // pl_vulkan_required_features).
        .features              = &pl_vulkan_required_features,
    ));
    if (!p->vk.vulkan) {
        MP_MSG(ctx, msgl, "libmpvvk: pl_vulkan_import failed (likely a "
                          "required device feature is missing — see "
                          "pl_vulkan_required_features)\n");
        goto fail;
    }

    struct ra_ctx_params rcp = {0};
    struct pl_vulkan_headless_swapchain_params sw = {
        .num_images      = p->pool.num_images,
        .images           = p->pool.images,
        .format           = p->pool.format,
        .width            = p->pool.width,
        .height           = p->pool.height,
        .usage            = p->pool.usage,
        .swapchain_depth  = p->pool.swapchain_depth,
        .acquire          = acquire_thunk,
        .present          = present_thunk,
        .priv             = p,
        // Translate the public int-encoded color metadata into libplacebo
        // structs. Zero on either side is "unknown" — libplacebo handles
        // that with the same SDR BT.709 fallback we'd pick by hand.
        .color_repr      = (struct pl_color_repr) {
            .sys    = (enum pl_color_system) p->pool.color_system,
            .levels = PL_COLOR_LEVELS_FULL,
            .alpha  = PL_ALPHA_UNKNOWN,
        },
        .color_space     = (struct pl_color_space) {
            .primaries = (enum pl_color_primaries) p->pool.color_primaries,
            .transfer  = (enum pl_color_transfer) p->pool.color_transfer,
        },
    };

    if (!ra_vk_ctx_init_headless(ctx, &p->vk, rcp, &sw))
        goto fail;

    // vo_gpu_next reads vo->dwidth/dheight to set its render viewport.
    // For a windowed ra_ctx, the platform reports the size on first
    // reconfig — for headless we know it up-front (the pool dimensions
    // are fixed at create time), so seed it now to avoid the
    // "Window size: 1x1" first-frame degenerate path.
    ctx->vo->dwidth  = p->pool.width;
    ctx->vo->dheight = p->pool.height;

    return true;

fail:
    libmpv_uninit(ctx);
    return false;
}

static bool libmpv_reconfig(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    // Pool dimensions are fixed; tell mpv our render size matches.
    //
    // We deliberately do NOT route through `ra_vk_ctx_resize` here:
    // that helper calls `pl_swapchain_resize`, and libplacebo's
    // contract for swapchains without a `resize` impl is to zero the
    // out-params, which would clobber dwidth/dheight back to 0 before
    // the surrounding code reads them.
    ctx->vo->dwidth  = p->pool.width;
    ctx->vo->dheight = p->pool.height;
    return true;
}

static int libmpv_control(struct ra_ctx *ctx, int *events, int request, void *arg)
{
    (void) ctx; (void) events; (void) request; (void) arg;
    return VO_NOTIMPL;
}

const struct ra_ctx_fns ra_ctx_vulkan_libmpv = {
    .type        = "vulkan",
    .name        = "libmpvvk",
    .description = "Headless Vulkan via consumer-supplied VkImage pool (libmpv)",
    .reconfig    = libmpv_reconfig,
    .control     = libmpv_control,
    .init        = libmpv_init,
    .uninit      = libmpv_uninit,
};
