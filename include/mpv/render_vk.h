/* Copyright (C) 2026 the mpv-apple developers
 *
 * Permission to use, copy, modify, and/or distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

#ifndef MPV_CLIENT_API_RENDER_VK_H_
#define MPV_CLIENT_API_RENDER_VK_H_

#include <vulkan/vulkan_core.h>

#include "render.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Vulkan backend
 * --------------
 *
 * This header contains definitions for using Vulkan with the render.h API.
 * The backend is built around libplacebo's Vulkan target, and is intended for
 * embedding mpv into an externally-managed Vulkan or Metal pipeline (e.g.
 * iOS/Catalyst apps that bridge to Metal via MoltenVK).
 *
 * Unlike the OpenGL backend, the Vulkan backend does NOT own a presentation
 * surface. There is no swapchain. The API user supplies a single VkImage per
 * frame (typically backed by an IOSurface, MTLTexture, or similar) and the
 * renderer writes the composited video frame into it. Presentation, vsync,
 * and any final compositing live entirely on the user side.
 *
 * Threading
 * ---------
 *
 * The general render.h threading rules apply. In addition:
 *
 * - mpv_render_context_render() must be called from a thread that holds
 *   exclusive access to the supplied VkDevice. If the API user shares the
 *   device with their own code, they must externally synchronize.
 * - mpv may submit command buffers on the supplied graphics-capable queue.
 *   The queue must support graphics + transfer operations.
 *
 * API use
 * -------
 *
 * Use mpv_render_context_create() with MPV_RENDER_PARAM_API_TYPE set to
 * MPV_RENDER_API_TYPE_VK and MPV_RENDER_PARAM_VULKAN_INIT_PARAMS provided.
 *
 * Call mpv_render_context_render() with MPV_RENDER_PARAM_VULKAN_TARGET_IMAGE
 * to render the video frame to a user-supplied VkImage.
 *
 * Hardware decoding
 * -----------------
 *
 * Hardware decoding via this API is fully supported on platforms whose hwdec
 * back-end can interop with Vulkan:
 *
 * - macOS / iOS / Catalyst / tvOS: VideoToolbox decode produces a
 *   CVPixelBuffer backed by IOSurface; the API user wraps the IOSurface as a
 *   VkImage via VK_EXT_metal_objects (preferred) or vkUseIOSurfaceMVK
 *   (older MoltenVK). The "hwdec" property accepts "videotoolbox" without a
 *   "-copy" suffix.
 * - Other platforms: Vulkan-native hwdec (e.g. NVDEC interop) follows the
 *   existing internal hwdec_vulkan paths.
 */

/**
 * For initializing the mpv Vulkan state via MPV_RENDER_PARAM_VULKAN_INIT_PARAMS.
 *
 * If `vk_instance`, `vk_physical_device`, and `vk_device` are all non-NULL the
 * renderer will reuse them via libplacebo's import path; otherwise libplacebo
 * creates the missing handles itself. When the API user pre-creates them, the
 * device must have been created with at least the queue family supplied in
 * `queue_family_index` and a graphics-capable queue at `queue_index`.
 */
typedef struct mpv_vulkan_init_params {
    /**
     * Function-pointer loader. mpv calls this through libplacebo to resolve
     * Vulkan entry points; libmpv does not link to a Vulkan loader itself.
     * Typically the address of vkGetInstanceProcAddr.
     */
    PFN_vkGetInstanceProcAddr get_proc_address;

    /**
     * Optional. If non-NULL, mpv reuses the supplied VkInstance instead of
     * creating one. The instance must have been created with the extensions
     * libplacebo expects (VK_KHR_get_physical_device_properties2 and any
     * platform-required surface extensions if the API user wants to use
     * pl_vulkan_create_swapchain on top — not required for the headless path).
     */
    VkInstance vk_instance;

    /**
     * Optional. If non-NULL, mpv targets the supplied VkPhysicalDevice
     * instead of auto-selecting one. Ignored when `vk_instance` is NULL.
     */
    VkPhysicalDevice vk_physical_device;

    /**
     * Optional. If non-NULL, mpv reuses the supplied VkDevice instead of
     * creating one. Requires `vk_instance` and `vk_physical_device` to also
     * be supplied. The device must enable VK_KHR_external_memory and any
     * extensions needed for the chosen image-import path
     * (VK_EXT_metal_objects for IOSurface on Apple platforms).
     */
    VkDevice vk_device;

    /**
     * Queue family index the renderer may submit work on. Must support
     * graphics and transfer. Ignored when `vk_device` is NULL.
     */
    uint32_t queue_family_index;

    /**
     * Index within `queue_family_index` of a queue the renderer may use.
     * Ignored when `vk_device` is NULL.
     */
    uint32_t queue_index;

    /**
     * If set to 1 the renderer enables Vulkan validation layers (when
     * available). For debug builds only — leaks performance on release.
     */
    int debug;
} mpv_vulkan_init_params;

/**
 * For MPV_RENDER_PARAM_VULKAN_TARGET_IMAGE.
 *
 * The VkImage is application-owned. mpv neither destroys nor reallocates it,
 * and assumes the supplied `layout` on entry. On return, mpv leaves the image
 * in `final_layout` (defaults to VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL when
 * left as VK_IMAGE_LAYOUT_UNDEFINED).
 */
typedef struct mpv_vulkan_target_image {
    /**
     * The VkImage handle to render into. Must have been created with
     * VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT and
     * VK_IMAGE_USAGE_TRANSFER_DST_BIT, and a format compatible with the
     * value supplied in `format`.
     */
    VkImage image;

    /**
     * The VkFormat of `image`. Used to negotiate the render pipeline's color
     * format. Common Apple-platform values:
     *   - VK_FORMAT_B8G8R8A8_UNORM       (8-bit SDR display-P3 / sRGB)
     *   - VK_FORMAT_A2B10G10R10_UNORM_PACK32  (10-bit HDR target via EDR)
     *   - VK_FORMAT_R16G16B16A16_SFLOAT  (extended-range float, EDR-friendly)
     */
    VkFormat format;

    /**
     * Image dimensions in pixels. Must match the VkImage's actual extent.
     */
    uint32_t width, height;

    /**
     * The VkImageLayout the image is in when render() is called. The
     * renderer transitions the image as needed for color-attachment writes
     * and transitions back to `final_layout` before returning.
     */
    VkImageLayout layout;

    /**
     * The VkImageLayout the image must be left in when render() returns.
     * Pass VK_IMAGE_LAYOUT_UNDEFINED to accept the renderer's default
     * (VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL).
     */
    VkImageLayout final_layout;
} mpv_vulkan_target_image;

#ifdef __cplusplus
}
#endif

#endif
