/* Copyright (C) 2026 the mpv-apple authors */

/*
 * Apple-platform extension to mpv's public render API.
 *
 * Provides a way to plug an externally-managed VkImage pool into the
 * `vo=gpu-next` / `gpu-context=libmpvvk` render path. Intended use is
 * embedding mpv in a media application where the platform's display
 * primitive (AVSampleBufferDisplayLayer / IOSurface on Apple) is
 * external to mpv and we want libplacebo's renderer to write frames
 * straight into it without going through a window/swapchain dance.
 *
 * Lifecycle:
 *   - Caller creates an mpv_handle via `mpv_create()` and configures it
 *     (`vo=gpu-next`, `gpu-api=vulkan`, `gpu-context=libmpvvk`,
 *     `mpv_initialize`).
 *   - Caller allocates a small pool of VkImages backed by the platform's
 *     surface primitive (e.g. IOSurfaces wrapped via VK_EXT_metal_objects).
 *   - Caller calls `mpv_libmpv_apple_set_pool` BEFORE the first
 *     `loadfile` / video-output creation. Calling it later is undefined.
 *   - During playback mpv invokes the `acquire` / `present` callbacks
 *     once per frame.
 *
 * The synchronisation contract mirrors the underlying libplacebo
 * `pl_vulkan_create_headless_swapchain`: `present` receives a binary
 * VkSemaphore which fires when the GPU is done writing. The caller
 * must wait on it (e.g. by importing it as an `MTLSharedEvent` and
 * waiting in the Metal command stream that hands the IOSurface to
 * AVSampleBufferDisplayLayer) before reading the underlying resource.
 *
 * Threading: the callbacks run on mpv's render thread.
 */

#ifndef MPV_RENDER_LIBMPV_APPLE_H_
#define MPV_RENDER_LIBMPV_APPLE_H_

#include <stdbool.h>
#include <stdint.h>

#include <vulkan/vulkan.h>

#include <mpv/client.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Color metadata for the swapchain images. Values match libplacebo's
 * pl_color_primaries and pl_color_transfer constants. We don't pull
 * libplacebo's headers into mpv's public surface — we forward as ints
 * and convert at the implementation site.
 */
typedef struct mpv_libmpv_apple_pool_params {
    /* Vulkan handles. The host app brings up MoltenVK itself — that's
     * what lets it allocate IOSurface-backed VkImages via
     * VK_EXT_metal_objects (mpv has no IOSurface lifecycle to drive).
     * mpv imports these into libplacebo via `pl_vulkan_import` rather
     * than creating its own VkDevice.
     *
     * The VkDevice MUST have been created with at least
     * `pl_vulkan_required_features` enabled (currently
     * VkPhysicalDeviceVulkan12Features.hostQueryReset and
     * .timelineSemaphore — chain via pNext into VkDeviceCreateInfo).
     * Without them, libplacebo's required-features check rejects the
     * import.
     *
     * Lifetime: handles must outlive the mpv_handle. (Required.)
     */
    VkInstance                instance;
    VkPhysicalDevice          phys_device;
    VkDevice                  device;
    PFN_vkGetInstanceProcAddr get_proc_addr; /* Optional; falls back to
                                                directly-linked vk loader. */
    uint32_t                  queue_family_index; /* Must support GRAPHICS_BIT. */
    uint32_t                  queue_index;        /* Within `queue_family_index`. */

    /* Optional: device-level extensions the host enabled at
     * vkCreateDevice. Forwarded to `pl_vulkan_import_params.extensions`
     * so libplacebo loads matching function pointers (e.g.
     * VK_EXT_external_memory_metal). */
    const char * const       *device_extensions;
    int                       num_device_extensions;

    /* Pool of VkImages the swapchain hands out via `acquire`. The host
     * is responsible for `vkDestroyImage` on each entry; the lifetime
     * must outlast the mpv_handle.
     *
     * Each image must have been created on `device` (above) with
     * identical `format`/`width`/`height`/`usage` and must include at
     * least VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
     * VK_IMAGE_USAGE_TRANSFER_DST_BIT in `usage`.
     */
    int       num_images;
    VkImage  *images;

    VkFormat          format;
    int               width;
    int               height;
    VkImageUsageFlags usage;

    /* Color metadata. Encoded as the integer values of libplacebo's
     * pl_color_primaries / pl_color_transfer / pl_color_system enums.
     * Pass 0 (PL_COLOR_PRIM_UNKNOWN / PL_COLOR_TRC_UNKNOWN /
     * PL_COLOR_SYSTEM_UNKNOWN) to fall back to SDR BT.709 defaults. */
    int color_primaries;
    int color_transfer;
    int color_system;

    /* Maximum number of in-flight frames before mpv's render thread is
     * back-pressured. Optional — defaults to 2. */
    int swapchain_depth;

    /* Per-frame callbacks. See `pl_vulkan_create_headless_swapchain` for
     * the full semantics — the parameters are forwarded 1:1. */
    bool (*acquire)(void *priv, int *out_index);
    void (*present)(void *priv, int index, VkSemaphore sem_wait);
    void *priv;
} mpv_libmpv_apple_pool_params;

/**
 * Register a headless VkImage pool with the gpu-context=libmpvvk render
 * path. Must be called after `mpv_initialize` and before the first
 * `loadfile`. Subsequent calls replace the previously-registered pool.
 *
 * Returns 0 on success, MPV_ERROR_INVALID_PARAMETER on validation
 * failure.
 */
int mpv_libmpv_apple_set_pool(mpv_handle *ctx,
                              const mpv_libmpv_apple_pool_params *params);

/**
 * Clear the registered pool. Idempotent. Called automatically when the
 * mpv_handle is destroyed; consumers normally don't need this directly.
 */
void mpv_libmpv_apple_clear_pool(mpv_handle *ctx);

#ifdef __cplusplus
}
#endif

#endif /* MPV_RENDER_LIBMPV_APPLE_H_ */
