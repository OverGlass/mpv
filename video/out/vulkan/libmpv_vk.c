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
 * - This backend is HEADLESS: there is no swapchain. The API user supplies a
 *   single VkImage per frame via MPV_RENDER_PARAM_VULKAN_TARGET_IMAGE. mpv
 *   wraps it as a pl_tex via pl_vulkan_wrap, hands a ra_tex to the renderer,
 *   and submits the frame via pl_gpu_finish/pl_gpu_submit.
 * - Unlike the existing ra_vk_ctx (which assumes a presentation surface), we
 *   construct pl_vulkan directly from the user's handles and wrap pl_gpu as a
 *   plain mpv `ra` via ra_create_pl. This keeps the swapchain path out of our
 *   way.
 * - Either all of {vk_instance, vk_physical_device, vk_device} are supplied
 *   together (libplacebo "import" path) or none (libplacebo creates them).
 *   Mixed states are an error.
 *
 * Implementation status (apple/main first commit)
 * -----------------------------------------------
 * Public API surface (mpv_vulkan_init_params, mpv_vulkan_target_image,
 * MPV_RENDER_API_TYPE_VK, MPV_RENDER_PARAM_VULKAN_*) is the contract Phase 1
 * Swift work depends on; that surface is fixed.
 *
 * The init/wrap_fbo/done_frame/destroy bodies are stubs that return
 * MPV_ERROR_NOT_IMPLEMENTED with a clear log message. Filling them in
 * requires the fork's build (Phase 0a) to be far enough along that we can
 * compile-check against libplacebo, and a follow-up commit will land the
 * real bodies. Keeping the stubs signals "this API exists but is not yet
 * functional" honestly, instead of half-working code that compiles cleanly
 * but produces black frames.
 */

#include "config.h"

#include "common/common.h"
#include "common/msg.h"
#include "mpv/render_vk.h"
#include "video/out/gpu/libmpv_gpu.h"
#include "video/out/libmpv.h"

struct priv {
    mpv_vulkan_init_params init_params;
    /* TODO(apple/main follow-up): pl_log, pl_vk_inst, pl_vulkan, ra* live here. */
    void *placebo_log;
    void *placebo_vk_inst;
    void *placebo_vulkan;
    void *ra;
};

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

    /* Either all of {instance, physical_device, device} or none. */
    int supplied = (init_params->vk_instance ? 1 : 0)
                 + (init_params->vk_physical_device ? 1 : 0)
                 + (init_params->vk_device ? 1 : 0);
    if (supplied != 0 && supplied != 3) {
        MP_FATAL(ctx, "Either all of vk_instance/vk_physical_device/vk_device "
                      "must be supplied, or none of them.\n");
        return MPV_ERROR_INVALID_PARAMETER;
    }

    p->init_params = *init_params;

    /* TODO(apple/main follow-up): build pl_log, pl_vk_inst, pl_vulkan via
     * libplacebo's import path; call ra_create_pl(pl_vulkan->gpu, log) and
     * stash the ra in ctx->ra_ctx so the surrounding render_backend_gpu can
     * drive it. */
    MP_WARN(ctx, "Vulkan render API backend is not yet implemented in this "
                 "fork commit — public API surface is locked but rendering "
                 "is a no-op. Track follow-up at apple/main.\n");
    return MPV_ERROR_NOT_IMPLEMENTED;
}

static int wrap_fbo(struct libmpv_gpu_context *ctx, mpv_render_param *params,
                    struct ra_tex **out)
{
    mpv_vulkan_target_image *target =
        get_mpv_render_param(params, MPV_RENDER_PARAM_VULKAN_TARGET_IMAGE, NULL);
    if (!target) {
        MP_FATAL(ctx, "MPV_RENDER_PARAM_VULKAN_TARGET_IMAGE is required for "
                      "Vulkan render targets.\n");
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

    /* TODO(apple/main follow-up): pl_vulkan_wrap(target->image, target->format,
     * target->width, target->height) -> pl_tex; mppl_wrap_tex -> ra_tex. */
    (void)out;
    return MPV_ERROR_NOT_IMPLEMENTED;
}

static void done_frame(struct libmpv_gpu_context *ctx, bool display_synced)
{
    /* TODO(apple/main follow-up): pl_gpu_finish (sync) or pl_gpu_submit (async)
     * + transition the wrapped image back to target->final_layout. */
    (void)ctx;
    (void)display_synced;
}

static void destroy(struct libmpv_gpu_context *ctx)
{
    struct priv *p = ctx->priv;
    if (!p)
        return;
    /* TODO(apple/main follow-up): teardown order is ra → pl_vulkan →
     * pl_vk_inst → pl_log; only destroy what we created (skip user-supplied
     * VkInstance/VkDevice). */
}

const struct libmpv_gpu_context_fns libmpv_gpu_context_vk = {
    .api_name = MPV_RENDER_API_TYPE_VK,
    .init = init,
    .wrap_fbo = wrap_fbo,
    .done_frame = done_frame,
    .destroy = destroy,
};
