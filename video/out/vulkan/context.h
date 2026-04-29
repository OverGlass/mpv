#pragma once

#include <libplacebo/vulkan.h>

#include "video/out/gpu/context.h"
#include "common.h"

// Helpers for ra_ctx based on ra_vk. These initialize ctx->ra and ctx->swchain.
void ra_vk_ctx_uninit(struct ra_ctx *ctx);
bool ra_vk_ctx_init(struct ra_ctx *ctx, struct mpvk_ctx *vk,
                    struct ra_ctx_params params,
                    VkPresentModeKHR preferred_mode);

// Headless variant of `ra_vk_ctx_init` for ra_ctx implementations that
// don't have a VkSurfaceKHR. Performs the same VkDevice + ra_create_pl
// dance, but creates a headless `pl_swapchain` (one that hands out
// pre-allocated VkImages via callbacks) instead of a surface-bound
// swapchain. The caller owns `sw_params->images` for the swapchain's
// lifetime; everything else (queue setup, `pl_vulkan` import,
// `ra_swapchain` wrapper) is identical to the surface path.
bool ra_vk_ctx_init_headless(struct ra_ctx *ctx, struct mpvk_ctx *vk,
                             struct ra_ctx_params params,
                             const struct pl_vulkan_headless_swapchain_params *sw_params);

// Helper for initializing mpvk_ctx->vulkan
pl_vulkan mppl_create_vulkan(struct vulkan_opts *opts,
                             pl_vk_inst vkinst,
                             pl_log pllog,
                             VkSurfaceKHR surface,
                             bool allow_software);

// Handles a resize request, and updates ctx->vo->dwidth/dheight
bool ra_vk_ctx_resize(struct ra_ctx *ctx, int width, int height);

// May be called on a ra_ctx of any type.
struct mpvk_ctx *ra_vk_ctx_get(struct ra_ctx *ctx);

// Get the user requested Vulkan device name.
char *ra_vk_ctx_get_device_name(struct ra_ctx *ctx);
