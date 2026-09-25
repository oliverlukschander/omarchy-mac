echo "Restore the Apple GPU's Vulkan driver after the Mesa 26.2 split"

# Mesa 26.2 moved the Asahi Vulkan ICD out of mesa into vulkan-asahi. Macs whose
# update replaced mesa without it lost Vulkan silently (#470). While an older
# mesa still provides vulkan-asahi, Vulkan works and there is nothing to do; the
# omarchy-mac dependency pulls the split package into that later upgrade.
omarchy-hw-apple-silicon || exit 0
omarchy-pkg-available vulkan-asahi || exit 0
omarchy-pkg-present vulkan-asahi && exit 0
omarchy-pkg-add vulkan-asahi
