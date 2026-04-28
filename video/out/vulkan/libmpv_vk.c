/*
 * libmpv_vk.c — context backend for MPV_RENDER_API_TYPE_VK.
 *
 * mpv-apple fork extension. Implements `libmpv_gpu_context_vk`, plugged into
 * the existing `render_backend_gpu` / `libmpv_gpu_context_*` machinery in
 * video/out/gpu/libmpv_gpu.c. The renderer is libplacebo-on-Vulkan; the API
 * user owns the VkInstance/VkDevice/VkImage.
 *
 * Design notes
 * ------------
 * - Headless: there is no swapchain. The API user supplies a single VkImage
 *   per frame via MPV_RENDER_PARAM_VULKAN_TARGET_IMAGE. mpv wraps it as a
 *   pl_tex via pl_vulkan_wrap, hands a ra_tex to the surrounding renderer,
 *   and submits the frame via pl_gpu_finish at done_frame() time.
 * - Unlike the existing ra_vk_ctx (which assumes a presentation surface), we
 *   construct pl_vulkan from the user's pre-created VkInstance / VkDevice
 *   via pl_vulkan_import and wrap pl_gpu as a plain mpv `ra` via
 *   ra_create_pl. This keeps the swapchain path out of our way.
 * - The renderer expects ctx->ra_ctx to be a populated `struct ra_ctx`. We
 *   allocate one and set its `.ra` / `.log` / `.global` fields; the rest
 *   stays zero (no swapchain, no fns, no spirv — the libmpv_gpu code path
 *   never calls into them for the headless case).
 */

#include "config.h"

#include "common/common.h"
#include "common/msg.h"
#include "mpv/render_vk.h"
#include "video/out/gpu/context.h"
#include "video/out/gpu/libmpv_gpu.h"
#include "video/out/libmpv.h"
#include "video/out/placebo/ra_pl.h"

#include <libplacebo/log.h>
#include <libplacebo/vulkan.h>

struct priv {
    pl_log pllog;
    pl_vulkan vulkan;
    struct ra_ctx *ra_ctx;
    pl_tex cur_target; // wrapped per-frame, freed in done_frame
};

// ─── Bridge mpv's mp_log to libplacebo's pl_log_cb ────────────────────────────

static void pl_log_to_mpv(void *ctx, enum pl_log_level level, const char *msg)
{
    struct mp_log *log = ctx;
    int mp_level;
    switch (level) {
    case PL_LOG_FATAL: mp_level = MSGL_FATAL; break;
    case PL_LOG_ERR:   mp_level = MSGL_ERR;   break;
    case PL_LOG_WARN:  mp_level = MSGL_WARN;  break;
    case PL_LOG_INFO:  mp_level = MSGL_V;     break;
    case PL_LOG_DEBUG: mp_level = MSGL_DEBUG; break;
    case PL_LOG_TRACE: mp_level = MSGL_TRACE; break;
    default:           mp_level = MSGL_V;     break;
    }
    mp_msg(log, mp_level, "[placebo] %s\n", msg);
}

// ─── Lifecycle ────────────────────────────────────────────────────────────────

static int init(struct libmpv_gpu_context *ctx, mpv_render_param *params)
{
    ctx->priv = talloc_zero(NULL, struct priv);
    struct priv *p = ctx->priv;

    mpv_vulkan_init_params *init_params =
        get_mpv_render_param(params, MPV_RENDER_PARAM_VULKAN_INIT_PARAMS, NULL);
    if (!init_params || !init_params->get_proc_address) {
        MP_FATAL(ctx, "MPV_RENDER_PARAM_VULKAN_INIT_PARAMS is required and "
                      "must supply get_proc_address.\n");
        return MPV_ERROR_INVALID_PARAMETER;
    }
    if (!init_params->vk_instance || !init_params->vk_physical_device ||
        !init_params->vk_device)
    {
        MP_FATAL(ctx, "vk_instance, vk_physical_device, and vk_device must "
                      "all be supplied. Pre-creation by the API user is "
                      "currently required (libplacebo-managed creation is a "
                      "follow-up).\n");
        return MPV_ERROR_INVALID_PARAMETER;
    }

    p->pllog = pl_log_create(PL_API_VER, pl_log_params(
        .log_cb    = pl_log_to_mpv,
        .log_priv  = ctx->log,
        .log_level = init_params->debug ? PL_LOG_DEBUG : PL_LOG_INFO,
    ));
    if (!p->pllog) {
        MP_FATAL(ctx, "pl_log_create failed.\n");
        return MPV_ERROR_UNSUPPORTED;
    }

    struct pl_vulkan_import_params import = {
        .instance     = init_params->vk_instance,
        .get_proc_addr = init_params->get_proc_address,
        .phys_device  = init_params->vk_physical_device,
        .device       = init_params->vk_device,
        .queue_graphics = {
            .index = init_params->queue_family_index,
            .count = 1,
        },
        // graphics queue can act as transfer/compute fallback; libplacebo
        // detects this when queue_compute / queue_transfer are zeroed.
    };

    p->vulkan = pl_vulkan_import(p->pllog, &import);
    if (!p->vulkan) {
        MP_FATAL(ctx, "pl_vulkan_import failed (likely a missing required "
                      "device feature — see pl_vulkan_required_features).\n");
        pl_log_destroy(&p->pllog);
        return MPV_ERROR_UNSUPPORTED;
    }

    struct ra *ra = ra_create_pl(p->vulkan->gpu, ctx->log);
    if (!ra) {
        MP_FATAL(ctx, "ra_create_pl failed.\n");
        pl_vulkan_destroy(&p->vulkan);
        pl_log_destroy(&p->pllog);
        return MPV_ERROR_UNSUPPORTED;
    }

    p->ra_ctx = talloc_zero(p, struct ra_ctx);
    p->ra_ctx->log    = ctx->log;
    p->ra_ctx->global = ctx->global;
    p->ra_ctx->ra     = ra;
    // No swapchain, no ra_ctx_fns, no spirv. The headless render-API path
    // doesn't reach into any of those.

    ctx->ra_ctx = p->ra_ctx;
    return 0;
}

static int wrap_fbo(struct libmpv_gpu_context *ctx, mpv_render_param *params,
                    struct ra_tex **out)
{
    struct priv *p = ctx->priv;

    mpv_vulkan_target_image *target =
        get_mpv_render_param(params, MPV_RENDER_PARAM_VULKAN_TARGET_IMAGE, NULL);
    if (!target) {
        MP_FATAL(ctx, "MPV_RENDER_PARAM_VULKAN_TARGET_IMAGE is required.\n");
        return MPV_ERROR_INVALID_PARAMETER;
    }
    if (target->image == VK_NULL_HANDLE) {
        MP_FATAL(ctx, "Vulkan target image handle is null.\n");
        return MPV_ERROR_INVALID_PARAMETER;
    }
    if (target->width == 0 || target->height == 0) {
        MP_FATAL(ctx, "Vulkan target image has zero dimensions.\n");
        return MPV_ERROR_INVALID_PARAMETER;
    }

    // Drop any previously-wrapped target — they're per-frame.
    if (p->cur_target) {
        pl_tex_destroy(p->vulkan->gpu, &p->cur_target);
    }

    p->cur_target = pl_vulkan_wrap(p->vulkan->gpu, pl_vulkan_wrap_params(
        .image  = target->image,
        .width  = (int)target->width,
        .height = (int)target->height,
        .format = target->format,
        // The renderer needs to write to the target as a color attachment
        // and may want to read from it for damage tracking; advertise both.
        .usage  = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT
                | VK_IMAGE_USAGE_TRANSFER_DST_BIT
                | VK_IMAGE_USAGE_TRANSFER_SRC_BIT
                | VK_IMAGE_USAGE_SAMPLED_BIT,
    ));
    if (!p->cur_target) {
        MP_FATAL(ctx, "pl_vulkan_wrap failed for target image.\n");
        return MPV_ERROR_UNSUPPORTED;
    }

    struct ra_tex *out_tex = talloc_zero(p, struct ra_tex);
    if (!mppl_wrap_tex(p->ra_ctx->ra, p->cur_target, out_tex)) {
        MP_FATAL(ctx, "mppl_wrap_tex failed.\n");
        pl_tex_destroy(p->vulkan->gpu, &p->cur_target);
        talloc_free(out_tex);
        return MPV_ERROR_UNSUPPORTED;
    }

    *out = out_tex;
    return 0;
}

static void done_frame(struct libmpv_gpu_context *ctx, bool display_synced)
{
    struct priv *p = ctx->priv;
    // Block until the GPU has finished this frame's submitted work. The API
    // user submitted a VkImage they own; they must be able to use it
    // (e.g. wrap it in a CMSampleBuffer) immediately when render() returns.
    // Async submission is a future optimization (would need fences exposed
    // through the public API).
    if (p->vulkan)
        pl_gpu_finish(p->vulkan->gpu);
    (void)display_synced;
}

static void destroy(struct libmpv_gpu_context *ctx)
{
    struct priv *p = ctx->priv;
    if (!p)
        return;
    if (p->cur_target)
        pl_tex_destroy(p->vulkan->gpu, &p->cur_target);
    // ra is owned by ra_ctx (talloc-parented to p). It tears down on
    // talloc_free below. ra_create_pl doesn't take ownership of pl_gpu, so
    // pl_vulkan_destroy after that is safe.
    if (p->vulkan)
        pl_vulkan_destroy(&p->vulkan);
    if (p->pllog)
        pl_log_destroy(&p->pllog);
    talloc_free(p);
    ctx->priv = NULL;
}

const struct libmpv_gpu_context_fns libmpv_gpu_context_vk = {
    .api_name  = MPV_RENDER_API_TYPE_VK,
    .init      = init,
    .wrap_fbo  = wrap_fbo,
    .done_frame = done_frame,
    .destroy   = destroy,
};
